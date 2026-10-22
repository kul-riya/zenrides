import 'package:cloud_firestore/cloud_firestore.dart';

import 'firestore_time.dart';
import 'repository_exception.dart';

/// `rides/{code}`: the ride document itself. Holds who leads it (adminId),
/// the live SOS and the shared multi-day plan. Both live on one document so
/// RideController's sync loop can read them together in one round trip.
class RideRepository {
  RideRepository({this._firestore});

  final FirebaseFirestore? _firestore;

  FirebaseFirestore get _db => _firestore ?? FirebaseFirestore.instance;

  Future<void> claimRide(String code, String uid) async {
    await _db.collection('rides').doc(code).set({'adminId': uid}, SetOptions(merge: true));
  }

  Future<void> deleteRideDocument(String code) async {
    try {
      final riders = await _db.collection('rides').doc(code).collection('riders').get();
      final members = await _db.collection('riders').doc(code).collection('members').get();
      for (final doc in [...riders.docs, ...members.docs]) {
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

class RideRecord {
  const RideRecord({this.sos, this.planJson, this.planUpdatedAt});

  final SosFix? sos;
  final String? planJson;
  final int? planUpdatedAt;
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
