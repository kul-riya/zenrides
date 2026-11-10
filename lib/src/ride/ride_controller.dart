import 'dart:async';
import 'dart:math';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../auth/auth_repository.dart';
import '../auth/auth_service.dart';
import '../location_service.dart';
import '../navigation/map_adapter.dart';
import '../navigation/navigation_repository.dart';
import '../pack/pack_repository.dart';
import 'ride_repository.dart';
import '../broadcast/broadcast_controller.dart';
import '../navigation/navigation_controller.dart';
import '../pack/pack_controller.dart';
import '../planning/planning_controller.dart';
import '../planning/shared_plan.dart';

export '../broadcast/broadcast_controller.dart';
export '../navigation/navigation_controller.dart';
export '../pack/pack_controller.dart';
export '../planning/planning_controller.dart';
export '../planning/shared_plan.dart';

enum RideTab { hud, pack, toll, tours }

enum NoticeKind { pack, fuel, chai, hazard, slow, regroup, sos }

/// idle: no code joined. live: tracking and broadcasting. paused: tracking
/// held without ending. ended: this ride is over; a new code starts fresh.
enum RidePhase { idle, live, paused, ended }

class RideNotice {
  const RideNotice({
    required this.kind,
    required this.kicker,
    required this.body,
  });

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

Color dayColor(int day) =>
    dayPalette[(day <= 1 ? 0 : day - 1) % dayPalette.length];

/// One colored line on the planning map. [alternative] is set for a road
/// the rider can still tap on the day they are editing.
class DayPath {
  const DayPath({
    required this.day,
    required this.points,
    required this.selected,
    this.alternative,
  });

  final int day;
  final List<LatLng> points;
  final bool selected;
  final int? alternative;
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
  RideController({
    DateTime Function()? clock,
    LocationService? location,
    MapAdapter? maps,
    AuthService? authService,
    AuthRepository? authRepository,
    PackRepository? packRepository,
    RideRepository? rideRepository,
    NavigationRepository? navigationRepository,
    this._network = true,
  }) : _clock = clock ?? DateTime.now,
       _location = location ?? const DeviceLocationService(),
       _maps = maps ?? const GoogleMapsAdapter(),
       _authService = authService ?? const FirebaseAuthService(),
       _authRepo = authRepository ?? AuthRepository(),
       _packRepo = packRepository ?? PackRepository(),
       _rideRepo = rideRepository ?? RideRepository(),
       _navRepo = navigationRepository ?? NavigationRepository() {
    pack = PackController(
      this,
      location: _location,
      packRepo: _packRepo,
      rideRepo: _rideRepo,
    );
    nav = NavigationController(this, maps: _maps, navRepo: _navRepo);
    plan = PlanningController(
      this,
      maps: _maps,
      navRepo: _navRepo,
      rideRepo: _rideRepo,
    );
    radio = BroadcastController(this, rideRepo: _rideRepo);
    plan.dayStarted = _clock();
  }

  late final PackController pack;
  late final NavigationController nav;
  late final PlanningController plan;
  late final BroadcastController radio;

  /// Feature objects are not the notifier. They call this after a change.
  void changed() => notifyListeners();

  static const riderMarkCount = 6;
  static const overviewZoom = 14.0;
  static const recenterZoom = 15.0;
  static const staleAfter = Duration(seconds: 12);
  static const dropKm = 0.5;
  static const parked = LatLng(18.3706, 73.8540);
  final DateTime Function() _clock;
  final LocationService _location;
  final MapAdapter _maps;
  final AuthService _authService;
  final AuthRepository _authRepo;
  final PackRepository _packRepo;
  final RideRepository _rideRepo;
  final NavigationRepository _navRepo;
  final bool _network;
  final Distance _distance = const Distance();
  Timer? _motion;
  Timer? _sync;
  Timer? _hazards;
  bool _started = false;
  RideTab tab = RideTab.hud;

  /// idle until users/{uid}.rideCode names a ride that still exists.
  RidePhase _phase = RidePhase.idle;
  bool admin = false;
  String? leadId;
  bool _joinedPack = false;
  String joinNote = '';
  String riderId = 'you';
  String riderName = 'Joe';
  String code = '';
  bool _signedIn = true;
  bool get signedIn => _signedIn;
  RidePhase get phase => _phase;

  /// On a code, whether live, paused, or ended. False only once idle.
  bool get onRide => _phase != RidePhase.idle;
  bool get paused => _phase == RidePhase.paused;
  bool get ended => _phase == RidePhase.ended;
  LatLng get you => pack.gpsFix ?? plan.startPoint ?? parked;

  /// This phone can plan unless it joined a ride someone else leads.
  bool get canPlan => admin || !_joinedPack;

