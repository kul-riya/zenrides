import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:zenrides/src/maps_types.dart';
import 'package:zenrides/src/ride_api.dart';
import 'package:zenrides/src/ride_controller.dart';

void main() {
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
    ride.routes = const [
      RouteChoice(
        summary: 'NH48',
        duration: '14 hr',
        distance: '980 km',
        points: [LatLng(19, 72.8), LatLng(15.5, 73.8)],
      ),
    ];
    expect(ride.showHudRoute, isFalse);

    ride.previewingRoute = true;
    expect(ride.showHudRoute, isTrue);

    ride.previewingRoute = false;
    ride.navigating = true;
    expect(ride.showHudRoute, isTrue);
  });

  test('a plan remembers the dates the rider is going', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.beginPlanning();
    ride.setPlanDates(DateTime(2026, 11, 2), DateTime(2026, 11, 4));

    expect(ride.draftDays, 3);
    expect(ride.draftDateLabel, '2–4 Nov');
    expect(ride.dateForDay(2, draft: true), DateTime(2026, 11, 3));

    ride.savePlan();
    expect(ride.tripDateLabel, '2–4 Nov');
    expect(ride.tripStartDate, DateTime(2026, 11, 2));

    final raw = encodeSharedPlan(SharedPlan(
      updatedAt: 1,
      days: ride.tripDays,
      startDate: ride.tripStartDate,
      startName: '',
      start: null,
      finishName: '',
      finish: null,
      halts: const [],
    ));
    expect(decodeSharedPlan(raw)!.startDate, DateTime(2026, 11, 2));
  });

  test('recenter zoom is 200 percent of the overview', () {
    expect(RideController.recenterZoom, RideController.overviewZoom + 1);
  });

  test('removing a rider clears the pack row, the map dot, and their SOS pin', () {
    final clock = DateTime(2026, 10, 14, 8);
    final ride = RideController(network: false, clock: () => clock);
    ride.raiseSos(id: 'mate', name: 'm.desai', at: const LatLng(18.37, 73.85));
    expect(ride.visibleSos?.id, 'mate');

    ride.removeRider('mate');

    expect(ride.visibleSos, isNull);
    final you = ride.mapRiders.firstWhere((rider) => rider.you).point;
    ride.tick(const Duration(seconds: 1));
    expect(ride.mapRiders.any((rider) => rider.id == 'mate'), isFalse);
    expect(ride.mapRiders.firstWhere((rider) => rider.you).point, you);
  });

  test('dismissing an SOS keeps that same alert from coming back', () {
    final clock = DateTime(2026, 10, 14, 8);
    final ride = RideController(network: false, clock: () => clock);
    ride.raiseSos(id: 'mate', name: 'Rider abcd', at: const LatLng(18.37, 73.85));
    final alert = ride.visibleSos!;
    ride.dismissSos();

    expect(ride.visibleSos, isNull);
    expect(ride.notice, isNull);
    ride.debugOfferSos(alert);
    expect(ride.visibleSos, isNull);

    ride.debugOfferSos(SosFix(
      id: alert.id,
      name: alert.name,
      lat: alert.lat,
      lng: alert.lng,
      at: alert.at.add(const Duration(seconds: 1)),
    ));
    expect(ride.visibleSos?.at, alert.at.add(const Duration(seconds: 1)));
  });

  test('a map pin sets location once and the ride does not move it', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 14, 8));
    ride.routes = [
      const RouteChoice(
        summary: 'NH48',
        duration: '1 hr',
        distance: '40 km',
        points: [LatLng(18.5, 73.8), LatLng(18.9, 73.9)],
      ),
    ];
    ride.navigating = true;
    const pin = LatLng(18.52, 73.82);
    ride.placeYou(pin);
    ride.tick(const Duration(minutes: 5));
    expect(ride.gpsLocked, isFalse);
    expect(ride.you.latitude, pin.latitude);
    expect(ride.you.longitude, pin.longitude);
  });

  test('a planned day names the chain and keeps day 2 start separate from day 1 end', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.beginPlanning();
    ride.setDraftDays(2);
    ride.selectPlanSlot(PlanSlot.start);
    ride.armPick(true);
    ride.dropHalt(const LatLng(18.52, 73.85));
    ride.selectPlanDay(1);
    ride.selectPlanSlot(PlanSlot.dayEnd);
    ride.armPick(true);
    ride.dropHalt(const LatLng(18.75, 73.40));
    expect(ride.planChain, isNull);

    ride.selectPlanDay(2);
    ride.selectPlanSlot(PlanSlot.dayEnd);
    ride.armPick(true);
    ride.dropHalt(const LatLng(19.99, 73.78));
    expect(ride.planChain, 'Day 1 start · Start. Day 1 end · Day 1 end. Day 2 end · Day 2 end.');
    expect(ride.shownRoute.first.latitude, 18.75);
    expect(ride.shownRoute.last.latitude, 19.99);

    ride.selectPlanSlot(PlanSlot.dayStart);
    ride.armPick(true);
    ride.dropHalt(const LatLng(18.80, 73.50));
    expect(ride.dayEnd(1, draft: true)!.point.latitude, 18.75);
    expect(ride.dayStart(2, draft: true)!.point.latitude, 18.80);
    expect(ride.shownRoute.first.latitude, 18.80);
    expect(ride.planChain, contains('Day 1 end · Day 1 end'));
    expect(ride.mapHalts.map((halt) => halt.point.latitude), containsAll([18.75, 18.80]));
  });

  test('a day start dropped on day 2 end stays on day 1 end', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.beginPlanning();
    ride.setDraftDays(2);
    ride.selectPlanSlot(PlanSlot.start);
    ride.armPick(true);
    ride.dropHalt(const LatLng(19.05, 72.84));
    ride.selectPlanSlot(PlanSlot.dayEnd);
    ride.armPick(true);
    ride.dropHalt(const LatLng(19.02, 72.84));
    ride.selectPlanDay(2);
    ride.selectPlanSlot(PlanSlot.dayEnd);
    ride.armPick(true);
    ride.dropHalt(const LatLng(18.95, 72.82));

    ride.selectPlanSlot(PlanSlot.dayStart);
    ride.armPick(true);
    ride.dropHalt(const LatLng(18.95, 72.82));

    expect(ride.dayStart(2, draft: true), isNull);
    expect(ride.shownRoute.first.latitude, 19.02);
    expect(ride.shownRoute.last.latitude, 18.95);
    expect(ride.mapHalts.map((halt) => halt.point.latitude), [19.05, 19.02, 18.95]);
    expect(ride.mapHalts[1].name, contains('Day 2 start'));
  });

  test('planning keeps day 1 and day 2 on the map together', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.beginPlanning();
    ride.setDraftDays(2);
    ride.selectPlanSlot(PlanSlot.start);
    ride.armPick(true);
    ride.dropHalt(const LatLng(19.05, 72.84));
    ride.selectPlanSlot(PlanSlot.dayEnd);
    ride.armPick(true);
    ride.dropHalt(const LatLng(19.02, 72.84));
    ride.selectPlanDay(2);
    ride.selectPlanSlot(PlanSlot.dayEnd);
    ride.armPick(true);
    ride.dropHalt(const LatLng(18.95, 72.82));

    expect(ride.planPaths.map((path) => path.day), [1, 2]);
    ride.openPlannedDay(1);
    expect(ride.planDay, 1);
    ride.openPlannedDay(2);
    expect(ride.planDay, 2);
    expect(ride.planPaths.first.points.first.latitude, 19.05);
    expect(ride.planPaths.last.points.last.latitude, 18.95);
    expect(dayColor(1), isNot(dayColor(2)));

    ride.routes = const [
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
    ride.selectRoute(1);
    expect(ride.planPaths.map((path) => path.day), [1, 2, 2]);
    expect(ride.planPaths.where((path) => path.day == 1).single.points.first.latitude, 19.05);
    expect(ride.planPaths.where((path) => path.selected && path.day == 2).single.points[1].latitude, 19.00);
  });

  test('leaving a day keeps its driving road on the map', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.beginPlanning();
    ride.setDraftDays(2);
    ride.selectPlanSlot(PlanSlot.start);
    ride.armPick(true);
    ride.dropHalt(const LatLng(19.05, 72.84));
    ride.selectPlanSlot(PlanSlot.dayEnd);
    ride.armPick(true);
    ride.dropHalt(const LatLng(19.02, 72.84));
    ride.routes = const [
      RouteChoice(
        summary: 'NH48',
        duration: '3 hr',
        distance: '150 km',
        points: [LatLng(19.05, 72.84), LatLng(19.03, 73.10), LatLng(19.02, 72.84)],
      ),
    ];
    ride.selectedRoute = 0;

    ride.selectPlanDay(2);

    final day1 = ride.planPaths.where((path) => path.day == 1).single;
    expect(day1.points.length, greaterThan(2));
    expect(day1.points[1].latitude, 19.03);
  });

  test('pumps and tolls cover day 1 even while another day is open', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.beginPlanning();
    ride.setDraftDays(2);
    ride.selectPlanSlot(PlanSlot.start);
    ride.armPick(true);
    ride.dropHalt(const LatLng(19.05, 72.84));
    ride.selectPlanSlot(PlanSlot.dayEnd);
    ride.armPick(true);
    ride.dropHalt(const LatLng(19.02, 72.84));
    ride.routes = const [
      RouteChoice(
        summary: 'Day 1',
        duration: '3 hr',
        distance: '150 km',
        points: [LatLng(19.05, 72.84), LatLng(19.03, 73.10), LatLng(19.02, 72.84)],
      ),
    ];
    ride.selectPlanDay(2);
    ride.selectPlanSlot(PlanSlot.dayEnd);
    ride.armPick(true);
    ride.dropHalt(const LatLng(18.95, 72.82));
    ride.routes = const [
      RouteChoice(
        summary: 'Day 2',
        duration: '2 hr',
        distance: '80 km',
        points: [LatLng(19.02, 72.84), LatLng(18.98, 72.83), LatLng(18.95, 72.82)],
      ),
    ];
    ride.selectRoute(0);

    expect(ride.planDay, 2);
    expect(ride.planRoadLines, hasLength(2));
    expect(ride.planRoadLines.first[1].latitude, 19.03);
    expect(ride.planRoadLines.last[1].latitude, 18.98);

    ride.togglePlanPumps();
    ride.togglePlanTolls();
    expect(ride.planPumpsOn, isTrue);
    expect(ride.planTollsOn, isTrue);
    expect(ride.planPumpNote, 'Pumps show on the live map.');
    expect(ride.planTollNote, 'Tolls show on the live map.');

    ride.togglePlanPumps();
    expect(ride.planPumpsOn, isFalse);
    expect(ride.planPumps, isEmpty);
    expect(ride.planTollsOn, isTrue);
  });

  test('a map tap shows the whole ride and a road tap shows that day', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.beginPlanning();
    ride.setDraftDays(2);
    expect(ride.wholeRide, isTrue);

    ride.routes = const [
      RouteChoice(
        summary: 'Day 1',
        duration: '1 hr',
        distance: '40 km',
        durationSeconds: 3600,
        distanceMeters: 40000,
        points: [LatLng(19.05, 72.84), LatLng(19.02, 72.84)],
      ),
    ];
    ride.selectedRoute = 1;
    ride.selectRoute(0);
    ride.openPlannedDay(2);
    ride.routes = const [
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
    ride.selectedRoute = 1;
    ride.selectRoute(0);

    expect(ride.wholeRide, isFalse);
    expect(ride.dayTiming(2), '2 hr · 80 km');
    expect(ride.planTimingLabel, 'Day 2 · 2 hr · 80 km · live traffic');
    expect(ride.visiblePlanNote, 'Day 2 · 2 hr · 80 km · live traffic');
    ride.showWholeRide();
    expect(ride.wholeRide, isTrue);
    expect(ride.rideTiming, '3 hr · 120 km');
    expect(ride.planTimingLabel, 'Ride · 3 hr · 120 km');
    expect(ride.visiblePlanNote, 'Ride · 3 hr · 120 km');
    expect(ride.planDay, 2);
  });

  test('saving a ride takes the location pins off the map', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.beginPlanning();
    ride.setDraftDays(2);
    ride.selectPlanSlot(PlanSlot.start);
    ride.armPick(true);
    ride.dropHalt(const LatLng(19.05, 72.84));
    ride.selectPlanSlot(PlanSlot.dayEnd);
    ride.armPick(true);
    ride.dropHalt(const LatLng(19.02, 72.84));
    ride.selectPlanDay(2);
    ride.selectPlanSlot(PlanSlot.dayEnd);
    ride.armPick(true);
    ride.dropHalt(const LatLng(18.95, 72.82));
    expect(ride.mapHalts, isNotEmpty);

    ride.routes = const [
      RouteChoice(
        summary: 'Day 2',
        duration: '2 hr',
        distance: '80 km',
        points: [LatLng(19.02, 72.84), LatLng(18.95, 72.82)],
      ),
    ];
    ride.savePlan();

    expect(ride.planning, isFalse);
    expect(ride.startPoint, isNotNull);
    expect(ride.halts, isNotEmpty);
    expect(ride.mapHalts, isEmpty);
    expect(ride.routes, isEmpty);
  });

  test('plan a ride is available before a code exists', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    expect(ride.canPlan, isTrue);
    ride.beginPlanning();
    expect(ride.planning, isTrue);

    ride.cancelPlanning();
    ride.joinCode('ZEN-2222');
    expect(ride.canPlan, isFalse);
    ride.beginPlanning();
    expect(ride.planning, isFalse);
  });

  test('delete ride clears the plan and the code', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.generateCode();
    ride.beginPlanning();
    ride.selectPlanSlot(PlanSlot.start);
    ride.armPick(true);
    ride.dropHalt(const LatLng(19.05, 72.84));
    ride.savePlan();

    ride.deleteRide();

    expect(ride.onRide, isFalse);
    expect(ride.admin, isFalse);
    expect(ride.planning, isFalse);
    expect(ride.code, isEmpty);
    expect(ride.startPoint, isNull);
    expect(ride.halts, isEmpty);
    expect(ride.planPaths, isEmpty);
    expect(ride.joinNote, 'Ride deleted.');
  });

  test('fuel on a chosen road does not list the surrounding area', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.routes = const [
      RouteChoice(
        summary: 'NH48',
        duration: '1 hr',
        distance: '40 km',
        points: [LatLng(18.52, 73.85), LatLng(18.75, 73.40)],
      ),
    ];
    ride.toggleFuel();
    expect(ride.fuelOn, isTrue);
    expect(ride.fuelNote, 'Looking for petrol pumps on this road…');
    expect(ride.pumps, isEmpty);

    ride.toggleFuel();
    ride.admin = true;
    ride.beginPlanning();
    ride.selectPlanSlot(PlanSlot.start);
    ride.armPick(true);
    ride.dropHalt(const LatLng(18.52, 73.85));
    ride.clearDirections();
    ride.toggleFuel();
    expect(ride.fuelNote, 'Choose a road to see pumps on it.');
    expect(ride.pumps, isEmpty);
  });

  test('choosing a road updates that day time', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.beginPlanning();
    ride.routes = const [
      RouteChoice(summary: 'A', duration: '2 hr', distance: '90 km', points: [LatLng(18.5, 73.8), LatLng(19.0, 73.8)]),
      RouteChoice(
        summary: 'B',
        duration: '2 hr 20 min',
        distance: '110 km',
        traffic: true,
        points: [LatLng(18.5, 73.8), LatLng(18.7, 73.9), LatLng(19.0, 73.8)],
      ),
    ];
    ride.selectRoute(1);
    expect(ride.dayTiming(1), '2 hr 20 min · 110 km');
    expect(ride.dayTraffic(1), isTrue);
    expect(dayColor(1), const Color(0xFF1D4ED8));
    expect(dayColor(2), const Color(0xFF15803D));
  });

  test('the map line follows the current day', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18));
    ride.tripDays = 2;
    ride.startPoint = const LatLng(20.01, 73.79);
    ride.finishPoint = const LatLng(19.81, 73.61);
    ride.halts = const [
      RideHalt(id: 's', name: 'Narayangaon', point: LatLng(19.12, 73.90), day: 1, kind: HaltKind.stop),
      RideHalt(id: 'e', name: 'Nashik', point: LatLng(20.01, 73.79), day: 1, kind: HaltKind.dayEnd),
    ];
    expect(ride.shownRoute.map((point) => point.latitude), [20.01, 19.12, 20.01]);

    ride.routes = const [
      RouteChoice(
        summary: 'NH848',
        duration: '1 hr',
        distance: '33 km',
        points: [LatLng(20.01, 73.79), LatLng(19.90, 73.70), LatLng(19.81, 73.61)],
      ),
    ];
    expect(ride.shownRoute.map((point) => point.latitude), [20.01, 19.12, 20.01]);
    expect(ride.roadFitsDay, isFalse);

    ride.ridingDay = 2;
    expect(ride.shownRoute.length, 3);
    expect(ride.shownRoute.last.latitude, 19.81);
  });

  test('a quiet rider stays in the pack', () {
    final clock = DateTime(2026, 10, 18, 1);
    final ride = RideController(network: false, clock: () => clock);
    ride.remote['kk'] = RemoteRider(
      id: 'kk',
      name: 'KK',
      lat: 18.37,
      lng: 73.85,
      updatedAt: clock.subtract(const Duration(hours: 6)),
    );
    final row = ride.packRows.firstWhere((row) => row.name == 'KK');
    expect(row.online, isFalse);
    expect(ride.mapRiders.map((rider) => rider.name), contains('KK'));
    expect(ride.joinedPhones.map((phone) => phone.label), contains('KK'));
  });

  test('a GPS lock stays on the real fix instead of the simulator', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 14, 8));
    const home = LatLng(19.07, 72.87);
    ride.gpsLocked = true;
    ride.gpsFix = home;
    ride.gpsAt = DateTime(2026, 10, 14, 7);

    ride.tick(const Duration(seconds: 30));

    expect(ride.you.latitude, home.latitude);
    expect(ride.you.longitude, home.longitude);
    expect(ride.mapRiders.firstWhere((rider) => rider.you).point.latitude, home.latitude);
  });

  test('generating a code makes you the admin of that ride', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 14, 8));
    ride.generateCode();
    expect(ride.admin, isTrue);
    ride.beginPlanning();
    expect(ride.planning, isTrue);
    ride.joinCode('ZEN-2222');
    expect(ride.admin, isFalse);
    ride.planning = false;
    ride.beginPlanning();
    expect(ride.planning, isFalse);
  });

  test('a toll naka becomes a halt on the nearest day', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.beginPlanning();
    ride.setDraftDays(2);
    ride.draftStart = const LatLng(19.0, 72.8);
    ride.draftStartName = 'Mumbai';
    ride.draftHalts = const [
      RideHalt(id: 'e1', name: 'Pune', point: LatLng(18.5, 73.8), day: 1, kind: HaltKind.dayEnd),
      RideHalt(id: 'e2', name: 'Goa', point: LatLng(15.5, 73.8), day: 2, kind: HaltKind.dayEnd),
    ];

    ride.pickToll(const TollPlaza(id: 'khed', name: 'Khed Shivapur', point: LatLng(17.0, 73.8)));
    expect(ride.pickedToll?.name, 'Khed Shivapur');
    ride.addTollAsHalt();

    expect(ride.pickedToll, isNull);
    expect(ride.dayStops(2, draft: true).map((halt) => halt.name), ['Khed Shivapur']);
    expect(ride.dayStops(1, draft: true), isEmpty);

    ride.pickToll(const TollPlaza(id: 'again', name: 'Khed again', point: LatLng(17.0, 73.8)));
    ride.addTollAsHalt();
    expect(ride.dayStops(2, draft: true), hasLength(1));
    expect(ride.planNote, contains('already a halt'));
  });

  test('a halt estimates the clock from the day start', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.beginPlanning();
    ride.draftStart = const LatLng(19.0, 72.8);
    ride.draftHalts = const [
      RideHalt(id: 'stop', name: 'Chai', point: LatLng(19.05, 72.8), day: 1, kind: HaltKind.stop),
      RideHalt(id: 'end', name: 'Pune', point: LatLng(19.1, 72.8), day: 1, kind: HaltKind.dayEnd),
    ];
    ride.routes = const [
      RouteChoice(
        summary: 'NH48',
        duration: '1 hr',
        distance: '11 km',
        durationSeconds: 3600,
        distanceMeters: 11000,
        points: [LatLng(19.0, 72.8), LatLng(19.1, 72.8)],
      ),
    ];

    expect(ride.haltEstimateLabel(1, const LatLng(19.05, 72.8)), 'Estimated time');

    ride.setDayClock(1, startMinute: 6 * 60);
    expect(ride.haltEstimateLabel(1, const LatLng(19.05, 72.8)), 'Estimated time · 6:30 AM');

    ride.setDayClock(1, startMinute: 22 * 60, endMinute: 6 * 60);
    expect(ride.haltEstimateLabel(1, const LatLng(19.05, 72.8)), 'Estimated time · 2:00 AM');
  });

  test('day start and end times survive a save and a shared plan', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.beginPlanning();
    ride.setDayClock(1, startMinute: 6 * 60, endMinute: 18 * 60);
    ride.savePlan();
    expect(ride.dayStartMinute(1, draft: false), 6 * 60);
    expect(ride.dayEndMinute(1, draft: false), 18 * 60);

    ride.beginPlanning();
    expect(ride.dayStartMinute(1), 6 * 60);
    expect(ride.dayEndMinute(1), 18 * 60);

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

  test('an empty pack is only the rider who joined', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 14, 8));
    expect(ride.packRows.map((row) => row.you), [true]);
    expect(ride.mapRiders.map((rider) => rider.you), [true]);
  });
}
