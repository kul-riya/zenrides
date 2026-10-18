import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'maps_bridge.dart';
import 'ride_api.dart';

enum RideTab { hud, pack, toll, tours }

enum NoticeKind { pack, fuel, chai, hazard, slow, regroup, sos }

class RideNotice {
  const RideNotice({required this.kind, required this.kicker, required this.body});

  final NoticeKind kind;
  final String kicker;
  final String body;
}

class PackRow {
  const PackRow({
    required this.id,
    required this.name,
    required this.role,
    required this.you,
    required this.km,
    required this.ahead,
    required this.online,
    required this.dropping,
    required this.breaking,
  });

  final String id;
  final String name;
  final String role;
  final bool you;
  final double km;
  final bool ahead;
  final bool online;
  final bool dropping;
  final bool breaking;
}

class MapRider {
  const MapRider({
    required this.id,
    required this.name,
    required this.point,
    required this.you,
    required this.shared,
    required this.breaking,
    required this.mark,
  });

  final String id;
  final String name;
  final LatLng point;
  final bool you;
  final bool shared;
  final bool breaking;

  /// Palette slot for other riders. YOU does not use one.
  final int mark;
}

enum HaltKind { start, finish, stop, dayEnd }

enum PlanSlot { start, finish, dayEnd, stop }

class RideHalt {
  const RideHalt({
    required this.id,
    required this.name,
    required this.point,
    this.day = 1,
    this.kind = HaltKind.stop,
  });

  final String id;
  final String name;
  final LatLng point;
  final int day;
  final HaltKind kind;
}

class DaySummary {
  const DaySummary({
    required this.km,
    required this.elapsed,
    required this.stayed,
    required this.reached,
  });

  final double km;
  final Duration elapsed;
  final List<String> stayed;
  final bool reached;
}

class RideController extends ChangeNotifier {
  RideController({RideApi? api, DateTime Function()? clock, this._network = true})
      : _api = api ?? RideApi(),
        _clock = clock ?? DateTime.now {
    dayStarted = _clock();
  }

  static const riderMarkCount = 6;
  static const overviewZoom = 14.0;
  static const recenterZoom = 15.0;
  static const groupCode = 'ZEN-4365';
  static const staleAfter = Duration(seconds: 12);
  static const dropKm = 0.5;

  static const parked = LatLng(18.3706, 73.8540);

  final RideApi _api;
  final DateTime Function() _clock;
  final bool _network;
  final Distance _distance = const Distance();

  Timer? _motion;
  Timer? _sync;
  Timer? _hazards;
  Timer? _searchDebounce;
  int _searchGeneration = 0;
  int _planSearchGeneration = 0;
  StreamSubscription<Position>? _gpsWatch;
  bool _started = false;

  RideTab tab = RideTab.hud;
  bool ended = false;
  bool paused = false;
  bool showOthers = true;
  bool picking = false;
  bool planning = false;
  bool onRide = true;
  bool admin = false;
  int tripDays = 1;
  int ridingDay = 1;
  int draftDays = 1;
  int planDay = 1;
  int planFit = 0;
  PlanSlot planSlot = PlanSlot.stop;
  String startName = '';
  String finishName = '';
  String draftStartName = '';
  String draftFinishName = '';
  String planNote = '';
  String joinNote = '';
  String shareNote = '';
  int _planUpdatedAt = 0;
  LatLng? startPoint;
  LatLng? finishPoint;
  LatLng? draftStart;
  LatLng? draftFinish;
  List<RideHalt> draftHalts = [];
  List<PlaceHit> planHits = [];
  bool fuelOn = false;
  bool gpsSeeking = false;
  bool gpsLocked = false;
  String riderId = 'you';
  String riderName = 'Joe';
  String code = groupCode;
  String gpsReason = '';
  String fuelNote = '';
  String searchNote = '';
  String destinationName = '';
  List<PlaceHit> suggestions = [];
  List<RouteChoice> routes = [];
  int selectedRoute = 0;
  int pumpFit = 0;
  int routeFit = 0;
  int navFit = 0;
  bool navigating = false;
  bool navArrived = false;
  int stepIndex = 0;
  double navKm = 0;
  double traveledKm = 0;
  double cruiseKmh = 62;
  int arrived = 0;
  DateTime? dayStarted;
  DateTime? gpsAt;
  LatLng? gpsFix;
  double? _course;
  RideNotice? notice;
  SosFix? sos;
  String? _dismissedSosId;
  DateTime? _dismissedSosAt;
  DaySummary? summary;
  List<RideHalt> halts = [];
  List<FuelPump> pumps = [];
  List<RoadHazard> roadHazards = [];
  List<String> hazardFailures = [];
  final List<FuelPump> _areaPumps = [];
  int _fuelGeneration = 0;
  final Map<String, DateTime> _holdUntil = {};
  final Set<String> removed = {};
  final Map<String, RemoteRider> remote = {};

  double get routeKm {
    final drive = chosen;
    if (drive == null || (roadFitsSomeDay && !roadFitsDay)) return 0;
    return drive.distanceMeters > 0 ? drive.distanceMeters / 1000 : _lengthKm(drive.points);
  }

  LatLng get you => gpsFix ?? startPoint ?? parked;

  RouteChoice? get chosen {
    if (routes.isEmpty) return null;
    final index = selectedRoute.clamp(0, routes.length - 1);
    return routes[index];
  }

  double get remainingKm {
    final drive = chosen;
    if (drive == null) return 0;
    final length = drive.distanceMeters > 0 ? drive.distanceMeters / 1000 : _lengthKm(drive.points);
    if (gpsFix != null) return _remainingAlong(drive.points, you);
    return length;
  }

  int get remainingMinutes {
    final drive = chosen;
    if (drive == null) return 0;
    final length = drive.distanceMeters > 0 ? drive.distanceMeters / 1000 : _lengthKm(drive.points);
    if (length <= 0) return 0;
    final seconds = drive.durationSeconds > 0 ? drive.durationSeconds * (remainingKm / length) : remainingKm / cruiseKmh * 3600;
    return max(1, (seconds / 60).round());
  }

  String get arrivalLabel {
    final at = _clock().add(Duration(minutes: remainingMinutes));
    final hour = at.hour % 12 == 0 ? 12 : at.hour % 12;
    final minute = at.minute.toString().padLeft(2, '0');
    final suffix = at.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $suffix';
  }

  RouteStep? get nextStep {
    final drive = chosen;
    if (drive == null || drive.steps.isEmpty) return null;
    final index = stepIndex.clamp(0, drive.steps.length - 1);
    return drive.steps[index];
  }

  double? get nearestPumpMeters {
    if (!navigating) return null;
    final drive = chosen;
    if (drive == null || pumps.isEmpty) return null;
    final hereKm = gpsFix != null ? _traveledAlong(drive.points, you) : 0.0;
    double? best;
    for (final pump in pumps) {
      final ahead = (_traveledAlong(drive.points, pump.point) - hereKm) * 1000;
      if (ahead < -80) continue;
      final gap = max(0.0, ahead);
      if (best == null || gap < best) best = gap;
    }
    return best;
  }

