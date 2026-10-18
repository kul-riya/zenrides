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

  test('an empty pack is only the rider who joined', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 14, 8));
    expect(ride.packRows.map((row) => row.you), [true]);
    expect(ride.mapRiders.map((rider) => rider.you), [true]);
  });
}
