import 'package:cloud_firestore/cloud_firestore.dart';

/// `users/{uid}`: a rider's saved name, their last ride code, and whether
/// they led it. Read by RideController.restoreIdentity and written when a
/// rider generates, joins, or leaves a ride.
class AuthRepository {
  AuthRepository({this._firestore});

  final FirebaseFirestore? _firestore;

  FirebaseFirestore get _db => _firestore ?? FirebaseFirestore.instance;

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

  /// Null when nobody has claimed [code] as its admin yet.
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
