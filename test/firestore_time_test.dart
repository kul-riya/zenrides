import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrides/src/ride_api.dart';

void main() {
  test('a rider time can be a timestamp or the older millisecond number', () {
    final stamp = DateTime.utc(2026, 10, 17, 11, 16);
    expect(firestoreTime(Timestamp.fromDate(stamp))?.toUtc(), stamp);
    expect(firestoreTime(1792233360825), DateTime.fromMillisecondsSinceEpoch(1792233360825));
    expect(firestoreTime('1792233360825'), DateTime.fromMillisecondsSinceEpoch(1792233360825));
    expect(firestoreTime(null), isNull);
  });
}
