import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrides/src/ride_controller.dart';
import 'package:zenrides/src/ride_shell.dart';

void main() {
  testWidgets('Pack shows the group code and END, and speed stays off the HUD', (tester) async {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 14, 8));
    await tester.pumpWidget(
      MaterialApp(
        home: RideScope(ride: ride, child: const RideShell()),
      ),
    );

    expect(find.text('Where to?'), findsOneWidget);
    expect(find.text('END'), findsNothing);
    expect(find.textContaining('KM/H'), findsNothing);

    await tester.tap(find.textContaining('Pack'));
    await tester.pump();

    expect(find.text('ZEN-4365'), findsOneWidget);
    expect(find.text('END'), findsOneWidget);
    expect(find.textContaining('KM/H'), findsNothing);
    expect(find.text('Recenter'), findsNothing);
  });

  testWidgets('the bike and GPS chips hide while a place search is open', (tester) async {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 14, 8));
    await tester.pumpWidget(MaterialApp(
      home: RideScope(ride: ride, child: const Scaffold(body: HudPage())),
    ));
    await tester.pump();

    expect(find.text('Hide Other Bikes'), findsOneWidget);
    expect(find.text('GPS off'), findsOneWidget);

    await tester.tap(find.byType(TextField));
    await tester.pump();

    expect(find.text('Hide Other Bikes'), findsNothing);
    expect(find.text('GPS off'), findsNothing);

    ride.setSearchFocused(false);
    await tester.pump();

    expect(find.text('Hide Other Bikes'), findsOneWidget);
    expect(find.text('GPS off'), findsOneWidget);
  });
}
