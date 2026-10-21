import 'package:latlong2/latlong.dart';

import 'maps_bridge.dart';
import 'ride_api.dart' show FuelPump, TollPlaza;

export 'maps_types.dart';

/// Wraps the Maps data bridge (search, routes, fuel, tolls, hazards) so
/// RideController never calls MapsBridge's statics directly.
abstract class MapAdapter {
  bool get available;

  Future<List<FuelPump>> nearbyFuel(LatLng here);

  Future<List<FuelPump>> fuelAlong(List<LatLng> road);

  Future<List<TollPlaza>> tollsAlong(List<LatLng> road);

  Future<List<PlaceHit>> search(String query, LatLng here);

  Future<List<RouteChoice>> directions({required LatLng origin, required String placeId, List<LatLng> via});

  Future<HazardReport> hazards(LatLng here, double heading);

  Future<LatLng?> placePoint(String placeId);
}

/// Delegates to MapsBridge, which is already split for web vs. non-web by
/// conditional import (maps_bridge_web.dart / maps_bridge_stub.dart).
class GoogleMapsAdapter implements MapAdapter {
  const GoogleMapsAdapter();

  @override
  bool get available => MapsBridge.available;

  @override
  Future<List<FuelPump>> nearbyFuel(LatLng here) => MapsBridge.nearbyFuel(here);

  @override
  Future<List<FuelPump>> fuelAlong(List<LatLng> road) => MapsBridge.fuelAlong(road);

  @override
  Future<List<TollPlaza>> tollsAlong(List<LatLng> road) => MapsBridge.tollsAlong(road);

  @override
  Future<List<PlaceHit>> search(String query, LatLng here) => MapsBridge.search(query, here);

  @override
  Future<List<RouteChoice>> directions({required LatLng origin, required String placeId, List<LatLng> via = const []}) =>
      MapsBridge.directions(origin: origin, placeId: placeId, via: via);

  @override
  Future<HazardReport> hazards(LatLng here, double heading) => MapsBridge.hazards(here, heading);

  @override
  Future<LatLng?> placePoint(String placeId) => MapsBridge.placePoint(placeId);
}
