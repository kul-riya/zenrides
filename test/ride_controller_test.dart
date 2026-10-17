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
    expect(ride.mapRiders.firstWhere((rider) => rider.you).point, isNot(you));
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

  test('only an admin can open the planner', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 14, 8));
    ride.beginPlanning();
    expect(ride.planning, isFalse);
    ride.admin = true;
    ride.beginPlanning();
    expect(ride.planning, isTrue);
  });

  test('an empty pack is only the rider who joined', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 14, 8));
    expect(ride.packRows.map((row) => row.you), [true]);
    expect(ride.mapRiders.map((rider) => rider.you), [true]);
  });
}
