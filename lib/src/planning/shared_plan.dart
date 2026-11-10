import 'dart:convert';
import 'dart:math';

import 'package:latlong2/latlong.dart';

import '../navigation/maps_types.dart';
import 'trip_plan.dart';

String bridgeMessage(Object error) {
  final text = error.toString();
  if (text.contains('REQUEST_DENIED') || text.contains('PERMISSION_DENIED')) {
    return 'Google blocked this key for Places or Routes.';
  }
  return text.replaceFirst('Exception: ', '').replaceFirst('Error: ', '');
}

class SharedPlan {
  const SharedPlan({
    required this.updatedAt,
    required this.days,
    required this.startName,
    required this.start,
    required this.finishName,
    required this.finish,
    required this.halts,
    this.startDate,
    this.startMinutes = const {},
    this.endMinutes = const {},
    this.route,
  });

  final int updatedAt;
  final int days;
  final DateTime? startDate;
  final String startName;
  final LatLng? start;
  final String finishName;
  final LatLng? finish;
  final List<RideHalt> halts;

  /// Minutes from midnight, keyed by day.
  final Map<int, int> startMinutes;
  final Map<int, int> endMinutes;
  final RouteChoice? route;
}

String encodeSharedPlan(SharedPlan plan) {
  return jsonEncode({
    'days': plan.days.clamp(1, 14),
    'startDate': _dateJson(plan.startDate),
    'startName': plan.startName,
    'start': _pointJson(plan.start),
    'finishName': plan.finishName,
    'finish': _pointJson(plan.finish),
    'halts': [
      for (final halt in plan.halts)
        {
          'id': halt.id,
          'name': halt.name,
          'lat': halt.point.latitude,
          'lng': halt.point.longitude,
          'day': halt.day,
          'kind': halt.kind.name,
        },
    ],
    'dayTimes': [
      for (final day in {...plan.startMinutes.keys, ...plan.endMinutes.keys})
        {
          'day': day,
          if (plan.startMinutes[day] != null) 'start': plan.startMinutes[day],
          if (plan.endMinutes[day] != null) 'end': plan.endMinutes[day],
        },
    ],
    'route': _routeJson(plan.route),
  });
}

SharedPlan? decodeSharedPlan(String raw) {
  try {
    final body = jsonDecode(raw);
    if (body is! Map) return null;
    final halts = <RideHalt>[];
    final rawHalts = body['halts'];
    if (rawHalts is List) {
      for (final item in rawHalts) {
        if (item is! Map) continue;
        final lat = _num(item['lat']);
        final lng = _num(item['lng']);
        if (lat == null || lng == null) continue;
        halts.add(
          RideHalt(
            id: item['id'] is String && (item['id'] as String).isNotEmpty
                ? item['id'] as String
                : 'halt-${halts.length}',
            name: item['name'] is String ? item['name'] as String : 'Stop',
            point: LatLng(lat, lng),
            day: (_num(item['day']) ?? 1).round().clamp(1, 14),
            kind: HaltKind.values.asNameMap()[item['kind']] ?? HaltKind.stop,
          ),
        );
      }
    }
    final startMinutes = <int, int>{};
    final endMinutes = <int, int>{};
    final rawTimes = body['dayTimes'];
    if (rawTimes is List) {
      for (final item in rawTimes) {
        if (item is! Map) continue;
        final day = (_num(item['day']) ?? 0).round();
        if (day < 1 || day > 14) continue;
        final start = _num(item['start']);
        final end = _num(item['end']);
        if (start != null) {
          startMinutes[day] = start.round().clamp(0, 24 * 60 - 1);
        }
        if (end != null) endMinutes[day] = end.round().clamp(0, 24 * 60 - 1);
      }
    }
    return SharedPlan(
      updatedAt: (_num(body['updatedAt']) ?? 0).round(),
      days: (_num(body['days']) ?? 1).round().clamp(1, 14),
      startDate: _date(body['startDate']),
      startName: body['startName'] is String ? body['startName'] as String : '',
      start: _point(body['start']),
      finishName: body['finishName'] is String
          ? body['finishName'] as String
          : '',
      finish: _point(body['finish']),
      halts: halts,
      startMinutes: startMinutes,
      endMinutes: endMinutes,
      route: _route(body['route']),
    );
  } catch (_) {
    return null;
  }
}

Map<String, double>? _pointJson(LatLng? point) {
  if (point == null) return null;
  return {'lat': point.latitude, 'lng': point.longitude};
}

LatLng? _point(Object? raw) {
  if (raw is! Map) return null;
  final lat = _num(raw['lat']);
  final lng = _num(raw['lng']);
  if (lat == null || lng == null) return null;
  return LatLng(lat, lng);
}

