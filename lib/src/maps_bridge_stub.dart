import 'package:latlong2/latlong.dart';

import 'maps_types.dart';
import 'ride_api.dart';

const bool mapsAvailable = false;

const bool mapsScriptReady = false;

Future<void> loadMaps() async {}

Future<List<FuelPump>> nearbyFuel(LatLng here) async => const [];

Future<List<FuelPump>> fuelAlong(List<LatLng> road) async => const [];

Future<List<TollPlaza>> tollsAlong(List<LatLng> road) async => const [];

Future<List<PlaceHit>> search(String query, LatLng here) async => const [];

Future<List<RouteChoice>> directions({required LatLng origin, required String placeId, List<LatLng> via = const []}) async => const [];

Future<HazardReport> hazards(LatLng here, double heading) async => const HazardReport(hazards: [], failures: []);

Future<LatLng?> placePoint(String placeId) async => null;
