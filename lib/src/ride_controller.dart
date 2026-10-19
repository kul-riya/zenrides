import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' show Color;

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

enum HaltKind { start, finish, stop, dayEnd, dayStart }

enum PlanSlot { start, dayStart, finish, dayEnd, stop }

/// Phone planning: the ride overview, one day's list, or the full-screen map.
enum PlanScreen { overview, day, map }

const dayPalette = <Color>[
  Color(0xFF1D4ED8),
  Color(0xFF15803D),
  Color(0xFFC2410C),
  Color(0xFF7C3AED),
  Color(0xFFBE123C),
  Color(0xFF0F766E),
];

Color dayColor(int day) => dayPalette[(day <= 1 ? 0 : day - 1) % dayPalette.length];

/// One colored line on the planning map. [alternative] is set for a road
/// the rider can still tap on the day they are editing.
class DayPath {
  const DayPath({required this.day, required this.points, required this.selected, this.alternative});

  final int day;
  final List<LatLng> points;
  final bool selected;
  final int? alternative;
}

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
  bool _joinedPack = false;
  int tripDays = 1;
  int ridingDay = 1;
  int draftDays = 1;
  DateTime? tripStartDate;
  DateTime? draftStartDate;
  int planDay = 1;

  /// True when the planner is showing the whole ride, not one day's time.
  bool wholeRide = true;
  PlanScreen planScreen = PlanScreen.overview;
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
  bool planPumpsOn = false;
  bool planTollsOn = false;
  bool gpsSeeking = false;
  bool gpsLocked = false;
  String riderId = 'you';
  String riderName = 'Joe';
  String code = groupCode;
  String gpsReason = '';
  String fuelNote = '';
  String planPumpNote = '';
  String planTollNote = '';
  String searchNote = '';
  bool searchFocused = false;
  String destinationName = '';
  List<PlaceHit> suggestions = [];
  List<RouteChoice> routes = [];
  int selectedRoute = 0;
  int pumpFit = 0;
  int routeFit = 0;
  int navFit = 0;
  bool navigating = false;

  /// True only after a search on the HUD, so a saved plan's road is not drawn on open.
  bool previewingRoute = false;
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
  List<FuelPump> planPumps = [];
  List<TollPlaza> planTolls = [];

  /// Toll the rider tapped, waiting on Add as halt.
  TollPlaza? pickedToll;

  /// Minutes from midnight for each planned day. Draft is edited; trip is saved.
  final Map<int, int> draftStartMinute = {};
  final Map<int, int> draftEndMinute = {};
  final Map<int, int> tripStartMinute = {};
  final Map<int, int> tripEndMinute = {};
  List<RoadHazard> roadHazards = [];
  List<String> hazardFailures = [];
  int _fuelGeneration = 0;
  int _planStopGeneration = 0;
  final Map<int, RouteChoice> _dayRoutes = {};
  final Map<int, int> _planRoadGeneration = {};
  final Map<String, DateTime> _holdUntil = {};
  final Set<String> removed = {};
  final Map<String, RemoteRider> remote = {};

  double get routeKm {
    final drive = chosen;
    if (drive == null) return 0;
    if (planning && roadFitsSomeDay && !roadFitsDay) return 0;
    return drive.distanceMeters > 0 ? drive.distanceMeters / 1000 : _lengthKm(drive.points);
  }

  LatLng get you => gpsFix ?? startPoint ?? parked;

  /// The blue line is a search or a live ride. A saved plan does not draw one.
  bool get showHudRoute => !planning && routes.isNotEmpty && (navigating || previewingRoute);

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

  /// Pins for the map. They show while planning and come off once the ride is saved.
  /// Day 2 starts where day 1 ended, so that place is one pin.
  List<RideHalt> get mapHalts {
    if (!planning) return const [];
    final draft = planning;
    final days = draft ? draftDays : tripDays;
    final kept = <RideHalt>[];
    for (final halt in visibleHalts) {
      if (halt.kind == HaltKind.dayStart && _samePlace(halt.point, _inheritedDayOrigin(halt.day, draft: draft))) {
        continue;
      }
      if (halt.kind == HaltKind.dayStart && _samePlace(halt.point, dayEnd(halt.day, draft: draft)?.point)) {
        continue;
      }
      final existing = kept.indexWhere((other) => _samePlace(other.point, halt.point));
      if (existing >= 0) {
        final other = kept[existing];
        kept[existing] = RideHalt(
          id: other.id,
          name: other.name.contains(halt.name) ? other.name : '${other.name} · ${halt.name}',
          point: other.point,
          day: other.day,
          kind: other.kind,
        );
        continue;
      }
      kept.add(halt);
    }
    return [
      for (final halt in kept)
        if (halt.kind == HaltKind.dayEnd &&
            halt.day < days &&
            _samePlace(_dayOrigin(halt.day + 1, draft: draft), halt.point))
          RideHalt(
            id: halt.id,
            name: '${halt.name} · Day ${halt.day + 1} start',
            point: halt.point,
            day: halt.day,
            kind: halt.kind,
          )
        else
          halt,
    ];
  }

  bool _samePlace(LatLng? a, LatLng? b) {
    if (a == null || b == null) return false;
    return _distance.as(LengthUnit.Meter, a, b) < 400;
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

  /// Every day's road while planning, so day 1 and day 2 stay on the map together.
  List<DayPath> get planPaths {
    if (!planning) return const [];
    final paths = <DayPath>[];
    for (var day = 1; day <= draftDays; day++) {
      final marks = _dayMarks(day, draft: true);
      if (day == planDay && routes.isNotEmpty && roadFitsDay) {
        for (var i = 0; i < routes.length; i++) {
          final points = routes[i].points;
          if (points.length < 2) continue;
          paths.add(DayPath(day: day, points: points, selected: i == selectedRoute, alternative: i));
        }
        continue;
      }
      final saved = _dayRoutes[day];
      if (saved != null && saved.points.length >= 2 && _roadFitsMarks(saved.points, marks)) {
        paths.add(DayPath(day: day, points: saved.points, selected: true));
        continue;
      }
      if (marks.length >= 2) paths.add(DayPath(day: day, points: marks, selected: true));
    }
    return paths;
  }

  /// One driving line per day, including day 1 while another day is open.
  List<List<LatLng>> get planRoadLines {
    if (!planning) return const [];
    final lines = <List<LatLng>>[];
    final seen = <int>{};
    for (final path in planPaths) {
      if (!path.selected || path.points.length < 2 || !seen.add(path.day)) continue;
      lines.add(path.points);
    }
    return lines;
  }

  List<FuelPump> get shownPumps => planning ? planPumps : pumps;

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
    final origin = _dayOrigin(day, draft: draft);
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

  RideHalt? dayStart(int day, {bool draft = false}) {
    final source = draft ? draftHalts : halts;
    for (final halt in source) {
      if (halt.day == day && halt.kind == HaltKind.dayStart) return halt;
    }
    return null;
  }

  /// Named once day 2 has an end: day 1's start, day 1's end, and day 2's end.
  String? get planChain {
    if (dayEnd(2, draft: true) == null) return null;
    final start = draftStartName.isEmpty ? 'Not set' : draftStartName;
    final end1 = dayEnd(1, draft: true)?.name ?? 'Not set';
    final end2 = dayEnd(2, draft: true)!.name;
    return 'Day 1 start · $start. Day 1 end · $end1. Day 2 end · $end2.';
  }

  RouteChoice? _timingRoute(int day) {
    if (planning && day == planDay && routes.isNotEmpty) {
      return routes[selectedRoute.clamp(0, routes.length - 1)];
    }
    return _dayRoutes[day];
  }

  String dayTiming(int day) {
    final live = _timingRoute(day);
    if (live == null || (live.duration.isEmpty && live.distance.isEmpty)) return '';
    return '${live.duration} · ${live.distance}';
  }

  /// True when this day's time came from Google with traffic, not a fallback.
  bool dayTraffic(int day) => _timingRoute(day)?.traffic ?? false;

  /// Time and distance for every planned day added together.
  String get rideTiming {
    final totals = _rideTotals();
    if (totals == null) return '';
    return '${_formatDuration(totals.seconds)} · ${_formatDistance(totals.meters)}';
  }

  /// The line under search: the open day, or the whole ride after a tap off the roads.
  String get planTimingLabel {
    if (wholeRide) {
      if (rideTiming.isEmpty) return '';
      return 'Ride · $rideTiming${rideTraffic ? ' · live traffic' : ''}';
    }
    final day = dayTiming(planDay);
    if (day.isEmpty) return '';
    return 'Day $planDay · $day${dayTraffic(planDay) ? ' · live traffic' : ''}';
  }

  /// Map chip. A stored day time yields to the whole-ride total once [wholeRide] is on.
  String get visiblePlanNote {
    if (!planning || planScreen == PlanScreen.map) return planNote;
    if (planNote.isNotEmpty && !_planNoteIsTiming(planNote)) return planNote;
    final label = planTimingLabel;
    return label.isEmpty ? planNote : label;
  }

  bool _planNoteIsTiming(String note) {
    if (rideTiming.isNotEmpty && note == rideTiming) return true;
    final days = planning ? draftDays : tripDays;
    for (var day = 1; day <= days; day++) {
      final timing = dayTiming(day);
      if (timing.isNotEmpty && note == timing) return true;
    }
    return false;
  }

  /// True when every counted day came back from Google with live traffic.
  bool get rideTraffic {
    final days = planning ? draftDays : tripDays;
    var any = false;
    for (var day = 1; day <= days; day++) {
      final live = _timingRoute(day);
      if (live == null || (live.durationSeconds <= 0 && live.distanceMeters <= 0)) continue;
      any = true;
      if (!live.traffic) return false;
    }
    return any;
  }

  ({int seconds, int meters})? _rideTotals() {
    final days = planning ? draftDays : tripDays;
    var seconds = 0;
    var meters = 0;
    var any = false;
    for (var day = 1; day <= days; day++) {
      final live = _timingRoute(day);
      if (live == null || (live.durationSeconds <= 0 && live.distanceMeters <= 0)) continue;
      any = true;
      seconds += live.durationSeconds;
      meters += live.distanceMeters;
    }
    if (!any) return null;
    return (seconds: seconds, meters: meters);
  }

  /// This phone can plan unless it joined a ride someone else leads.
  bool get canPlan => admin || !_joinedPack;

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
            _joinedPack = adminId != null && adminId != user.uid;
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
    final road = _selectedRoad();
    final planned = _hasPlan;
    fuelNote = road != null
        ? 'Looking for petrol pumps on this road…'
        : planned
            ? 'Choose a road to see pumps on it.'
            : 'Looking for mapped petrol pumps…';
    notice = RideNotice(
      kind: NoticeKind.fuel,
      kicker: 'BROADCAST: FUEL STOP · You (Lead Pilot)',
      body: road != null ? 'Fuel stop. Pumps on this road only.' : 'Fuel stop. Pack, roll in and hold the stagger.',
    );
    notifyListeners();
    if (!_network) return;
    if (road == null) {
      if (planned) {
        pumps = [];
        notifyListeners();
        return;
      }
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
      return;
    }
    unawaited(_loadSelectedRoadFuel(road));
  }

  bool get _hasPlan => planning ? (draftStart != null || draftHalts.isNotEmpty) : (startPoint != null || halts.isNotEmpty);

  List<LatLng>? _selectedRoad() {
    final drive = chosen;
    if (drive != null && drive.points.length >= 2) return drive.points;
    return null;
  }

  Future<void> _loadSelectedRoadFuel(List<LatLng> road) async {
    final generation = ++_fuelGeneration;
    try {
      List<FuelPump> found = const [];
      if (kIsWeb && MapsBridge.available) {
        try {
          found = await MapsBridge.fuelAlong(road);
        } catch (_) {
          found = const [];
        }
      }
      if (found.isEmpty) found = await _api.fuelAlong(road);
      if (generation != _fuelGeneration || !fuelOn) return;
      pumps = [
        for (final pump in found)
          if (_offPathMeters(road, pump.point) <= 400) pump,
      ];
      pumpFit += 1;
      fuelNote = pumps.isEmpty ? 'No petrol pumps on this road.' : '${pumps.length} petrol pump${pumps.length == 1 ? '' : 's'} on this road.';
      notice = RideNotice(
        kind: NoticeKind.fuel,
        kicker: 'BROADCAST: FUEL STOP · You (Lead Pilot)',
        body: fuelNote,
      );
    } catch (error) {
      if (generation != _fuelGeneration || !fuelOn) return;
      pumps = [];
      fuelNote = error is RideApiException ? error.message : 'Fuel lookup failed';
    }
    notifyListeners();
  }

  void togglePlanPumps() {
    planPumpsOn = !planPumpsOn;
    if (!planPumpsOn) {
      planPumps = [];
      planPumpNote = '';
      _planStopGeneration++;
      notifyListeners();
      if (planTollsOn) unawaited(_loadPlanStops());
      return;
    }
    planPumpNote = 'Looking for petrol pumps on the ride…';
    notifyListeners();
    unawaited(_loadPlanStops());
  }

  void togglePlanTolls() {
    planTollsOn = !planTollsOn;
    if (!planTollsOn) {
      planTolls = [];
      planTollNote = '';
      pickedToll = null;
      _planStopGeneration++;
      notifyListeners();
      if (planPumpsOn) unawaited(_loadPlanStops());
      return;
    }
    planTollNote = 'Looking for toll nakas on the ride…';
    notifyListeners();
    unawaited(_loadPlanStops());
  }

  void _clearPlanOverlays() {
    _planStopGeneration++;
    planPumpsOn = false;
    planTollsOn = false;
    planPumps = [];
    planTolls = [];
    pickedToll = null;
    planPumpNote = '';
    planTollNote = '';
  }

  /// Pumps and tolls for every colored day, so day 1 is included while day 2 is open.
  Future<void> _loadPlanStops() async {
    final generation = ++_planStopGeneration;
    final roads = planRoadLines;
    if (roads.isEmpty) {
      if (planPumpsOn) planPumpNote = 'Add a start and an end to see pumps.';
      if (planTollsOn) planTollNote = 'Add a start and an end to see tolls.';
      notifyListeners();
      return;
    }
    if (!_network || !MapsBridge.available) {
      if (planPumpsOn) planPumpNote = 'Pumps show on the live map.';
      if (planTollsOn) planTollNote = 'Tolls show on the live map.';
      notifyListeners();
      return;
    }
    try {
      final found = await Future.wait(roads.map((road) async {
        List<FuelPump> pumpsOnRoad = const [];
        List<TollPlaza> tollsOnRoad = const [];
        if (planPumpsOn) {
          try {
            pumpsOnRoad = await _pumpsOn(road);
          } catch (_) {
            pumpsOnRoad = const [];
          }
        }
        if (planTollsOn) {
          try {
            tollsOnRoad = await _tollsOn(road);
          } catch (_) {
            tollsOnRoad = const [];
          }
        }
        return (road: road, pumps: pumpsOnRoad, tolls: tollsOnRoad);
      }));
      if (generation != _planStopGeneration) return;
      final pumps = <FuelPump>[];
      final tolls = <TollPlaza>[];
      final pumpIds = <String>{};
      final tollIds = <String>{};
      for (final row in found) {
        if (planPumpsOn) {
          for (final pump in row.pumps) {
            if (_offPathMeters(row.road, pump.point) > 800) continue;
            if (pumpIds.add(pump.id)) pumps.add(pump);
          }
        }
        if (planTollsOn) {
          for (final toll in row.tolls) {
            if (_offPathMeters(row.road, toll.point) > 800) continue;
            if (tollIds.add(toll.id)) tolls.add(toll);
          }
        }
      }
      if (planPumpsOn) {
        planPumps = pumps;
        planPumpNote = pumps.isEmpty ? 'No petrol pumps on this ride.' : '${pumps.length} petrol pump${pumps.length == 1 ? '' : 's'} on the ride.';
      }
      if (planTollsOn) {
        planTolls = tolls;
        planTollNote = tolls.isEmpty ? 'No toll nakas on this ride.' : '${tolls.length} toll naka${tolls.length == 1 ? '' : 's'} on the ride.';
      }
    } catch (error) {
      if (generation != _planStopGeneration) return;
      final message = error is RideApiException ? error.message : 'Lookup failed';
      if (planPumpsOn) planPumpNote = message;
      if (planTollsOn) planTollNote = message;
    }
    notifyListeners();
  }

  Future<List<FuelPump>> _pumpsOn(List<LatLng> road) async {
    if (kIsWeb && MapsBridge.available) {
      try {
        final found = await MapsBridge.fuelAlong(road);
        if (found.isNotEmpty) return found;
      } catch (_) {}
    }
    return _api.fuelAlong(road);
  }

  Future<List<TollPlaza>> _tollsOn(List<LatLng> road) async {
    if (kIsWeb && MapsBridge.available) {
      try {
        final found = await MapsBridge.tollsAlong(road);
        if (found.isNotEmpty) return found;
      } catch (_) {}
    }
    return _api.tollsAlong(road);
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

  void setSearchFocused(bool focused) {
    if (searchFocused == focused) return;
    searchFocused = focused;
    notifyListeners();
  }

  /// The HUD map is a normal map. A saved plan stays in Tours and does not own this route.
  void _clearHudRoute() {
    routes = [];
    selectedRoute = 0;
    navigating = false;
    previewingRoute = false;
    navArrived = false;
    destinationName = '';
    searchNote = '';
    suggestions = [];
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
        previewingRoute = routes.isNotEmpty;
        routeFit += 1;
        searchNote = routes.isEmpty ? 'No driving route from here.' : '';
        if (fuelOn && routes.isNotEmpty) unawaited(_loadSelectedRoadFuel(routes.first.points));
      } catch (error) {
        if (generation != _searchGeneration) return;
        routes = [];
        previewingRoute = false;
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
      _dayRoutes[planDay] = route;
      planNote = '${route.duration} · ${route.distance}';
    }
    if (fuelOn) {
      final road = routes[index].points;
      if (road.length >= 2) unawaited(_loadSelectedRoadFuel(road));
    }
    if (planning && (planPumpsOn || planTollsOn)) unawaited(_loadPlanStops());
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
    previewingRoute = false;
    navArrived = false;
    navKm = 0;
    stepIndex = 0;
    if (pumps.isNotEmpty) {
      pumps = [];
      fuelOn = false;
    }
    notifyListeners();
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
    if (!canPlan) return;
    draftDays = tripDays;
    draftStartDate = tripStartDate;
    draftStartName = startName;
    draftStart = startPoint;
    draftFinishName = finishName;
    draftFinish = finishPoint;
    draftHalts = [...halts];
    draftStartMinute
      ..clear()
      ..addAll(tripStartMinute);
    draftEndMinute
      ..clear()
      ..addAll(tripEndMinute);
    pickedToll = null;
    planDay = ridingDay.clamp(1, draftDays);
    planSlot = PlanSlot.stop;
    wholeRide = true;
    planScreen = PlanScreen.overview;
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
    planScreen = PlanScreen.overview;
    picking = false;
    planHits = [];
    planNote = '';
    _clearHudRoute();
    _clearPlanOverlays();
    notifyListeners();
  }

  void setDraftDays(int days) {
    draftDays = days.clamp(1, 14);
    if (planDay > draftDays) planDay = draftDays;
    draftHalts = [for (final halt in draftHalts) if (halt.day <= draftDays) halt];
    draftStartMinute.removeWhere((day, _) => day > draftDays);
    draftEndMinute.removeWhere((day, _) => day > draftDays);
    planFit++;
    notifyListeners();
  }

  /// The calendar day for a planned day, once a start date is chosen.
  DateTime? dateForDay(int day, {bool draft = false}) {
    final start = draft ? draftStartDate : tripStartDate;
    if (start == null) return null;
    final from = DateTime(start.year, start.month, start.day);
    return from.add(Duration(days: day - 1));
  }

  String get draftDateLabel => draftStartDate == null ? '' : formatPlanSpan(draftStartDate!, draftDays);

  String get tripDateLabel => tripStartDate == null ? '' : formatPlanSpan(tripStartDate!, tripDays);

  void setPlanDates(DateTime start, DateTime end) {
    final from = DateTime(start.year, start.month, start.day);
    final to = DateTime(end.year, end.month, end.day);
    var days = to.difference(from).inDays + 1;
    if (days < 1) days = 1;
    if (days > 14) days = 14;
    draftStartDate = from;
    setDraftDays(days);
  }

  void selectPlanDay(int day) {
    final next = day.clamp(1, draftDays);
    wholeRide = false;
    if (next == planDay) {
      notifyListeners();
      return;
    }
    _keepShownRoad(planDay);
    planDay = next;
    routeFit++;
    _loadPlanRoads();
  }

  /// The road on screen stays with its day, so leaving the day does not turn it into a straight line.
  void _keepShownRoad(int day) {
    if (routes.isEmpty) return;
    final route = routes[selectedRoute.clamp(0, routes.length - 1)];
    if (route.points.length < 2) return;
    if (!_roadFitsMarks(route.points, _dayMarks(day, draft: true))) return;
    _dayRoutes[day] = route;
  }

  void showWholeRide() {
    if (!planning || wholeRide) return;
    wholeRide = true;
    notifyListeners();
  }

  /// A tap on a colored road opens that day. A lighter road on the open day picks that route.
  void openPlanDay(int day) {
    selectPlanDay(day);
    planScreen = PlanScreen.day;
    picking = false;
    notifyListeners();
  }

  void closePlanDay() {
    if (!planning) return;
    picking = false;
    planHits = [];
    planScreen = PlanScreen.overview;
    wholeRide = true;
    notifyListeners();
  }

  void pickOnMap(PlanSlot slot) {
    if (!planning) return;
    selectPlanSlot(slot);
    picking = true;
    planNote = 'Tap the map, or search for the place.';
    planScreen = PlanScreen.map;
    notifyListeners();
  }

  void closeMapPick() {
    if (planScreen != PlanScreen.map) return;
    picking = false;
    planHits = [];
    planNote = '';
    planScreen = PlanScreen.day;
    notifyListeners();
  }

  void openPlannedDay(int day, {int? alternative}) {
    if (!planning) return;
    wholeRide = false;
    final next = day.clamp(1, draftDays);
    if (next != planDay) {
      selectPlanDay(next);
      return;
    }
    if (alternative != null) selectRoute(alternative);
  }

  void selectPlanSlot(PlanSlot slot) {
    planSlot = slot;
    notifyListeners();
    if ((slot == PlanSlot.dayEnd || slot == PlanSlot.dayStart || slot == PlanSlot.finish || slot == PlanSlot.stop) &&
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
      PlanSlot.dayStart => 'Day $planDay start',
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

  void pickToll(TollPlaza toll) {
    if (!planning) return;
    pickedToll = toll;
    notifyListeners();
  }

  void dismissToll() {
    if (pickedToll == null) return;
    pickedToll = null;
    notifyListeners();
  }

  /// Drops the tapped toll onto the nearest day's road and into the plan list.
  void addTollAsHalt() {
    final toll = pickedToll;
    if (!planning || toll == null) return;
    final day = _nearestPlanDay(toll.point);
    pickedToll = null;
    if (day == null) {
      planNote = 'That toll is not on a planned day.';
      notifyListeners();
      return;
    }
    for (final stop in dayStops(day, draft: true)) {
      if (_distance.as(LengthUnit.Meter, stop.point, toll.point) < 200) {
        planNote = '${toll.name} is already a halt.';
        notifyListeners();
        return;
      }
    }
    final halt = RideHalt(
      id: 'toll-${toll.id}',
      name: toll.name,
      point: toll.point,
      day: day,
      kind: HaltKind.stop,
    );
    final stops = [...dayStops(day, draft: true), halt];
    final line = _timingRoute(day)?.points;
    if (line != null && line.length >= 2) {
      stops.sort((a, b) => _traveledAlong(line, a.point).compareTo(_traveledAlong(line, b.point)));
    }
    draftHalts = [
      for (final existing in draftHalts)
        if (!(existing.day == day && existing.kind == HaltKind.stop)) existing,
      ...stops,
    ];
    planNote = '';
    if (_legOrigin(planDay) != null && _planDestination() != null) {
      _loadPlanRoads();
      return;
    }
    planFit++;
    notifyListeners();
  }

  int? _nearestPlanDay(LatLng point) {
    int? bestDay;
    var best = double.infinity;
    for (var day = 1; day <= draftDays; day++) {
      final saved = _timingRoute(day)?.points;
      final marks = _dayMarks(day, draft: true);
      final line = saved != null && saved.length >= 2 ? saved : marks;
      if (line.length < 2) continue;
      final gap = _offPathMeters(line, point);
      if (gap < best) {
        best = gap;
        bestDay = day;
      }
    }
    if (bestDay == null || best > 800) return null;
    return bestDay;
  }

  int? dayStartMinute(int day, {bool draft = true}) => (draft ? draftStartMinute : tripStartMinute)[day];

  int? dayEndMinute(int day, {bool draft = true}) => (draft ? draftEndMinute : tripEndMinute)[day];

  void setDayClock(int day, {int? startMinute, int? endMinute}) {
    final which = day.clamp(1, draftDays);
    if (startMinute != null) draftStartMinute[which] = startMinute.clamp(0, 24 * 60 - 1);
    if (endMinute != null) draftEndMinute[which] = endMinute.clamp(0, 24 * 60 - 1);
    notifyListeners();
  }

  /// "Estimated time", plus a clock when the day's start and the road can place it.
  String haltEstimateLabel(int day, LatLng point, {bool draft = true}) {
    final clock = _haltEstimateClock(day, point, draft: draft);
    if (clock == null) return 'Estimated time';
    return 'Estimated time · $clock';
  }

  String? _haltEstimateClock(int day, LatLng point, {required bool draft}) {
    final start = dayStartMinute(day, draft: draft);
    if (start == null) return null;
    final route = _timingRoute(day);
    final points = route?.points ?? const <LatLng>[];
    if (route == null || points.length < 2) return null;
    final length = _lengthKm(points);
    if (length <= 0) return null;
    final along = _traveledAlong(points, point).clamp(0.0, length);
    final fraction = along / length;
    final end = dayEndMinute(day, draft: draft);
    final int span;
    if (end != null) {
      span = end >= start ? end - start : (24 * 60 - start) + end;
    } else if (route.durationSeconds > 0) {
      span = (route.durationSeconds / 60).round();
    } else {
      return null;
    }
    if (span <= 0) return formatClock(start);
    final minute = (start + (fraction * span).round()) % (24 * 60);
    return formatClock(minute);
  }

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
    tripStartDate = draftStartDate;
    startName = draftStartName;
    startPoint = draftStart;
    finishName = draftFinishName;
    finishPoint = draftFinish;
    halts = [...draftHalts];
    tripStartMinute
      ..clear()
      ..addAll(draftStartMinute);
    tripEndMinute
      ..clear()
      ..addAll(draftEndMinute);
    pickedToll = null;
    ridingDay = 1;
    planning = false;
    planScreen = PlanScreen.overview;
    picking = false;
    planHits = [];
    planNote = '';
    _clearHudRoute();
    _clearPlanOverlays();
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

  void deleteRide() {
    final leavingCode = code;
    final wasOnRide = onRide;
    planning = false;
    picking = false;
    ended = false;
    paused = false;
    onRide = false;
    admin = false;
    _joinedPack = false;
    navigating = false;
    navArrived = false;
    fuelOn = false;
    pumps = [];
    _clearPlanOverlays();
    routes = [];
    selectedRoute = 0;
    _dayRoutes.clear();
    _planRoadGeneration.clear();
    draftHalts = [];
    draftStart = null;
    draftStartName = '';
    draftFinish = null;
    draftFinishName = '';
    draftDays = 1;
    draftStartDate = null;
    planDay = 1;
    planHits = [];
    planNote = '';
    remote.clear();
    sos = null;
    notice = null;
    summary = null;
    destinationName = '';
    searchNote = '';
    suggestions = [];
    _clearSavedPlan();
    code = '';
    joinNote = 'Ride deleted.';
    shareNote = '';
    tab = RideTab.hud;
    notifyListeners();
    if (!_network || !wasOnRide || leavingCode.isEmpty) return;
    unawaited(_api.deleteRideDocument(leavingCode).catchError((_) {}));
    _rememberRide('', asAdmin: false);
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
    _joinedPack = false;
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
    _joinedPack = true;
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
    _joinedPack = false;
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
    tripStartDate = null;
    draftStartDate = null;
    startName = '';
    startPoint = null;
    finishName = '';
    finishPoint = null;
    halts = [];
    tripStartMinute.clear();
    tripEndMinute.clear();
    draftStartMinute.clear();
    draftEndMinute.clear();
    routes = [];
    selectedRoute = 0;
    _dayRoutes.clear();
    _planRoadGeneration.clear();
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
      startDate: tripStartDate,
      startName: startName,
      start: startPoint,
      finishName: finishName,
      finish: finishPoint,
      halts: [...halts],
      startMinutes: Map<int, int>.from(tripStartMinute),
      endMinutes: Map<int, int>.from(tripEndMinute),
      route: chosen,
    );
  }

  void _acceptSharedPlan(String? json, int? updatedAt) {
    if (planning || json == null || json.isEmpty || updatedAt == null || updatedAt <= _planUpdatedAt) return;
    final plan = decodeSharedPlan(json);
    if (plan == null) return;
    tripDays = plan.days;
    tripStartDate = plan.startDate;
    startName = plan.startName;
    startPoint = plan.start;
    finishName = plan.finishName;
    finishPoint = plan.finish;
    halts = plan.halts;
    tripStartMinute
      ..clear()
      ..addAll(plan.startMinutes);
    tripEndMinute
      ..clear()
      ..addAll(plan.endMinutes);
    if (!navigating && !previewingRoute) {
      routes = [];
      selectedRoute = 0;
      destinationName = '';
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
      case PlanSlot.dayStart:
        if (planDay <= 1) {
          draftStartName = name;
          draftStart = point;
          break;
        }
        final inherited = _inheritedDayOrigin(planDay, draft: true);
        final ownEnd = dayEnd(planDay, draft: true)?.point;
        if (_samePlace(point, inherited) || _samePlace(point, ownEnd)) {
          draftHalts = [
            for (final halt in draftHalts)
              if (!(halt.day == planDay && halt.kind == HaltKind.dayStart)) halt,
          ];
          planNote = inherited == null
              ? 'Set day ${planDay - 1}\'s end. Day $planDay starts there.'
              : 'Day $planDay starts at day ${planDay - 1}\'s end.';
          break;
        }
        draftHalts = [
          for (final halt in draftHalts)
            if (!(halt.day == planDay && halt.kind == HaltKind.dayStart)) halt,
          RideHalt(id: id, name: name, point: point, day: planDay, kind: HaltKind.dayStart),
        ];
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
    if (planScreen == PlanScreen.map) planScreen = PlanScreen.day;
    if (_legOrigin(planDay) != null && _planDestination() != null) {
      _loadPlanRoads();
      return;
    }
    planFit++;
    notifyListeners();
  }

  LatLng? _legOrigin(int day) => _dayOrigin(day, draft: true);

  /// Where a day begins. Later days begin at the previous day's end.
  /// A start dropped on that same point, or on this day's own end, stays there.
  LatLng? _dayOrigin(int day, {required bool draft}) {
    final tripStart = draft ? draftStart : startPoint;
    if (day <= 1) return tripStart;
    final inherited = _inheritedDayOrigin(day, draft: draft);
    final custom = dayStart(day, draft: draft);
    if (custom == null) return inherited;
    if (_samePlace(custom.point, inherited) || _samePlace(custom.point, dayEnd(day, draft: draft)?.point)) {
      return inherited;
    }
    return custom.point;
  }

  LatLng? _inheritedDayOrigin(int day, {required bool draft}) {
    if (day <= 1) return draft ? draftStart : startPoint;
    return dayEnd(day - 1, draft: draft)?.point ?? (draft ? draftStart : startPoint);
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
  ({LatLng point, String name})? _dayLegDestination([int? day]) {
    final which = day ?? planDay;
    final origin = _legOrigin(which);
    final end = dayEnd(which, draft: true);
    if (end != null && (origin == null || _distance.as(LengthUnit.Meter, origin, end.point) >= 400)) {
      return (point: end.point, name: end.name);
    }
    for (final stop in dayStops(which, draft: true).reversed) {
      if (origin == null || _distance.as(LengthUnit.Meter, origin, stop.point) >= 400) {
        return (point: stop.point, name: stop.name);
      }
    }
    if (which >= draftDays &&
        draftFinish != null &&
        (origin == null || _distance.as(LengthUnit.Meter, origin, draftFinish!) >= 400)) {
      return (point: draftFinish!, name: draftFinishName.isEmpty ? 'Finish' : draftFinishName);
    }
    return null;
  }

  void _loadPlanRoads() {
    for (var day = 1; day <= draftDays; day++) {
      _loadDayRoad(day, alternatives: day == planDay);
    }
  }

  /// Fetches the driving road for [day]. The open day also keeps its alternatives.
  /// Other days are fetched on their own, so each path is a road without a tap.
  void _loadDayRoad(int day, {required bool alternatives}) {
    final origin = _legOrigin(day);
    final end = _dayLegDestination(day);
    if (origin == null || end == null) {
      if (!alternatives) return;
      planNote = draftStart == null ? 'Set a start, then choose the day end to see the roads.' : planNote;
      planFit++;
      notifyListeners();
      return;
    }
    final saved = _dayRoutes[day];
    final marks = _dayMarks(day, draft: true);
    if (!alternatives && saved != null && saved.points.length >= 2 && _roadFitsMarks(saved.points, marks)) {
      return;
    }
    if (!MapsBridge.available) {
      if (!alternatives) return;
      planNote = 'Roads show on the live map.';
      planFit++;
      notifyListeners();
      return;
    }
    if (alternatives) {
      destinationName = end.name;
      planNote = 'Finding roads…';
      routes = [];
      selectedRoute = 0;
      navigating = false;
      navArrived = false;
      notifyListeners();
    }
    final generation = (_planRoadGeneration[day] ?? 0) + 1;
    _planRoadGeneration[day] = generation;
    final placeId = '${end.point.latitude},${end.point.longitude}';
    final via = <LatLng>[
      for (final stop in dayStops(day, draft: true))
        if (_distance.as(LengthUnit.Meter, origin, stop.point) >= 400 &&
            _distance.as(LengthUnit.Meter, end.point, stop.point) >= 400)
          stop.point,
    ];
    unawaited(() async {
      try {
        final found = await MapsBridge.directions(origin: origin, placeId: placeId, via: via);
        if (_planRoadGeneration[day] != generation) return;
        final roads = found.where((route) => route.points.length >= 2).toList();
        if (roads.isEmpty) {
          if (alternatives && planDay == day) planNote = 'No road between these places.';
        } else {
          _dayRoutes[day] = roads.first;
          if (alternatives && planDay == day) {
            routes = roads;
            selectedRoute = 0;
            routeFit += 1;
            planNote = '${roads.first.duration} · ${roads.first.distance}';
            if (fuelOn) unawaited(_loadSelectedRoadFuel(roads.first.points));
          }
          if (planPumpsOn || planTollsOn) unawaited(_loadPlanStops());
        }
      } catch (error) {
        if (_planRoadGeneration[day] != generation) return;
        if (alternatives && planDay == day) {
          routes = [];
          planNote = _bridgeMessage(error);
        }
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
      _joinedPack = adminId != null && adminId != riderId;
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
    this.startDate,
    this.startMinutes = const {},
    this.endMinutes = const {},
    this.route,
  });

  final int updatedAt;
  final int days;
  final DateTime? startDate;
  final String startName;
  final LatLng? start;
  final String finishName;
  final LatLng? finish;
  final List<RideHalt> halts;

  /// Minutes from midnight, keyed by day.
  final Map<int, int> startMinutes;
  final Map<int, int> endMinutes;
  final RouteChoice? route;
}

String encodeSharedPlan(SharedPlan plan) {
  return jsonEncode({
    'days': plan.days.clamp(1, 14),
    'startDate': _dateJson(plan.startDate),
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
    'dayTimes': [
      for (final day in {...plan.startMinutes.keys, ...plan.endMinutes.keys})
        {
          'day': day,
          if (plan.startMinutes[day] != null) 'start': plan.startMinutes[day],
          if (plan.endMinutes[day] != null) 'end': plan.endMinutes[day],
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
    final startMinutes = <int, int>{};
    final endMinutes = <int, int>{};
    final rawTimes = body['dayTimes'];
    if (rawTimes is List) {
      for (final item in rawTimes) {
        if (item is! Map) continue;
        final day = (_num(item['day']) ?? 0).round();
        if (day < 1 || day > 14) continue;
        final start = _num(item['start']);
        final end = _num(item['end']);
        if (start != null) startMinutes[day] = start.round().clamp(0, 24 * 60 - 1);
        if (end != null) endMinutes[day] = end.round().clamp(0, 24 * 60 - 1);
      }
    }
    return SharedPlan(
      updatedAt: (_num(body['updatedAt']) ?? 0).round(),
      days: (_num(body['days']) ?? 1).round().clamp(1, 14),
      startDate: _date(body['startDate']),
      startName: body['startName'] is String ? body['startName'] as String : '',
      start: _point(body['start']),
      finishName: body['finishName'] is String ? body['finishName'] as String : '',
      finish: _point(body['finish']),
      halts: halts,
      startMinutes: startMinutes,
      endMinutes: endMinutes,
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

const _planMonths = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String formatPlanDate(DateTime date) => '${date.day} ${_planMonths[date.month - 1]}';

/// 12-hour clock from minutes past midnight.
String formatClock(int minute) {
  final wrapped = minute % (24 * 60);
  final hour24 = wrapped ~/ 60;
  final mins = wrapped % 60;
  final period = hour24 >= 12 ? 'PM' : 'AM';
  final hour = hour24 % 12 == 0 ? 12 : hour24 % 12;
  return '$hour:${mins.toString().padLeft(2, '0')} $period';
}

String formatPlanSpan(DateTime start, int days) {
  final from = DateTime(start.year, start.month, start.day);
  final to = from.add(Duration(days: max(1, days) - 1));
  if (days <= 1) return formatPlanDate(from);
  if (from.month == to.month && from.year == to.year) return '${from.day}–${to.day} ${_planMonths[to.month - 1]}';
  return '${formatPlanDate(from)} – ${formatPlanDate(to)}';
}

String? _dateJson(DateTime? date) {
  if (date == null) return null;
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

DateTime? _date(Object? raw) {
  if (raw is! String) return null;
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw);
  if (match == null) return null;
  return DateTime(int.parse(match.group(1)!), int.parse(match.group(2)!), int.parse(match.group(3)!));
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
    'traffic': route.traffic,
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
    traffic: raw['traffic'] == true,
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

String _formatDuration(int seconds) {
  final total = max(1, (seconds / 60).round());
  final hours = total ~/ 60;
  final mins = total % 60;
  if (hours == 0) return '$total min';
  if (mins == 0) return '$hours hr';
  return '$hours hr $mins min';
}

String _formatDistance(int meters) {
  if (meters < 1000) return '$meters m';
  if (meters < 10000) return '${(meters / 1000).toStringAsFixed(1)} km';
  return '${(meters / 1000).round()} km';
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
