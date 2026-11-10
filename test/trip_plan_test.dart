import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:zenrides/src/navigation/maps_types.dart';
import 'package:zenrides/src/planning/trip_plan.dart';

String _clock(int minute) {
  final hour = minute ~/ 60;
  final mins = minute % 60;
  final twelve = hour % 12 == 0 ? 12 : hour % 12;
  return '$twelve:${mins.toString().padLeft(2, '0')} ${hour >= 12 ? 'PM' : 'AM'}';
}

void main() {
  const mumbai = (point: LatLng(19.0, 72.8), name: 'Mumbai');
  const pune = (point: LatLng(18.5, 73.8), name: 'Pune');
  const goa = (point: LatLng(15.5, 73.8), name: 'Goa');

  group('originOf', () {
    test('day 1 starts at the plan start', () {
      final plan = TripPlan(days: 2, start: mumbai, finish: goa);
      expect(plan.originOf(1), mumbai.point);
    });

    test('day 2 inherits day 1\'s end', () {
      final plan = TripPlan(
        days: 2,
        start: mumbai,
        finish: goa,
        halts: [RideHalt(id: 'e1', name: 'Pune', point: pune.point, day: 1, kind: HaltKind.dayEnd)],
      );
      expect(plan.originOf(2), pune.point);
    });

    test('a custom day start that matches the inherited point reverts to inherited', () {
      final plan = TripPlan(
        days: 2,
        start: mumbai,
        finish: goa,
        halts: [
          RideHalt(id: 'e1', name: 'Pune', point: pune.point, day: 1, kind: HaltKind.dayEnd),
          RideHalt(id: 's2', name: 'Pune again', point: pune.point, day: 2, kind: HaltKind.dayStart),
        ],
      );
      expect(plan.originOf(2), pune.point);
    });

    test('a genuinely different custom day start is kept', () {
      const elsewhere = LatLng(18.6, 73.9);
      final plan = TripPlan(
        days: 2,
        start: mumbai,
        finish: goa,
        halts: [
          RideHalt(id: 'e1', name: 'Pune', point: pune.point, day: 1, kind: HaltKind.dayEnd),
          RideHalt(id: 's2', name: 'Elsewhere', point: elsewhere, day: 2, kind: HaltKind.dayStart),
        ],
      );
      expect(plan.originOf(2), elsewhere);
    });
  });

  group('destinationOf', () {
    test('a far-enough day end is the destination', () {
      final plan = TripPlan(
        days: 1,
        start: mumbai,
        halts: [RideHalt(id: 'e1', name: 'Pune', point: pune.point, day: 1, kind: HaltKind.dayEnd)],
      );
      expect(plan.destinationOf(1)?.point, pune.point);
    });

    test('a loop day (end back at the start) falls back to its last stop', () {
      const stop = LatLng(18.7, 73.6);
      final plan = TripPlan(
        days: 1,
        start: mumbai,
        halts: [
          RideHalt(id: 's', name: 'Lonavala', point: stop, day: 1, kind: HaltKind.stop),
          RideHalt(id: 'e1', name: 'Back home', point: mumbai.point, day: 1, kind: HaltKind.dayEnd),
        ],
      );
      expect(plan.destinationOf(1)?.point, stop);
    });

    test('the last day falls back to the trip finish', () {
      final plan = TripPlan(days: 1, start: mumbai, finish: goa);
      expect(plan.destinationOf(1)?.point, goa.point);
    });

    test('a day with nowhere to go yet has no destination', () {
      final plan = TripPlan(days: 1, start: mumbai);
      expect(plan.destinationOf(1), isNull);
    });
  });

  test('marksOf collapses near-duplicate points', () {
    final plan = TripPlan(
      days: 1,
      start: mumbai,
      halts: [RideHalt(id: 's', name: 'Still Mumbai', point: LatLng(19.001, 72.801), day: 1, kind: HaltKind.stop)],
      finish: goa,
    );
    // The near-duplicate stop collapses into the start; day 1 is also the
    // only (last) day, so the trip finish is still added.
    expect(plan.marksOf(1), [mumbai.point, goa.point]);
  });

  group('place', () {
    test('placing the start sets TripPlan.start', () {
      const plan = TripPlan.empty;
      final next = plan.place(PlanSlot.start, 1, mumbai, id: 'x');
      expect(next.start, mumbai);
    });

    test('a day-start that lands on the inherited origin is dropped, not stored', () {
      final plan = TripPlan(
        days: 2,
        start: mumbai,
        halts: [RideHalt(id: 'e1', name: 'Pune', point: pune.point, day: 1, kind: HaltKind.dayEnd)],
      );
      final next = plan.place(PlanSlot.dayStart, 2, pune, id: 'x');
      expect(next.customStartOf(2), isNull);
    });

    test('adding a stop appends it', () {
      final plan = TripPlan(days: 1, start: mumbai);
      final next = plan.place(PlanSlot.stop, 1, pune, id: 'stop-1');
      expect(next.stopsOn(1).map((h) => h.name), ['Pune']);
    });
  });

  test('withDays trims halts and clocks beyond the new day count', () {
    final plan = TripPlan(
      days: 3,
      halts: [
        RideHalt(id: 'a', name: 'A', point: LatLng(1, 1), day: 2, kind: HaltKind.stop),
        RideHalt(id: 'b', name: 'B', point: LatLng(2, 2), day: 3, kind: HaltKind.stop),
      ],
      clocks: {2: DayClock(startMinute: 360), 3: DayClock(startMinute: 420)},
    );
    final next = plan.withDays(2);
    expect(next.days, 2);
    expect(next.halts.map((h) => h.day), [2]);
    expect(next.clocks.keys, [2]);
  });

  test('roadFitsDay matches a road that starts and ends on this day\'s marks', () {
    final plan = TripPlan(
      days: 1,
      start: mumbai,
      halts: [RideHalt(id: 'e1', name: 'Pune', point: pune.point, day: 1, kind: HaltKind.dayEnd)],
    );
    final fitting = [mumbai.point, LatLng(18.7, 73.3), pune.point];
    final notFitting = [goa.point, LatLng(16, 74)];
    expect(plan.roadFitsDay(fitting, 1), isTrue);
    expect(plan.roadFitsDay(notFitting, 1), isFalse);
  });

  test('nearestDayForPoint picks the day whose road (or marks) is closest', () {
    final plan = TripPlan(
      days: 2,
      start: mumbai,
      halts: [RideHalt(id: 'e1', name: 'Pune', point: pune.point, day: 1, kind: HaltKind.dayEnd)],
      finish: goa,
    );
    final day = nearestDayForPoint(plan, (_) => null, const LatLng(18.9, 73.0));
    expect(day, 1);
  });

  test('nearestDayForPoint is null when nothing is close enough', () {
    final plan = TripPlan(days: 1, start: mumbai, finish: pune);
    final day = nearestDayForPoint(plan, (_) => null, const LatLng(-30, 140));
    expect(day, isNull);
  });

  group('haltEtaLabel', () {
    const road = RouteChoice(
      summary: 'NH48',
      duration: '1 hr',
      distance: '11 km',
      durationSeconds: 3600,
      distanceMeters: 11000,
      points: [LatLng(19.0, 72.8), LatLng(19.1, 72.8)],
    );

    test('falls back to a bare label with no day start', () {
      final plan = TripPlan(days: 1, start: mumbai);
      expect(haltEtaLabel(plan, road, 1, const LatLng(19.05, 72.8), _clock), 'Estimated time');
    });

    test('estimates a clock from the day start once one is set', () {
      final plan = const TripPlan(days: 1, start: mumbai).withClock(1, startMinute: 6 * 60);
      expect(haltEtaLabel(plan, road, 1, const LatLng(19.05, 72.8), _clock), 'Estimated time · 6:30 AM');
    });

    test('wraps past midnight when the end time is before the start time', () {
      final plan = const TripPlan(days: 1, start: mumbai).withClock(1, startMinute: 22 * 60, endMinute: 6 * 60);
      expect(haltEtaLabel(plan, road, 1, const LatLng(19.05, 72.8), _clock), 'Estimated time · 2:00 AM');
    });
  });
}
