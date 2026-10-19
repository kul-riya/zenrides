import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:zenrides/src/maps_types.dart';
import 'package:zenrides/src/ride_api.dart';
import 'package:zenrides/src/ride_controller.dart';
import 'package:zenrides/src/ride_shell.dart';

void main() {
  testWidgets('a day fills the screen, then the map fills it to place a point', (tester) async {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 14, 8));
    ride.admin = true;
    ride.beginPlanning();
    ride.setDraftDays(3);

    await tester.pumpWidget(MaterialApp(
      home: RideScope(ride: ride, child: const Scaffold(body: HudPage())),
    ));
    await tester.pump();

    expect(find.text('Day 1'), findsOneWidget);
    expect(find.text('Day 1 of 3'), findsOneWidget);
    expect(find.text('Day 3'), findsOneWidget);
    expect(find.text('Search a day 1 stop'), findsOneWidget);
    expect(find.text('Search a place'), findsNothing);

    await tester.tap(find.text('Day 1'));
    await tester.pumpAndSettle();
    expect(ride.planScreen, PlanScreen.day);
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('End'), findsOneWidget);
    expect(find.text('Halts'), findsOneWidget);
    expect(find.text('Add a halt'), findsOneWidget);
    expect(find.text('Search a day 1 stop'), findsNothing);
    expect(find.text('Day 1 of 3'), findsNothing);

    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    expect(ride.planSlot, PlanSlot.start);
    expect(ride.planScreen, PlanScreen.map);
    expect(find.text('Search the start'), findsOneWidget);
    expect(find.text('Start'), findsNothing);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(ride.planScreen, PlanScreen.day);
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Search the start'), findsNothing);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(ride.planScreen, PlanScreen.overview);
    expect(find.text('Day 1 of 3'), findsOneWidget);

    await tester.tap(find.text('Day 2'));
    await tester.pumpAndSettle();
    expect(ride.planDay, 2);
    expect(ride.planScreen, PlanScreen.day);
    expect(find.text('Day start'), findsOneWidget);
    expect(find.text('End'), findsOneWidget);
    expect(find.text('Add a halt'), findsOneWidget);
    expect(find.text('Start'), findsNothing);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    expect(find.text('Day 4'), findsOneWidget);
    expect(ride.draftDays, 4);
  });

  testWidgets('a tap off the roads switches the map note to the whole ride', (tester) async {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 14, 8));
    ride.admin = true;
    ride.beginPlanning();
    ride.setDraftDays(2);
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

    await tester.pumpWidget(MaterialApp(
      home: RideScope(ride: ride, child: const Scaffold(body: HudPage())),
    ));
    await tester.pump();

    expect(find.text('Day 2 · 2 hr · 80 km · live traffic'), findsWidgets);
    expect(find.text('Ride · 3 hr · 120 km'), findsNothing);

    ride.showWholeRide();
    await tester.pump();

    expect(find.text('Ride · 3 hr · 120 km'), findsWidgets);
    expect(ride.planDay, 2);
  });

  testWidgets('a long route name scrolls inside the card and the right curve stays on screen', (tester) async {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 14, 8));
    ride.admin = true;
    ride.beginPlanning();
    ride.draftStart = const LatLng(19.05, 72.84);
    ride.draftStartName = 'Mumbai';
    ride.draftHalts = const [
      RideHalt(id: 'end', name: 'Pune', point: LatLng(19.02, 72.84), day: 1, kind: HaltKind.dayEnd),
    ];
    ride.routes = const [
      RouteChoice(
        summary: 'Symbiosis Law School Road · National Games Village',
        duration: '4 hr 6 min',
        distance: '154 km',
        points: [LatLng(19.05, 72.84), LatLng(19.02, 72.84)],
      ),
    ];

    await tester.binding.setSurfaceSize(const Size(360, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: RideScope(ride: ride, child: const Scaffold(body: HudPage())),
    ));
    await tester.pump();

    const detail = '154 km · Symbiosis Law School Road · National Games Village';
    final line = find.text(detail);
    expect(line, findsOneWidget);
    final scroller = find.ancestor(of: line, matching: find.byType(SingleChildScrollView));
    expect(scroller, findsOneWidget);
    expect(tester.widget<SingleChildScrollView>(scroller).scrollDirection, Axis.horizontal);

    final card = find.ancestor(of: line, matching: find.byType(Material)).first;
    final material = tester.widget<Material>(card);
    expect(material.borderRadius, BorderRadius.circular(16));
    expect(material.clipBehavior, Clip.antiAlias);
    final rect = tester.getRect(card);
    expect(rect.right, lessThanOrEqualTo(360));
    expect(rect.right, greaterThan(200));
  });

  testWidgets('planning offers small fuel pump and toll naka switches', (tester) async {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.beginPlanning();

    await tester.pumpWidget(MaterialApp(
      home: RideScope(ride: ride, child: const Scaffold(body: HudPage())),
    ));
    await tester.pump();

    expect(find.text('Fuel pumps'), findsOneWidget);
    expect(find.text('Toll nakas'), findsOneWidget);

    await tester.tap(find.text('Fuel pumps'));
    await tester.pump();
    expect(ride.planPumpsOn, isTrue);

    await tester.tap(find.text('Toll nakas'));
    await tester.pump();
    expect(ride.planTollsOn, isTrue);
  });

  testWidgets('a day place lifts while a finger is on it', (tester) async {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 14, 8));
    ride.admin = true;
    ride.beginPlanning();
    ride.setDraftDays(2);

    await tester.pumpWidget(MaterialApp(
      home: RideScope(ride: ride, child: const Scaffold(body: HudPage())),
    ));
    await tester.pump();
    await tester.tap(find.text('Day 1'));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(tester.getCenter(find.text('Start')));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 180));
    final lifted = tester
        .widgetList<Transform>(find.ancestor(of: find.text('Start'), matching: find.byType(Transform)))
        .map((transform) => transform.transform.getTranslation().y)
        .reduce((a, b) => a < b ? a : b);
    expect(lifted, lessThan(-3));

    await gesture.up();
    await tester.pumpAndSettle();
    expect(ride.planScreen, PlanScreen.map);
  });

  testWidgets('each start, halt, and end sits in its own box', (tester) async {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.beginPlanning();
    ride.setDraftDays(2);
    ride.selectPlanSlot(PlanSlot.start);
    ride.armPick(true);
    ride.dropHalt(const LatLng(19.05, 72.84));
    ride.draftStartName = 'Rohan Mithila Lower Parijat';
    ride.selectPlanSlot(PlanSlot.dayEnd);
    ride.armPick(true);
    ride.dropHalt(const LatLng(19.09, 72.87));
    ride.selectPlanSlot(PlanSlot.stop);
    ride.armPick(true);
    ride.dropHalt(const LatLng(19.07, 72.85));
    ride.selectPlanDay(2);
    ride.selectPlanSlot(PlanSlot.dayEnd);
    ride.armPick(true);
    ride.dropHalt(const LatLng(15.49, 73.82));

    await tester.pumpWidget(MaterialApp(
      home: RideScope(ride: ride, child: const Scaffold(body: HudPage())),
    ));
    await tester.pump();

    expect(find.text('Day 1 start · Start. Day 1 end · Day 1 end. Day 2 end · Day 2 end.'), findsNothing);
    expect(find.text('Day 1 · Start'), findsOneWidget);
    expect(find.text('Rohan Mithila Lower Parijat'), findsWidgets);
    expect(find.text('Day 1 · Halt'), findsOneWidget);
    expect(find.text('Day 1 · End'), findsOneWidget);
    expect(find.text('Day 2 · Start'), findsOneWidget);
    expect(find.text('Same as day 1 end'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Day 2 · End'),
      80,
      scrollable: find.ancestor(of: find.text('Day 1 · Start'), matching: find.byType(Scrollable)),
    );
    expect(find.text('Day 2 · End'), findsOneWidget);

    await tester.tap(find.text('Day 1 · Halt'));
    await tester.pumpAndSettle();
    expect(ride.planDay, 1);
    expect(ride.planScreen, PlanScreen.day);
  });

  testWidgets('the plan panel contracts so the map can take the screen', (tester) async {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.beginPlanning();
    ride.setDraftDays(2);
    ride.selectPlanSlot(PlanSlot.start);
    ride.armPick(true);
    ride.dropHalt(const LatLng(19.05, 72.84));
    ride.draftStartName = 'Rohan Mithila Lower Parijat';

    await tester.pumpWidget(MaterialApp(
      home: RideScope(ride: ride, child: const Scaffold(body: HudPage())),
    ));
    await tester.pump();

    expect(find.text('Fuel pumps'), findsOneWidget);
    expect(find.text('Toll nakas'), findsOneWidget);
    expect(find.text('Day 1 · Start'), findsOneWidget);

    await tester.tap(find.byTooltip('Hide plan'));
    await tester.pumpAndSettle();

    expect(find.text('Day 1'), findsWidgets);
    expect(find.text('Fuel pumps'), findsOneWidget);
    expect(find.text('Toll nakas'), findsOneWidget);
    expect(find.text('Day 1 · Start'), findsNothing);
    expect(find.byTooltip('Show plan'), findsOneWidget);

    await tester.tap(find.byTooltip('Show plan'));
    await tester.pumpAndSettle();

    expect(find.text('Fuel pumps'), findsOneWidget);
    expect(find.text('Day 1 · Start'), findsOneWidget);
  });

  testWidgets('a day page has a start time, an end time, and estimated halt times', (tester) async {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.beginPlanning();
    ride.draftStart = const LatLng(19.0, 72.8);
    ride.draftStartName = 'Mumbai';
    ride.draftHalts = const [
      RideHalt(id: 'stop', name: 'Chai stop', point: LatLng(19.05, 72.8), day: 1, kind: HaltKind.stop),
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
    ride.openPlanDay(1);

    await tester.pumpWidget(MaterialApp(
      home: RideScope(ride: ride, child: const Scaffold(body: HudPage())),
    ));
    await tester.pump();

    expect(find.text('Set start time'), findsOneWidget);
    expect(find.text('Set end time'), findsOneWidget);
    expect(find.text('Estimated time'), findsWidgets);

    ride.setDayClock(1, startMinute: 6 * 60);
    await tester.pump();
    expect(find.text('6:00 AM'), findsOneWidget);
    expect(find.text('Estimated time · 6:30 AM'), findsWidgets);

    await tester.tap(find.text('Set end time'));
    await tester.pumpAndSettle();
    expect(ride.planScreen, PlanScreen.day);
    expect(find.text('When does day 1 end?'), findsOneWidget);
  });

  testWidgets('tapping a toll naka offers to add it as a halt on the plan', (tester) async {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 18, 8));
    ride.admin = true;
    ride.beginPlanning();
    ride.draftStart = const LatLng(19.0, 72.8);
    ride.draftStartName = 'Mumbai';
    ride.draftHalts = const [
      RideHalt(id: 'end', name: 'Pune', point: LatLng(18.5, 73.8), day: 1, kind: HaltKind.dayEnd),
    ];
    ride.pickToll(const TollPlaza(id: 'khed', name: 'Khed Shivapur', point: LatLng(18.75, 73.3)));

    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: RideScope(ride: ride, child: const Scaffold(body: HudPage())),
    ));
    await tester.pump();

    expect(find.text('Khed Shivapur'), findsOneWidget);
    expect(find.text('Add as halt'), findsOneWidget);

    await tester.tap(find.text('Add as halt'));
    await tester.pump();

    expect(ride.dayStops(1, draft: true).map((halt) => halt.name), ['Khed Shivapur']);
    expect(find.text('Add as halt'), findsNothing);
    expect(find.text('Day 1 · Halt'), findsOneWidget);
    expect(find.text('Estimated time'), findsOneWidget);
  });
}
