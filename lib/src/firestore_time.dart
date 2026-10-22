import 'package:cloud_firestore/cloud_firestore.dart';

/// A rider's updatedAt/at field can be a Firestore Timestamp (current
/// writes) or the older millisecond number/string some rides still carry.
DateTime? firestoreTime(Object? value) {
  if (value is Timestamp) return value.toDate();
  if (value is num) return DateTime.fromMillisecondsSinceEpoch(value.round());
  if (value is String) {
    final parsed = int.tryParse(value);
    if (parsed != null) return DateTime.fromMillisecondsSinceEpoch(parsed);
  }
  return null;
}
