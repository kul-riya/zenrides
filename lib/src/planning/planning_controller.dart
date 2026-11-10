import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../geo.dart';
import '../navigation/map_adapter.dart';
import '../navigation/navigation_repository.dart';
import '../repository_exception.dart';
import '../ride/ride_controller.dart';
import '../ride/ride_repository.dart';
import 'trip_plan.dart';

class PlanningController {
  PlanningController(
    this.ride, {
    required this.maps,
    required this.navRepo,
    required this.rideRepo,
  });

  final RideController ride;
  final MapAdapter maps;
  final NavigationRepository navRepo;
  final RideRepository rideRepo;

  int _planSearchGeneration = 0;
  bool picking = false;
  bool planning = false;

  /// True when this ride has a start or a halt, in the draft while editing.
  bool get hasPlaces => planning
      ? (draftStart != null || draftHalts.isNotEmpty)
      : (startPoint != null || halts.isNotEmpty);
  int tripDays = 1;
  int ridingDay = 1;
  int draftDays = 1;
  DateTime? tripStartDate;
  DateTime? draftStartDate;
  int planDay = 1;

  /// True when the planner is showing the whole ride, not one day's time.
  bool wholeRide = true;
  PlanScreen planScreen = PlanScreen.overview;
  int planFit = 0;

  /// Alternatives for the day being edited. Navigation keeps its own list.
  List<RouteChoice> routes = [];
  int selectedRoute = 0;
  int routeFit = 0;
  Timer? _searchDebounce;
  PlanSlot planSlot = PlanSlot.stop;
  String startName = '';
  String finishName = '';
  String draftStartName = '';
  String draftFinishName = '';
  String planNote = '';
  String shareNote = '';
  int _planUpdatedAt = 0;
  LatLng? startPoint;
  LatLng? finishPoint;
  LatLng? draftStart;
  LatLng? draftFinish;
  List<RideHalt> draftHalts = [];
  List<PlaceHit> planHits = [];
  bool planPumpsOn = false;
  bool planTollsOn = false;
  String planPumpNote = '';
  String planTollNote = '';
  DateTime? dayStarted;
  DaySummary? summary;
  List<RideHalt> halts = [];
  List<FuelPump> planPumps = [];
  List<TollPlaza> planTolls = [];

  /// Toll the rider tapped, waiting on Add as halt.
  TollPlaza? pickedToll;

  /// Minutes from midnight for each planned day. Draft is edited; trip is saved.
  final Map<int, int> draftStartMinute = {};
  final Map<int, int> draftEndMinute = {};
  final Map<int, int> tripStartMinute = {};
  final Map<int, int> tripEndMinute = {};
  int _planStopGeneration = 0;
  final Map<int, RouteChoice> _dayRoutes = {};
  final Map<int, int> _planRoadGeneration = {};
  RideHalt? get nextHalt {
    final todays = [
      for (final halt in halts)
        if (halt.day == ridingDay &&
            halt.kind != HaltKind.start &&
            halt.kind != HaltKind.finish)
          halt,
    ];
    if (todays.isEmpty) return null;
    RideHalt? best;
    var bestKm = double.infinity;
    for (final halt in todays) {
      final km = ride.kmTo(halt.point);
      if (km < bestKm) {
        best = halt;
        bestKm = km;
      }
    }
    return best;
  }

  bool get todayHasPlan => halts.any((halt) => halt.day == ridingDay);
  List<RideHalt> get visibleHalts {
    final stops = planning ? draftHalts : halts;
    final start = planning ? draftStart : startPoint;
    final finish = planning ? draftFinish : finishPoint;
    final from = planning ? draftStartName : startName;
    final to = planning ? draftFinishName : finishName;
    return [
      if (start != null)
        RideHalt(
          id: 'plan-start',
          name: from.isEmpty ? 'Start' : from,
          point: start,
          day: 0,
          kind: HaltKind.start,
        ),
      ...stops,
      if (finish != null)
        RideHalt(
          id: 'plan-finish',
          name: to.isEmpty ? 'Finish' : to,
          point: finish,
          day: 0,
          kind: HaltKind.finish,
        ),
    ];
  }

