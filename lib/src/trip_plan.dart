import 'package:latlong2/latlong.dart';

import 'geo.dart';
import 'maps_types.dart' show RouteChoice;

enum HaltKind { start, finish, stop, dayEnd, dayStart }

enum PlanSlot { start, dayStart, finish, dayEnd, stop }

class RideHalt {
  const RideHalt({
    required this.id,
    required this.name,
    required this.point,
    this.day = 1,
    this.kind = HaltKind.stop,
  });

  final String id;
  final String name;
  final LatLng point;
  final int day;
  final HaltKind kind;
}

/// Minutes from midnight for one planned day.
class DayClock {
  const DayClock({this.startMinute, this.endMinute});

  final int? startMinute;
  final int? endMinute;

  DayClock copyWith({int? startMinute, int? endMinute}) =>
      DayClock(startMinute: startMinute ?? this.startMinute, endMinute: endMinute ?? this.endMinute);
}

/// One immutable value. "Draft" and "saved" are two TripPlan instances —
/// this is the pure geometry a multi-day plan is built from: where each day
/// starts, where it ends, and the marks in between. Ported from the private
/// _dayOrigin/_inheritedDayOrigin/_dayLegDestination/_dayMarks helpers that
/// used to live on RideController, so this logic is unit-testable without
/// Flutter and without a live RideController.
class TripPlan {
  const TripPlan({
    this.days = 1,
    this.startDate,
    this.start,
    this.finish,
    this.halts = const [],
    this.clocks = const {},
  });

  static const maxDays = 14;
  static const empty = TripPlan();

  final int days;
  final DateTime? startDate;
  final ({LatLng point, String name})? start;
  final ({LatLng point, String name})? finish;
  final List<RideHalt> halts;
  final Map<int, DayClock> clocks;

  TripPlan copyWith({
    int? days,
    DateTime? startDate,
    List<RideHalt>? halts,
    Map<int, DayClock>? clocks,
  }) =>
      TripPlan(
        days: days ?? this.days,
        startDate: startDate ?? this.startDate,
        start: start,
        finish: finish,
        halts: halts ?? this.halts,
        clocks: clocks ?? this.clocks,
      );

  // Nullable fields need explicit setters, otherwise copyWith cannot clear them.
  TripPlan withStart(({LatLng point, String name})? value) =>
      TripPlan(days: days, startDate: startDate, start: value, finish: finish, halts: halts, clocks: clocks);

  TripPlan withFinish(({LatLng point, String name})? value) =>
      TripPlan(days: days, startDate: startDate, start: start, finish: value, halts: halts, clocks: clocks);

  TripPlan withDays(int n) {
    final clamped = n.clamp(1, maxDays);
    return copyWith(
      days: clamped,
      halts: [for (final h in halts) if (h.day <= clamped) h],
      clocks: {for (final e in clocks.entries) if (e.key <= clamped) e.key: e.value},
    );
  }

  TripPlan withClock(int day, {int? startMinute, int? endMinute}) {
    final current = clocks[day] ?? const DayClock();
    return copyWith(clocks: {...clocks, day: current.copyWith(startMinute: startMinute, endMinute: endMinute)});
  }

  // ---- queries (were private helpers on RideController) --------------------

  List<RideHalt> stopsOn(int day) => [for (final h in halts) if (h.day == day && h.kind == HaltKind.stop) h];

  RideHalt? endOf(int day) => _first(day, HaltKind.dayEnd);

  RideHalt? _customStartOf(int day) => _first(day, HaltKind.dayStart);

  RideHalt? _first(int day, HaltKind kind) {
    for (final halt in halts) {
      if (halt.day == day && halt.kind == kind) return halt;
    }
    return null;
  }

  LatLng? _inheritedOrigin(int day) => day <= 1 ? start?.point : (endOf(day - 1)?.point ?? start?.point);

  /// The default origin a day would have with no custom day-start halt.
  /// Exposed so callers can tell a custom halt apart from one that merely
  /// restates the default (used to de-duplicate map pins).
  LatLng? inheritedOriginOf(int day) => _inheritedOrigin(day);

  /// The day-start halt the lead placed by hand, if any (before falling
  /// back to the inherited origin).
  RideHalt? customStartOf(int day) => _customStartOf(day);

  /// Where a day begins. Later days begin where the previous day ended,
  /// unless the lead set a genuinely different start.
  LatLng? originOf(int day) {
    if (day <= 1) return start?.point;
    final inherited = _inheritedOrigin(day);
    final custom = _customStartOf(day);
    if (custom == null) return inherited;
    if (samePlace(custom.point, inherited) || samePlace(custom.point, endOf(day)?.point)) return inherited;
    return custom.point;
  }

  /// Where this day's road finishes. A loop day (one that ends back where
  /// it started) falls back to its last stop, so it is not drawn as the
  /// next day's road.
  ({LatLng point, String name})? destinationOf(int day) {
    final origin = originOf(day);
    bool far(LatLng p) => origin == null || !samePlace(origin, p);
    final end = endOf(day);
    if (end != null && far(end.point)) return (point: end.point, name: end.name);
    for (final stop in stopsOn(day).reversed) {
      if (far(stop.point)) return (point: stop.point, name: stop.name);
    }
    final f = finish;
    if (day >= days && f != null && far(f.point)) return f;
    return null;
  }

