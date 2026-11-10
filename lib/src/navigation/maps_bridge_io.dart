import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../planning/shared_plan.dart';
import 'maps_types.dart';

const _mapsApiKey = String.fromEnvironment('MAPS_API_KEY');

bool get mapsAvailable => _mapsApiKey.isNotEmpty;

const bool mapsScriptReady = false;

Future<void> loadMaps() async {}

Future<List<FuelPump>> nearbyFuel(LatLng here) async => const [];

Future<List<FuelPump>> fuelAlong(List<LatLng> road) async => const [];

Future<List<TollPlaza>> tollsAlong(List<LatLng> road) async => const [];

Future<HazardReport> hazards(LatLng here, double heading) async =>
    const HazardReport(hazards: [], failures: []);

Future<List<PlaceHit>> search(String query, LatLng here) async {
  final body = await _post(
    'https://places.googleapis.com/v1/places:searchText',
    {
      'textQuery': query,
      'maxResultCount': 6,
      'locationBias': {
        'circle': {
          'center': {'latitude': here.latitude, 'longitude': here.longitude},
          'radius': 50000,
        },
      },
    },
    'places.id,places.displayName,places.formattedAddress,places.location',
  );
  final places = body['places'];
  if (places is! List) return const [];
  final hits = <PlaceHit>[];
  for (final place in places) {
    if (place is! Map) continue;
    final location = place['location'];
    final lat = location is Map ? location['latitude'] : null;
    final lng = location is Map ? location['longitude'] : null;
    final id = lat is num && lng is num ? '${lat.toDouble()},${lng.toDouble()}' : '${place['id']}';
    if (id.isEmpty) continue;
    final display = place['displayName'];
    final name = display is Map ? display['text'] : null;
    hits.add(PlaceHit(
      placeId: id,
      name: name is String && name.isNotEmpty ? name : query,
      detail: place['formattedAddress'] is String ? place['formattedAddress'] as String : '',
    ));
  }
  return hits;
}

Future<LatLng?> placePoint(String placeId) async {
  final direct = RegExp(r'^(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)$').firstMatch(placeId);
  if (direct != null) {
    return LatLng(double.parse(direct.group(1)!), double.parse(direct.group(2)!));
  }
  final body = await _get(
    'https://places.googleapis.com/v1/places/$placeId',
    'location',
  );
  final location = body['location'];
  if (location is! Map) return null;
  final lat = location['latitude'];
  final lng = location['longitude'];
  if (lat is! num || lng is! num) return null;
  return LatLng(lat.toDouble(), lng.toDouble());
}

Future<List<RouteChoice>> directions({
  required LatLng origin,
  required String placeId,
  List<LatLng> via = const [],
}) async {
  final coordinate = RegExp(r'^(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)$').firstMatch(placeId);
  final destination = coordinate == null
      ? {'placeId': placeId}
      : {
          'location': {
            'latLng': {
              'latitude': double.parse(coordinate.group(1)!),
              'longitude': double.parse(coordinate.group(2)!),
            },
          },
        };
  final body = await _post(
    'https://routes.googleapis.com/directions/v2:computeRoutes',
    {
      'origin': {
        'location': {
          'latLng': {'latitude': origin.latitude, 'longitude': origin.longitude},
        },
      },
      'destination': destination,
      if (via.isNotEmpty)
        'intermediates': [
          for (final point in via)
            {
              'location': {
                'latLng': {'latitude': point.latitude, 'longitude': point.longitude},
              },
            },
        ],
      'travelMode': 'DRIVE',
      'routingPreference': 'TRAFFIC_AWARE',
      'computeAlternativeRoutes': via.isEmpty,
    },
    'routes.duration,routes.distanceMeters,routes.description,routes.polyline.encodedPolyline,routes.legs.steps.navigationInstruction,routes.legs.steps.startLocation',
  );
  final routes = body['routes'];
  if (routes is! List) return const [];
  final choices = <RouteChoice>[];
  for (final route in routes) {
    if (route is! Map) continue;
    final polyline = route['polyline'];
    final encoded = polyline is Map ? polyline['encodedPolyline'] : null;
    if (encoded is! String || encoded.isEmpty) continue;
    final points = decodeRoutePolyline(encoded);
    if (points.length < 2) continue;
    final meters = (route['distanceMeters'] as num?)?.round() ?? 0;
    final seconds = _seconds(route['duration']);
    final steps = <RouteStep>[];
    final legs = route['legs'];
    if (legs is List) {
      for (final leg in legs) {
        if (leg is! Map) continue;
        final rawSteps = leg['steps'];
        if (rawSteps is! List) continue;
        for (final step in rawSteps) {
          if (step is! Map) continue;
          final instruction = step['navigationInstruction'];
          final text = instruction is Map ? instruction['instructions'] : null;
          final start = step['startLocation'];
          final latLng = start is Map ? start['latLng'] : null;
          final lat = latLng is Map ? latLng['latitude'] : null;
          final lng = latLng is Map ? latLng['longitude'] : null;
          if (text is! String || lat is! num || lng is! num) continue;
          steps.add(RouteStep(instruction: text, point: LatLng(lat.toDouble(), lng.toDouble())));
        }
      }
    }
    final summary = route['description'];
    choices.add(RouteChoice(
      summary: summary is String && summary.isNotEmpty ? summary : 'Driving route',
      duration: formatSeconds(seconds),
      distance: formatMeters(meters),
      durationSeconds: seconds,
      distanceMeters: meters,
      traffic: true,
      points: points,
      steps: steps,
    ));
  }
  return choices;
}

List<LatLng> decodeRoutePolyline(String encoded) {
  final points = <LatLng>[];
  var index = 0;
  var lat = 0;
  var lng = 0;
  while (index < encoded.length) {
    int read() {
      var shift = 0;
      var result = 0;
      var byte = 0;
      do {
        byte = encoded.codeUnitAt(index++) - 63;
        result |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20 && index <= encoded.length);
      return (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
    }

    lat += read();
    lng += read();
    points.add(LatLng(lat / 1e5, lng / 1e5));
  }
  return points;
}

int _seconds(Object? duration) {
  if (duration is! String || !duration.endsWith('s')) return 0;
  return int.tryParse(duration.substring(0, duration.length - 1)) ?? 0;
}

Future<Map<String, dynamic>> _post(String url, Map<String, Object?> body, String mask) async {
  final response = await http.post(
    Uri.parse(url),
    headers: {
      'Content-Type': 'application/json',
      'X-Goog-Api-Key': _mapsApiKey,
      'X-Goog-FieldMask': mask,
    },
    body: jsonEncode(body),
  );
  return _read(response);
}

Future<Map<String, dynamic>> _get(String url, String mask) async {
  final response = await http.get(
    Uri.parse(url),
    headers: {
      'X-Goog-Api-Key': _mapsApiKey,
      'X-Goog-FieldMask': mask,
    },
  );
  return _read(response);
}

Map<String, dynamic> _read(http.Response response) {
  final decoded = response.body.isEmpty ? null : jsonDecode(response.body);
  if (response.statusCode >= 200 && response.statusCode < 300) {
    return decoded is Map<String, dynamic> ? decoded : const {};
  }
  final error = decoded is Map ? decoded['error'] : null;
  final message = error is Map ? error['message'] : null;
  final status = error is Map ? error['status'] : null;
  throw Exception(message is String && message.isNotEmpty ? '$status $message' : 'Google Maps request failed');
}