  /// Pins for the map. They show while planning and come off once the ride is saved.
  /// Day 2 starts where day 1 ended, so that place is one pin.
  List<RideHalt> get mapHalts {
    if (!planning) return const [];
    final plan = _planSnapshot(draft: true);
    final days = plan.days;
    final kept = <RideHalt>[];
    for (final halt in visibleHalts) {
      if (halt.kind == HaltKind.dayStart &&
          samePlace(halt.point, plan.inheritedOriginOf(halt.day))) {
        continue;
      }
      if (halt.kind == HaltKind.dayStart &&
          samePlace(halt.point, plan.endOf(halt.day)?.point)) {
        continue;
      }
      final existing = kept.indexWhere(
        (other) => samePlace(other.point, halt.point),
      );
      if (existing >= 0) {
        final other = kept[existing];
        kept[existing] = RideHalt(
          id: other.id,
          name: other.name.contains(halt.name)
              ? other.name
              : '${other.name} · ${halt.name}',
          point: other.point,
          day: other.day,
          kind: other.kind,
        );
        continue;
      }
      kept.add(halt);
    }
    return [
      for (final halt in kept)
        if (halt.kind == HaltKind.dayEnd &&
            halt.day < days &&
            samePlace(plan.originOf(halt.day + 1), halt.point))
          RideHalt(
            id: halt.id,
            name: '${halt.name} · Day ${halt.day + 1} start',
            point: halt.point,
            day: halt.day,
            kind: halt.kind,
          )
        else
          halt,
    ];
  }

  /// The road for the day shown on the map. Uses the driving line when it
  /// starts on this day and ends on one of this day's places.
  List<LatLng> get shownRoute {
    final plan = _planSnapshot(draft: planning);
    final day = planning ? planDay : ridingDay;
    final marks = plan.marksOf(day);
    if (marks.length < 2) return const [];
    final road = roadFor(day);
    if (road != null && plan.roadFitsDay(road.points, day)) return road.points;
    return marks;
  }

  /// The open day's selected alternative.
  RouteChoice? get activeRoad {
    if (routes.isEmpty) return null;
    return routes[selectedRoute.clamp(0, routes.length - 1)];
  }

  /// The driving line kept for [day]. The open day uses its selected alternative.
  RouteChoice? roadFor(int day) => _timingRoute(day);

  void keepRoad(int day, RouteChoice route) {
    if (route.points.length < 2) return;
    _dayRoutes[day] = route;
  }

  void selectRoute(int index) {
    if (index < 0 || index >= routes.length || index == selectedRoute) return;
    selectedRoute = index;
    routeFit += 1;
    final route = routes[index];
    keepRoad(planDay, route);
    planNote = '${route.duration} · ${route.distance}';
    if (planPumpsOn || planTollsOn) unawaited(_loadPlanStops());
    ride.changed();
  }

  /// True when the saved driving line belongs to the day selected on screen.
  bool get roadFitsDay {
    final road = roadFor(planning ? planDay : ridingDay);
    if (road == null) return false;
    return _planSnapshot(draft: planning)
        .roadFitsDay(road.points, planning ? planDay : ridingDay);
  }

  /// Every day's road while planning, so day 1 and day 2 stay on the map together.
  List<DayPath> get planPaths {
    if (!planning) return const [];
    final plan = _planSnapshot(draft: true);
    final paths = <DayPath>[];
    for (var day = 1; day <= draftDays; day++) {
      final marks = plan.marksOf(day);
      if (day == planDay && routes.isNotEmpty && roadFitsDay) {
        for (var i = 0; i < routes.length; i++) {
          final points = routes[i].points;
          if (points.length < 2) continue;
          paths.add(
            DayPath(
              day: day,
              points: points,
              selected: i == selectedRoute,
              alternative: i,
            ),
          );
        }
        continue;
      }
      final saved = _dayRoutes[day];
      if (saved != null && saved.points.length >= 2) {
        // Use the saved route if it's a reasonable fit for this day.
        // More lenient than roadFitsDay: just check that it starts somewhere on or near this day.
        if (plan.roadFitsDay(saved.points, day) ||
            (marks.isNotEmpty && ride.metersBetween(saved.points.first, marks.first) <= 5000)) {
          paths.add(DayPath(day: day, points: saved.points, selected: true));
          continue;
        }
      }
      if (marks.length >= 2) {
        paths.add(DayPath(day: day, points: marks, selected: true));
      }
    }
    return paths;
  }

  /// One driving line per day, including day 1 while another day is open.
  List<List<LatLng>> get planRoadLines {
    if (!planning) return const [];
    final lines = <List<LatLng>>[];
    final seen = <int>{};
    for (final path in planPaths) {
      if (!path.selected || path.points.length < 2 || !seen.add(path.day)) {
        continue;
      }
      lines.add(path.points);
    }
    return lines;
  }

  List<FuelPump> get shownPumps => planning ? planPumps : ride.nav.pumps;