  /// Origin, stops, destination, with near-duplicates collapsed. Was _dayMarks.
  List<LatLng> marksOf(int day) {
    final marks = <LatLng>[];
    void add(LatLng? point) {
      if (point == null || (marks.isNotEmpty && samePlace(marks.last, point))) return;
      marks.add(point);
    }

    add(originOf(day));
    for (final stop in stopsOn(day)) {
      add(stop.point);
    }
    add(endOf(day)?.point ?? (day >= days ? finish?.point : null));
    return marks;
  }

  /// True when [road] belongs to this day: it starts near this day's origin
  /// and ends near one of this day's marks. Was _roadFitsMarks, parameterized
  /// on the day's own marks instead of taking them separately.
  bool roadFitsDay(List<LatLng> road, int day) {
    final marks = marksOf(day);
    if (road.length < 2 || marks.length < 2) return false;
    if (!samePlace(road.first, marks.first, meters: 800)) return false;
    final end = road.last;
    for (final mark in marks) {
      if (samePlace(end, mark, meters: 800)) return true;
    }
    return false;
  }

  // ---- edits -----------------------------------------------------------

  /// Single place that knows what each slot means. Was _placeDraft's switch,
  /// minus the UI note text (the caller decides what to say about the edit).
  TripPlan place(PlanSlot slot, int day, ({LatLng point, String name}) value, {required String id}) {
    RideHalt halt(HaltKind kind) => RideHalt(id: id, name: value.name, point: value.point, day: day, kind: kind);
    List<RideHalt> replacing(HaltKind kind) =>
        [for (final h in halts) if (!(h.day == day && h.kind == kind)) h, halt(kind)];

    switch (slot) {
      case PlanSlot.start:
        return withStart(value);
      case PlanSlot.finish:
        return withFinish(value);
      case PlanSlot.dayStart:
        if (day <= 1) return withStart(value);
        final dropsToDefault =
            samePlace(value.point, _inheritedOrigin(day)) || samePlace(value.point, endOf(day)?.point);
        return dropsToDefault
            ? copyWith(halts: [for (final h in halts) if (!(h.day == day && h.kind == HaltKind.dayStart)) h])
            : copyWith(halts: replacing(HaltKind.dayStart));
      case PlanSlot.dayEnd:
        return copyWith(halts: replacing(HaltKind.dayEnd));
      case PlanSlot.stop:
        return copyWith(halts: [...halts, halt(HaltKind.stop)]);
    }
  }

  TripPlan remove(String id) => copyWith(halts: [for (final h in halts) if (h.id != id) h]);
}

/// Day whose road (or, if none is known yet, straight-line marks) passes
/// closest to [point]. Null when nothing is within 800m. Was _nearestPlanDay;
/// [roadForDay] mirrors RideController's _timingRoute lookup.
int? nearestDayForPoint(TripPlan plan, RouteChoice? Function(int day) roadForDay, LatLng point) {
  int? bestDay;
  var best = double.infinity;
  for (var day = 1; day <= plan.days; day++) {
    final saved = roadForDay(day)?.points ?? const <LatLng>[];
    final marks = plan.marksOf(day);
    final line = saved.length >= 2 ? saved : marks;
    if (line.length < 2) continue;
    final gap = offPathMeters(line, point);
    if (gap < best) {
      best = gap;
      bestDay = day;
    }
  }
  return (bestDay == null || best > 800) ? null : bestDay;
}

/// Clock time for a point along [day]'s road, derived from that day's start
/// (and end, if set) plus how far along the road [point] sits. Null when
/// there isn't enough information yet (no start time, or no usable road).
/// Was _haltEstimateClock. Named to avoid colliding with RideController's
/// public haltEstimateLabel method, which this backs.
String? haltEtaClock(TripPlan plan, RouteChoice? road, int day, LatLng point, String Function(int minute) formatClock) {
  final start = plan.clocks[day]?.startMinute;
  if (start == null || road == null || road.points.length < 2) return null;
  final length = lengthKm(road.points);
  if (length <= 0) return null;
  final fraction = traveledAlong(road.points, point).clamp(0.0, length) / length;
  final end = plan.clocks[day]?.endMinute;
  final int span;
  if (end != null) {
    span = end >= start ? end - start : (24 * 60 - start) + end;
  } else if (road.durationSeconds > 0) {
    span = (road.durationSeconds / 60).round();
  } else {
    return null;
  }
  if (span <= 0) return formatClock(start);
  return formatClock((start + (fraction * span).round()) % (24 * 60));
}

/// "Estimated time", plus a clock when the day's start and the road can
/// place it. Backs RideController.haltEstimateLabel.
String haltEtaLabel(
  TripPlan plan,
  RouteChoice? road,
  int day,
  LatLng point,
  String Function(int minute) formatClock,
) {
  final clock = haltEtaClock(plan, road, day, point, formatClock);
  return clock == null ? 'Estimated time' : 'Estimated time · $clock';
}
