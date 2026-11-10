import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:zenrides/src/auth/auth_repository.dart';
import 'package:zenrides/src/auth/auth_service.dart';
import 'package:zenrides/src/location_service.dart';
import 'package:zenrides/src/navigation/map_adapter.dart';
import 'package:zenrides/src/pack/pack_repository.dart';
import 'package:zenrides/src/ride/ride_controller.dart';
import 'package:zenrides/src/ride/ride_repository.dart';
import 'package:zenrides/src/planning/trip_plan.dart';

class _FakeLocation implements LocationService {
  const _FakeLocation(this.fix);

  final LatLng fix;

  @override
  Future<LocationPermission> ensurePermission() async => LocationPermission.whileInUse;

  @override
  Future<Position> currentPosition() async => Position(
        latitude: fix.latitude,
        longitude: fix.longitude,
        timestamp: DateTime(2026, 10, 18, 8),
        accuracy: 5,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      );

  @override
  Stream<Position> positionStream() => const Stream.empty();
}

class _FakeMaps implements MapAdapter {
  const _FakeMaps(this.hazard);

  final RoadHazard hazard;

  @override
  bool get available => true;

  @override
  Future<List<FuelPump>> nearbyFuel(LatLng here) async => const [];

  @override
  Future<List<FuelPump>> fuelAlong(List<LatLng> road) async => const [];

  @override
  Future<List<TollPlaza>> tollsAlong(List<LatLng> road) async => const [];

  @override
  Future<List<PlaceHit>> search(String query, LatLng here) async => const [];

  @override
  Future<List<RouteChoice>> directions({required LatLng origin, required String placeId, List<LatLng> via = const []}) async => const [];

  @override
  Future<HazardReport> hazards(LatLng here, double heading) async => HazardReport(hazards: [hazard], failures: const []);

  @override
  Future<LatLng?> placePoint(String placeId) async => null;
}