  /// Everything about the open plan (saved or draft) as one immutable value,
  /// so the origin/destination/marks geometry lives in trip_plan.dart instead
  /// of being duplicated across private helpers here.
  TripPlan _planSnapshot({required bool draft}) {
    final start = draft ? draftStart : startPoint;
    final finish = draft ? draftFinish : finishPoint;
    final startMinutes = draft ? draftStartMinute : tripStartMinute;
    final endMinutes = draft ? draftEndMinute : tripEndMinute;
    return TripPlan(
      days: draft ? draftDays : tripDays,
      startDate: draft ? draftStartDate : tripStartDate,
      start: start == null
          ? null
          : (point: start, name: draft ? draftStartName : startName),
      finish: finish == null
          ? null
          : (point: finish, name: draft ? draftFinishName : finishName),
      halts: draft ? draftHalts : halts,
      clocks: {
        for (final day in {...startMinutes.keys, ...endMinutes.keys})
          day: DayClock(
            startMinute: startMinutes[day],
            endMinute: endMinutes[day],
          ),
      },
    );
  }

  List<RideHalt> dayStops(int day, {bool draft = false}) =>
      _planSnapshot(draft: draft).stopsOn(day);
  RideHalt? dayEnd(int day, {bool draft = false}) =>
      _planSnapshot(draft: draft).endOf(day);
  RideHalt? dayStart(int day, {bool draft = false}) =>
      _planSnapshot(draft: draft).customStartOf(day);

  /// Named once day 2 has an end: day 1's start, day 1's end, and day 2's end.
  String? get planChain {
    if (dayEnd(2, draft: true) == null) return null;
    final start = draftStartName.isEmpty ? 'Not set' : draftStartName;
    final end1 = dayEnd(1, draft: true)?.name ?? 'Not set';
    final end2 = dayEnd(2, draft: true)!.name;
    return 'Day 1 start · $start. Day 1 end · $end1. Day 2 end · $end2.';
  }

  RouteChoice? _timingRoute(int day) {
    if (planning && day == planDay && routes.isNotEmpty) {
      return routes[selectedRoute.clamp(
        0,
        routes.length - 1,
      )];
    }
    return _dayRoutes[day];
  }

  String dayTiming(int day) {
    final live = _timingRoute(day);
    if (live == null || (live.duration.isEmpty && live.distance.isEmpty)) {
      return '';
    }
    return '${live.duration} · ${live.distance}';
  }

  /// True when this day's time came from Google with traffic, not a fallback.
  bool dayTraffic(int day) => _timingRoute(day)?.traffic ?? false;

  /// Time and distance for every planned day added together.
  String get rideTiming {
    final totals = _rideTotals();
    if (totals == null) return '';
    return '${formatSeconds(totals.seconds)} · ${formatMeters(totals.meters)}';
  }

  /// The line under search: the open day, or the whole ride after a tap off the roads.
  String get planTimingLabel {
    if (wholeRide) {
      if (rideTiming.isEmpty) return '';
      return 'Ride · $rideTiming${rideTraffic ? ' · live traffic' : ''}';
    }
    final day = dayTiming(planDay);
    if (day.isEmpty) return '';
    return 'Day $planDay · $day${dayTraffic(planDay) ? ' · live traffic' : ''}';
  }

  /// Map chip. A stored day time yields to the whole-ride total once [wholeRide] is on.
  String get visiblePlanNote {
    if (!planning || planScreen == PlanScreen.map) return planNote;
    if (planNote.isNotEmpty && !_planNoteIsTiming(planNote)) return planNote;
    final label = planTimingLabel;
    return label.isEmpty ? planNote : label;
  }

  bool _planNoteIsTiming(String note) {
    if (rideTiming.isNotEmpty && note == rideTiming) return true;
    final days = planning ? draftDays : tripDays;
    for (var day = 1; day <= days; day++) {
      final timing = dayTiming(day);
      if (timing.isNotEmpty && note == timing) return true;
    }
    return false;
  }

  /// True when every counted day came back from Google with live traffic.
  bool get rideTraffic {
    final days = planning ? draftDays : tripDays;
    var any = false;
    for (var day = 1; day <= days; day++) {
      final live = _timingRoute(day);
      if (live == null ||
          (live.durationSeconds <= 0 && live.distanceMeters <= 0)) {
        continue;
      }
      any = true;
      if (!live.traffic) return false;
    }
    return any;
  }

  ({int seconds, int meters})? _rideTotals() {
    final days = planning ? draftDays : tripDays;
    var seconds = 0;
    var meters = 0;
    var any = false;
    for (var day = 1; day <= days; day++) {
      final live = _timingRoute(day);
      if (live == null ||
          (live.durationSeconds <= 0 && live.distanceMeters <= 0)) {
        continue;
      }
      any = true;
      seconds += live.durationSeconds;
      meters += live.distanceMeters;
    }
    if (!any) return null;
    return (seconds: seconds, meters: meters);
  }

  void togglePlanPumps() {
    planPumpsOn = !planPumpsOn;
    if (!planPumpsOn) {
      planPumps = [];
      planPumpNote = '';
      _planStopGeneration++;
      ride.changed();
      if (planTollsOn) unawaited(_loadPlanStops());
      return;
    }
    planPumpNote = 'Looking for petrol pumps on the ride…';
    ride.changed();
    unawaited(_loadPlanStops());
  }

