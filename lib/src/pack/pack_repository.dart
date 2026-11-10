import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';

import '../firestore_time.dart';
import '../repository_exception.dart';

/// Riders live at `rides/{code}/riders/{riderId}` in Firestore. Live positions
/// also go to Realtime Database at the same path so the pack updates without
/// polling. There is no root `riders` collection.
class PackRepository {
  PackRepository({this._firestore, this._live});

  final FirebaseFirestore? _firestore;
  final FirebaseDatabase? _live;

  FirebaseFirestore get _db => _firestore ?? FirebaseFirestore.instance;
  FirebaseDatabase get _rtdb => _live ?? FirebaseDatabase.instance;

  /// Live pack for [code]. Emits the current children, then each change.
  Stream<List<RemoteRider>> watchRiders(String code) {
    return _rtdb.ref('rides/$code/riders').onValue.map(
      (event) => ridersFromSnapshot(event.snapshot.value),
    );
  }

  /// Riders stored on the ride. Used when the ride is opened from users/{uid}.
  Future<List<RemoteRider>> riders(String code) async {
    try {
      final snapshot = await _db.collection('rides').doc(code).collection('riders').get();
      final riders = <RemoteRider>[];
      for (final doc in snapshot.docs) {
        final rider = remoteRiderFrom(doc.id, doc.data());
        if (rider != null) riders.add(rider);
      }
      return riders;
    } catch (e) {
      throw RideApiException('Could not read the riding group: $e');
    }
  }

  /// Puts a rider on the ride and on the live map when they join a code.
  Future<void> addRider({
    required String code,
    required String id,
    required String name,
    required double lat,
    required double lng,
    required DateTime at,
    RiderStop? nextPlanStop,
    RiderStop? lastFuelStop,
  }) async {
    try {
      await Future.wait([
        _db.collection('rides').doc(code).collection('riders').doc(id).set({
          'name': name,
          'lat': lat,
          'lng': lng,
          'updatedAt': Timestamp.fromDate(at),
        }, SetOptions(merge: true)),
        pushLocation(
          code: code,
          id: id,
          name: name,
          lat: lat,
          lng: lng,
          at: at,
          nextPlanStop: nextPlanStop,
          lastFuelStop: lastFuelStop,
        ),
      ]);
    } catch (e) {
      throw RideApiException('Could not join this ride: $e');
    }
  }

  Future<void> pushLocation({
    required String code,
    required String id,
    required String name,
    required double lat,
    required double lng,
    required DateTime at,
    RiderStop? nextPlanStop,
    RiderStop? lastFuelStop,
  }) async {
    try {
      await _rtdb.ref('rides/$code/riders/$id').set(liveRiderJson(
        name: name,
        lat: lat,
        lng: lng,
        at: at,
        nextPlanStop: nextPlanStop,
        lastFuelStop: lastFuelStop,
      ));
    } catch (e) {
      throw RideApiException('Could not store this ride: $e');
    }
  }

  Future<void> deleteRider(String code, String id) async {
    try {
      await Future.wait([
        _rtdb.ref('rides/$code/riders/$id').remove(),
        _db.collection('rides').doc(code).collection('riders').doc(id).delete(),
      ]);
    } catch (e) {
      throw RideApiException('Could not remove that rider: $e');
    }
  }

  /// Drops every live dot for a deleted ride. The roster document goes with
  /// the Firestore ride record.
  Future<void> deleteLiveRide(String code) async {
    try {
      await _rtdb.ref('rides/$code/riders').remove();
    } catch (e) {
      throw RideApiException('Could not remove that ride: $e');
    }
  }
}

class RiderStop {
  const RiderStop({required this.name, required this.lat, required this.lng});

  final String name;
  final double lat;
  final double lng;

  Map<String, Object> toJson() => {'name': name, 'lat': lat, 'lng': lng};
}

class RemoteRider {
  const RemoteRider({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    required this.updatedAt,
    this.nextPlanStop,
    this.lastFuelStop,
  });

  final String id;
  final String name;
  final double lat;
  final double lng;
  final DateTime updatedAt;
  final RiderStop? nextPlanStop;
  final RiderStop? lastFuelStop;
}

Map<String, Object?> liveRiderJson({
  required String name,
  required double lat,
  required double lng,
  required DateTime at,
  RiderStop? nextPlanStop,
  RiderStop? lastFuelStop,
}) =>
    {
      'name': name,
      'lat': lat,
      'lng': lng,
      'updatedAt': at.millisecondsSinceEpoch,
      'nextPlanStop': ?nextPlanStop?.toJson(),
      'lastFuelStop': ?lastFuelStop?.toJson(),
    };

List<RemoteRider> ridersFromSnapshot(Object? value) {
  if (value is! Map) return const [];
  final riders = <RemoteRider>[];
  for (final entry in value.entries) {
    final rider = remoteRiderFrom('${entry.key}', entry.value);
    if (rider != null) riders.add(rider);
  }
  return riders;
}

RemoteRider? remoteRiderFrom(String id, Object? raw) {
  if (raw is! Map) return null;
  final lat = raw['lat'];
  final lng = raw['lng'];
  final at = firestoreTime(raw['updatedAt']);
  if (lat is! num || lng is! num || at == null) return null;
  final name = raw['name'];
  return RemoteRider(
    id: id,
    name: name is String && name.isNotEmpty ? name : 'Rider',
    lat: lat.toDouble(),
    lng: lng.toDouble(),
    updatedAt: at,
    nextPlanStop: riderStopFrom(raw['nextPlanStop']),
    lastFuelStop: riderStopFrom(raw['lastFuelStop']),
  );
}

RiderStop? riderStopFrom(Object? raw) {
  if (raw is! Map) return null;
  final name = raw['name'];
  final lat = raw['lat'];
  final lng = raw['lng'];
  if (name is! String || name.isEmpty || lat is! num || lng is! num) return null;
  return RiderStop(name: name, lat: lat.toDouble(), lng: lng.toDouble());
}