  double get bearing {
    final drive = chosen;
    if (!navigating || drive == null || drive.points.length < 2) return 0;
    return _headingAlong(drive.points, you);
  }

  /// Degrees clockwise from north, along the way the rider is moving.
  double get travelHeading {
    if (!ended && gpsLocked && _course != null) return _course!;
    final drive = chosen;
    if (navigating && gpsFix != null && drive != null && drive.points.length >= 2) {
      return _headingAlong(drive.points, you);
    }
    return _course ?? 0;
  }

  bool get youBreaking => _holding('you');

  List<PackRow> get packRows {
    final now = _clock();
    final rows = <PackRow>[
      PackRow(
        id: riderId,
        name: riderName,
        role: 'Lead Pilot',
        you: true,
        km: 0,
        ahead: false,
        online: !ended,
        dropping: false,
        breaking: youBreaking,
      ),
    ];
    for (final rider in remote.values) {
      if (removed.contains(rider.id) || rider.id == riderId) continue;
      final km = _distance.as(LengthUnit.Kilometer, you, LatLng(rider.lat, rider.lng));
      rows.add(PackRow(
        id: rider.id,
        name: rider.name,
        role: 'Pack rider',
        you: false,
        km: km,
        ahead: false,
        online: now.difference(rider.updatedAt) <= staleAfter,
        dropping: km > dropKm,
        breaking: false,
      ));
    }
    return rows;
  }

  List<MapRider> get mapRiders {
    final pins = <MapRider>[
      MapRider(id: riderId, name: 'YOU', point: you, you: true, shared: false, breaking: youBreaking, mark: -1),
    ];
    if (!showOthers) return pins;
    final used = <int>{};
    for (final rider in remote.values) {
      if (removed.contains(rider.id) || rider.id == riderId) continue;
      pins.add(MapRider(
        id: rider.id,
        name: rider.name,
        point: LatLng(rider.lat, rider.lng),
        you: false,
        shared: true,
        breaking: false,
        mark: _claimMark(rider.id, used),
      ));
    }
    return pins;
  }

  List<RoadHazard> get nearbyHazards {
    return [
      for (final hazard in roadHazards)
        if (hazard.point == null || kmTo(hazard.point!) <= 2) hazard,
    ];
  }

  SosFix? get visibleSos {
    final alert = sos;
    if (alert == null || removed.contains(alert.id)) return null;
    return alert;
  }

  List<String> get chaiNames {
    final names = <String>[];
    if (youBreaking) names.add(riderName);
    for (final row in packRows) {
      if (!row.you && row.breaking) names.add(row.name);
    }
    return names;
  }

  RideHalt? get nextHalt {
    final todays = [
      for (final halt in halts)
        if (halt.day == ridingDay && halt.kind != HaltKind.start && halt.kind != HaltKind.finish) halt,
    ];
    if (todays.isEmpty) return null;
    RideHalt? best;
    var bestKm = double.infinity;
    for (final halt in todays) {
      final km = _distance.as(LengthUnit.Kilometer, you, halt.point);
      if (km < bestKm) {
        best = halt;
        bestKm = km;
      }
    }
    return best;
  }

  bool get todayHasPlan => halts.any((halt) => halt.day == ridingDay);

  List<RideHalt> get visibleHalts {
    final stops = planning ? draftHalts : halts;
    final start = planning ? draftStart : startPoint;
    final finish = planning ? draftFinish : finishPoint;
    final from = planning ? draftStartName : startName;
    final to = planning ? draftFinishName : finishName;
    return [
      if (start != null)
        RideHalt(id: 'plan-start', name: from.isEmpty ? 'Start' : from, point: start, day: 0, kind: HaltKind.start),
      ...stops,
      if (finish != null)
        RideHalt(id: 'plan-finish', name: to.isEmpty ? 'Finish' : to, point: finish, day: 0, kind: HaltKind.finish),
    ];
  }

  /// The road for the day shown on the map. Uses the driving line when it
  /// starts on this day and ends on one of this day's places.
  List<LatLng> get shownRoute {
    final marks = _dayMarks(planning ? planDay : ridingDay, draft: planning);
    if (marks.length < 2) return const [];
    final road = chosen;
    if (road != null && _roadFitsMarks(road.points, marks)) return road.points;
    return marks;
  }

  /// True when the saved driving line belongs to the day selected on screen.
  bool get roadFitsDay {
    final road = chosen;
    if (road == null) return false;
    return _roadFitsMarks(road.points, _dayMarks(planning ? planDay : ridingDay, draft: planning));
  }

  /// True when that line belongs to some day of this ride, even if it is not
  /// the day selected on screen.
  bool get roadFitsSomeDay {
    final road = chosen;
    if (road == null) return false;
    final days = planning ? draftDays : tripDays;
    final draft = planning;
    for (var day = 1; day <= days; day++) {
      if (_roadFitsMarks(road.points, _dayMarks(day, draft: draft))) return true;
    }
    return false;
  }

  List<LatLng> _dayMarks(int day, {required bool draft}) {
    final total = draft ? draftDays : tripDays;
    final origin = day <= 1
        ? (draft ? draftStart : startPoint)
        : dayEnd(day - 1, draft: draft)?.point ?? (draft ? draftStart : startPoint);
    final end = dayEnd(day, draft: draft)?.point ?? (day >= total ? (draft ? draftFinish : finishPoint) : null);
    final marks = <LatLng>[];
    void add(LatLng? point) {
      if (point == null) return;
      if (marks.isNotEmpty && _distance.as(LengthUnit.Meter, marks.last, point) < 400) return;
      marks.add(point);
    }

    add(origin);
    for (final stop in dayStops(day, draft: draft)) {
      add(stop.point);
    }
    add(end);
    return marks;
  }

  bool _roadFitsMarks(List<LatLng> road, List<LatLng> marks) {
    if (road.length < 2 || marks.length < 2) return false;
    if (_distance.as(LengthUnit.Meter, road.first, marks.first) >= 800) return false;
    final end = road.last;
    for (final mark in marks) {
      if (_distance.as(LengthUnit.Meter, end, mark) < 800) return true;
    }
    return false;
  }

  List<RideHalt> dayStops(int day, {bool draft = false}) {
    final source = draft ? draftHalts : halts;
    return [for (final halt in source) if (halt.day == day && halt.kind == HaltKind.stop) halt];
  }

  RideHalt? dayEnd(int day, {bool draft = false}) {
    final source = draft ? draftHalts : halts;
    for (final halt in source) {
      if (halt.day == day && halt.kind == HaltKind.dayEnd) return halt;
    }
    return null;
  }

  double kmTo(LatLng point) => _distance.as(LengthUnit.Kilometer, you, point);

