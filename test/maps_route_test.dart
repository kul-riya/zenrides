import 'package:flutter_test/flutter_test.dart';
import 'package:zenrides/src/navigation/maps_bridge_io.dart';

void main() {
  test('a Google route polyline decodes to the encoded point', () {
    final points = decodeRoutePolyline(r'_p~iF~ps|U');
    expect(points.single.latitude, closeTo(38.5, 0.00001));
    expect(points.single.longitude, closeTo(-120.2, 0.00001));
  });
}