double? _num(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

const _planMonths = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String formatPlanDate(DateTime date) =>
    '${date.day} ${_planMonths[date.month - 1]}';

/// 12-hour clock from minutes past midnight.
String formatClock(int minute) {
  final wrapped = minute % (24 * 60);
  final hour24 = wrapped ~/ 60;
  final mins = wrapped % 60;
  final period = hour24 >= 12 ? 'PM' : 'AM';
  final hour = hour24 % 12 == 0 ? 12 : hour24 % 12;
  return '$hour:${mins.toString().padLeft(2, '0')} $period';
}

String formatPlanSpan(DateTime start, int days) {
  final from = DateTime(start.year, start.month, start.day);
  final to = from.add(Duration(days: max(1, days) - 1));
  if (days <= 1) return formatPlanDate(from);
  if (from.month == to.month && from.year == to.year) {
    return '${from.day}–${to.day} ${_planMonths[to.month - 1]}';
  }
  return '${formatPlanDate(from)} – ${formatPlanDate(to)}';
}

String? _dateJson(DateTime? date) {
  if (date == null) return null;
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

DateTime? _date(Object? raw) {
  if (raw is! String) return null;
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw);
  if (match == null) return null;
  return DateTime(
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  );
}

Map<String, Object?>? _routeJson(RouteChoice? route) {
  if (route == null || route.points.length < 2) return null;
  final points = _thinPoints(route.points);
  return {
    'summary': route.summary,
    'duration': route.duration,
    'distance': route.distance,
    'durationSeconds': route.durationSeconds,
    'distanceMeters': route.distanceMeters,
    'traffic': route.traffic,
    'points': [
      for (final point in points) [point.latitude, point.longitude],
    ],
  };
}

RouteChoice? _route(Object? raw) {
  if (raw is! Map) return null;
  final rawPoints = raw['points'];
  if (rawPoints is! List) return null;
  final points = <LatLng>[];
  for (final item in rawPoints) {
    if (item is! List || item.length < 2) continue;
    final lat = _num(item[0]);
    final lng = _num(item[1]);
    if (lat == null || lng == null) continue;
    points.add(LatLng(lat, lng));
  }
  if (points.length < 2) return null;
  return RouteChoice(
    summary: raw['summary'] is String
        ? raw['summary'] as String
        : 'Driving route',
    duration: raw['duration'] is String ? raw['duration'] as String : '',
    distance: raw['distance'] is String ? raw['distance'] as String : '',
    durationSeconds: (_num(raw['durationSeconds']) ?? 0).round(),
    distanceMeters: (_num(raw['distanceMeters']) ?? 0).round(),
    traffic: raw['traffic'] == true,
    points: points,
  );
}

List<LatLng> _thinPoints(List<LatLng> points, {int max = 500}) {
  if (points.length <= max) return points;
  final kept = <LatLng>[];
  final step = (points.length - 1) / (max - 1);
  for (var i = 0; i < max; i++) {
    kept.add(points[(i * step).round()]);
  }
  kept[kept.length - 1] = points.last;
  return kept;
}

class JoinedPhone {
  const JoinedPhone({required this.label, required this.you});

  final String label;
  final bool you;
}

String formatSeconds(int seconds) {
  final total = max(1, (seconds / 60).round());
  final hours = total ~/ 60;
  final mins = total % 60;
  if (hours == 0) return '$total min';
  if (mins == 0) return '$hours hr';
  return '$hours hr $mins min';
}

String formatMeters(int meters) {
  if (meters < 1000) return '$meters m';
  if (meters < 10000) return '${(meters / 1000).toStringAsFixed(1)} km';
  return '${(meters / 1000).round()} km';
}

String? normalizeRideCode(String raw) {
  final compact = raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  final match = RegExp(r'^(?:ZEN)?(\d{4})$').firstMatch(compact);
  if (match == null) return null;
  return 'ZEN-${match.group(1)}';
}

String riderLabelFor(String id) {
  final clean = id.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
  if (clean.isEmpty) return 'Rider';
  final tail = clean.length <= 4 ? clean : clean.substring(clean.length - 4);
  return 'Rider $tail';
}

String newId() {
  final rand = Random.secure();
  return List.generate(
    16,
    (_) => rand.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

String formatKm(double km) {
  final abs = km.abs();
  if (abs < 1) return '${max(1, (abs * 1000).round())} m';
  return '${abs.toStringAsFixed(1)} km';
}

String formatDuration(Duration duration) {
  final total = max(0, duration.inSeconds);
  final minutes = total ~/ 60;
  final seconds = total % 60;
  if (minutes <= 0) return '$seconds sec';
  return '$minutes min $seconds sec';
}