  Future<void> restoreIdentity() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      riderId = user.uid;
      final named = user.displayName?.trim() ?? '';
      riderName = named.isEmpty ? riderLabelFor(user.uid) : named;
      if (_network) {
        try {
          final profile = await _api.ensureUser(uid: user.uid, name: riderName);
          riderName = profile.name;
          if (profile.rideCode.isNotEmpty) {
            code = profile.rideCode;
            onRide = true;
            final adminId = await _api.rideAdmin(profile.rideCode);
            admin = adminId == user.uid;
          }
        } catch (_) {}
      }
    } else {
      try {
        final prefs = await SharedPreferences.getInstance();
        final savedId = prefs.getString('zenrides-rider-id');
        if (savedId != null && savedId.isNotEmpty) riderId = savedId;
        if (savedId == null || savedId.isEmpty) {
          riderId = _newId();
          await prefs.setString('zenrides-rider-id', riderId);
        }
        riderName = riderLabelFor(riderId);
        await prefs.setString('zenrides-rider-name', riderName);
      } catch (_) {
        riderId = _newId();
        riderName = riderLabelFor(riderId);
      }
    }
    dayStarted ??= _clock();
    notice ??= RideNotice(
      kind: NoticeKind.pack,
      kicker: 'BROADCAST: PACK NOTICE · You (Lead Pilot)',
      body: 'New ride started. Share code $code for the pack to attach.',
    );
    notifyListeners();
  }

  void start() {
    if (_started) return;
    _started = true;
    dayStarted ??= _clock();
    _motion = Timer.periodic(const Duration(milliseconds: 200), (_) => tick());
    if (_network) {
      _sync = Timer.periodic(const Duration(seconds: 4), (_) => _syncGroup());
      unawaited(_syncGroup());
      _hazards = Timer.periodic(const Duration(seconds: 45), (_) => refreshHazards());
      unawaited(refreshHazards());
    }
  }

  Future<void> refreshHazards() async {
    if (ended || !_network || !MapsBridge.available) return;
    try {
      final report = await MapsBridge.hazards(you, travelHeading);
      roadHazards = report.hazards;
      hazardFailures = report.failures;
    } catch (error) {
      final text = error.toString().replaceFirst('Exception: ', '');
      hazardFailures = ['Routes API Route.computeRoutes: $text'];
    }
    notifyListeners();
  }

  void tick([Duration _ = const Duration(milliseconds: 200)]) {
    if (ended || paused || !gpsLocked) return;
    _syncStep();
    notifyListeners();
  }

  void selectTab(RideTab next) {
    tab = next;
    notifyListeners();
  }

  void togglePause() {
    if (ended) return;
    paused = !paused;
    notifyListeners();
  }

  void endRide() {
    if (ended) return;
    ended = true;
    paused = false;
    fuelOn = false;
    pumps = [];
    clearDirections();
    _stopGps();
    notifyListeners();
  }

  void removeRider(String id) {
    if (id == riderId || removed.contains(id)) return;
    removed.add(id);
    remote.remove(id);
    if (sos?.id == id) sos = null;
    notifyListeners();
    if (_network) {
      unawaited(_api.deleteRider(code, id).catchError((_) {}));
    }
  }

  void toggleOthers() {
    showOthers = !showOthers;
    notifyListeners();
  }

  void send(NoticeKind kind) {
    if (ended) return;
    switch (kind) {
      case NoticeKind.fuel:
        toggleFuel();
        return;
      case NoticeKind.sos:
        raiseSos();
        return;
      case NoticeKind.regroup:
        arrived = min(2, arrived + 1);
        notice = RideNotice(
          kind: kind,
          kicker: 'BROADCAST: REGROUP · You (Lead Pilot)',
          body: 'Regroup. $arrived of 2 riders are at the toll naka.',
        );
      case NoticeKind.chai:
        _holdUntil['you'] = _clock().add(const Duration(seconds: 4));
        notice = const RideNotice(
          kind: NoticeKind.chai,
          kicker: 'BROADCAST: CHAI / BREAK · You (Lead Pilot)',
          body: 'Chai stop. Holding here while the pack closes up.',
        );
      case NoticeKind.hazard:
        notice = const RideNotice(
          kind: NoticeKind.hazard,
          kicker: 'BROADCAST: HAZARD · You (Lead Pilot)',
          body: 'Hazard warning. Eyes up, slow the pack, and keep your line.',
        );
      case NoticeKind.slow:
        notice = const RideNotice(
          kind: NoticeKind.slow,
          kicker: 'BROADCAST: SLOW PACE · You (Lead Pilot)',
          body: 'Slowing the pack. Ease off and hold the stagger.',
        );
      case NoticeKind.pack:
        break;
    }
    notifyListeners();
  }

  void toggleFuel() {
    if (fuelOn) {
      fuelOn = false;
      pumps = [];
      fuelNote = '';
      if (notice?.kind == NoticeKind.fuel) notice = null;
      notifyListeners();
      return;
    }
    fuelOn = true;
    fuelNote = 'Looking for mapped petrol pumps…';
    notice = const RideNotice(
      kind: NoticeKind.fuel,
      kicker: 'BROADCAST: FUEL STOP · You (Lead Pilot)',
      body: 'Fuel stop. Pack, roll in and hold the stagger.',
    );
    notifyListeners();
    if (!_network) return;
    final here = you;
    unawaited(() async {
      try {
        final found = await _lookupFuel(here);
        if (!fuelOn) return;
        pumps = found;
        pumpFit += 1;
        fuelNote = found.isEmpty
            ? 'No petrol pumps within 15 km.'
            : '${found.length} petrol pump${found.length == 1 ? '' : 's'} within 15 km.';
        notice = RideNotice(
          kind: NoticeKind.fuel,
          kicker: 'BROADCAST: FUEL STOP · You (Lead Pilot)',
          body: fuelNote,
        );
      } catch (error) {
        if (!fuelOn) return;
        fuelNote = error is RideApiException ? error.message : 'Fuel lookup failed';
      }
      notifyListeners();
    }());
  }

  Future<List<FuelPump>> _lookupFuel(LatLng here) async {
    if (kIsWeb && MapsBridge.available) {
      try {
        return await MapsBridge.nearbyFuel(here);
      } catch (error) {
        final fallback = await _api.fuelNear(here);
        if (fallback.isNotEmpty) return fallback;
        throw RideApiException(_bridgeMessage(error));
      }
    }
    return _api.fuelNear(here);
  }

  void lookUp(String query) {
    _searchDebounce?.cancel();
    final trimmed = query.trim();
    if (trimmed.length < 2) {
      suggestions = [];
      searchNote = '';
      notifyListeners();
      return;
    }
    if (!_network || !MapsBridge.available) {
      suggestions = [];
      searchNote = 'Search opens with the live map.';
      notifyListeners();
      return;
    }
    final generation = ++_searchGeneration;
    _searchDebounce = Timer(const Duration(milliseconds: 280), () async {
      try {
        final found = await MapsBridge.search(trimmed, you);
        if (generation != _searchGeneration) return;
        suggestions = found;
        searchNote = found.isEmpty ? 'No matching places.' : '';
      } catch (error) {
        if (generation != _searchGeneration) return;
        suggestions = [];
        searchNote = _bridgeMessage(error);
      }
      notifyListeners();
    });
  }

  void choosePlace(PlaceHit place) {
    destinationName = place.name;
    suggestions = [];
    searchNote = 'Finding roads from here…';
    routes = [];
    selectedRoute = 0;
    navigating = false;
    navArrived = false;
    notifyListeners();
    final generation = ++_searchGeneration;
    final origin = you;
    unawaited(() async {
      try {
        final found = await MapsBridge.directions(origin: origin, placeId: place.placeId);
        if (generation != _searchGeneration) return;
        routes = found.where((route) => route.points.length >= 2).toList();
        selectedRoute = 0;
        routeFit += 1;
        searchNote = routes.isEmpty ? 'No driving route from here.' : '';
        if (routes.isNotEmpty) _loadRouteFuel();
      } catch (error) {
        if (generation != _searchGeneration) return;
        routes = [];
        searchNote = _bridgeMessage(error);
      }
      notifyListeners();
    }());
  }

  void selectRoute(int index) {
    if (index < 0 || index >= routes.length || index == selectedRoute) return;
    selectedRoute = index;
    navigating = false;
    navArrived = false;
    routeFit += 1;
    if (planning) {
      final route = routes[index];
      planNote = '${route.duration} · ${route.distance}';
    }
    _showPumpsOnPath();
    notifyListeners();
  }

  void startNavigation() {
    final drive = chosen;
    if (drive == null || drive.points.length < 2) return;
    navigating = true;
    navArrived = false;
    navKm = 0;
    stepIndex = 0;
    navFit += 1;
    _syncStep();
    notifyListeners();
  }

  void stopNavigation() {
    if (!navigating && !navArrived) return;
    navigating = false;
    navArrived = false;
    routeFit += 1;
    notifyListeners();
  }

  void clearDirections() {
    _searchDebounce?.cancel();
    _searchGeneration += 1;
    _fuelGeneration += 1;
    suggestions = [];
    routes = [];
    selectedRoute = 0;
    destinationName = '';
    searchNote = '';
    navigating = false;
    navArrived = false;
    navKm = 0;
    stepIndex = 0;
    _areaPumps.clear();
    if (pumps.isNotEmpty) {
      pumps = [];
      fuelOn = false;
    }
    notifyListeners();
  }

  void _loadRouteFuel() {
    final generation = ++_fuelGeneration;
    final points = [for (final drive in routes) ...drive.points];
    if (points.length < 2 || !_network) return;
    unawaited(() async {
      try {
        final found = await _api.fuelAlong(points);
        if (generation != _fuelGeneration || routes.isEmpty) return;
        _areaPumps
          ..clear()
          ..addAll(found);
        _showPumpsOnPath();
      } catch (_) {}
      notifyListeners();
    }());
  }

  void _showPumpsOnPath() {
    final drive = chosen;
    if (drive == null || _areaPumps.isEmpty) return;
    pumps = [
      for (final pump in _areaPumps)
        if (_offPathMeters(drive.points, pump.point) <= 700) pump,
    ];
    fuelOn = pumps.isNotEmpty;
    fuelNote = '';
  }

  void _syncStep() {
    final drive = chosen;
    if (!navigating || drive == null || drive.steps.isEmpty) return;
    final here = you;
    var upcoming = drive.steps.length - 1;
    for (var i = 0; i < drive.steps.length; i++) {
      final meters = _distance.as(LengthUnit.Meter, here, drive.steps[i].point);
      if (meters > 40) {
        upcoming = i;
        break;
      }
    }
    stepIndex = upcoming;
  }

  String _bridgeMessage(Object error) {
    final text = error.toString();
    if (text.contains('REQUEST_DENIED')) {
      return 'Google blocked this key for Places or Directions.';
    }
    return text.replaceFirst('Exception: ', '').replaceFirst('Error: ', '');
  }

  void raiseSos({String? id, String? name, LatLng? at}) {
    final point = at ?? you;
    final now = _clock();
    final alert = SosFix(
      id: id ?? riderId,
      name: name ?? riderName,
      lat: point.latitude,
      lng: point.longitude,
      at: now,
    );
    sos = alert;
    notice = RideNotice(
      kind: NoticeKind.sos,
      kicker: 'BROADCAST: SOS · ${alert.name}',
      body: 'SOS. Last spot ${alert.lat.toStringAsFixed(5)}, ${alert.lng.toStringAsFixed(5)}.',
    );
    notifyListeners();
    if (_network && id == null) {
      unawaited(_api.sendSos(
        code: code,
        id: alert.id,
        name: alert.name,
        lat: alert.lat,
        lng: alert.lng,
        at: now,
      ).catchError((_) {}));
    }
  }

  void dismissSos() {
    final alert = sos;
    if (alert != null) {
      _dismissedSosId = alert.id;
      _dismissedSosAt = alert.at;
    }
    sos = null;
    if (notice?.kind == NoticeKind.sos) notice = null;
    notifyListeners();
  }

  void dismissNotice() {
    if (notice?.kind == NoticeKind.sos) {
      dismissSos();
      return;
    }
    notice = null;
    notifyListeners();
  }

  Future<void> requestGps() async {
    if (ended || gpsLocked) return;
    gpsSeeking = true;
    gpsReason = '';
    notifyListeners();
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        gpsReason = 'Location permission denied.';
        gpsSeeking = false;
        notifyListeners();
        return;
      }
      final position = await Geolocator.getCurrentPosition();
      _applyFix(position);
      gpsLocked = true;
      await _gpsWatch?.cancel();
      _gpsWatch = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
        ),
      ).listen(
        _applyFix,
        onError: (_) {
          gpsReason = 'GPS is holding the last fix.';
          notifyListeners();
        },
      );
    } catch (error) {
      gpsLocked = false;
      gpsReason = 'GPS is not available in this browser.';
    } finally {
      gpsSeeking = false;
      notifyListeners();
    }
  }

  void placeYou(LatLng point) {
    if (ended || gpsLocked) return;
    final previous = gpsFix;
    if (previous != null) {
      final moved = _distance.as(LengthUnit.Meter, previous, point);
      if (moved >= 4) _course = _bearing(previous, point);
      traveledKm += moved / 1000;
    }
    gpsFix = point;
    gpsAt = _clock();
    final drive = chosen;
    if (navigating && drive != null && drive.points.length >= 2) {
      final length = _lengthKm(drive.points);
      navKm = min(length, _traveledAlong(drive.points, point));
      navArrived = length > 0 && navKm >= length - 0.05;
      _syncStep();
    }
    notifyListeners();
    if (!_network || paused || !onRide) return;
    unawaited(_api.pushLocation(
      code: code,
      id: riderId,
      name: riderName,
      lat: point.latitude,
      lng: point.longitude,
      at: gpsAt!,
    ).catchError((_) {}));
  }

  void _applyFix(Position position) {
    final next = LatLng(position.latitude, position.longitude);
    final previous = gpsFix;
    if (previous != null) {
      final moved = _distance.as(LengthUnit.Meter, previous, next);
      if (moved >= 4) _course = _bearing(previous, next);
      traveledKm += moved / 1000;
    }
    if (position.heading >= 0 && position.speed >= 0.8) _course = position.heading;
    gpsFix = next;
    gpsAt = _clock();
    gpsReason = '';
    notifyListeners();
  }

  double _headingAlong(List<LatLng> points, LatLng here) {
    if (points.length < 2) return 0;
    const lookAheadKm = 0.12;
    var best = double.infinity;
    var at = 0.0;
    var cursor = 0.0;
    for (var i = 1; i < points.length; i++) {
      final span = _distance.as(LengthUnit.Kilometer, points[i - 1], points[i]);
      final t = _segmentT(points[i - 1], points[i], here);
      final on = LatLng(
        points[i - 1].latitude + (points[i].latitude - points[i - 1].latitude) * t,
        points[i - 1].longitude + (points[i].longitude - points[i - 1].longitude) * t,
      );
      final gap = _distance.as(LengthUnit.Meter, here, on);
      if (gap < best) {
        best = gap;
        at = cursor + span * t;
      }
      cursor += span;
    }
    if (cursor == 0) return 0;
    final target = min(cursor, at + lookAheadKm);
    if (target - at < 0.01) return _bearing(points[points.length - 2], points.last);
    return _bearing(_along(points, at / cursor), _along(points, target / cursor));
  }

  void _stopGps() {
    gpsLocked = false;
    gpsFix = null;
    gpsAt = null;
    unawaited(_gpsWatch?.cancel());
    _gpsWatch = null;
  }

  void beginPlanning() {
    if (!admin) return;
    draftDays = tripDays;
    draftStartName = startName;
    draftStart = startPoint;
    draftFinishName = finishName;
    draftFinish = finishPoint;
    draftHalts = [...halts];
    planDay = ridingDay.clamp(1, draftDays);
    planSlot = PlanSlot.stop;
    planHits = [];
    planNote = '';
    picking = false;
    planning = true;
    tab = RideTab.hud;
    if (_legOrigin(planDay) != null && _planDestination() != null) {
      _loadPlanRoads();
      return;
    }
    planFit++;
    notifyListeners();
  }

  void cancelPlanning() {
    planning = false;
    picking = false;
    planHits = [];
    planNote = '';
    notifyListeners();
  }

  void setDraftDays(int days) {
    draftDays = days.clamp(1, 14);
    if (planDay > draftDays) planDay = draftDays;
    draftHalts = [for (final halt in draftHalts) if (halt.day <= draftDays) halt];
    planFit++;
    notifyListeners();
  }

  void selectPlanDay(int day) {
    final next = day.clamp(1, draftDays);
    if (next == planDay) return;
    planDay = next;
    routeFit++;
    _loadPlanRoads();
  }

  void selectPlanSlot(PlanSlot slot) {
    planSlot = slot;
    notifyListeners();
    if ((slot == PlanSlot.dayEnd || slot == PlanSlot.finish || slot == PlanSlot.stop) &&
        _legOrigin(planDay) != null &&
        _planDestination() != null) {
      _loadPlanRoads();
    }
  }

  void armPick(bool armed) {
    picking = armed;
    planNote = armed ? 'Tap the road. The map is pulled back so a long ride fits.' : '';
    notifyListeners();
  }

  void dropHalt(LatLng point) {
    if (!picking || !planning) return;
    final name = switch (planSlot) {
      PlanSlot.start => 'Start',
      PlanSlot.finish => 'Finish',
      PlanSlot.dayEnd => 'Day $planDay end',
      PlanSlot.stop => 'Day $planDay stop',
    };
    _placeDraft(name, point);
  }

  void removeDraftHalt(String id) {
    if (id == 'plan-start') {
      draftStart = null;
      draftStartName = '';
    } else if (id == 'plan-finish') {
      draftFinish = null;
      draftFinishName = '';
    } else {
      draftHalts = [for (final halt in draftHalts) if (halt.id != id) halt];
    }
    planFit++;
    notifyListeners();
  }

  void removeHalt(String id) => removeDraftHalt(id);

  void lookUpPlan(String query) {
    _searchDebounce?.cancel();
    final trimmed = query.trim();
    if (trimmed.length < 2) {
      planHits = [];
      planNote = '';
      notifyListeners();
      return;
    }
    if (!_network || !MapsBridge.available) {
      planHits = [];
      planNote = 'Search needs the map. Select on map still drops the halt.';
      notifyListeners();
      return;
    }
    final generation = ++_planSearchGeneration;
    _searchDebounce = Timer(const Duration(milliseconds: 280), () async {
      try {
        final found = await MapsBridge.search(trimmed, you);
        if (generation != _planSearchGeneration) return;
        planHits = found;
        planNote = found.isEmpty ? 'No matching places.' : '';
      } catch (error) {
        if (generation != _planSearchGeneration) return;
        planHits = [];
        planNote = _bridgeMessage(error);
      }
      notifyListeners();
    });
  }

  Future<void> choosePlanPlace(PlaceHit place) async {
    planHits = [];
    planNote = 'Placing ${place.name}…';
    notifyListeners();
    final direct = _latLngFromId(place.placeId);
    if (direct != null) {
      _placeDraft(place.name, direct);
      return;
    }
    if (!MapsBridge.available) {
      planNote = 'That place has no map point. Tap the road instead.';
      notifyListeners();
      return;
    }
    try {
      final point = await MapsBridge.placePoint(place.placeId);
      if (point == null) {
        planNote = 'That place has no map point. Tap the road instead.';
      } else {
        _placeDraft(place.name, point);
        return;
      }
    } catch (error) {
      planNote = _bridgeMessage(error);
    }
    notifyListeners();
  }

  void savePlan() {
    tripDays = draftDays;
    startName = draftStartName;
    startPoint = draftStart;
    finishName = draftFinishName;
    finishPoint = draftFinish;
    halts = [...draftHalts];
    ridingDay = 1;
    planning = false;
    picking = false;
    planHits = [];
    planNote = '';
    summary = null;
    dayStarted = _clock();
    traveledKm = 0;
    tab = RideTab.hud;
    shareNote = '';
    notifyListeners();
    if (!_network) return;
    if (!onRide) {
      shareNote = 'Generate or join a code so the other phones can see this plan.';
      notifyListeners();
      return;
    }
    unawaited(_pushCurrentPlan());
  }

  void endDay() {
    final todays = [for (final halt in halts) if (halt.day == ridingDay) halt];
    RideHalt? point;
    for (final halt in todays) {
      if (halt.kind == HaltKind.dayEnd) point = halt;
    }
    point ??= todays.isEmpty ? null : todays.last;
    final reached = point != null && kmTo(point.point) <= 0.4;
    final started = dayStarted ?? _clock();
    summary = DaySummary(
      km: traveledKm,
      elapsed: _clock().difference(started),
      stayed: packRows.where((row) => row.online).map((row) => row.name).toList(),
      reached: reached,
    );
    if (ridingDay < tripDays) {
      ridingDay += 1;
      dayStarted = _clock();
      traveledKm = 0;
      routeFit++;
    }
    notifyListeners();
  }

  void leaveRide() {
    final leavingCode = code;
    final leavingId = riderId;
    onRide = false;
    planning = false;
    picking = false;
    remote.clear();
    joinNote = '';
    notifyListeners();
    admin = false;
    if (_network) unawaited(_api.deleteRider(leavingCode, leavingId).catchError((_) {}));
    _rememberRide('', asAdmin: false);
  }

  void setCode(String next) {
    joinCode(next);
  }

  /// Joins [raw] and returns the code that was accepted.
  ///
  /// Accepts `ZEN-1234`, `zen 1234`, and `1234`.
  String? joinCode(String raw) {
    final next = normalizeRideCode(raw);
    if (next == null) {
      joinNote = 'Codes look like ZEN-1234.';
      notifyListeners();
      return null;
    }
    code = next;
    onRide = true;
    admin = false;
    joinNote = _network ? 'Joining $next…' : 'Could not reach the ride.';
    remote.clear();
    _clearSavedPlan();
    notifyListeners();
    if (_network) {
      unawaited(_syncGroup());
      unawaited(_adoptRide(next));
    }
    return next;
  }

  void debugOfferSos(SosFix alert) {
    if (removed.contains(alert.id) || _sosWasDismissed(alert)) return;
    final current = sos;
    if (current == null || alert.at.isAfter(current.at)) sos = alert;
  }

  bool _sosWasDismissed(SosFix alert) {
    final id = _dismissedSosId;
    final at = _dismissedSosAt;
    if (id == null || at == null || alert.id != id) return false;
    return !alert.at.isAfter(at);
  }

  List<JoinedPhone> get joinedPhones {
    final others = [
      for (final rider in remote.values)
        if (rider.id != riderId && !removed.contains(rider.id))
          JoinedPhone(label: rider.name, you: false),
    ]..sort((a, b) => a.label.compareTo(b.label));
    return [
      JoinedPhone(label: riderName, you: true),
      ...others,
    ];
  }

  String generateCode() {
    final rand = Random();
    final next = 'ZEN-${1000 + rand.nextInt(9000)}';
    code = next;
    onRide = true;
    admin = true;
    joinNote = '';
    remote.clear();
    notifyListeners();
    if (_network) {
      unawaited(_api.claimRide(next, riderId).then((_) {}, onError: (Object _) {}));
      unawaited(_pushCurrentPlan());
      unawaited(_syncGroup());
      _rememberRide(next, asAdmin: true);
    }
    return next;
  }

  void _clearSavedPlan() {
    tripDays = 1;
    startName = '';
    startPoint = null;
    finishName = '';
    finishPoint = null;
    halts = [];
    routes = [];
    selectedRoute = 0;
    _planUpdatedAt = 0;
    shareNote = '';
  }

  Future<void> _pushCurrentPlan() async {
    final savedCode = code;
    final updatedAt = max(_planUpdatedAt + 1, _clock().millisecondsSinceEpoch);
    try {
      await _api.pushPlan(code: savedCode, planJson: encodeSharedPlan(_currentPlan(updatedAt)), updatedAt: updatedAt);
      if (code != savedCode) return;
      _planUpdatedAt = updatedAt;
      shareNote = '';
    } catch (_) {
      if (code != savedCode) return;
      shareNote = 'Could not save the plan to the ride.';
    }
    notifyListeners();
  }

  SharedPlan _currentPlan(int updatedAt) {
    return SharedPlan(
      updatedAt: updatedAt,
      days: tripDays,
      startName: startName,
      start: startPoint,
      finishName: finishName,
      finish: finishPoint,
      halts: [...halts],
      route: chosen,
    );
  }

  void _acceptSharedPlan(String? json, int? updatedAt) {
    if (planning || json == null || json.isEmpty || updatedAt == null || updatedAt <= _planUpdatedAt) return;
    final plan = decodeSharedPlan(json);
    if (plan == null) return;
    tripDays = plan.days;
    startName = plan.startName;
    startPoint = plan.start;
    finishName = plan.finishName;
    finishPoint = plan.finish;
    halts = plan.halts;
    if (plan.route == null) {
      routes = [];
      selectedRoute = 0;
    } else {
      routes = [plan.route!];
      selectedRoute = 0;
      destinationName = plan.finishName.isEmpty ? plan.startName : plan.finishName;
      routeFit += 1;
    }
    _planUpdatedAt = updatedAt;
    shareNote = '';
  }

  void _placeDraft(String name, LatLng point) {
    final id = 'halt-${_clock().microsecondsSinceEpoch}';
    switch (planSlot) {
      case PlanSlot.start:
        draftStartName = name;
        draftStart = point;
      case PlanSlot.finish:
        draftFinishName = name;
        draftFinish = point;
      case PlanSlot.dayEnd:
        draftHalts = [
          for (final halt in draftHalts)
            if (!(halt.day == planDay && halt.kind == HaltKind.dayEnd)) halt,
          RideHalt(id: id, name: name, point: point, day: planDay, kind: HaltKind.dayEnd),
        ];
      case PlanSlot.stop:
        draftHalts = [
          ...draftHalts,
          RideHalt(id: id, name: name, point: point, day: planDay, kind: HaltKind.stop),
        ];
    }
    picking = false;
    planHits = [];
    planNote = '';
    if (_legOrigin(planDay) != null && _planDestination() != null) {
      _loadPlanRoads();
      return;
    }
    planFit++;
    notifyListeners();
  }

  LatLng? _legOrigin(int day) {
    if (day > 1) {
      final previous = dayEnd(day - 1, draft: true);
      if (previous != null) return previous.point;
    }
    return draftStart;
  }

  ({LatLng point, String name})? _planDestination() {
    if (planSlot == PlanSlot.finish && draftFinish != null) {
      return (point: draftFinish!, name: draftFinishName.isEmpty ? 'Finish' : draftFinishName);
    }
    final end = dayEnd(planDay, draft: true);
    if (planSlot == PlanSlot.dayEnd && end != null) {
      return (point: end.point, name: end.name);
    }
    final stops = dayStops(planDay, draft: true);
    if (planSlot == PlanSlot.stop && stops.isNotEmpty) {
      final stop = stops.last;
      return (point: stop.point, name: stop.name);
    }
    if (end != null) return (point: end.point, name: end.name);
    if (draftFinish != null) {
      return (point: draftFinish!, name: draftFinishName.isEmpty ? 'Finish' : draftFinishName);
    }
    if (stops.isNotEmpty) {
      final stop = stops.last;
      return (point: stop.point, name: stop.name);
    }
    return null;
  }

  /// Where this day's road should finish. A day that ends where it started
  /// uses its last stop, so a loop is not drawn as the next day's road.
  ({LatLng point, String name})? _dayLegDestination() {
    final origin = _legOrigin(planDay);
    final end = dayEnd(planDay, draft: true);
    if (end != null && (origin == null || _distance.as(LengthUnit.Meter, origin, end.point) >= 400)) {
      return (point: end.point, name: end.name);
    }
    for (final stop in dayStops(planDay, draft: true).reversed) {
      if (origin == null || _distance.as(LengthUnit.Meter, origin, stop.point) >= 400) {
        return (point: stop.point, name: stop.name);
      }
    }
    if (planDay >= draftDays &&
        draftFinish != null &&
        (origin == null || _distance.as(LengthUnit.Meter, origin, draftFinish!) >= 400)) {
      return (point: draftFinish!, name: draftFinishName.isEmpty ? 'Finish' : draftFinishName);
    }
    return null;
  }

  void _loadPlanRoads() {
    final origin = _legOrigin(planDay);
    final end = _dayLegDestination();
    if (origin == null || end == null) {
      planNote = draftStart == null ? 'Set a start, then choose the day end to see the roads.' : planNote;
      planFit++;
      notifyListeners();
      return;
    }
    if (!MapsBridge.available) {
      planNote = 'Roads show on the live map.';
      planFit++;
      notifyListeners();
      return;
    }
    destinationName = end.name;
    planNote = 'Finding roads…';
    routes = [];
    selectedRoute = 0;
    navigating = false;
    navArrived = false;
    notifyListeners();
    final generation = ++_searchGeneration;
    final placeId = '${end.point.latitude},${end.point.longitude}';
    unawaited(() async {
      try {
        final found = await MapsBridge.directions(origin: origin, placeId: placeId);
        if (generation != _searchGeneration) return;
        routes = found.where((route) => route.points.length >= 2).toList();
        selectedRoute = 0;
        routeFit += 1;
        if (routes.isEmpty) {
          planNote = 'No road between these places.';
        } else {
          final route = routes.first;
          planNote = '${route.duration} · ${route.distance}';
        }
      } catch (error) {
        if (generation != _searchGeneration) return;
        routes = [];
        planNote = _bridgeMessage(error);
      }
      notifyListeners();
    }());
  }

  LatLng? _latLngFromId(String id) {
    final match = RegExp(r'^(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)$').firstMatch(id);
    if (match == null) return null;
    return LatLng(double.parse(match.group(1)!), double.parse(match.group(2)!));
  }

  @override
  void dispose() {
    _motion?.cancel();
    _sync?.cancel();
    _hazards?.cancel();
    _searchDebounce?.cancel();
    unawaited(_gpsWatch?.cancel());
    super.dispose();
  }

  int _claimMark(String id, Set<int> used) {
    var hash = 0;
    for (final code in id.codeUnits) {
      hash = (hash * 33 + code) & 0x7fffffff;
    }
    var slot = hash % riderMarkCount;
    if (used.contains(slot)) {
      for (var i = 0; i < riderMarkCount; i++) {
        final next = (slot + i) % riderMarkCount;
        if (!used.contains(next)) {
          slot = next;
          break;
        }
      }
    }
    used.add(slot);
    return slot;
  }

  bool _holding(String id) {
    final hold = _holdUntil[id];
    return hold != null && _clock().isBefore(hold);
  }

  void _rememberRide(String rideCode, {required bool asAdmin}) {
    if (!_network) return;
    unawaited(_api.setMembership(riderId, rideCode: rideCode, role: asAdmin ? 'admin' : 'rider').then((_) {}, onError: (Object _) {}));
  }

  Future<void> _adoptRide(String rideCode) async {
    try {
      final adminId = await _api.rideAdmin(rideCode);
      if (code != rideCode) return;
      admin = adminId == riderId;
      notifyListeners();
      _rememberRide(rideCode, asAdmin: admin);
    } catch (_) {
      _rememberRide(rideCode, asAdmin: false);
    }
  }

  Future<void> _syncGroup() async {
    if (ended || !onRide) return;
    try {
      final here = gpsFix;
      if (!paused && gpsLocked && here != null) {
        await _api.pushLocation(
          code: code,
          id: riderId,
          name: riderName,
          lat: here.latitude,
          lng: here.longitude,
          at: _clock(),
        );
      }
      final riders = await _api.riders(code);
      remote
        ..clear()
        ..addEntries(riders.where((rider) => rider.id != riderId && !removed.contains(rider.id)).map((rider) => MapEntry(rider.id, rider)));
      final record = await _api.rideRecord(code);
      if (record.sos != null) debugOfferSos(record.sos!);
      _acceptSharedPlan(record.planJson, record.planUpdatedAt);
      if (joinNote.startsWith('Joining ') || joinNote == 'Could not reach the ride.') {
        joinNote = '';
      }
    } catch (_) {
      joinNote = 'Could not reach the ride.';
    }
    notifyListeners();
  }
}

