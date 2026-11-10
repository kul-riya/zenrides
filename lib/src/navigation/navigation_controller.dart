import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../geo.dart';
import 'map_adapter.dart';
import 'navigation_repository.dart';
import '../repository_exception.dart';
import '../ride/ride_controller.dart';

class NavigationController {
  NavigationController(
    this.ride, {
    required this.maps,
    required this.navRepo,
  });

  final RideController ride;
  final MapAdapter maps;
  final NavigationRepository navRepo;

  Timer? _searchDebounce;
  int _searchGeneration = 0;
  bool fuelOn = false;
  String fuelNote = '';
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
  double cruiseKmh = 62;
  List<FuelPump> pumps = [];
  List<RoadHazard> roadHazards = [];
  List<String> hazardFailures = [];
  int _fuelGeneration = 0;
  double get routeKm {
    final drive = activeRoad;
    if (drive == null) return 0;
    return drive.distanceMeters > 0
        ? drive.distanceMeters / 1000
        : lengthKm(drive.points);
  }

  /// The blue line is a search or a live ride. A saved plan does not draw one.
  bool get showHudRoute =>
      !ride.plan.planning &&
      routes.isNotEmpty &&
      (navigating || previewingRoute);
  /// The road the HUD is following, after a search or a start.
  RouteChoice? get activeRoad {
    if (routes.isEmpty) return null;
    final index = selectedRoute.clamp(0, routes.length - 1);
    return routes[index];
  }

  double get remainingKm {
    final drive = activeRoad;
    if (drive == null) return 0;
    final length = drive.distanceMeters > 0
        ? drive.distanceMeters / 1000
        : lengthKm(drive.points);
    if (ride.pack.gpsFix != null) return remainingAlong(drive.points, ride.you);
    return length;
  }

  int get remainingMinutes {
    final drive = activeRoad;
    if (drive == null) return 0;
    final length = drive.distanceMeters > 0
        ? drive.distanceMeters / 1000
        : lengthKm(drive.points);
    if (length <= 0) return 0;
    final seconds = drive.durationSeconds > 0
        ? drive.durationSeconds * (remainingKm / length)
        : remainingKm / cruiseKmh * 3600;
    return max(1, (seconds / 60).round());
  }

  String get arrivalLabel {
    final at = ride.now().add(Duration(minutes: remainingMinutes));
    final hour = at.hour % 12 == 0 ? 12 : at.hour % 12;
    final minute = at.minute.toString().padLeft(2, '0');
    final suffix = at.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $suffix';
  }

  RouteStep? get nextStep {
    final drive = activeRoad;
    if (drive == null || drive.steps.isEmpty) return null;
    final index = stepIndex.clamp(0, drive.steps.length - 1);
    return drive.steps[index];
  }

  double? get nearestPumpMeters {
    if (!navigating) return null;
    final drive = activeRoad;
    if (drive == null || pumps.isEmpty) return null;
    final hereKm = ride.pack.gpsFix != null
        ? traveledAlong(drive.points, ride.you)
        : 0.0;
    double? best;
    for (final pump in pumps) {
      final ahead = (traveledAlong(drive.points, pump.point) - hereKm) * 1000;
      if (ahead < -80) continue;
      final gap = max(0.0, ahead);
      if (best == null || gap < best) best = gap;
    }
    return best;
  }

  double get bearing {
    final drive = activeRoad;
    if (!navigating || drive == null || drive.points.length < 2) return 0;
    return _headingAlong(drive.points, ride.you);
  }

  /// Degrees clockwise from north, along the way the rider is moving.
  double get travelHeading {
    if (!ride.ended && ride.pack.gpsLocked && ride.pack.course != null) {
      return ride.pack.course!;
    }
    final drive = activeRoad;
    if (navigating &&
        ride.pack.gpsFix != null &&
        drive != null &&
        drive.points.length >= 2) {
      return _headingAlong(drive.points, ride.you);
    }
    return ride.pack.course ?? 0;
  }

  List<RoadHazard> get nearbyHazards {
    return [
      for (final hazard in roadHazards)
        if (hazard.point == null || ride.kmTo(hazard.point!) <= 2) hazard,
    ];
  }