  void togglePlanTolls() {
    planTollsOn = !planTollsOn;
    if (!planTollsOn) {
      planTolls = [];
      planTollNote = '';
      pickedToll = null;
      _planStopGeneration++;
      ride.changed();
      if (planPumpsOn) unawaited(_loadPlanStops());
      return;
    }
    planTollNote = 'Looking for toll nakas on the ride…';
    ride.changed();
    unawaited(_loadPlanStops());
  }

  void clearOverlays() {
    _planStopGeneration++;
    planPumpsOn = false;
    planTollsOn = false;
    planPumps = [];
    planTolls = [];
    pickedToll = null;
    planPumpNote = '';
    planTollNote = '';
  }

  /// Pumps and tolls for every colored day, so day 1 is included while day 2 is open.
  Future<void> _loadPlanStops() async {
    final generation = ++_planStopGeneration;
    final roads = planRoadLines;
    if (roads.isEmpty) {
      if (planPumpsOn) planPumpNote = 'Add a start and an end to see pumps.';
      if (planTollsOn) planTollNote = 'Add a start and an end to see tolls.';
      ride.changed();
      return;
    }
    if (!ride.network || !maps.available) {
      if (planPumpsOn) planPumpNote = 'Pumps show on the live map.';
      if (planTollsOn) planTollNote = 'Tolls show on the live map.';
      ride.changed();
      return;
    }
    try {
      final found = await Future.wait(
        roads.map((road) async {
          List<FuelPump> pumpsOnRoad = const [];
          List<TollPlaza> tollsOnRoad = const [];
          if (planPumpsOn) {
            try {
              pumpsOnRoad = await _pumpsOn(road);
            } catch (_) {
              pumpsOnRoad = const [];
            }
          }
          if (planTollsOn) {
            try {
              tollsOnRoad = await _tollsOn(road);
            } catch (_) {
              tollsOnRoad = const [];
            }
          }
          return (road: road, pumps: pumpsOnRoad, tolls: tollsOnRoad);
        }),
      );
      if (generation != _planStopGeneration) return;
      final pumps = <FuelPump>[];
      final tolls = <TollPlaza>[];
      final pumpIds = <String>{};
      final tollIds = <String>{};
      for (final row in found) {
        if (planPumpsOn) {
          for (final pump in row.pumps) {
            if (offPathMeters(row.road, pump.point) > 800) continue;
            if (pumpIds.add(pump.id)) pumps.add(pump);
          }
        }
        if (planTollsOn) {
          for (final toll in row.tolls) {
            if (offPathMeters(row.road, toll.point) > 800) continue;
            if (tollIds.add(toll.id)) tolls.add(toll);
          }
        }
      }
      if (planPumpsOn) {
        planPumps = pumps;
        planPumpNote = pumps.isEmpty
            ? 'No petrol pumps on this ride.'
            : '${pumps.length} petrol pump${pumps.length == 1 ? '' : 's'} on the ride.';
      }
      if (planTollsOn) {
        planTolls = tolls;
        planTollNote = tolls.isEmpty
            ? 'No toll nakas on this ride.'
            : '${tolls.length} toll naka${tolls.length == 1 ? '' : 's'} on the ride.';
      }
    } catch (error) {
      if (generation != _planStopGeneration) return;
      final message = error is RideApiException
          ? error.message
          : 'Lookup failed';
      if (planPumpsOn) planPumpNote = message;
      if (planTollsOn) planTollNote = message;
    }
    ride.changed();
  }

  Future<List<FuelPump>> _pumpsOn(List<LatLng> road) async {
    if (kIsWeb && maps.available) {
      try {
        final found = await maps.fuelAlong(road);
        if (found.isNotEmpty) return found;
      } catch (_) {}
    }
    return navRepo.fuelAlong(road);
  }

  Future<List<TollPlaza>> _tollsOn(List<LatLng> road) async {
    if (kIsWeb && maps.available) {
      try {
        final found = await maps.tollsAlong(road);
        if (found.isNotEmpty) return found;
      } catch (_) {}
    }
    return navRepo.tollsAlong(road);
  }

  void beginPlanning() {
    if (!ride.canPlan) return;
    draftDays = tripDays;
    draftStartDate = tripStartDate;
    draftStartName = startName;
    draftStart = startPoint;
    draftFinishName = finishName;
    draftFinish = finishPoint;
    draftHalts = [...halts];
    draftStartMinute
      ..clear()
      ..addAll(tripStartMinute);
    draftEndMinute
      ..clear()
      ..addAll(tripEndMinute);
    pickedToll = null;
    planDay = ridingDay.clamp(1, draftDays);
    planSlot = PlanSlot.stop;
    wholeRide = true;
    planScreen = PlanScreen.overview;
    planHits = [];
    planNote = '';
    picking = false;
    planning = true;
    ride.tab = RideTab.hud;
    if (_legOrigin(planDay) != null && _planDestination() != null) {
      _loadPlanRoads();
      return;
    }
    planFit++;
    ride.changed();
  }