void main() {
  test('location and maps adapters can be swapped for fakes, so GPS and hazards never need real plugins in tests', () async {
    const fix = LatLng(19.5, 72.8);
    const hazard = RoadHazard(id: 'h1', title: 'Pothole', detail: 'Pothole ahead', point: fix);
    final ride = RideController(
      network: true,
      clock: () => DateTime(2026, 10, 18, 8),
      location: const _FakeLocation(fix),
      maps: const _FakeMaps(hazard),
    );

    await ride.pack.requestGps();
    expect(ride.pack.gpsLocked, isTrue);
    expect(ride.you, fix);

    await ride.nav.refreshHazards();
    expect(ride.nav.nearbyHazards, [hazard]);
  });


  test('a shared plan keeps the days, stops, and selected road', () {
    final raw = encodeSharedPlan(SharedPlan(
      updatedAt: 10,
      days: 2,
      startName: 'Mumbai',
      start: const LatLng(19, 72.8),
      finishName: 'Bengaluru',
      finish: const LatLng(12.97, 77.59),
      halts: const [
        RideHalt(id: 'end', name: 'Pune', point: LatLng(18.5, 73.8), day: 1, kind: HaltKind.dayEnd),
        RideHalt(id: 'stop', name: 'Chai', point: LatLng(18.7, 73.4), day: 1, kind: HaltKind.stop),
      ],
      route: RouteChoice(
        summary: 'NH48',
        duration: '14 hr',
        distance: '980 km',
        points: const [LatLng(19, 72.8), LatLng(18.5, 73.8), LatLng(12.97, 77.59)],
      ),
    ));
    final plan = decodeSharedPlan(raw)!;
    expect(plan.days, 2);
    expect(plan.startName, 'Mumbai');
    expect(plan.finishName, 'Bengaluru');
    expect(plan.halts.map((halt) => halt.kind), [HaltKind.dayEnd, HaltKind.stop]);
    expect(plan.route!.distance, '980 km');
    expect(plan.route!.points.length, 3);
    expect(plan.startDate, isNull);
  });

  test('a saved road is not drawn on the HUD until a search or a start', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.nav.routes = const [
      RouteChoice(
        summary: 'NH48',
        duration: '14 hr',
        distance: '980 km',
        points: [LatLng(19, 72.8), LatLng(15.5, 73.8)],
      ),
    ];
    expect(ride.nav.showHudRoute, isFalse);

    ride.nav.previewingRoute = true;
    expect(ride.nav.showHudRoute, isTrue);

    ride.nav.previewingRoute = false;
    ride.nav.navigating = true;
    expect(ride.nav.showHudRoute, isTrue);
  });

  test('a plan remembers the dates the rider is going', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.plan.beginPlanning();
    ride.plan.setPlanDates(DateTime(2026, 11, 2), DateTime(2026, 11, 4));

    expect(ride.plan.draftDays, 3);
    expect(ride.plan.draftDateLabel, '2–4 Nov');
    expect(ride.plan.dateForDay(2, draft: true), DateTime(2026, 11, 3));

    ride.plan.savePlan();
    expect(ride.plan.tripDateLabel, '2–4 Nov');
    expect(ride.plan.tripStartDate, DateTime(2026, 11, 2));

    final raw = encodeSharedPlan(SharedPlan(
      updatedAt: 1,
      days: ride.plan.tripDays,
      startDate: ride.plan.tripStartDate,
      startName: '',
      start: null,
      finishName: '',
      finish: null,
      halts: const [],
    ));
    expect(decodeSharedPlan(raw)!.startDate, DateTime(2026, 11, 2));
  });

  test('a chai broadcast marks you as breaking until the hold lapses', () {
    var clock = DateTime(2026, 10, 18, 8);
    final ride = RideController(network: false, clock: () => clock);

    ride.radio.send(NoticeKind.chai);
    expect(ride.pack.youBreaking, isTrue);

    clock = clock.add(const Duration(seconds: 5));
    expect(ride.pack.youBreaking, isFalse);
  });

  test('recenter zoom is 200 percent of the overview', () {
    expect(RideController.recenterZoom, RideController.overviewZoom + 1);
  });

  test('removing a rider clears the pack row, the map dot, and their SOS pin', () {
    final clock = DateTime(2026, 10, 14, 8);
    final ride = RideController(network: false, clock: () => clock);
    ride.radio.raiseSos(id: 'mate', name: 'm.desai', at: const LatLng(18.37, 73.85));
    expect(ride.radio.visibleSos?.id, 'mate');

    ride.pack.removeRider('mate');

    expect(ride.radio.visibleSos, isNull);
    final you = ride.pack.mapRiders.firstWhere((rider) => rider.you).point;
    ride.tick(const Duration(seconds: 1));
    expect(ride.pack.mapRiders.any((rider) => rider.id == 'mate'), isFalse);
    expect(ride.pack.mapRiders.firstWhere((rider) => rider.you).point, you);
  });

  test('dismissing an SOS keeps that same alert from coming back', () {
    final clock = DateTime(2026, 10, 14, 8);
    final ride = RideController(network: false, clock: () => clock);
    ride.radio.raiseSos(id: 'mate', name: 'Rider abcd', at: const LatLng(18.37, 73.85));
    final alert = ride.radio.visibleSos!;
    ride.radio.dismissSos();

    expect(ride.radio.visibleSos, isNull);
    expect(ride.radio.notice, isNull);
    ride.radio.debugOfferSos(alert);
    expect(ride.radio.visibleSos, isNull);

    ride.radio.debugOfferSos(SosFix(
      id: alert.id,
      name: alert.name,
      lat: alert.lat,
      lng: alert.lng,
      at: alert.at.add(const Duration(seconds: 1)),
    ));
    expect(ride.radio.visibleSos?.at, alert.at.add(const Duration(seconds: 1)));
  });

  test('a map pin sets location once and the ride does not move it', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 14, 8));
    ride.nav.routes = [
      const RouteChoice(
        summary: 'NH48',
        duration: '1 hr',
        distance: '40 km',
        points: [LatLng(18.5, 73.8), LatLng(18.9, 73.9)],
      ),
    ];
    ride.nav.navigating = true;
    const pin = LatLng(18.52, 73.82);
    ride.pack.placeYou(pin);
    ride.tick(const Duration(minutes: 5));
    expect(ride.pack.gpsLocked, isFalse);
    expect(ride.you.latitude, pin.latitude);
    expect(ride.you.longitude, pin.longitude);
  });

  test('a planned day names the chain and keeps day 2 start separate from day 1 end', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.plan.beginPlanning();
    ride.plan.setDraftDays(2);
    ride.plan.selectPlanSlot(PlanSlot.start);
    ride.plan.armPick(true);
    ride.plan.dropHalt(const LatLng(18.52, 73.85));
    ride.plan.selectPlanDay(1);
    ride.plan.selectPlanSlot(PlanSlot.dayEnd);
    ride.plan.armPick(true);
    ride.plan.dropHalt(const LatLng(18.75, 73.40));
    expect(ride.plan.planChain, isNull);

    ride.plan.selectPlanDay(2);
    ride.plan.selectPlanSlot(PlanSlot.dayEnd);
    ride.plan.armPick(true);
    ride.plan.dropHalt(const LatLng(19.99, 73.78));
    expect(ride.plan.planChain, 'Day 1 start · Start. Day 1 end · Day 1 end. Day 2 end · Day 2 end.');
    expect(ride.plan.shownRoute.first.latitude, 18.75);
    expect(ride.plan.shownRoute.last.latitude, 19.99);

    ride.plan.selectPlanSlot(PlanSlot.dayStart);
    ride.plan.armPick(true);
    ride.plan.dropHalt(const LatLng(18.80, 73.50));
    expect(ride.plan.dayEnd(1, draft: true)!.point.latitude, 18.75);
    expect(ride.plan.dayStart(2, draft: true)!.point.latitude, 18.80);
    expect(ride.plan.shownRoute.first.latitude, 18.80);
    expect(ride.plan.planChain, contains('Day 1 end · Day 1 end'));
    expect(ride.plan.mapHalts.map((halt) => halt.point.latitude), containsAll([18.75, 18.80]));
  });

  test('a day start dropped on day 2 end stays on day 1 end', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.plan.beginPlanning();
    ride.plan.setDraftDays(2);
    ride.plan.selectPlanSlot(PlanSlot.start);
    ride.plan.armPick(true);
    ride.plan.dropHalt(const LatLng(19.05, 72.84));
    ride.plan.selectPlanSlot(PlanSlot.dayEnd);
    ride.plan.armPick(true);
    ride.plan.dropHalt(const LatLng(19.02, 72.84));
    ride.plan.selectPlanDay(2);
    ride.plan.selectPlanSlot(PlanSlot.dayEnd);
    ride.plan.armPick(true);
    ride.plan.dropHalt(const LatLng(18.95, 72.82));

    ride.plan.selectPlanSlot(PlanSlot.dayStart);
    ride.plan.armPick(true);
    ride.plan.dropHalt(const LatLng(18.95, 72.82));

    expect(ride.plan.dayStart(2, draft: true), isNull);
    expect(ride.plan.shownRoute.first.latitude, 19.02);
    expect(ride.plan.shownRoute.last.latitude, 18.95);
    expect(ride.plan.mapHalts.map((halt) => halt.point.latitude), [19.05, 19.02, 18.95]);
    expect(ride.plan.mapHalts[1].name, contains('Day 2 start'));
  });

  test('planning keeps day 1 and day 2 on the map together', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.plan.beginPlanning();
    ride.plan.setDraftDays(2);
    ride.plan.selectPlanSlot(PlanSlot.start);
    ride.plan.armPick(true);
    ride.plan.dropHalt(const LatLng(19.05, 72.84));
    ride.plan.selectPlanSlot(PlanSlot.dayEnd);
    ride.plan.armPick(true);
    ride.plan.dropHalt(const LatLng(19.02, 72.84));
    ride.plan.selectPlanDay(2);
    ride.plan.selectPlanSlot(PlanSlot.dayEnd);
    ride.plan.armPick(true);
    ride.plan.dropHalt(const LatLng(18.95, 72.82));

    expect(ride.plan.planPaths.map((path) => path.day), [1, 2]);
    ride.plan.openPlannedDay(1);
    expect(ride.plan.planDay, 1);
    ride.plan.openPlannedDay(2);
    expect(ride.plan.planDay, 2);
    expect(ride.plan.planPaths.first.points.first.latitude, 19.05);
    expect(ride.plan.planPaths.last.points.last.latitude, 18.95);
    expect(dayColor(1), isNot(dayColor(2)));

    ride.plan.routes = const [
      RouteChoice(
        summary: 'A',
        duration: '40 min',
        distance: '18 km',
        points: [LatLng(19.02, 72.84), LatLng(18.99, 72.83), LatLng(18.95, 72.82)],
      ),
      RouteChoice(
        summary: 'B',
        duration: '50 min',
        distance: '22 km',
        points: [LatLng(19.02, 72.84), LatLng(19.00, 72.90), LatLng(18.95, 72.82)],
      ),
    ];
    ride.plan.selectRoute(1);
    expect(ride.plan.planPaths.map((path) => path.day), [1, 2, 2]);
    expect(ride.plan.planPaths.where((path) => path.day == 1).single.points.first.latitude, 19.05);
    expect(ride.plan.planPaths.where((path) => path.selected && path.day == 2).single.points[1].latitude, 19.00);
  });

  test('leaving a day keeps its driving road on the map', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.plan.beginPlanning();
    ride.plan.setDraftDays(2);
    ride.plan.selectPlanSlot(PlanSlot.start);
    ride.plan.armPick(true);
    ride.plan.dropHalt(const LatLng(19.05, 72.84));
    ride.plan.selectPlanSlot(PlanSlot.dayEnd);
    ride.plan.armPick(true);
    ride.plan.dropHalt(const LatLng(19.02, 72.84));
    ride.plan.routes = const [
      RouteChoice(
        summary: 'NH48',
        duration: '3 hr',
        distance: '150 km',
        points: [LatLng(19.05, 72.84), LatLng(19.03, 73.10), LatLng(19.02, 72.84)],
      ),
    ];
    ride.plan.selectedRoute = 0;

    ride.plan.selectPlanDay(2);

    final day1 = ride.plan.planPaths.where((path) => path.day == 1).single;
    expect(day1.points.length, greaterThan(2));
    expect(day1.points[1].latitude, 19.03);
  });

  test('pumps and tolls cover day 1 even while another day is open', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.plan.beginPlanning();
    ride.plan.setDraftDays(2);
    ride.plan.selectPlanSlot(PlanSlot.start);
    ride.plan.armPick(true);
    ride.plan.dropHalt(const LatLng(19.05, 72.84));
    ride.plan.selectPlanSlot(PlanSlot.dayEnd);
    ride.plan.armPick(true);
    ride.plan.dropHalt(const LatLng(19.02, 72.84));
    ride.plan.routes = const [
      RouteChoice(
        summary: 'Day 1',
        duration: '3 hr',
        distance: '150 km',
        points: [LatLng(19.05, 72.84), LatLng(19.03, 73.10), LatLng(19.02, 72.84)],
      ),
    ];
    ride.plan.selectPlanDay(2);
    ride.plan.selectPlanSlot(PlanSlot.dayEnd);
    ride.plan.armPick(true);
    ride.plan.dropHalt(const LatLng(18.95, 72.82));
    ride.plan.routes = const [
      RouteChoice(
        summary: 'Day 2',
        duration: '2 hr',
        distance: '80 km',
        points: [LatLng(19.02, 72.84), LatLng(18.98, 72.83), LatLng(18.95, 72.82)],
      ),
    ];
    ride.plan.selectRoute(0);

    expect(ride.plan.planDay, 2);
    expect(ride.plan.planRoadLines, hasLength(2));
    expect(ride.plan.planRoadLines.first[1].latitude, 19.03);
    expect(ride.plan.planRoadLines.last[1].latitude, 18.98);

    ride.plan.togglePlanPumps();
    ride.plan.togglePlanTolls();
    expect(ride.plan.planPumpsOn, isTrue);
    expect(ride.plan.planTollsOn, isTrue);
    expect(ride.plan.planPumpNote, 'Pumps show on the live map.');
    expect(ride.plan.planTollNote, 'Tolls show on the live map.');

    ride.plan.togglePlanPumps();
    expect(ride.plan.planPumpsOn, isFalse);
    expect(ride.plan.planPumps, isEmpty);
    expect(ride.plan.planTollsOn, isTrue);
  });

  test('a map tap shows the whole ride and a road tap shows that day', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.plan.beginPlanning();
    ride.plan.setDraftDays(2);
    expect(ride.plan.wholeRide, isTrue);

    ride.plan.routes = const [
      RouteChoice(
        summary: 'Day 1',
        duration: '1 hr',
        distance: '40 km',
        durationSeconds: 3600,
        distanceMeters: 40000,
        points: [LatLng(19.05, 72.84), LatLng(19.02, 72.84)],
      ),
    ];
    ride.plan.selectedRoute = 1;
    ride.plan.selectRoute(0);
    ride.plan.openPlannedDay(2);
    ride.plan.routes = const [
      RouteChoice(
        summary: 'Day 2',
        duration: '2 hr',
        distance: '80 km',
        durationSeconds: 7200,
        distanceMeters: 80000,
        traffic: true,
        points: [LatLng(19.02, 72.84), LatLng(18.95, 72.82)],
      ),
    ];
    ride.plan.selectedRoute = 1;
    ride.plan.selectRoute(0);

    expect(ride.plan.wholeRide, isFalse);
    expect(ride.plan.dayTiming(2), '2 hr · 80 km');
    expect(ride.plan.planTimingLabel, 'Day 2 · 2 hr · 80 km · live traffic');
    expect(ride.plan.visiblePlanNote, 'Day 2 · 2 hr · 80 km · live traffic');
    ride.plan.showWholeRide();
    expect(ride.plan.wholeRide, isTrue);
    expect(ride.plan.rideTiming, '3 hr · 120 km');
    expect(ride.plan.planTimingLabel, 'Ride · 3 hr · 120 km');
    expect(ride.plan.visiblePlanNote, 'Ride · 3 hr · 120 km');
    expect(ride.plan.planDay, 2);
  });

  test('saving a ride takes the location pins off the map', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.plan.beginPlanning();
    ride.plan.setDraftDays(2);
    ride.plan.selectPlanSlot(PlanSlot.start);
    ride.plan.armPick(true);
    ride.plan.dropHalt(const LatLng(19.05, 72.84));
    ride.plan.selectPlanSlot(PlanSlot.dayEnd);
    ride.plan.armPick(true);
    ride.plan.dropHalt(const LatLng(19.02, 72.84));
    ride.plan.selectPlanDay(2);
    ride.plan.selectPlanSlot(PlanSlot.dayEnd);
    ride.plan.armPick(true);
    ride.plan.dropHalt(const LatLng(18.95, 72.82));
    expect(ride.plan.mapHalts, isNotEmpty);

    ride.nav.routes = const [
      RouteChoice(
        summary: 'HUD',
        duration: '10 min',
        distance: '4 km',
        points: [LatLng(19.05, 72.84), LatLng(19.02, 72.84)],
      ),
    ];
    ride.nav.previewingRoute = true;
    ride.plan.routes = const [
      RouteChoice(
        summary: 'Day 2',
        duration: '2 hr',
        distance: '80 km',
        points: [LatLng(19.02, 72.84), LatLng(18.95, 72.82)],
      ),
    ];
    ride.plan.savePlan();

    expect(ride.plan.planning, isFalse);
    expect(ride.plan.startPoint, isNotNull);
    expect(ride.plan.halts, isNotEmpty);
    expect(ride.plan.mapHalts, isEmpty);
    expect(ride.plan.routes, isEmpty);
    expect(ride.nav.showHudRoute, isTrue);
  });

  test('plan a ride is available before a code exists', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    expect(ride.canPlan, isTrue);
    ride.plan.beginPlanning();
    expect(ride.plan.planning, isTrue);

    ride.plan.cancelPlanning();
    ride.joinCode('ZEN-2222');
    expect(ride.canPlan, isFalse);
    ride.plan.beginPlanning();
    expect(ride.plan.planning, isFalse);
  });

  test('delete ride clears the plan and the code', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.generateCode();
    ride.plan.beginPlanning();
    ride.plan.selectPlanSlot(PlanSlot.start);
    ride.plan.armPick(true);
    ride.plan.dropHalt(const LatLng(19.05, 72.84));
    ride.plan.savePlan();

    ride.deleteRide();

    expect(ride.onRide, isFalse);
    expect(ride.admin, isFalse);
    expect(ride.plan.planning, isFalse);
    expect(ride.code, isEmpty);
    expect(ride.plan.startPoint, isNull);
    expect(ride.plan.halts, isEmpty);
    expect(ride.plan.planPaths, isEmpty);
    expect(ride.joinNote, 'Ride deleted.');
  });

  test('fuel on a chosen road does not list the surrounding area', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.nav.routes = const [
      RouteChoice(
        summary: 'NH48',
        duration: '1 hr',
        distance: '40 km',
        points: [LatLng(18.52, 73.85), LatLng(18.75, 73.40)],
      ),
    ];
    ride.nav.toggleFuel();
    expect(ride.nav.fuelOn, isTrue);
    expect(ride.nav.fuelNote, 'Looking for petrol pumps on this road…');
    expect(ride.nav.pumps, isEmpty);

    ride.nav.toggleFuel();
    ride.admin = true;
    ride.plan.beginPlanning();
    ride.plan.selectPlanSlot(PlanSlot.start);
    ride.plan.armPick(true);
    ride.plan.dropHalt(const LatLng(18.52, 73.85));
    ride.nav.clearDirections();
    ride.nav.toggleFuel();
    expect(ride.nav.fuelNote, 'Choose a road to see pumps on it.');
    expect(ride.nav.pumps, isEmpty);
  });

  test('choosing a road updates that day time', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.plan.beginPlanning();
    ride.plan.routes = const [
      RouteChoice(summary: 'A', duration: '2 hr', distance: '90 km', points: [LatLng(18.5, 73.8), LatLng(19.0, 73.8)]),
      RouteChoice(
        summary: 'B',
        duration: '2 hr 20 min',
        distance: '110 km',
        traffic: true,
        points: [LatLng(18.5, 73.8), LatLng(18.7, 73.9), LatLng(19.0, 73.8)],
      ),
    ];
    ride.plan.selectRoute(1);
    expect(ride.plan.dayTiming(1), '2 hr 20 min · 110 km');
    expect(ride.plan.dayTraffic(1), isTrue);
    expect(dayColor(1), const Color(0xFF1D4ED8));
    expect(dayColor(2), const Color(0xFF15803D));
  });

  test('the map line follows the current day', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18));
    ride.plan.tripDays = 2;
    ride.plan.startPoint = const LatLng(20.01, 73.79);
    ride.plan.finishPoint = const LatLng(19.81, 73.61);
    ride.plan.halts = const [
      RideHalt(id: 's', name: 'Narayangaon', point: LatLng(19.12, 73.90), day: 1, kind: HaltKind.stop),
      RideHalt(id: 'e', name: 'Nashik', point: LatLng(20.01, 73.79), day: 1, kind: HaltKind.dayEnd),
    ];
    expect(ride.plan.shownRoute.map((point) => point.latitude), [20.01, 19.12, 20.01]);

    ride.nav.routes = const [
      RouteChoice(
        summary: 'NH848',
        duration: '1 hr',
        distance: '33 km',
        points: [LatLng(20.01, 73.79), LatLng(19.90, 73.70), LatLng(19.81, 73.61)],
      ),
    ];
    ride.nav.previewingRoute = true;
    ride.plan.keepRoad(
      2,
      const RouteChoice(
        summary: 'NH848',
        duration: '1 hr',
        distance: '33 km',
        points: [LatLng(20.01, 73.79), LatLng(19.90, 73.70), LatLng(19.81, 73.61)],
      ),
    );
    expect(ride.plan.shownRoute.map((point) => point.latitude), [20.01, 19.12, 20.01]);
    expect(ride.plan.roadFitsDay, isFalse);
    expect(ride.nav.showHudRoute, isTrue);

    ride.plan.ridingDay = 2;
    expect(ride.plan.shownRoute.length, 3);
    expect(ride.plan.shownRoute.last.latitude, 19.81);
  });

  test('a quiet rider stays in the pack', () {
    final clock = DateTime(2026, 10, 18, 1);
    final ride = RideController(network: false, clock: () => clock);
    ride.pack.remote['kk'] = RemoteRider(
      id: 'kk',
      name: 'KK',
      lat: 18.37,
      lng: 73.85,
      updatedAt: clock.subtract(const Duration(hours: 6)),
    );
    final row = ride.pack.packRows.firstWhere((row) => row.name == 'KK');
    expect(row.online, isFalse);
    expect(ride.pack.mapRiders.map((rider) => rider.name), contains('KK'));
    expect(ride.pack.joinedPhones.map((phone) => phone.label), contains('KK'));
  });

  test('a GPS lock stays on the real fix instead of the simulator', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 14, 8));
    const home = LatLng(19.07, 72.87);
    ride.pack.gpsLocked = true;
    ride.pack.gpsFix = home;
    ride.pack.gpsAt = DateTime(2026, 10, 14, 7);

    ride.tick(const Duration(seconds: 30));

    expect(ride.you.latitude, home.latitude);
    expect(ride.you.longitude, home.longitude);
    expect(ride.pack.mapRiders.firstWhere((rider) => rider.you).point.latitude, home.latitude);
  });

  test('generating a code makes you the admin of that ride', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 14, 8));
    ride.generateCode();
    expect(ride.admin, isTrue);
    expect(ride.pack.packRows.first.role, 'Lead Pilot');
    ride.plan.beginPlanning();
    expect(ride.plan.planning, isTrue);
    ride.joinCode('ZEN-2222');
    expect(ride.admin, isFalse);
    expect(ride.pack.packRows.first.role, 'Pack rider');
    expect(ride.radio.notice?.kicker, contains('Pack rider'));
    ride.leadId = 'leader';
    ride.pack.remote['leader'] = RemoteRider(
      id: 'leader',
      name: 'Asha',
      lat: 18.4,
      lng: 73.8,
      updatedAt: DateTime(2026, 10, 14, 8),
    );
    expect(ride.pack.packRows.firstWhere((row) => row.you).role, 'Pack rider');
    expect(ride.pack.packRows.firstWhere((row) => row.id == 'leader').role, 'Lead Pilot');
    ride.plan.planning = false;
    ride.plan.beginPlanning();
    expect(ride.plan.planning, isFalse);
  });

  test('a toll naka becomes a halt on the nearest day', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.plan.beginPlanning();
    ride.plan.setDraftDays(2);
    ride.plan.draftStart = const LatLng(19.0, 72.8);
    ride.plan.draftStartName = 'Mumbai';
    ride.plan.draftHalts = const [
      RideHalt(id: 'e1', name: 'Pune', point: LatLng(18.5, 73.8), day: 1, kind: HaltKind.dayEnd),
      RideHalt(id: 'e2', name: 'Goa', point: LatLng(15.5, 73.8), day: 2, kind: HaltKind.dayEnd),
    ];

    ride.plan.pickToll(const TollPlaza(id: 'khed', name: 'Khed Shivapur', point: LatLng(17.0, 73.8)));
    expect(ride.plan.pickedToll?.name, 'Khed Shivapur');
    ride.plan.addTollAsHalt();

    expect(ride.plan.pickedToll, isNull);
    expect(ride.plan.dayStops(2, draft: true).map((halt) => halt.name), ['Khed Shivapur']);
    expect(ride.plan.dayStops(1, draft: true), isEmpty);

    ride.plan.pickToll(const TollPlaza(id: 'again', name: 'Khed again', point: LatLng(17.0, 73.8)));
    ride.plan.addTollAsHalt();
    expect(ride.plan.dayStops(2, draft: true), hasLength(1));
    expect(ride.plan.planNote, contains('already a halt'));
  });

  test('a halt estimates the clock from the day start', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.plan.beginPlanning();
    ride.plan.draftStart = const LatLng(19.0, 72.8);
    ride.plan.draftHalts = const [
      RideHalt(id: 'stop', name: 'Chai', point: LatLng(19.05, 72.8), day: 1, kind: HaltKind.stop),
      RideHalt(id: 'end', name: 'Pune', point: LatLng(19.1, 72.8), day: 1, kind: HaltKind.dayEnd),
    ];
    ride.plan.routes = const [
      RouteChoice(
        summary: 'NH48',
        duration: '1 hr',
        distance: '11 km',
        durationSeconds: 3600,
        distanceMeters: 11000,
        points: [LatLng(19.0, 72.8), LatLng(19.1, 72.8)],
      ),
    ];

    expect(ride.plan.haltEstimateLabel(1, const LatLng(19.05, 72.8)), 'Estimated time');

    ride.plan.setDayClock(1, startMinute: 6 * 60);
    expect(ride.plan.haltEstimateLabel(1, const LatLng(19.05, 72.8)), 'Estimated time · 6:30 AM');

    ride.plan.setDayClock(1, startMinute: 22 * 60, endMinute: 6 * 60);
    expect(ride.plan.haltEstimateLabel(1, const LatLng(19.05, 72.8)), 'Estimated time · 2:00 AM');
  });

  test('day start and end times survive a save and a shared plan', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.plan.beginPlanning();
    ride.plan.setDayClock(1, startMinute: 6 * 60, endMinute: 18 * 60);
    ride.plan.savePlan();
    expect(ride.plan.dayStartMinute(1, draft: false), 6 * 60);
    expect(ride.plan.dayEndMinute(1, draft: false), 18 * 60);

    ride.plan.beginPlanning();
    expect(ride.plan.dayStartMinute(1), 6 * 60);
    expect(ride.plan.dayEndMinute(1), 18 * 60);

    final raw = encodeSharedPlan(SharedPlan(
      updatedAt: 4,
      days: 2,
      startName: '',
      start: null,
      finishName: '',
      finish: null,
      halts: const [],
      startMinutes: {1: 6 * 60, 2: 7 * 60},
      endMinutes: {1: 18 * 60},
    ));
    final plan = decodeSharedPlan(raw)!;
    expect(plan.startMinutes[1], 6 * 60);
    expect(plan.startMinutes[2], 7 * 60);
    expect(plan.endMinutes[1], 18 * 60);
    expect(plan.endMinutes[2], isNull);
  });

  test('pause holds the ride without ending it, and does nothing once ended', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.generateCode();
    ride.togglePause();
    expect(ride.paused, isTrue);
    expect(ride.ended, isFalse);

    ride.togglePause();
    expect(ride.paused, isFalse);

    ride.endRide();
    ride.togglePause();
    expect(ride.paused, isFalse, reason: 'an ended ride cannot be paused');
    expect(ride.ended, isTrue);
  });

  test('ending a ride does not carry over into the next joined code', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.endRide();
    expect(ride.ended, isTrue);

    ride.joinCode('ZEN-2222');
    expect(ride.ended, isFalse);
    expect(ride.paused, isFalse);
    expect(ride.onRide, isTrue);
  });

  test('an empty pack is only the rider who joined', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 14, 8));
    expect(ride.pack.packRows.map((row) => row.you), [true]);
    expect(ride.pack.mapRiders.map((rider) => rider.you), [true]);
  });

  test('opening with no rideCode leaves the pack ready to join', () async {
    final users = _FakeUsers(const RiderProfile(name: 'Riya', rideCode: '', role: 'rider'));
    final ride = RideController(
      network: true,
      clock: () => DateTime(2026, 10, 18, 8),
      authService: _FakeAuth(),
      authRepository: users,
      rideRepository: _FakeRides(),
      packRepository: _FakePack(const []),
    );
    await ride.restoreIdentity();
    expect(ride.riderId, 'uid-0501');
    expect(ride.riderName, 'Riya');
    expect(ride.code, isEmpty);
    expect(ride.onRide, isFalse);
  });

  test('a deleted ride is not kept on the phone', () async {
    final users = _FakeUsers(const RiderProfile(name: 'Riya', rideCode: 'ZEN-4365', role: 'rider'));
    final ride = RideController(
      network: true,
      clock: () => DateTime(2026, 10, 18, 8),
      authService: _FakeAuth(),
      authRepository: users,
      rideRepository: _FakeRides(),
      packRepository: _FakePack(const []),
    );
    await ride.restoreIdentity();
    expect(ride.code, isEmpty);
    expect(ride.onRide, isFalse);
    expect(users.profile.rideCode, isEmpty);
  });

  test('a saved ride loads the riders stored on it', () async {
    final ride = RideController(
      network: true,
      clock: () => DateTime(2026, 10, 18, 8),
      authService: _FakeAuth(),
      authRepository: _FakeUsers(const RiderProfile(name: 'Riya', rideCode: 'ZEN-1111', role: 'rider')),
      rideRepository: _FakeRides(exists: true, adminId: 'lead'),
      packRepository: _FakePack([
        RemoteRider(id: 'kk', name: 'KK', lat: 18.5, lng: 73.8, updatedAt: DateTime(2026, 10, 18)),
      ]),
    );
    await ride.restoreIdentity();
    expect(ride.code, 'ZEN-1111');
    expect(ride.onRide, isTrue);
    expect(ride.admin, isFalse);
    expect(ride.leadId, 'lead');
    expect(ride.pack.remote['kk']?.name, 'KK');
  });
}

