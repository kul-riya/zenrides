import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:zenrides/src/navigation/maps_types.dart';
import 'package:zenrides/src/pack/pack_repository.dart';
import 'package:zenrides/src/planning/trip_plan.dart';
import 'package:zenrides/src/ride/ride_controller.dart';

void main() {
  test('a live rider carries the next halt and the last pump', () {
    final at = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    final json = liveRiderJson(
      name: 'KK',
      lat: 18.5,
      lng: 73.8,
      at: at,
      nextPlanStop: const RiderStop(name: 'Chai', lat: 18.7, lng: 73.4),
      lastFuelStop: const RiderStop(name: 'HP', lat: 18.6, lng: 73.5),
    );
    final rider = ridersFromSnapshot({'kk': json}).single;
    expect(rider.id, 'kk');
    expect(rider.name, 'KK');
    expect(rider.updatedAt, at);
    expect(rider.nextPlanStop?.name, 'Chai');
    expect(rider.nextPlanStop?.lat, 18.7);
    expect(rider.lastFuelStop?.name, 'HP');
    expect(rider.lastFuelStop?.lng, 73.5);

    final bare = ridersFromSnapshot({
      'a': liveRiderJson(name: 'A', lat: 1, lng: 2, at: at),
    }).single;
    expect(bare.nextPlanStop, isNull);
    expect(bare.lastFuelStop, isNull);
    expect(ridersFromSnapshot(null), isEmpty);
    expect(ridersFromSnapshot({'bad': 'nope'}), isEmpty);
  });

  test('passing a pump remembers it as the last fuel stop', () {
    final ride = RideController(network: false, clock: () => DateTime(2026, 10, 14, 8));
    ride.plan.halts = const [
      RideHalt(id: 'far', name: 'Pune', point: LatLng(18.5, 73.8), day: 1, kind: HaltKind.dayEnd),
      RideHalt(id: 'near', name: 'Chai', point: LatLng(19.08, 72.88), day: 1, kind: HaltKind.stop),
    ];
    ride.nav.pumps = const [
      FuelPump(id: 'hp', name: 'HP', point: LatLng(19.0704, 72.8704)),
    ];
    ride.pack.placeYou(const LatLng(19.07, 72.87));
    expect(ride.pack.nextPlanStop?.name, 'Chai');
    expect(ride.pack.lastFuelStop?.name, 'HP');

    ride.nav.pumps = const [];
    ride.pack.placeYou(const LatLng(19.2, 72.9));
    expect(ride.pack.lastFuelStop?.name, 'HP');
  });
}