  void cancelPlanning() {
    planning = false;
    planScreen = PlanScreen.overview;
    picking = false;
    planHits = [];
    planNote = '';
    routes = [];
    selectedRoute = 0;
    clearOverlays();
    ride.changed();
  }

  void setDraftDays(int days) {
    draftDays = days.clamp(1, 14);
    if (planDay > draftDays) planDay = draftDays;
    draftHalts = [
      for (final halt in draftHalts)
        if (halt.day <= draftDays) halt,
    ];
    draftStartMinute.removeWhere((day, _) => day > draftDays);
    draftEndMinute.removeWhere((day, _) => day > draftDays);
    planFit++;
    ride.changed();
  }

  /// The calendar day for a planned day, once a start date is chosen.
  DateTime? dateForDay(int day, {bool draft = false}) {
    final start = draft ? draftStartDate : tripStartDate;
    if (start == null) return null;
    final from = DateTime(start.year, start.month, start.day);
    return from.add(Duration(days: day - 1));
  }

  String get draftDateLabel =>
      draftStartDate == null ? '' : formatPlanSpan(draftStartDate!, draftDays);
  String get tripDateLabel =>
      tripStartDate == null ? '' : formatPlanSpan(tripStartDate!, tripDays);
  void setPlanDates(DateTime start, DateTime end) {
    final from = DateTime(start.year, start.month, start.day);
    final to = DateTime(end.year, end.month, end.day);
    var days = to.difference(from).inDays + 1;
    if (days < 1) days = 1;
    if (days > 14) days = 14;
    draftStartDate = from;
    setDraftDays(days);
  }

  void selectPlanDay(int day) {
    final next = day.clamp(1, draftDays);
    wholeRide = false;
    if (next == planDay) {
      ride.changed();
      return;
    }
    _keepShownRoad(planDay);
    planDay = next;
    routeFit++;
    _loadPlanRoads();
  }

  /// The road on screen stays with its day, so leaving the day does not turn it into a straight line.
  void _keepShownRoad(int day) {
    final route = activeRoad;
    if (route == null || route.points.length < 2) return;
    if (!_planSnapshot(draft: true).roadFitsDay(route.points, day)) return;
    keepRoad(day, route);
  }

  void showWholeRide() {
    if (!planning || wholeRide) return;
    wholeRide = true;
    ride.changed();
  }

  /// A tap on a colored road opens that day. A lighter road on the open day picks that route.
  void openPlanDay(int day) {
    selectPlanDay(day);
    planScreen = PlanScreen.day;
    picking = false;
    ride.changed();
  }

  void closePlanDay() {
    if (!planning) return;
    picking = false;
    planHits = [];
    planScreen = PlanScreen.overview;
    wholeRide = true;
    ride.changed();
  }

  void pickOnMap(PlanSlot slot) {
    if (!planning) return;
    selectPlanSlot(slot);
    picking = true;
    planNote = 'Tap the map, or search for the place.';
    planScreen = PlanScreen.map;
    ride.changed();
  }

  void closeMapPick() {
    if (planScreen != PlanScreen.map) return;
    picking = false;
    planHits = [];
    planNote = '';
    planScreen = PlanScreen.day;
    ride.changed();
  }

  void openPlannedDay(int day, {int? alternative}) {
    if (!planning) return;
    wholeRide = false;
    final next = day.clamp(1, draftDays);
    if (next != planDay) {
      selectPlanDay(next);
      return;
    }
    if (alternative != null) selectRoute(alternative);
  }

  void selectPlanSlot(PlanSlot slot) {
    planSlot = slot;
    ride.changed();
    if ((slot == PlanSlot.dayEnd ||
            slot == PlanSlot.dayStart ||
            slot == PlanSlot.finish ||
            slot == PlanSlot.stop) &&
        _legOrigin(planDay) != null &&
        _planDestination() != null) {
      _loadPlanRoads();
    }
  }

  void armPick(bool armed) {
    picking = armed;
    planNote = armed
        ? 'Tap the road. The map is pulled back so a long ride fits.'
        : '';
    ride.changed();
  }

  void dropHalt(LatLng point) {
    if (!picking || !planning) return;
    final name = switch (planSlot) {
      PlanSlot.start => 'Start',
      PlanSlot.dayStart => 'Day $planDay start',
      PlanSlot.finish => 'Finish',
      PlanSlot.dayEnd => 'Day $planDay end',
      PlanSlot.stop => 'Day $planDay stop',
    };
    _placeDraft(name, point);
  }

