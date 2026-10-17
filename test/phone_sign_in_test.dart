import 'package:flutter_test/flutter_test.dart';
import 'package:zenrides/src/phone_sign_in.dart';

void main() {
  test('a 10 digit phone number is an Indian number', () {
    expect(phoneE164('98765 43210'), '+919876543210');
    expect(phoneE164('+1 202 555 0143'), '+12025550143');
    expect(phoneE164('123'), isNull);
  });
}
