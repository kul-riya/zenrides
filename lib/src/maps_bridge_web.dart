import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:latlong2/latlong.dart';

import 'maps_types.dart';
import 'ride_api.dart';

const bool mapsAvailable = true;

@JS('document.createElement')
external JSObject _createElement(JSString tag);

@JS('document.head.appendChild')
external void _appendChild(JSObject child);

extension type _Script(JSObject _) implements JSObject {
  external set src(JSString value);
  external set onload(JSFunction? value);
  external set onerror(JSFunction? value);
}

Future<void> loadMaps() {
  final key = RideApi.mapsKey;
  if (key.isEmpty) {
    throw StateError('MAPS_API_KEY missing. Run with --dart-define-from-file=.env');
  }
  final done = Completer<void>();
  final script = _Script(_createElement('script'.toJS));
  script.onload = (() {
    if (!done.isCompleted) done.complete();
  }).toJS;
  script.onerror = (() {
    if (!done.isCompleted) done.completeError(StateError('Google Maps failed to load'));
  }).toJS;
  script.src = 'https://maps.googleapis.com/maps/api/js?key=$key'.toJS;
  _appendChild(script);
  return done.future;
}

@JS('zenRidesMaps.nearbyFuel')
external JSPromise<JSString> _nearbyFuel(JSNumber lat, JSNumber lng);

@JS('zenRidesMaps.search')
external JSPromise<JSString> _search(JSString query, JSNumber lat, JSNumber lng);

@JS('zenRidesMaps.directions')
external JSPromise<JSString> _directions(JSNumber lat, JSNumber lng, JSString placeId);

@JS('zenRidesMaps.hazards')
external JSPromise<JSString> _hazards(JSNumber lat, JSNumber lng, JSNumber heading);

@JS('zenRidesMaps.placePoint')
external JSPromise<JSString> _placePoint(JSString placeId);

Future<List<FuelPump>> nearbyFuel(LatLng here) async {
  final raw = (await _nearbyFuel(here.latitude.toJS, here.longitude.toJS).toDart).toDart;
  final decoded = jsonDecode(raw);
  if (decoded is! List) return const [];
  return [
    for (final item in decoded)
      if (item is Map)
        FuelPump(
          id: '${item['id']}',
          name: '${item['name']}',
          point: LatLng((item['lat'] as num).toDouble(), (item['lng'] as num).toDouble()),
        ),
  ];
}

Future<List<PlaceHit>> search(String query, LatLng here) async {
  final raw = (await _search(query.toJS, here.latitude.toJS, here.longitude.toJS).toDart).toDart;
  final decoded = jsonDecode(raw);
  if (decoded is! List) return const [];
  return [
    for (final item in decoded)
      if (item is Map)
        PlaceHit(
          placeId: '${item['placeId']}',
          name: '${item['name']}',
          detail: '${item['detail']}',
        ),
  ];
}

Future<List<RouteChoice>> directions({required LatLng origin, required String placeId}) async {
  final raw = (await _directions(origin.latitude.toJS, origin.longitude.toJS, placeId.toJS).toDart).toDart;
  final decoded = jsonDecode(raw);
  if (decoded is! List) return const [];
  return [
    for (final item in decoded)
      if (item is Map)
        RouteChoice(
          summary: '${item['summary']}',
          duration: '${item['duration']}',
          distance: '${item['distance']}',
          durationSeconds: (item['durationSeconds'] as num?)?.round() ?? 0,
          distanceMeters: (item['distanceMeters'] as num?)?.round() ?? 0,
          points: [
            for (final point in (item['points'] as List? ?? const []))
              if (point is Map) LatLng((point['lat'] as num).toDouble(), (point['lng'] as num).toDouble()),
          ],
          steps: [
            for (final step in (item['steps'] as List? ?? const []))
              if (step is Map && step['lat'] is num && step['lng'] is num)
                RouteStep(
                  instruction: '${step['instruction']}',
                  point: LatLng((step['lat'] as num).toDouble(), (step['lng'] as num).toDouble()),
                ),
          ],
        ),
  ];
}

Future<HazardReport> hazards(LatLng here, double heading) async {
  final raw = (await _hazards(here.latitude.toJS, here.longitude.toJS, heading.toJS).toDart).toDart;
  final decoded = jsonDecode(raw);
  if (decoded is! Map) {
    return const HazardReport(hazards: [], failures: ['Routes API Route.computeRoutes: empty response']);
  }
  return HazardReport(
    hazards: [
      for (final item in (decoded['hazards'] as List? ?? const []))
        if (item is Map)
          RoadHazard(
            id: '${item['id']}',
            title: '${item['title']}',
            detail: '${item['detail']}',
            point: item['lat'] is num && item['lng'] is num
                ? LatLng((item['lat'] as num).toDouble(), (item['lng'] as num).toDouble())
                : null,
          ),
    ],
    failures: [
      for (final item in (decoded['failures'] as List? ?? const [])) '$item',
    ],
  );
}

Future<LatLng?> placePoint(String placeId) async {
  final raw = (await _placePoint(placeId.toJS).toDart).toDart;
  final decoded = jsonDecode(raw);
  if (decoded is! Map || decoded['lat'] is! num || decoded['lng'] is! num) return null;
  return LatLng((decoded['lat'] as num).toDouble(), (decoded['lng'] as num).toDouble());
}