  /// Lead is the rider id stored on the ride. Everyone else is pack.
  String get youRole => admin ? 'Lead Pilot' : 'Pack rider';
  String roleFor(String id) => id == riderId ? youRole : (id == leadId ? 'Lead Pilot' : 'Pack rider');
  DateTime now() => _clock();

  /// False in tests and anywhere the phone must not talk to Firebase or Maps.
  bool get network => _network;
  double metersBetween(LatLng a, LatLng b) =>
      _distance.as(LengthUnit.Meter, a, b);
  double kmBetween(LatLng a, LatLng b) =>
      _distance.as(LengthUnit.Kilometer, a, b);
  double kmTo(LatLng point) => kmBetween(you, point);
  Future<void> restoreIdentity() async {
    var user = _authService.currentUser;
    if (user == null && _network) {
      try {
        user = await _authService.signInAnonymously();
      } catch (_) {}
    }
    if (user != null) {
      riderId = user.uid;
      final named = user.displayName?.trim() ?? '';
      riderName = named.isEmpty ? riderLabelFor(user.uid) : named;
      if (_network) {
        try {
          final profile = await _authRepo.ensureUser(
            uid: user.uid,
            name: riderName,
          );
          riderName = profile.name;
          if (profile.rideCode.isEmpty) {
            _dropCode();
          } else {
            await _openStoredRide(profile.rideCode);
          }
        } catch (_) {}
      }
    }
    plan.dayStarted ??= _clock();
    if (onRide) _noteRole();
    notifyListeners();
  }

  Future<void> _openStoredRide(String rideCode) async {
    final record = await _rideRepo.rideRecord(rideCode);
    if (!record.exists) {
      _dropCode();
      _rememberRide('', asAdmin: false);
      return;
    }
    code = rideCode;
    _phase = RidePhase.live;
    leadId = record.adminId;
    admin = record.adminId != null && record.adminId == riderId;
    _joinedPack = record.adminId != null && record.adminId != riderId;
    final riders = await _packRepo.riders(rideCode);
    pack.remote
      ..clear()
      ..addEntries(
        riders.where((rider) => rider.id != riderId).map((rider) => MapEntry(rider.id, rider)),
      );
    _loadLiveRoute();
  }

  void _dropCode() {
    code = '';
    _phase = RidePhase.idle;
    admin = false;
    leadId = null;
    _joinedPack = false;
    pack.remote.clear();
  }

  Future<void> logOut() async {
    _dropCode();
    pack.dropLive();
    _signedIn = false;
    notifyListeners();
    if (!_network) return;
    try {
      await _authService.signOut();
    } catch (_) {}
  }

  void start() {
    if (_started) return;
    _started = true;
    plan.dayStarted ??= _clock();
    _motion = Timer.periodic(const Duration(milliseconds: 200), (_) => tick());
    if (_network) {
      pack.listenPack();
      _sync = Timer.periodic(
        const Duration(seconds: 4),
        (_) => pack.syncGroup(),
      );
      unawaited(pack.syncGroup());
      _hazards = Timer.periodic(
        const Duration(seconds: 45),
        (_) => nav.refreshHazards(),
      );
      unawaited(nav.refreshHazards());
    }
  }

  void tick([Duration _ = const Duration(milliseconds: 200)]) {
    if (ended || paused || !pack.gpsLocked) return;
    nav.syncStep();
    notifyListeners();
  }

  /// Load the current riding day's planned route into nav so it displays on the HUD.
  void _loadLiveRoute() {
    final road = plan.roadFor(plan.ridingDay);
    if (road != null && road.points.length >= 2) {
      nav.routes = [road];
      nav.selectedRoute = 0;
      nav.routeFit += 1;
    }
  }

  void selectTab(RideTab next) {
    tab = next;
    notifyListeners();
  }

  /// live ⇄ paused. Paused actually suspends the GPS watch (not just the
  /// sync to Firestore), so YOU stops moving on the map until resumed.
  void togglePause() {
    switch (_phase) {
      case RidePhase.live:
        _phase = RidePhase.paused;
        pack.suspendGps();
      case RidePhase.paused:
        _phase = RidePhase.live;
        if (pack.gpsLocked) pack.watchGps();
      case RidePhase.idle:
      case RidePhase.ended:
        return;
    }
    notifyListeners();
  }

  void endRide() {
    if (ended) return;
    _phase = RidePhase.ended;
    nav.fuelOn = false;
    nav.pumps = [];
    nav.clearDirections();
    pack.stopGps();
    notifyListeners();
  }