double _traveledAlong(List<LatLng> points, LatLng here) {
  final total = _lengthKm(points);
  return max(0, total - _remainingAlong(points, here));
}

double _offPathMeters(List<LatLng> points, LatLng here) {
  if (points.length < 2) return double.infinity;
  const distance = Distance();
  var best = double.infinity;
  for (var i = 1; i < points.length; i++) {
    final t = _segmentT(points[i - 1], points[i], here);
    final on = LatLng(
      points[i - 1].latitude + (points[i].latitude - points[i - 1].latitude) * t,
      points[i - 1].longitude + (points[i].longitude - points[i - 1].longitude) * t,
    );
    final gap = distance.as(LengthUnit.Meter, here, on);
    if (gap < best) best = gap;
  }
  return best;
}

double _remainingAlong(List<LatLng> points, LatLng here) {
  if (points.length < 2) return 0;
  const distance = Distance();
  var best = double.infinity;
  var traveled = 0.0;
  var cursor = 0.0;
  var total = 0.0;
  for (var i = 1; i < points.length; i++) {
    final span = distance.as(LengthUnit.Kilometer, points[i - 1], points[i]);
    final t = _segmentT(points[i - 1], points[i], here);
    final on = LatLng(
      points[i - 1].latitude + (points[i].latitude - points[i - 1].latitude) * t,
      points[i - 1].longitude + (points[i].longitude - points[i - 1].longitude) * t,
    );
    final gap = distance.as(LengthUnit.Kilometer, here, on);
    if (gap < best) {
      best = gap;
      traveled = cursor + span * t;
    }
    cursor += span;
    total += span;
  }
  return max(0, total - traveled);
}

