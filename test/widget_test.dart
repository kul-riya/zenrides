import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrides/src/ride/ride_controller.dart';
import 'package:zenrides/src/ride/ride_shell.dart';

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

    expect(find.text('Generate a code'), findsOneWidget);
    expect(find.text('Join a code, ZEN-1234'), findsOneWidget);
    expect(find.text('END'), findsNothing);
    expect(find.textContaining('KM/H'), findsNothing);
    expect(find.text('Recenter'), findsNothing);
  });

  testWidgets('the profile drawer logs out', (tester) async {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 14, 8));
    ride.generateCode();
    await tester.pumpWidget(
      MaterialApp(home: RideScope(ride: ride, child: const RideShell())),
    );
    await tester.tap(find.byTooltip('Profile'));
    await tester.pumpAndSettle();
    expect(find.text('Log out'), findsOneWidget);
    expect(find.text('Lead Pilot · ${ride.code}'), findsOneWidget);
    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();
    expect(ride.signedIn, isFalse);
    expect(ride.onRide, isFalse);
    expect(find.text('You are signed out.'), findsOneWidget);
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

    ride.nav.setSearchFocused(false);
    await tester.pump();

    expect(find.text('Hide Other Bikes'), findsOneWidget);
    expect(find.text('GPS off'), findsOneWidget);
  });
}