  void removeDraftHalt(String id) {
    if (id == 'plan-start') {
      draftStart = null;
      draftStartName = '';
    } else if (id == 'plan-finish') {
      draftFinish = null;
      draftFinishName = '';
    } else {
      draftHalts = [
        for (final halt in draftHalts)
          if (halt.id != id) halt,
      ];
    }
    planFit++;
    ride.changed();
  }

  void removeHalt(String id) => removeDraftHalt(id);
  void pickToll(TollPlaza toll) {
    if (!planning) return;
    pickedToll = toll;
    ride.changed();
  }

  void dismissToll() {
    if (pickedToll == null) return;
    pickedToll = null;
    ride.changed();
  }

  /// Drops the tapped toll onto the nearest day's road and into the plan list.
  void addTollAsHalt() {
    final toll = pickedToll;
    if (!planning || toll == null) return;
    final day = nearestDayForPoint(
      _planSnapshot(draft: true),
      _timingRoute,
      toll.point,
    );
    pickedToll = null;
    if (day == null) {
      planNote = 'That toll is not on a planned day.';
      ride.changed();
      return;
    }
    for (final stop in dayStops(day, draft: true)) {
      if (ride.metersBetween(stop.point, toll.point) < 200) {
        planNote = '${toll.name} is already a halt.';
        ride.changed();
        return;
      }
    }
    final halt = RideHalt(
      id: 'toll-${toll.id}',
      name: toll.name,
      point: toll.point,
      day: day,
      kind: HaltKind.stop,
    );
    final stops = [...dayStops(day, draft: true), halt];
    final line = _timingRoute(day)?.points;
    if (line != null && line.length >= 2) {
      stops.sort(
        (a, b) => traveledAlong(
          line,
          a.point,
        ).compareTo(traveledAlong(line, b.point)),
      );
    }
    draftHalts = [
      for (final existing in draftHalts)
        if (!(existing.day == day && existing.kind == HaltKind.stop)) existing,
      ...stops,
    ];
    planNote = '';
    if (_legOrigin(planDay) != null && _planDestination() != null) {
      _loadPlanRoads();
      return;
    }
    planFit++;
    ride.changed();
  }

  int? dayStartMinute(int day, {bool draft = true}) =>
      (draft ? draftStartMinute : tripStartMinute)[day];
  int? dayEndMinute(int day, {bool draft = true}) =>
      (draft ? draftEndMinute : tripEndMinute)[day];
  void setDayClock(int day, {int? startMinute, int? endMinute}) {
    final which = day.clamp(1, draftDays);
    if (startMinute != null) {
      draftStartMinute[which] = startMinute.clamp(0, 24 * 60 - 1);
    }
    if (endMinute != null) {
      draftEndMinute[which] = endMinute.clamp(0, 24 * 60 - 1);
    }
    ride.changed();
  }

  /// "Estimated time", plus a clock when the day's start and the road can place it.
  String haltEstimateLabel(int day, LatLng point, {bool draft = true}) =>
      haltEtaLabel(
        _planSnapshot(draft: draft),
        _timingRoute(day),
        day,
        point,
        formatClock,
      );
  void lookUpPlan(String query) {
    _searchDebounce?.cancel();
    final trimmed = query.trim();
    if (trimmed.length < 2) {
      planHits = [];
      planNote = '';
      ride.changed();
      return;
    }
    if (!ride.network || !maps.available) {
      planHits = [];
      planNote = 'Search needs the map. Select on map still drops the halt.';
      ride.changed();
      return;
    }
    final generation = ++_planSearchGeneration;
    _searchDebounce = Timer(
      const Duration(milliseconds: 280),
      () async {
        try {
          final found = await maps.search(trimmed, ride.you);
          if (generation != _planSearchGeneration) return;
          planHits = found;
          planNote = found.isEmpty ? 'No matching places.' : '';
        } catch (error) {
          if (generation != _planSearchGeneration) return;
          planHits = [];
          planNote = bridgeMessage(error);
        }
        ride.changed();
      },
    );
  }

  Future<void> choosePlanPlace(PlaceHit place) async {
    planHits = [];
    planNote = 'Placing ${place.name}…';
    ride.changed();
    final direct = _latLngFromId(place.placeId);
    if (direct != null) {
      _placeDraft(place.name, direct);
      return;
    }
    if (!maps.available) {
      planNote = 'That place has no map point. Tap the road instead.';
      ride.changed();
      return;
    }
    try {
      final point = await maps.placePoint(place.placeId);
      if (point == null) {
        planNote = 'That place has no map point. Tap the road instead.';
      } else {
        _placeDraft(place.name, point);
        return;
      }
    } catch (error) {
      planNote = bridgeMessage(error);
    }
    ride.changed();
  }

