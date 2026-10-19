import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;

class RemoteRider {
  const RemoteRider({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final double lat;
  final double lng;
  final DateTime updatedAt;
}

class SosFix {
  const SosFix({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    required this.at,
  });

  final String id;
  final String name;
  final double lat;
  final double lng;
  final DateTime at;
}

class FuelPump {
  const FuelPump({required this.id, required this.name, required this.point});

  final String id;
  final String name;
  final LatLng point;
}

class TollPlaza {
  const TollPlaza({required this.id, required this.name, required this.point});

  final String id;
  final String name;
  final LatLng point;
}

class RideApi {
  RideApi({http.Client? client, FirebaseFirestore? firestore})
      : _client = client ?? http.Client(),
        _firestore = firestore;

  static const mapsKey = String.fromEnvironment('MAPS_API_KEY');

  final http.Client _client;
  final FirebaseFirestore? _firestore;

  FirebaseFirestore get _db => _firestore ?? FirebaseFirestore.instance;

  Future<List<RemoteRider>> riders(String code) async {
    try {
      final snapshot = await _db.collection('rides/$code/riders').get();
      final riders = <RemoteRider>[];
      for (final doc in snapshot.docs) {
        final data = doc.data();
        final lat = data['lat'];
        final lng = data['lng'];
        final updated = firestoreTime(data['updatedAt']);
        if (lat is! num || lng is! num || updated == null) continue;
        final name = data['name'];
        riders.add(RemoteRider(
          id: doc.id,
          name: name is String && name.isNotEmpty ? name : 'Rider',
          lat: lat.toDouble(),
          lng: lng.toDouble(),
          updatedAt: updated,
        ));
      }
      return riders;
    } catch (e) {
      throw RideApiException('Could not read the riding group: $e');
    }
  }

  Future<SosFix?> sos(String code) async {
    try {
      final doc = await _db.collection('rides').doc(code).get();
      if (!doc.exists) return null;
      return _sos(doc.data()?['sos']);
    } catch (e) {
      return null;
    }
  }

  Future<void> pushLocation({
    required String code,
    required String id,
    required String name,
    required double lat,
    required double lng,
    required DateTime at,
  }) async {
    try {
      await _db.collection('rides/$code/riders').doc(id).set({
        'name': name,
        'lat': lat,
        'lng': lng,
        'updatedAt': Timestamp.fromDate(at),
      }, SetOptions(merge: true));
    } catch (e) {
      throw RideApiException('Could not store this ride: $e');
    }
  }

  Future<void> deleteRider(String code, String id) async {
    try {
      await _db.collection('rides/$code/riders').doc(id).delete();
    } catch (e) {
      throw RideApiException('Could not remove that rider: $e');
    }
  }

  Future<void> deleteRideDocument(String code) async {
    try {
      final riders = await _db.collection('rides').doc(code).collection('riders').get();
      for (final doc in riders.docs) {
        await doc.reference.delete();
      }
      await _db.collection('rides').doc(code).delete();
    } catch (e) {
      throw RideApiException('Could not delete that ride: $e');
    }
  }

  Future<RideRecord> rideRecord(String code) async {
    try {
      final doc = await _db.collection('rides').doc(code).get();
      if (!doc.exists) return const RideRecord();
      final data = doc.data() ?? {};
      return RideRecord(
        sos: _sos(data['sos']),
        planJson: data['plan'] as String?,
        planUpdatedAt: (data['planUpdatedAt'] as num?)?.round(),
      );
    } catch (e) {
      throw RideApiException('Could not read the ride: $e');
    }
  }

  Future<void> pushPlan({
    required String code,
    required String planJson,
    required int updatedAt,
  }) async {
    try {
      await _db.collection('rides').doc(code).set({
        'plan': planJson,
        'planUpdatedAt': updatedAt,
      }, SetOptions(merge: true));
    } catch (e) {
      throw RideApiException('Could not save the plan: $e');
    }
  }

  Future<void> sendSos({
    required String code,
    required String id,
    required String name,
    required double lat,
    required double lng,
    required DateTime at,
  }) async {
    try {
      await _db.collection('rides').doc(code).set({
        'sos': {
          'id': id,
          'name': name,
          'lat': lat,
          'lng': lng,
          'at': Timestamp.fromDate(at),
        },
      }, SetOptions(merge: true));
    } catch (e) {
      throw RideApiException('Could not send SOS: $e');
    }
  }

  Future<List<FuelPump>> fuelNear(LatLng here) async {
    final query = '''
[out:json][timeout:20];
(
  node["amenity"="fuel"](around:15000,${here.latitude},${here.longitude});
  way["amenity"="fuel"](around:15000,${here.latitude},${here.longitude});
);
out center 80;
''';
    http.Response? response;
    Object? lastError;
    for (final server in const [
      'https://overpass-api.de/api/interpreter',
      'https://overpass.kumi.systems/api/interpreter',
    ]) {
      try {
        response = await _client.post(Uri.parse(server), body: {'data': query});
        if (response.statusCode >= 200 && response.statusCode < 300) break;
      } catch (error) {
        lastError = error;
      }
    }
    if (response == null || response.statusCode < 200 || response.statusCode >= 300) {
      throw RideApiException(lastError == null ? 'Fuel lookup failed' : 'Fuel lookup failed');
    }
    return _readPumps(response.body);
  }

  Future<List<FuelPump>> fuelAlong(List<LatLng> points) async {
    if (points.isEmpty) return const [];
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
    const pad = 0.01;
    final query = '''
[out:json][timeout:20];
(
  node["amenity"="fuel"](${south - pad},${west - pad},${north + pad},${east + pad});
  way["amenity"="fuel"](${south - pad},${west - pad},${north + pad},${east + pad});
);
out center 160;
''';
    http.Response? response;
    for (final server in const [
      'https://overpass-api.de/api/interpreter',
      'https://overpass.kumi.systems/api/interpreter',
    ]) {
      try {
        response = await _client.post(Uri.parse(server), body: {'data': query});
        if (response.statusCode >= 200 && response.statusCode < 300) break;
      } catch (_) {}
    }
    if (response == null || response.statusCode < 200 || response.statusCode >= 300) return const [];
    return _readPumps(response.body);
  }

  Future<List<TollPlaza>> tollsAlong(List<LatLng> points) async {
    if (points.isEmpty) return const [];
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
    const pad = 0.02;
    final query = '''
[out:json][timeout:20];
(
  node["barrier"="toll_booth"](${south - pad},${west - pad},${north + pad},${east + pad});
  way["barrier"="toll_booth"](${south - pad},${west - pad},${north + pad},${east + pad});
  node["highway"="toll_gantry"](${south - pad},${west - pad},${north + pad},${east + pad});
);
out center 80;
''';
    http.Response? response;
    for (final server in const [
      'https://overpass-api.de/api/interpreter',
      'https://overpass.kumi.systems/api/interpreter',
    ]) {
      try {
        response = await _client.post(Uri.parse(server), body: {'data': query});
        if (response.statusCode >= 200 && response.statusCode < 300) break;
      } catch (_) {}
    }
    if (response == null || response.statusCode < 200 || response.statusCode >= 300) return const [];
    return _readTolls(response.body);
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

  Future<RiderProfile> ensureUser({required String uid, required String name}) async {
    final ref = _db.collection('users').doc(uid);
    final snap = await ref.get();
    if (snap.exists) return RiderProfile.fromMap(snap.data() ?? {}, fallbackName: name);
    final profile = RiderProfile(name: name, rideCode: '', role: 'rider');
    await ref.set(profile.toMap());
    return profile;
  }

  Future<void> setMembership(String uid, {required String rideCode, required String role}) async {
    await _db.collection('users').doc(uid).set({'rideCode': rideCode, 'role': role}, SetOptions(merge: true));
  }

  Future<void> claimRide(String code, String uid) async {
    await _db.collection('rides').doc(code).set({'adminId': uid}, SetOptions(merge: true));
  }

  Future<String?> rideAdmin(String code) async {
    final doc = await _db.collection('rides').doc(code).get();
    final id = doc.data()?['adminId'];
    return id is String && id.isNotEmpty ? id : null;
  }
}

class RiderProfile {
  const RiderProfile({required this.name, required this.rideCode, required this.role});

  final String name;
  final String rideCode;
  final String role;

  bool get admin => role.trim().toLowerCase() == 'admin';

  Map<String, String> toMap() => {'name': name, 'rideCode': rideCode, 'role': role};

  factory RiderProfile.fromMap(Map<String, dynamic> data, {required String fallbackName}) {
    final stored = data['name'] ?? data['Name'];
    final name = stored is String && stored.trim().isNotEmpty ? stored.trim() : fallbackName;
    final role = data['role'];
    return RiderProfile(
      name: name,
      rideCode: _storedRideCode(data),
      role: role is String && role.trim().isNotEmpty ? role.trim() : 'rider',
    );
  }
}

String _storedRideCode(Map<String, dynamic> data) {
  final single = data['rideCode'];
  if (single is String && single.trim().isNotEmpty) return single.trim();
  final rides = data['rides'];
  if (rides is List) {
    for (final ride in rides) {
      if (ride is String && ride.trim().isNotEmpty) return ride.trim();
    }
  }
  return '';
}

DateTime? firestoreTime(Object? value) {
  if (value is Timestamp) return value.toDate();
  if (value is num) return DateTime.fromMillisecondsSinceEpoch(value.round());
  if (value is String) {
    final parsed = int.tryParse(value);
    if (parsed != null) return DateTime.fromMillisecondsSinceEpoch(parsed);
  }
  return null;
}

SosFix? _sos(Object? raw) {
  if (raw is! Map) return null;
  final lat = raw['lat'];
  final lng = raw['lng'];
  final at = firestoreTime(raw['at']);
  if (lat is! num || lng is! num || at == null) return null;
  final id = raw['id'];
  final name = raw['name'];
  return SosFix(
    id: id is String && id.isNotEmpty ? id : 'rider',
    name: name is String && name.isNotEmpty ? name : 'Rider',
    lat: lat.toDouble(),
    lng: lng.toDouble(),
    at: at,
  );
}

class RideRecord {
  const RideRecord({this.sos, this.planJson, this.planUpdatedAt});

  final SosFix? sos;
  final String? planJson;
  final int? planUpdatedAt;
}

class RideApiException implements Exception {
  RideApiException(this.message);
  final String message;
  @override
  String toString() => message;
}