double _segmentT(LatLng a, LatLng b, LatLng here) {
  final dx = b.longitude - a.longitude;
  final dy = b.latitude - a.latitude;
  final denom = dx * dx + dy * dy;
  if (denom == 0) return 0;
  return (((here.longitude - a.longitude) * dx + (here.latitude - a.latitude) * dy) / denom).clamp(0.0, 1.0);
}

double _bearing(LatLng from, LatLng to) {
  final lat1 = from.latitude * pi / 180;
  final lat2 = to.latitude * pi / 180;
  final dLng = (to.longitude - from.longitude) * pi / 180;
  final y = sin(dLng) * cos(lat2);
  final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLng);
  return (atan2(y, x) * 180 / pi + 360) % 360;
}

double _lengthKm(List<LatLng> points) {
  const distance = Distance();
  var total = 0.0;
  for (var i = 1; i < points.length; i++) {
    total += distance.as(LengthUnit.Kilometer, points[i - 1], points[i]);
  }
  return total;
}

LatLng _along(List<LatLng> points, double progress) {
  final length = _lengthKm(points);
  if (length == 0 || points.isEmpty) return const LatLng(18.37, 73.85);
  var target = length * (progress - progress.floor());
  const distance = Distance();
  for (var i = 1; i < points.length; i++) {
    final span = distance.as(LengthUnit.Kilometer, points[i - 1], points[i]);
    if (target <= span || i == points.length - 1) {
      final t = span == 0 ? 0.0 : (target / span).clamp(0.0, 1.0);
      return LatLng(
        points[i - 1].latitude + (points[i].latitude - points[i - 1].latitude) * t,
        points[i - 1].longitude + (points[i].longitude - points[i - 1].longitude) * t,
      );
    }
    target -= span;
  }
  return points.last;
}