  void deleteRide() {
    final leavingCode = code;
    final wasOnRide = onRide;
    plan.planning = false;
    plan.picking = false;
    _phase = RidePhase.idle;
    admin = false;
    leadId = null;
    _joinedPack = false;
    nav.navigating = false;
    nav.navArrived = false;
    nav.fuelOn = false;
    nav.pumps = [];
    plan.clearOverlays();
    nav.routes = [];
    nav.selectedRoute = 0;
    plan.draftHalts = [];
    plan.draftStart = null;
    plan.draftStartName = '';
    plan.draftFinish = null;
    plan.draftFinishName = '';
    plan.draftDays = 1;
    plan.draftStartDate = null;
    plan.planDay = 1;
    plan.planHits = [];
    plan.planNote = '';
    pack.remote.clear();
    pack.dropLive();
    radio.sos = null;
    radio.notice = null;
    plan.summary = null;
    nav.destinationName = '';
    nav.searchNote = '';
    nav.suggestions = [];
    plan.clearSaved();
    code = '';
    joinNote = 'Ride deleted.';
    plan.shareNote = '';
    tab = RideTab.hud;
    notifyListeners();
    if (!_network || !wasOnRide || leavingCode.isEmpty) return;
    unawaited(_rideRepo.deleteRideDocument(leavingCode).catchError((_) {}));
    unawaited(_packRepo.deleteLiveRide(leavingCode).catchError((_) {}));
    _rememberRide('', asAdmin: false);
  }

  void leaveRide() {
    final leavingCode = code;
    final leavingId = riderId;
    _phase = RidePhase.idle;
    plan.planning = false;
    plan.picking = false;
    pack.remote.clear();
    pack.dropLive();
    joinNote = '';
    code = '';
    notifyListeners();
    admin = false;
    leadId = null;
    _joinedPack = false;
    if (_network) {
      unawaited(
        _packRepo.deleteRider(leavingCode, leavingId).catchError((_) {}),
      );
    }
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
    _phase = RidePhase.live;
    admin = false;
    leadId = null;
    _joinedPack = true;
    joinNote = _network ? 'Joining $next…' : 'Could not reach the ride.';
    _noteRole();
    pack.remote.clear();
    plan.clearSaved();
    nav.dropIdleRoute();
    _loadLiveRoute();
    notifyListeners();
    if (_network) {
      pack.listenPack();
      unawaited(_announceRider(next));
      unawaited(pack.syncGroup());
      unawaited(_adoptRide(next));
    }
    return next;
  }

  Future<void> _announceRider(String rideCode) async {
    try {
      await pack.announce(rideCode);
    } catch (_) {}
  }

  String generateCode() {
    final rand = Random();
    final next = 'ZEN-${1000 + rand.nextInt(9000)}';
    code = next;
    _phase = RidePhase.live;
    admin = true;
    leadId = riderId;
    _joinedPack = false;
    _noteRole();
    joinNote = '';
    pack.remote.clear();
    _loadLiveRoute();
    notifyListeners();
    if (_network) {
      pack.listenPack();
      unawaited(
        _rideRepo.claimRide(next, riderId).then((_) {}, onError: (Object _) {}),
      );
      unawaited(_announceRider(next));
      unawaited(plan.pushCurrentPlan());
      unawaited(pack.syncGroup());
      _rememberRide(next, asAdmin: true);
    }
    return next;
  }

  @override
  void dispose() {
    _motion?.cancel();
    _sync?.cancel();
    _hazards?.cancel();
    nav.dispose();
    plan.dispose();
    pack.dispose();
    super.dispose();
  }

  void _rememberRide(String rideCode, {required bool asAdmin}) {
    if (!_network) return;
    unawaited(
      _authRepo
          .setMembership(
            riderId,
            rideCode: rideCode,
            role: asAdmin ? 'admin' : 'rider',
          )
          .then((_) {}, onError: (Object _) {}),
    );
  }

  void applyLead(String? id) {
    if (id == null || id.isEmpty) return;
    final changed = id != leadId;
    leadId = id;
    admin = id == riderId;
    _joinedPack = !admin;
    if (changed) _noteRole();
  }

  void _noteRole() {
    final current = radio.notice;
    if (current != null && current.kind != NoticeKind.pack) return;
    radio.notice = RideNotice(
      kind: NoticeKind.pack,
      kicker: 'BROADCAST: PACK NOTICE · You ($youRole)',
      body: current?.body ?? 'New ride started. Share code $code for the pack to attach.',
    );
  }

  Future<void> _adoptRide(String rideCode) async {
    try {
      final adminId = await _authRepo.rideAdmin(rideCode);
      if (code != rideCode) return;
      if (adminId == null) {
        leadId = null;
        admin = false;
        _joinedPack = false;
        _noteRole();
      } else {
        applyLead(adminId);
      }
      notifyListeners();
      _rememberRide(rideCode, asAdmin: admin);
    } catch (_) {
      _rememberRide(rideCode, asAdmin: false);
    }
  }
}