  Future<void> refreshHazards() async {
    if (ride.ended || !ride.network || !maps.available) return;
    try {
      final report = await maps.hazards(ride.you, travelHeading);
      roadHazards = report.hazards;
      hazardFailures = report.failures;
    } catch (error) {
      final text = error.toString().replaceFirst('Exception: ', '');
      hazardFailures = ['Routes API Route.computeRoutes: $text'];
    }
    ride.changed();
  }

  void toggleFuel() {
    if (fuelOn) {
      fuelOn = false;
      pumps = [];
      fuelNote = '';
      if (ride.radio.notice?.kind == NoticeKind.fuel) ride.radio.notice = null;
      ride.changed();
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
    ride.radio.notice = RideNotice(
      kind: NoticeKind.fuel,
      kicker: 'BROADCAST: FUEL STOP · You (${ride.youRole})',
      body: road != null
          ? 'Fuel stop. Pumps on this road only.'
          : 'Fuel stop. Pack, roll in and hold the stagger.',
    );
    ride.changed();
    if (!ride.network) return;
    if (road == null) {
      if (planned) {
        pumps = [];
        ride.changed();
        return;
      }
      final here = ride.you;
      unawaited(() async {
        try {
          final found = await _lookupFuel(here);
          if (!fuelOn) return;
          pumps = found;
          pumpFit += 1;
          fuelNote = found.isEmpty
              ? 'No petrol pumps within 15 km.'
              : '${found.length} petrol pump${found.length == 1 ? '' : 's'} within 15 km.';
          ride.radio.notice = RideNotice(
            kind: NoticeKind.fuel,
            kicker: 'BROADCAST: FUEL STOP · You (${ride.youRole})',
            body: fuelNote,
          );
        } catch (error) {
          if (!fuelOn) return;
          fuelNote = error is RideApiException
              ? error.message
              : 'Fuel lookup failed';
        }
        ride.changed();
      }());
      return;
    }
    unawaited(_loadSelectedRoadFuel(road));
  }

  bool get _hasPlan => ride.plan.hasPlaces;
  List<LatLng>? _selectedRoad() {
    final drive = activeRoad;
    if (drive != null && drive.points.length >= 2) return drive.points;
    return null;
  }

  Future<void> _loadSelectedRoadFuel(List<LatLng> road) async {
    final generation = ++_fuelGeneration;
    try {
      List<FuelPump> found = const [];
      if (kIsWeb && maps.available) {
        try {
          found = await maps.fuelAlong(road);
        } catch (_) {
          found = const [];
        }
      }
      if (found.isEmpty) found = await navRepo.fuelAlong(road);
      if (generation != _fuelGeneration || !fuelOn) return;
      pumps = [
        for (final pump in found)
          if (offPathMeters(road, pump.point) <= 400) pump,
      ];
      pumpFit += 1;
      fuelNote = pumps.isEmpty
          ? 'No petrol pumps on this road.'
          : '${pumps.length} petrol pump${pumps.length == 1 ? '' : 's'} on this road.';
      ride.radio.notice = RideNotice(
        kind: NoticeKind.fuel,
        kicker: 'BROADCAST: FUEL STOP · You (${ride.youRole})',
        body: fuelNote,
      );
    } catch (error) {
      if (generation != _fuelGeneration || !fuelOn) return;
      pumps = [];
      fuelNote = error is RideApiException
          ? error.message
          : 'Fuel lookup failed';
    }
    ride.changed();
  }

  Future<List<FuelPump>> _lookupFuel(LatLng here) async {
    if (kIsWeb && maps.available) {
      try {
        return await maps.nearbyFuel(here);
      } catch (error) {
        final fallback = await navRepo.fuelNear(here);
        if (fallback.isNotEmpty) return fallback;
        throw RideApiException(bridgeMessage(error));
      }
    }
    return navRepo.fuelNear(here);
  }

  void lookUp(String query) {
    _searchDebounce?.cancel();
    final trimmed = query.trim();
    if (trimmed.length < 2) {
      suggestions = [];
      searchNote = '';
      ride.changed();
      return;
    }
    if (!ride.network || !maps.available) {
      suggestions = [];
      searchNote = 'Search opens with the live map.';
      ride.changed();
      return;
    }
    final generation = ++_searchGeneration;
    _searchDebounce = Timer(const Duration(milliseconds: 280), () async {
      try {
        final found = await maps.search(trimmed, ride.you);
        if (generation != _searchGeneration) return;
        suggestions = found;
        searchNote = found.isEmpty ? 'No matching places.' : '';
      } catch (error) {
        if (generation != _searchGeneration) return;
        suggestions = [];
        searchNote = bridgeMessage(error);
      }
      ride.changed();
    });
  }

  void setSearchFocused(bool focused) {
    if (searchFocused == focused) return;
    searchFocused = focused;
    ride.changed();
  }

  /// Drops a search line that nobody is riding.
  void dropIdleRoute() {
    if (navigating || previewingRoute) return;
    routes = [];
    selectedRoute = 0;
    destinationName = '';
  }

  void dispose() {
    _searchDebounce?.cancel();
  }

  void choosePlace(PlaceHit place) {
    destinationName = place.name;
    suggestions = [];
    searchNote = 'Finding roads from here…';
    routes = [];
    selectedRoute = 0;
    navigating = false;
    navArrived = false;
    ride.changed();
    final generation = ++_searchGeneration;
    final origin = ride.you;
    unawaited(() async {
      try {
        final found = await maps.directions(
          origin: origin,
          placeId: place.placeId,
        );
        if (generation != _searchGeneration) return;
        routes = found.where((route) => route.points.length >= 2).toList();
        selectedRoute = 0;
        previewingRoute = routes.isNotEmpty;
        routeFit += 1;
        searchNote = routes.isEmpty ? 'No driving route from here.' : '';
        if (fuelOn && routes.isNotEmpty) {
          unawaited(_loadSelectedRoadFuel(routes.first.points));
        }
      } catch (error) {
        if (generation != _searchGeneration) return;
        routes = [];
        previewingRoute = false;
        searchNote = bridgeMessage(error);
      }
      ride.changed();
    }());
  }

  void selectRoute(int index) {
    if (index < 0 || index >= routes.length || index == selectedRoute) return;
    selectedRoute = index;
    navigating = false;
    navArrived = false;
    routeFit += 1;
    if (fuelOn) {
      final road = routes[index].points;
      if (road.length >= 2) unawaited(_loadSelectedRoadFuel(road));
    }
    ride.changed();
  }

  void startNavigation() {
    final drive = activeRoad;
    if (drive == null || drive.points.length < 2) return;
    navigating = true;
    navArrived = false;
    navKm = 0;
    stepIndex = 0;
    navFit += 1;
    syncStep();
    ride.changed();
  }

  void stopNavigation() {
    if (!navigating && !navArrived) return;
    navigating = false;
    navArrived = false;
    routeFit += 1;
    ride.changed();
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
    ride.changed();
  }

  void syncStep() {
    final drive = activeRoad;
    if (!navigating || drive == null || drive.steps.isEmpty) return;
    final here = ride.you;
    var upcoming = drive.steps.length - 1;
    for (var i = 0; i < drive.steps.length; i++) {
      final meters = ride.metersBetween(here, drive.steps[i].point);
      if (meters > 40) {
        upcoming = i;
        break;
      }
    }
    stepIndex = upcoming;
  }

  double _headingAlong(List<LatLng> points, LatLng here) {
    if (points.length < 2) return 0;
    const lookAheadKm = 0.12;
    var best = double.infinity;
    var at = 0.0;
    var cursor = 0.0;
    for (var i = 1; i < points.length; i++) {
      final span = ride.kmBetween(points[i - 1], points[i]);
      final t = segmentT(points[i - 1], points[i], here);
      final on = LatLng(
        points[i - 1].latitude +
            (points[i].latitude - points[i - 1].latitude) * t,
        points[i - 1].longitude +
            (points[i].longitude - points[i - 1].longitude) * t,
      );
      final gap = ride.metersBetween(here, on);
      if (gap < best) {
        best = gap;
        at = cursor + span * t;
      }
      cursor += span;
    }
    if (cursor == 0) return 0;
    final target = min(cursor, at + lookAheadKm);
    if (target - at < 0.01) {
      return headingTo(points[points.length - 2], points.last);
    }
    return headingTo(
      along(points, at / cursor),
      along(points, target / cursor),
    );
  }
}
