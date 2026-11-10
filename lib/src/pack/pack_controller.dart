import 'dart:async';
import 'dart:math';

import 'package:latlong2/latlong.dart';

import '../geo.dart';
import '../location_service.dart';
import '../navigation/maps_types.dart';
import 'pack_repository.dart';
import '../ride/ride_controller.dart';
import '../ride/ride_repository.dart';

class PackController {
  PackController(
    this.ride, {
    required this.location,
    required this.packRepo,
    required this.rideRepo,
  });

  final RideController ride;
  final LocationService location;
  final PackRepository packRepo;
  final RideRepository rideRepo;

  StreamSubscription<Position>? _gpsWatch;
  StreamSubscription<List<RemoteRider>>? _riders;
  bool showOthers = true;
  bool gpsSeeking = false;
  bool gpsLocked = false;
  String gpsReason = '';
  double traveledKm = 0;
  DateTime? gpsAt;
  LatLng? gpsFix;
  double? _course;

  /// Degrees clockwise from north, from the last GPS move. Null before any move.
  double? get course => _course;
  final Set<String> removed = {};
  final Map<String, RemoteRider> remote = {};

  /// Pump this phone last came within [_fuelReach] of. Kept for the ride.
  RiderStop? lastFuelStop;

  /// Nearest halt still ahead today, or null when the day has none.
  RiderStop? get nextPlanStop {
    final halt = ride.plan.nextHalt;
    if (halt == null) return null;
    return RiderStop(name: halt.name, lat: halt.point.latitude, lng: halt.point.longitude);
  }
  bool get youBreaking => ride.radio.holding('you');
  List<PackRow> get packRows {
    final now = ride.now();
    final rows = <PackRow>[
      PackRow(
        id: ride.riderId,
        name: ride.riderName,
        role: ride.roleFor(ride.riderId),
        you: true,
        km: 0,
        ahead: false,
        online: !ride.ended,
        dropping: false,
        breaking: youBreaking,
      ),
    ];
    for (final rider in remote.values) {
      if (removed.contains(rider.id) || rider.id == ride.riderId) continue;
      final km = ride.kmBetween(ride.you, LatLng(rider.lat, rider.lng));
      rows.add(
        PackRow(
          id: rider.id,
          name: rider.name,
          role: ride.roleFor(rider.id),
          you: false,
          km: km,
          ahead: false,
          online: now.difference(rider.updatedAt) <= RideController.staleAfter,
          dropping: km > RideController.dropKm,
          breaking: false,
        ),
      );
    }
    return rows;
  }

  List<MapRider> get mapRiders {
    final pins = <MapRider>[
      MapRider(
        id: ride.riderId,
        name: 'YOU',
        point: ride.you,
        you: true,
        shared: false,
        breaking: youBreaking,
        mark: -1,
      ),
    ];
    if (!showOthers) return pins;
    final used = <int>{};
    for (final rider in remote.values) {
      if (removed.contains(rider.id) || rider.id == ride.riderId) continue;
      pins.add(
        MapRider(
          id: rider.id,
          name: rider.name,
          point: LatLng(rider.lat, rider.lng),
          you: false,
          shared: true,
          breaking: false,
          mark: _claimMark(rider.id, used),
        ),
      );
    }
    return pins;
  }

  void removeRider(String id) {
    if (id == ride.riderId || removed.contains(id)) return;
    removed.add(id);
    remote.remove(id);
    if (ride.radio.sos?.id == id) ride.radio.sos = null;
    ride.changed();
    if (ride.network) {
      unawaited(packRepo.deleteRider(ride.code, id).catchError((_) {}));
    }
  }

  void toggleOthers() {
    showOthers = !showOthers;
    ride.changed();
  }