  void savePlan() {
    tripDays = draftDays;
    tripStartDate = draftStartDate;
    startName = draftStartName;
    startPoint = draftStart;
    finishName = draftFinishName;
    finishPoint = draftFinish;
    halts = [...draftHalts];
    tripStartMinute
      ..clear()
      ..addAll(draftStartMinute);
    tripEndMinute
      ..clear()
      ..addAll(draftEndMinute);
    pickedToll = null;
    ridingDay = 1;
    planning = false;
    planScreen = PlanScreen.overview;
    picking = false;
    planHits = [];
    planNote = '';
    routes = [];
    selectedRoute = 0;
    clearOverlays();
    summary = null;
    dayStarted = ride.now();
    ride.pack.traveledKm = 0;
    ride.tab = RideTab.hud;
    shareNote = '';
    ride.changed();
    if (!ride.network) return;
    if (!ride.onRide) {
      shareNote =
          'Generate or join a code so the other phones can see this plan.';
      ride.changed();
      return;
    }
    unawaited(pushCurrentPlan());
  }

  void endDay() {
    final todays = [
      for (final halt in halts)
        if (halt.day == ridingDay) halt,
    ];
    RideHalt? point;
    for (final halt in todays) {
      if (halt.kind == HaltKind.dayEnd) point = halt;
    }
    point ??= todays.isEmpty ? null : todays.last;
    final reached = point != null && ride.kmTo(point.point) <= 0.4;
    final started = dayStarted ?? ride.now();
    summary = DaySummary(
      km: ride.pack.traveledKm,
      elapsed: ride.now().difference(started),
      stayed: ride.pack.packRows
          .where((row) => row.online)
          .map((row) => row.name)
          .toList(),
      reached: reached,
    );
    if (ridingDay < tripDays) {
      ridingDay += 1;
      dayStarted = ride.now();
      ride.pack.traveledKm = 0;
      ride.nav.routeFit++;
    }
    ride.changed();
  }

  void clearSaved() {
    tripDays = 1;
    tripStartDate = null;
    draftStartDate = null;
    startName = '';
    startPoint = null;
    finishName = '';
    finishPoint = null;
    halts = [];
    tripStartMinute.clear();
    tripEndMinute.clear();
    draftStartMinute.clear();
    draftEndMinute.clear();
    routes = [];
    selectedRoute = 0;
    _dayRoutes.clear();
    _planRoadGeneration.clear();
    _planUpdatedAt = 0;
    shareNote = '';
  }

  Future<void> pushCurrentPlan() async {
    final savedCode = ride.code;
    final updatedAt = max(
      _planUpdatedAt + 1,
      ride.now().millisecondsSinceEpoch,
    );
    try {
      await rideRepo.pushPlan(
        code: savedCode,
        planJson: encodeSharedPlan(_currentPlan(updatedAt)),
        updatedAt: updatedAt,
      );
      if (ride.code != savedCode) return;
      _planUpdatedAt = updatedAt;
      shareNote = '';
    } catch (_) {
      if (ride.code != savedCode) return;
      shareNote = 'Could not save the plan to the ride.';
    }
    ride.changed();
  }

  SharedPlan _currentPlan(int updatedAt) {
    return SharedPlan(
      updatedAt: updatedAt,
      days: tripDays,
      startDate: tripStartDate,
      startName: startName,
      start: startPoint,
      finishName: finishName,
      finish: finishPoint,
      halts: [...halts],
      startMinutes: Map<int, int>.from(tripStartMinute),
      endMinutes: Map<int, int>.from(tripEndMinute),
      route: roadFor(1),
    );
  }

  void acceptSharedPlan(String? json, int? updatedAt) {
    if (planning ||
        json == null ||
        json.isEmpty ||
        updatedAt == null ||
        updatedAt <= _planUpdatedAt) {
      return;
    }
    final plan = decodeSharedPlan(json);
    if (plan == null) return;
    tripDays = plan.days;
    tripStartDate = plan.startDate;
    startName = plan.startName;
    startPoint = plan.start;
    finishName = plan.finishName;
    finishPoint = plan.finish;
    halts = plan.halts;
    tripStartMinute
      ..clear()
      ..addAll(plan.startMinutes);
    tripEndMinute
      ..clear()
      ..addAll(plan.endMinutes);
    ride.nav.dropIdleRoute();
    _planUpdatedAt = updatedAt;
    shareNote = '';
  }

