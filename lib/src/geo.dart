import 'dart:math';

import 'package:latlong2/latlong.dart';

/// Pure geometry helpers shared by live navigation and planning. No Flutter,
/// no controller state. Extracted from ride_controller.dart so both features
/// use one tested implementation instead of duplicating polyline math.
const _distance = Distance();

/// True when two points are close enough to count as "the same place" for
/// plan-chaining purposes (a day start that lands on the previous day's end,
/// a toll that already has a halt nearby, and so on).
bool samePlace(LatLng? a, LatLng? b, {double meters = 400}) {
  if (a == null || b == null) return false;
  return _distance.as(LengthUnit.Meter, a, b) < meters;
}

double lengthKm(List<LatLng> points) {
  var total = 0.0;
  for (var i = 1; i < points.length; i++) {
    total += _distance.as(LengthUnit.Kilometer, points[i - 1], points[i]);
  }
  return total;
}

double segmentT(LatLng a, LatLng b, LatLng here) {
  final dx = b.longitude - a.longitude;
  final dy = b.latitude - a.latitude;
  final denom = dx * dx + dy * dy;
  if (denom == 0) return 0;
  return (((here.longitude - a.longitude) * dx + (here.latitude - a.latitude) * dy) / denom).clamp(0.0, 1.0);
}

double offPathMeters(List<LatLng> points, LatLng here) {
  if (points.length < 2) return double.infinity;
  var best = double.infinity;
  for (var i = 1; i < points.length; i++) {
    final t = segmentT(points[i - 1], points[i], here);
    final on = LatLng(
      points[i - 1].latitude + (points[i].latitude - points[i - 1].latitude) * t,
      points[i - 1].longitude + (points[i].longitude - points[i - 1].longitude) * t,
    );
    final gap = _distance.as(LengthUnit.Meter, here, on);
    if (gap < best) best = gap;
  }
  return best;
}

double remainingAlong(List<LatLng> points, LatLng here) {
  if (points.length < 2) return 0;
  var best = double.infinity;
  var traveled = 0.0;
  var cursor = 0.0;
  var total = 0.0;
  for (var i = 1; i < points.length; i++) {
    final span = _distance.as(LengthUnit.Kilometer, points[i - 1], points[i]);
    final t = segmentT(points[i - 1], points[i], here);
    final on = LatLng(
      points[i - 1].latitude + (points[i].latitude - points[i - 1].latitude) * t,
      points[i - 1].longitude + (points[i].longitude - points[i - 1].longitude) * t,
    );
    final gap = _distance.as(LengthUnit.Kilometer, here, on);
    if (gap < best) {
      best = gap;
      traveled = cursor + span * t;
    }
    cursor += span;
    total += span;
  }
  return max(0, total - traveled);
}

double traveledAlong(List<LatLng> points, LatLng here) {
  final total = lengthKm(points);
  return max(0, total - remainingAlong(points, here));
}

/// Named headingTo, not bearing, so it doesn't collide with RideController's
/// own `bearing` getter when called from inside its instance methods.
double headingTo(LatLng from, LatLng to) {
  final lat1 = from.latitude * pi / 180;
  final lat2 = to.latitude * pi / 180;
  final dLng = (to.longitude - from.longitude) * pi / 180;
  final y = sin(dLng) * cos(lat2);
  final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLng);
  return (atan2(y, x) * 180 / pi + 360) % 360;
}

LatLng along(List<LatLng> points, double progress) {
  final length = lengthKm(points);
  if (length == 0 || points.isEmpty) return const LatLng(18.37, 73.85);
  var target = length * (progress - progress.floor());
  for (var i = 1; i < points.length; i++) {
    final span = _distance.as(LengthUnit.Kilometer, points[i - 1], points[i]);
    if (target <= span || i == points.length - 1) {
      final t = span == 0 ? 0.0 : (target / span).clamp(0.0, 1.0);
      return LatLng(
        points[i - 1].latitude + (points[i].latitude - points[i - 1].latitude) * t,
        points[i - 1].longitude + (points[i].longitude - points[i - 1].longitude) * t,
      );
    }
    target -= span;
  }
  return points.last;
}