class SharedPlan {
  const SharedPlan({
    required this.updatedAt,
    required this.days,
    required this.startName,
    required this.start,
    required this.finishName,
    required this.finish,
    required this.halts,
    this.route,
  });

  final int updatedAt;
  final int days;
  final String startName;
  final LatLng? start;
  final String finishName;
  final LatLng? finish;
  final List<RideHalt> halts;
  final RouteChoice? route;
}

String encodeSharedPlan(SharedPlan plan) {
  return jsonEncode({
    'days': plan.days.clamp(1, 14),
    'startName': plan.startName,
    'start': _pointJson(plan.start),
    'finishName': plan.finishName,
    'finish': _pointJson(plan.finish),
    'halts': [
      for (final halt in plan.halts)
        {
          'id': halt.id,
          'name': halt.name,
          'lat': halt.point.latitude,
          'lng': halt.point.longitude,
          'day': halt.day,
          'kind': halt.kind.name,
        },
    ],
    'route': _routeJson(plan.route),
  });
}

SharedPlan? decodeSharedPlan(String raw) {
  try {
    final body = jsonDecode(raw);
    if (body is! Map) return null;
    final halts = <RideHalt>[];
    final rawHalts = body['halts'];
    if (rawHalts is List) {
      for (final item in rawHalts) {
        if (item is! Map) continue;
        final lat = _num(item['lat']);
        final lng = _num(item['lng']);
        if (lat == null || lng == null) continue;
        halts.add(RideHalt(
          id: item['id'] is String && (item['id'] as String).isNotEmpty ? item['id'] as String : 'halt-${halts.length}',
          name: item['name'] is String ? item['name'] as String : 'Stop',
          point: LatLng(lat, lng),
          day: (_num(item['day']) ?? 1).round().clamp(1, 14),
          kind: HaltKind.values.asNameMap()[item['kind']] ?? HaltKind.stop,
        ));
      }
    }
    return SharedPlan(
      updatedAt: (_num(body['updatedAt']) ?? 0).round(),
      days: (_num(body['days']) ?? 1).round().clamp(1, 14),
      startName: body['startName'] is String ? body['startName'] as String : '',
      start: _point(body['start']),
      finishName: body['finishName'] is String ? body['finishName'] as String : '',
      finish: _point(body['finish']),
      halts: halts,
      route: _route(body['route']),
    );
  } catch (_) {
    return null;
  }
}

