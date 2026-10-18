import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrides/src/ride_controller.dart';
import 'package:zenrides/src/ride_shell.dart';

void main() {
  testWidgets('planning uses a day tab for each day and searches on the map', (tester) async {
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

    await tester.tap(find.text('Day 2'));
    await tester.pumpAndSettle();
    expect(ride.planDay, 2);
    expect(find.text('Day 2 of 3'), findsOneWidget);
    expect(find.text('Search a day 2 stop'), findsOneWidget);

    await tester.tap(find.text('Placing Day 2 stop'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    expect(ride.planSlot, PlanSlot.start);
    expect(find.text('Search the start'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    expect(find.text('Day 4'), findsOneWidget);
    expect(ride.draftDays, 4);
  });
}
