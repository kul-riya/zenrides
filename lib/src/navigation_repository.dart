import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'maps_types.dart';
import 'repository_exception.dart';

const _overpassServers = [
  'https://overpass-api.de/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
];

/// OSM Overpass fallback for fuel pumps and toll nakas, used when the
/// Google Maps bridge (MapAdapter) is unavailable or comes back empty.
class NavigationRepository {
  NavigationRepository({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<List<FuelPump>> fuelNear(LatLng here) async {
    final query = '''
[out:json][timeout:20];
(
  node["amenity"="fuel"](around:15000,${here.latitude},${here.longitude});
  way["amenity"="fuel"](around:15000,${here.latitude},${here.longitude});
);
out center 80;
''';
    final response = await _query(query);
    if (response == null) throw RideApiException('Fuel lookup failed');
    return _readPumps(response.body);
  }

  Future<List<FuelPump>> fuelAlong(List<LatLng> points) async {
    final box = _boundingBox(points, pad: 0.01);
    if (box == null) return const [];
    final query = '''
[out:json][timeout:20];
(
  node["amenity"="fuel"](${box.south},${box.west},${box.north},${box.east});
  way["amenity"="fuel"](${box.south},${box.west},${box.north},${box.east});
);
out center 160;
''';
    final response = await _query(query);
    return response == null ? const [] : _readPumps(response.body);
  }

  Future<List<TollPlaza>> tollsAlong(List<LatLng> points) async {
    final box = _boundingBox(points, pad: 0.02);
    if (box == null) return const [];
    final query = '''
[out:json][timeout:20];
(
  node["barrier"="toll_booth"](${box.south},${box.west},${box.north},${box.east});
  way["barrier"="toll_booth"](${box.south},${box.west},${box.north},${box.east});
  node["highway"="toll_gantry"](${box.south},${box.west},${box.north},${box.east});
);
out center 80;
''';
    final response = await _query(query);
    return response == null ? const [] : _readTolls(response.body);
  }

  Future<http.Response?> _query(String query) async {
    for (final server in _overpassServers) {
      try {
        final response = await _client.post(Uri.parse(server), body: {'data': query});
        if (response.statusCode >= 200 && response.statusCode < 300) return response;
      } catch (_) {}
    }
    return null;
  }

  List<FuelPump> _readPumps(String raw) {
    final body = jsonDecode(raw);
    if (body is! Map<String, dynamic>) return const [];
    final elements = body['elements'];
    if (elements is! List) return const [];
    final pumps = <FuelPump>[];
    for (final element in elements) {
      if (element is! Map<String, dynamic>) continue;
      final tags = element['tags'];
      final tagMap = tags is Map<String, dynamic> ? tags : const <String, dynamic>{};
      double? lat = (element['lat'] as num?)?.toDouble();
      double? lng = (element['lon'] as num?)?.toDouble();
      final center = element['center'];
      if ((lat == null || lng == null) && center is Map<String, dynamic>) {
        lat = (center['lat'] as num?)?.toDouble();
        lng = (center['lon'] as num?)?.toDouble();
      }
      if (lat == null || lng == null) continue;
      final brand = tagMap['brand'] ?? tagMap['name'] ?? tagMap['operator'];
      pumps.add(FuelPump(
        id: '${element['type']}-${element['id']}',
        name: brand is String && brand.isNotEmpty ? brand : 'Petrol pump',
        point: LatLng(lat, lng),
      ));
    }
    return pumps;
  }

  List<TollPlaza> _readTolls(String raw) {
    final body = jsonDecode(raw);
    if (body is! Map<String, dynamic>) return const [];
    final elements = body['elements'];
    if (elements is! List) return const [];
    final tolls = <TollPlaza>[];
    for (final element in elements) {
      if (element is! Map<String, dynamic>) continue;
      final tags = element['tags'];
      final tagMap = tags is Map<String, dynamic> ? tags : const <String, dynamic>{};
      var lat = element['lat'];
      var lng = element['lon'];
      final center = element['center'];
      if ((lat is! num || lng is! num) && center is Map<String, dynamic>) {
        lat = center['lat'];
        lng = center['lon'];
      }
      if (lat is! num || lng is! num) continue;
      final name = tagMap['name'] ?? tagMap['ref'] ?? tagMap['operator'];
      final type = element['type'];
      final id = element['id'];
      tolls.add(TollPlaza(
        id: '$type-$id',
        name: name is String && name.isNotEmpty ? name : 'Toll naka',
        point: LatLng(lat.toDouble(), lng.toDouble()),
      ));
    }
    return tolls;
  }

  ({double south, double north, double west, double east})? _boundingBox(List<LatLng> points, {required double pad}) {
    if (points.isEmpty) return null;
    var south = points.first.latitude;
    var north = south;
    var west = points.first.longitude;
    var east = west;
    for (final point in points) {
      south = south < point.latitude ? south : point.latitude;
      north = north > point.latitude ? north : point.latitude;
      west = west < point.longitude ? west : point.longitude;
      east = east > point.longitude ? east : point.longitude;
    }
    return (south: south - pad, north: north + pad, west: west - pad, east: east + pad);
  }
}