Map<String, double>? _pointJson(LatLng? point) {
  if (point == null) return null;
  return {'lat': point.latitude, 'lng': point.longitude};
}

LatLng? _point(Object? raw) {
  if (raw is! Map) return null;
  final lat = _num(raw['lat']);
  final lng = _num(raw['lng']);
  if (lat == null || lng == null) return null;
  return LatLng(lat, lng);
}

double? _num(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

Map<String, Object?>? _routeJson(RouteChoice? route) {
  if (route == null || route.points.length < 2) return null;
  final points = _thinPoints(route.points);
  return {
    'summary': route.summary,
    'duration': route.duration,
    'distance': route.distance,
    'durationSeconds': route.durationSeconds,
    'distanceMeters': route.distanceMeters,
    'points': [
      for (final point in points) [point.latitude, point.longitude],
    ],
  };
}

RouteChoice? _route(Object? raw) {
  if (raw is! Map) return null;
  final rawPoints = raw['points'];
  if (rawPoints is! List) return null;
  final points = <LatLng>[];
  for (final item in rawPoints) {
    if (item is! List || item.length < 2) continue;
    final lat = _num(item[0]);
    final lng = _num(item[1]);
    if (lat == null || lng == null) continue;
    points.add(LatLng(lat, lng));
  }
  if (points.length < 2) return null;
  return RouteChoice(
    summary: raw['summary'] is String ? raw['summary'] as String : 'Driving route',
    duration: raw['duration'] is String ? raw['duration'] as String : '',
    distance: raw['distance'] is String ? raw['distance'] as String : '',
    durationSeconds: (_num(raw['durationSeconds']) ?? 0).round(),
    distanceMeters: (_num(raw['distanceMeters']) ?? 0).round(),
    points: points,
  );
}

List<LatLng> _thinPoints(List<LatLng> points, {int max = 500}) {
  if (points.length <= max) return points;
  final kept = <LatLng>[];
  final step = (points.length - 1) / (max - 1);
  for (var i = 0; i < max; i++) {
    kept.add(points[(i * step).round()]);
  }
  kept[kept.length - 1] = points.last;
  return kept;
}

class JoinedPhone {
  const JoinedPhone({required this.label, required this.you});

  final String label;
  final bool you;
}

String? normalizeRideCode(String raw) {
  final compact = raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  final match = RegExp(r'^(?:ZEN)?(\d{4})$').firstMatch(compact);
  if (match == null) return null;
  return 'ZEN-${match.group(1)}';
}

String riderLabelFor(String id) {
  final clean = id.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
  if (clean.isEmpty) return 'Rider';
  final tail = clean.length <= 4 ? clean : clean.substring(clean.length - 4);
  return 'Rider $tail';
}

String _newId() {
  final rand = Random.secure();
  return List.generate(16, (_) => rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

String formatKm(double km) {
  final abs = km.abs();
  if (abs < 1) return '${max(1, (abs * 1000).round())} m';
  return '${abs.toStringAsFixed(1)} km';
}

String formatDuration(Duration duration) {
  final total = max(0, duration.inSeconds);
  final minutes = total ~/ 60;
  final seconds = total % 60;
  if (minutes <= 0) return '$seconds sec';
  return '$minutes min $seconds sec';
}
