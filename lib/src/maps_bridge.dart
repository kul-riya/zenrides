import 'package:latlong2/latlong.dart';

import 'maps_bridge_stub.dart' if (dart.library.js_interop) 'maps_bridge_web.dart' as impl;
import 'maps_types.dart';
import 'ride_api.dart';

export 'maps_types.dart';

class MapsBridge {
  static bool get available => impl.mapsAvailable;

  static bool get scriptReady => impl.mapsScriptReady;

  static Future<void> loadMaps() => impl.loadMaps();

  static Future<List<FuelPump>> nearbyFuel(LatLng here) => impl.nearbyFuel(here);

  static Future<List<FuelPump>> fuelAlong(List<LatLng> road) => impl.fuelAlong(road);

  static Future<List<TollPlaza>> tollsAlong(List<LatLng> road) => impl.tollsAlong(road);

  static Future<List<PlaceHit>> search(String query, LatLng here) => impl.search(query, here);

  static Future<List<RouteChoice>> directions({
    required LatLng origin,
    required String placeId,
    List<LatLng> via = const [],
  }) =>
      impl.directions(origin: origin, placeId: placeId, via: via);

  static Future<HazardReport> hazards(LatLng here, double heading) => impl.hazards(here, heading);

  static Future<LatLng?> placePoint(String placeId) => impl.placePoint(placeId);
}
