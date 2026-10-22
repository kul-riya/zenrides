import 'package:cloud_firestore/cloud_firestore.dart';

import 'firestore_time.dart';
import 'repository_exception.dart';

/// `rides/{code}/riders`: every pack rider's live position, plus
/// `riders/{code}/members` for the roster. Written on every GPS fix while
/// live, read by RideController's sync loop to populate Pack and the map.
class PackRepository {
  PackRepository({this._firestore});

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

  /// Puts a rider on the roster and on the map in one call, when they join a code.
  Future<void> addRider({
    required String code,
    required String id,
    required String name,
    required double lat,
    required double lng,
    required DateTime at,
  }) async {
    final stamp = Timestamp.fromDate(at);
    try {
      await Future.wait([
        _db.collection('riders').doc(code).collection('members').doc(id).set({
          'name': name,
          'joinedAt': stamp,
        }, SetOptions(merge: true)),
        _db.collection('rides').doc(code).collection('riders').doc(id).set({
          'name': name,
          'lat': lat,
          'lng': lng,
          'updatedAt': stamp,
        }, SetOptions(merge: true)),
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
      await Future.wait([
        _db.collection('rides').doc(code).collection('riders').doc(id).delete(),
        _db.collection('riders').doc(code).collection('members').doc(id).delete(),
      ]);
    } catch (e) {
      throw RideApiException('Could not remove that rider: $e');
    }
  }
}

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