class _FakeAuth implements AuthService {
  AuthUser? user;

  @override
  AuthUser? get currentUser => user;

  @override
  Stream<AuthUser?> authStateChanges() => const Stream.empty();

  @override
  Future<AuthUser> signInAnonymously() async {
    user = const AuthUser(uid: 'uid-0501', displayName: null);
    return user!;
  }

  @override
  Future<PhoneCodeSent> sendCode(String phoneE164) => throw UnimplementedError();

  @override
  Future<AuthUser> confirmCode(PhoneCodeSent sent, String smsCode) => throw UnimplementedError();

  @override
  Future<void> setDisplayName(String name) async {}

  @override
  Future<void> signOut() async {
    user = null;
  }
}

class _FakeUsers extends AuthRepository {
  _FakeUsers(this.profile);

  RiderProfile profile;

  @override
  Future<RiderProfile> ensureUser({required String uid, required String name}) async => profile;

  @override
  Future<void> setMembership(String uid, {required String rideCode, required String role}) async {
    profile = RiderProfile(name: profile.name, rideCode: rideCode, role: role);
  }
}

class _FakeRides extends RideRepository {
  _FakeRides({this.exists = false, this.adminId});

  final bool exists;
  final String? adminId;

  @override
  Future<RideRecord> rideRecord(String code) async => RideRecord(exists: exists, adminId: adminId);
}

class _FakePack extends PackRepository {
  _FakePack(this.stored);

  final List<RemoteRider> stored;

  @override
  Future<List<RemoteRider>> riders(String code) async => stored;
}