  Future<void> requestGps() async {
    if (ride.ended || gpsLocked) return;
    gpsSeeking = true;
    gpsReason = '';
    ride.changed();
    try {
      final permission = await location.ensurePermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        gpsReason = 'Location permission denied.';
        gpsSeeking = false;
        ride.changed();
        return;
      }
      final position = await location.currentPosition();
      _applyFix(position);
      gpsLocked = true;
      watchGps();
    } catch (error) {
      gpsLocked = false;
      gpsReason = 'GPS is not available in this browser.';
    } finally {
      gpsSeeking = false;
      ride.changed();
    }
  }

  void placeYou(LatLng point) {
    if (ride.ended || gpsLocked) return;
    final previous = gpsFix;
    if (previous != null) {
      final moved = ride.metersBetween(previous, point);
      if (moved >= 4) _course = headingTo(previous, point);
      traveledKm += moved / 1000;
    }
    gpsFix = point;
    gpsAt = ride.now();
    _rememberFuel(point);
    final drive = ride.nav.activeRoad;
    if (ride.nav.navigating && drive != null && drive.points.length >= 2) {
      final length = lengthKm(drive.points);
      ride.nav.navKm = min(length, traveledAlong(drive.points, point));
      ride.nav.navArrived = length > 0 && ride.nav.navKm >= length - 0.05;
      ride.nav.syncStep();
    }
    ride.changed();
    if (!ride.network || ride.paused || !ride.onRide) return;
    unawaited(publishFix(point, gpsAt!).catchError((_) {}));
  }

  void _applyFix(Position position) {
    final next = LatLng(position.latitude, position.longitude);
    final previous = gpsFix;
    if (previous != null) {
      final moved = ride.metersBetween(previous, next);
      if (moved >= 4) _course = headingTo(previous, next);
      traveledKm += moved / 1000;
    }
    if (position.heading >= 0 && position.speed >= 0.8) {
      _course = position.heading;
    }
    gpsFix = next;
    gpsAt = ride.now();
    _rememberFuel(next);
    gpsReason = '';
    ride.changed();
  }

  void watchGps() {
    unawaited(_gpsWatch?.cancel());
    _gpsWatch = location.positionStream().listen(
      _applyFix,
      onError: (_) {
        gpsReason = 'GPS is holding the last fix.';
        ride.changed();
      },
    );
  }

  /// Cancels the live watch but keeps the last fix, for a pause.
  void suspendGps() {
    unawaited(_gpsWatch?.cancel());
    _gpsWatch = null;
  }

  /// Cancels the watch and drops the fix, for an ended ride.
  void stopGps() {
    gpsLocked = false;
    gpsFix = null;
    gpsAt = null;
    suspendGps();
  }

  List<JoinedPhone> get joinedPhones {
    final others = [
      for (final rider in remote.values)
        if (rider.id != ride.riderId && !removed.contains(rider.id))
          JoinedPhone(label: rider.name, you: false),
    ]..sort((a, b) => a.label.compareTo(b.label));
    return [JoinedPhone(label: ride.riderName, you: true), ...others];
  }

  int _claimMark(String id, Set<int> used) {
    var hash = 0;
    for (final code in id.codeUnits) {
      hash = (hash * 33 + code) & 0x7fffffff;
    }
    var slot = hash % RideController.riderMarkCount;
    if (used.contains(slot)) {
      for (var i = 0; i < RideController.riderMarkCount; i++) {
        final next = (slot + i) % RideController.riderMarkCount;
        if (!used.contains(next)) {
          slot = next;
          break;
        }
      }
    }
    used.add(slot);
    return slot;
  }

  /// Subscribes to the live pack for the current code. Other phones push
  /// changes; this phone does not poll them.
  void listenPack() {
    unawaited(_riders?.cancel());
    final code = ride.code;
    if (!ride.network || code.isEmpty) {
      _riders = null;
      return;
    }
    _riders = packRepo.watchRiders(code).listen((riders) {
      if (ride.code != code || riders.isEmpty) return;
      remote
        ..clear()
        ..addEntries(
          riders
              .where((rider) => rider.id != ride.riderId && !removed.contains(rider.id))
              .map((rider) => MapEntry(rider.id, rider)),
        );
      if (ride.joinNote.startsWith('Joining ')) ride.joinNote = '';
      ride.changed();
    }, onError: (_) {
      ride.joinNote = 'Could not reach the ride.';
      ride.changed();
    });
  }

  void dropLive() {
    lastFuelStop = null;
    unawaited(_riders?.cancel());
    _riders = null;
  }

  Future<void> announce(String code) {
    final here = gpsFix ?? ride.you;
    _rememberFuel(here);
    return packRepo.addRider(
      code: code,
      id: ride.riderId,
      name: ride.riderName,
      lat: here.latitude,
      lng: here.longitude,
      at: ride.now(),
      nextPlanStop: nextPlanStop,
      lastFuelStop: lastFuelStop,
    );
  }

  Future<void> publishFix(LatLng point, DateTime at) {
    _rememberFuel(point);
    return packRepo.pushLocation(
      code: ride.code,
      id: ride.riderId,
      name: ride.riderName,
      lat: point.latitude,
      lng: point.longitude,
      at: at,
      nextPlanStop: nextPlanStop,
      lastFuelStop: lastFuelStop,
    );
  }

  static const _fuelReach = 150.0;

  void _rememberFuel(LatLng here) {
    FuelPump? best;
    var bestM = _fuelReach;
    for (final pump in ride.plan.shownPumps) {
      final meters = ride.metersBetween(here, pump.point);
      if (meters <= bestM) {
        best = pump;
        bestM = meters;
      }
    }
    if (best == null) return;
    lastFuelStop = RiderStop(
      name: best.name,
      lat: best.point.latitude,
      lng: best.point.longitude,
    );
  }

  Future<void> syncGroup() async {
    if (ride.ended || !ride.onRide) return;
    try {
      final here = gpsFix;
      if (!ride.paused && gpsLocked && here != null) {
        await publishFix(here, ride.now());
      }
      final record = await rideRepo.rideRecord(ride.code);
      if (record.sos != null) ride.radio.debugOfferSos(record.sos!);
      ride.plan.acceptSharedPlan(record.planJson, record.planUpdatedAt);
      ride.applyLead(record.adminId);
      if (ride.joinNote.startsWith('Joining ') ||
          ride.joinNote == 'Could not reach the ride.') {
        ride.joinNote = '';
      }
    } catch (_) {
      ride.joinNote = 'Could not reach the ride.';
    }
    ride.changed();
  }

  void dispose() {
    unawaited(_gpsWatch?.cancel());
    unawaited(_riders?.cancel());
  }
}