  void _placeDraft(String name, LatLng point) {
    final id = 'halt-${ride.now().microsecondsSinceEpoch}';
    final after = _planSnapshot(draft: true)
        .place(planSlot, planDay, (point: point, name: name), id: id);
    draftStart = after.start?.point;
    draftStartName = after.start?.name ?? '';
    draftFinish = after.finish?.point;
    draftFinishName = after.finish?.name ?? '';
    draftHalts = after.halts;
    picking = false;
    planHits = [];
    planNote = '';
    if (planScreen == PlanScreen.map) planScreen = PlanScreen.day;
    if (_legOrigin(planDay) != null && _planDestination() != null) {
      _loadPlanRoads();
      return;
    }
    planFit++;
    ride.changed();
  }

  LatLng? _legOrigin(int day) => _planSnapshot(draft: true).originOf(day);
  ({LatLng point, String name})? _planDestination() {
    if (planSlot == PlanSlot.finish && draftFinish != null) {
      return (
        point: draftFinish!,
        name: draftFinishName.isEmpty ? 'Finish' : draftFinishName,
      );
    }
    final end = dayEnd(planDay, draft: true);
    if (planSlot == PlanSlot.dayEnd && end != null) {
      return (point: end.point, name: end.name);
    }
    final stops = dayStops(planDay, draft: true);
    if (planSlot == PlanSlot.stop && stops.isNotEmpty) {
      final stop = stops.last;
      return (point: stop.point, name: stop.name);
    }
    if (end != null) return (point: end.point, name: end.name);
    if (draftFinish != null) {
      return (
        point: draftFinish!,
        name: draftFinishName.isEmpty ? 'Finish' : draftFinishName,
      );
    }
    if (stops.isNotEmpty) {
      final stop = stops.last;
      return (point: stop.point, name: stop.name);
    }
    return null;
  }

  /// Where this day's road should finish. A day that ends where it started
  /// uses its last stop, so a loop is not drawn as the next day's road.
  ({LatLng point, String name})? _dayLegDestination([int? day]) =>
      _planSnapshot(draft: true).destinationOf(day ?? planDay);
  void _loadPlanRoads() {
    for (var day = 1; day <= draftDays; day++) {
      _loadDayRoad(day, alternatives: day == planDay);
    }
  }

  /// Fetches the driving road for [day]. The open day also keeps its alternatives.
  /// Other days are fetched on their own, so each path is a road without a tap.
  void _loadDayRoad(int day, {required bool alternatives}) {
    final origin = _legOrigin(day);
    final end = _dayLegDestination(day);
    if (origin == null || end == null) {
      if (!alternatives) return;
      planNote = draftStart == null
          ? 'Set a start, then choose the day end to see the roads.'
          : planNote;
      planFit++;
      ride.changed();
      return;
    }
    final saved = _dayRoutes[day];
    if (!alternatives &&
        saved != null &&
        saved.points.length >= 2 &&
        _planSnapshot(draft: true).roadFitsDay(saved.points, day)) {
      return;
    }
    if (!maps.available) {
      if (!alternatives) return;
      planNote = 'Roads show on the live map.';
      planFit++;
      ride.changed();
      return;
    }
    if (alternatives) {
      planNote = 'Finding roads…';
      routes = [];
      selectedRoute = 0;
      ride.changed();
    }
    final generation = (_planRoadGeneration[day] ?? 0) + 1;
    _planRoadGeneration[day] = generation;
    final placeId = '${end.point.latitude},${end.point.longitude}';
    final via = <LatLng>[
      for (final stop in dayStops(day, draft: true))
        if (ride.metersBetween(origin, stop.point) >= 400 &&
            ride.metersBetween(end.point, stop.point) >= 400)
          stop.point,
    ];
    unawaited(() async {
      try {
        final found = await maps.directions(
          origin: origin,
          placeId: placeId,
          via: via,
        );
        if (_planRoadGeneration[day] != generation) return;
        final roads = found.where((route) => route.points.length >= 2).toList();
        if (roads.isEmpty) {
          if (alternatives && planDay == day) {
            planNote = 'No road between these places.';
          }
        } else {
          _dayRoutes[day] = roads.first;
          if (alternatives && planDay == day) {
            routes = roads;
            selectedRoute = 0;
            routeFit += 1;
            planNote = '${roads.first.duration} · ${roads.first.distance}';
          }
          if (planPumpsOn || planTollsOn) unawaited(_loadPlanStops());
        }
      } catch (error) {
        if (_planRoadGeneration[day] != generation) return;
        if (alternatives && planDay == day) {
          routes = [];
          planNote = bridgeMessage(error);
        }
      }
      ride.changed();
    }());
  }

  LatLng? _latLngFromId(String id) {
    final match = RegExp(r'^(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)$')
        .firstMatch(id);
    if (match == null) return null;
    return LatLng(double.parse(match.group(1)!), double.parse(match.group(2)!));
  }

  void dispose() {
    _searchDebounce?.cancel();
  }
}
