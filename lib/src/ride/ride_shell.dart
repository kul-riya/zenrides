import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:url_launcher/url_launcher.dart';

import 'ride_controller.dart';
import 'ride_map.dart';
import '../planning/trip_plan.dart';

class RideScope extends InheritedNotifier<RideController> {
  const RideScope({super.key, required RideController ride, required super.child}) : super(notifier: ride);

  static RideController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<RideScope>();
    assert(scope != null, 'RideScope missing');
    return scope!.notifier!;
  }
}

class RideShell extends StatelessWidget {
  const RideShell({super.key});

  @override
  Widget build(BuildContext context) {
    final ride = RideScope.of(context);
    return Scaffold(
      backgroundColor: const Color(0xFFD7DEE6),
      appBar: ride.signedIn
          ? AppBar(
              backgroundColor: Colors.white,
              elevation: 1,
              centerTitle: false,
              titleSpacing: 16,
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('ZenRides', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF64748B))),
                  Text(
                    ride.onRide ? ride.code : 'Not on a ride',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
                  ),
                ],
              ),
              actions: [
                Builder(
                  builder: (context) => IconButton(
                    tooltip: 'Profile',
                    onPressed: () => Scaffold.of(context).openEndDrawer(),
                    icon: const Icon(Icons.menu, color: Color(0xFF0F172A)),
                  ),
                ),
              ],
            )
          : null,
      endDrawer: const _ProfileDrawer(),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: ColoredBox(
            color: const Color(0xFFEEF1F5),
            child: SafeArea(
              child: ride.signedIn
                  ? Column(
                      children: [
                        Expanded(
                          child: switch (ride.tab) {
                            RideTab.hud => const HudPage(),
                            RideTab.pack => const PackPage(),
                            RideTab.toll => const TollPage(),
                            RideTab.tours => const ToursPage(),
                          },
                        ),
                        const RideNav(),
                      ],
                    )
                  : const Center(child: Text('You are signed out.')),
            ),
          ),
        ),
      ),
    );
  }
}


class _ProfileDrawer extends StatelessWidget {
  const _ProfileDrawer();

  @override
  Widget build(BuildContext context) {
    final ride = RideScope.of(context);
    return Drawer(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CircleAvatar(
                backgroundColor: Color(0xFF0F172A),
                child: Icon(Icons.person, color: Colors.white),
              ),
              const SizedBox(height: 12),
              Text(ride.riderName, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
              const SizedBox(height: 4),
              Text(
                ride.onRide ? '${ride.youRole} · ${ride.code}' : 'Not on a ride',
                style: const TextStyle(color: Color(0xFF64748B)),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    Navigator.pop(context);
                    ride.logOut();
                  },
                  child: const Text('Log out'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class HudPage extends StatefulWidget {
  const HudPage({super.key});

  @override
  State<HudPage> createState() => _HudPageState();
}

class _HudPageState extends State<HudPage> {
  bool _planCollapsed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!RideScope.of(context).plan.planning && _planCollapsed) _planCollapsed = false;
  }

  @override
  Widget build(BuildContext context) {
    final ride = RideScope.of(context);
    final dayPage = ride.plan.planning && ride.plan.planScreen == PlanScreen.day;
    final mapFull = ride.plan.planning && ride.plan.planScreen == PlanScreen.map;
    final planOpen = ride.plan.planning && !mapFull && !dayPage;
    final collapsed = planOpen && _planCollapsed;
    final edgeToEdge = mapFull || dayPage;
    return Stack(
      children: [
        Column(
          children: [
            if (!mapFull && !dayPage)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
              child: Column(
                children: [
                  if (planOpen)
                    _PlannerCard(
                      collapsed: collapsed,
                      onToggle: () => setState(() => _planCollapsed = !_planCollapsed),
                    ),
                  if (!ride.plan.planning && ride.radio.notice != null) ...[
                    const SizedBox(height: 8),
                    _NoticeCard(notice: ride.radio.notice!),
                  ],
                  if (!ride.plan.planning) ...[
                    const SizedBox(height: 8),
                    const _TodayCard(),
                  ],
                  if (!ride.plan.planning && ride.radio.visibleSos != null) ...[
                    const SizedBox(height: 8),
                    const _SosCard(),
                  ],
                  if (!ride.plan.planning && ride.nav.nearbyHazards.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    const _RoadHazardCard(),
                  ],
                ],
              ),
            ),
            if (!edgeToEdge) const SizedBox(height: 8),
            Expanded(
              key: const ValueKey('ride-map'),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: edgeToEdge ? 0 : 10),
                child: ClipRRect(
                  borderRadius: BorderRadius.all(Radius.circular(edgeToEdge ? 0 : 22)),
                  child: const _BoundMap(),
                ),
              ),
            ),
            if (!ride.plan.planning) const _BroadcastRow(),
          ],
        ),
        if (dayPage) Positioned.fill(child: PointerInterceptor(child: const _DayPlanPage())),
      ],
    );
  }
}

class _DayPlanPage extends StatelessWidget {
  const _DayPlanPage();

  @override
  Widget build(BuildContext context) {
    final ride = RideScope.of(context);
    final day = ride.plan.planDay;
    final color = dayColor(day);
    final timing = ride.plan.dayTiming(day);
    final stops = ride.plan.dayStops(day, draft: true);
    final end = ride.plan.dayEnd(day, draft: true);
    return ColoredBox(
      color: Colors.white,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          Row(
            children: [
              IconButton(
                onPressed: ride.plan.closePlanDay,
                icon: const Icon(Icons.arrow_back),
                tooltip: 'Back',
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Day $day',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22, color: color),
                    ),
                    if (ride.plan.dateForDay(day, draft: true) != null)
                      Text(
                        formatPlanDate(ride.plan.dateForDay(day, draft: true)!),
                        style: TextStyle(fontWeight: FontWeight.w700, color: color),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (timing.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 8),
              child: Text(
                '$timing${ride.plan.dayTraffic(day) ? ' · live traffic' : ''}',
                style: TextStyle(fontWeight: FontWeight.w800, color: color),
              ),
            ),
          _DayPlaceRow(
            title: day == 1 ? 'Start' : 'Day start',
            subtitle: _startLabel(ride, day),
            icon: Icons.trip_origin,
            color: color,
            onTap: () => ride.plan.pickOnMap(day == 1 ? PlanSlot.start : PlanSlot.dayStart),
            onClear: _startClear(ride, day),
            timeLabel: _clockLabel(ride.plan.dayStartMinute(day), empty: 'Set start time'),
            onTime: () => pickDayClock(context, ride, day, start: true),
          ),
          _DayPlaceRow(
            title: 'End',
            subtitle: end?.name ?? 'Choose on the map',
            icon: Icons.flag_outlined,
            color: color,
            onTap: () => ride.plan.pickOnMap(PlanSlot.dayEnd),
            onClear: end == null ? null : () => ride.plan.removeDraftHalt(end.id),
            timeLabel: _clockLabel(ride.plan.dayEndMinute(day), empty: 'Set end time'),
            onTime: () => pickDayClock(context, ride, day, start: false),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 18, 4, 8),
            child: Text('Halts', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
          ),
          if (stops.isEmpty)
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 8),
              child: Text('No halts yet', style: TextStyle(color: Color(0xFF64748B))),
            ),
          for (final stop in stops)
            _DayPlaceRow(
              title: stop.name,
              subtitle: ride.plan.haltEstimateLabel(day, stop.point),
              icon: Icons.place_outlined,
              color: color,
              onTap: () => ride.plan.pickOnMap(PlanSlot.stop),
              onClear: () => ride.plan.removeDraftHalt(stop.id),
            ),
          const SizedBox(height: 8),
          _PopTap(
            onTap: () => ride.plan.pickOnMap(PlanSlot.stop),
            radius: 28,
            highlight: const Color(0xFF1D4ED8),
            child: Material(
              color: Theme.of(context).colorScheme.primary,
              borderRadius: BorderRadius.circular(28),
              child: const SizedBox(
                height: 48,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add_location_alt, color: Colors.white, size: 18),
                    SizedBox(width: 8),
                    Text('Add a halt', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _startLabel(RideController ride, int day) {
    if (day <= 1) {
      if (ride.plan.draftStart == null) return 'Choose on the map';
      return ride.plan.draftStartName.isEmpty ? 'Start' : ride.plan.draftStartName;
    }
    final custom = ride.plan.dayStart(day, draft: true);
    if (custom != null) return custom.name;
    final inherited = ride.plan.dayEnd(day - 1, draft: true);
    if (inherited != null) return 'Starts at day ${day - 1} end · ${inherited.name}';
    return 'Choose on the map';
  }

  VoidCallback? _startClear(RideController ride, int day) {
    if (day <= 1) return ride.plan.draftStart == null ? null : () => ride.plan.removeDraftHalt('plan-start');
    final custom = ride.plan.dayStart(day, draft: true);
    if (custom == null) return null;
    return () => ride.plan.removeDraftHalt(custom.id);
  }

  String _clockLabel(int? minute, {required String empty}) {
    if (minute == null) return empty;
    return formatClock(minute);
  }
}

class _DayPlaceRow extends StatelessWidget {
  const _DayPlaceRow({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.onTap,
    this.onClear,
    this.timeLabel,
    this.onTime,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final VoidCallback? onClear;
  final String? timeLabel;
  final VoidCallback? onTime;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: _PopTap(
        onTap: onTap,
        highlight: color,
        child: Material(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 16, 8, 16),
            child: Row(
              children: [
                Icon(icon, color: color),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                      const SizedBox(height: 2),
                      Text(subtitle, style: const TextStyle(color: Color(0xFF64748B), fontSize: 13)),
                    ],
                  ),
                ),
                if (timeLabel != null && onTime != null)
                  TextButton(
                    onPressed: onTime,
                    style: TextButton.styleFrom(
                      foregroundColor: color,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 36),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      timeLabel!,
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
                    ),
                  ),
                if (onClear != null)
                  IconButton(onPressed: onClear, icon: const Icon(Icons.close), tooltip: 'Remove'),
                const Icon(Icons.chevron_right, color: Color(0xFF94A3B8)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Lifts a control a few pixels and rings it in color while a finger is down.
class _PopTap extends StatefulWidget {
  const _PopTap({
    required this.onTap,
    required this.child,
    required this.highlight,
    this.radius = 16,
  });

  final VoidCallback onTap;
  final Widget child;
  final Color highlight;
  final double radius;

  @override
  State<_PopTap> createState() => _PopTapState();
}

class _PopTapState extends State<_PopTap> {
  bool _down = false;

  void _set(bool down) {
    if (_down == down || !mounted) return;
    setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: _down ? 1 : 0),
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutBack,
        builder: (context, t, child) {
          final lift = t.clamp(0.0, 1.2);
          return Transform.translate(
            offset: Offset(0, -6 * lift),
            child: Transform.scale(
              scale: 1 + 0.035 * lift,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(widget.radius),
                  boxShadow: [
                    BoxShadow(
                      color: widget.highlight.withValues(alpha: 0.28 * lift),
                      blurRadius: 16 * lift,
                      offset: Offset(0, 8 * lift),
                    ),
                  ],
                ),
                child: Stack(
                  children: [
                    child!,
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(widget.radius),
                            border: Border.all(
                              color: widget.highlight.withValues(alpha: 0.9 * lift),
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
        child: widget.child,
      ),
    );
  }
}

class _BoundMap extends StatelessWidget {
  const _BoundMap();

  @override
  Widget build(BuildContext context) {
    return RideMap(ride: RideScope.of(context));
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.notice});

  final RideNotice notice;

  @override
  Widget build(BuildContext context) {
    final ride = RideScope.of(context);
    final sos = notice.kind == NoticeKind.sos;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: sos ? const Color(0xFFC81E1E) : const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(sos ? Icons.campaign : Icons.campaign_outlined, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(notice.kicker, style: const TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.w800)),
                Text(notice.body, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          TextButton(
            onPressed: ride.radio.dismissNotice,
            child: const Text('ACK', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }
}

class _TodayCard extends StatelessWidget {
  const _TodayCard();

  @override
  Widget build(BuildContext context) {
    final ride = RideScope.of(context);
    final next = ride.plan.nextHalt;
    final summary = ride.plan.summary;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: Text("Today's plan", style: TextStyle(fontWeight: FontWeight.w800))),
              if (ride.plan.todayHasPlan)
                TextButton(onPressed: ride.plan.endDay, child: const Text('End the day')),
            ],
          ),
          if (next == null)
            Text(
              ride.canPlan
                  ? (ride.plan.tripDays > 1 ? 'Day ${ride.plan.ridingDay} has no halt yet.' : 'No halts saved yet.')
                  : 'No halts saved yet. The ride lead plans this one.',
              style: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
            )
          else
            Text('Next halt · ${next.name} · ${formatKm(ride.kmTo(next.point))} left', style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            ride.radio.chaiNames.isEmpty ? 'Nobody has stopped for chai.' : 'Chai: ${ride.radio.chaiNames.join(', ')}',
            style: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
          ),
          if (summary != null) ...[
            const SizedBox(height: 8),
            Text(
              '${formatKm(summary.km)} · ${formatDuration(summary.elapsed)} · ${summary.stayed.join(', ')} · ${summary.reached ? 'Day point reached' : 'Day point not reached'}',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }
}

class _SosCard extends StatelessWidget {
  const _SosCard();

  @override
  Widget build(BuildContext context) {
    final ride = RideScope.of(context);
    final alert = ride.radio.visibleSos!;
    final spot = '${alert.lat.toStringAsFixed(5)}, ${alert.lng.toStringAsFixed(5)}';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF5F5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFC81E1E), width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('SOS · ${alert.name}', style: const TextStyle(color: Color(0xFFC81E1E), fontWeight: FontWeight.w900)),
          const SizedBox(height: 4),
          Text('Last spot $spot'),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFFC81E1E)),
                onPressed: () => launchUrl(Uri.parse('tel:')),
                child: const Text('Call'),
              ),
              const SizedBox(width: 8),
              TextButton(onPressed: ride.radio.dismissSos, child: const Text('Dismiss')),
            ],
          ),
        ],
      ),
    );
  }
}

class _RoadHazardCard extends StatelessWidget {
  const _RoadHazardCard();

  @override
  Widget build(BuildContext context) {
    final ride = RideScope.of(context);
    final nearby = ride.nav.nearbyHazards;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF5F5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFC81E1E)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final hazard in nearby)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                hazard.point == null
                    ? hazard.title
                    : '${hazard.title} · ${formatKm(ride.kmTo(hazard.point!))}',
                style: const TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF9A3412)),
              ),
            ),
        ],
      ),
    );
  }
}

class _PlannerCard extends StatelessWidget {
  const _PlannerCard({required this.collapsed, required this.onToggle});

  final bool collapsed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final ride = RideScope.of(context);
    return PointerInterceptor(
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 4,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('Days', style: TextStyle(fontWeight: FontWeight.w800)),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: ride.plan.draftDays > 1 ? () => ride.plan.setDraftDays(ride.plan.draftDays - 1) : null,
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  Text('${ride.plan.draftDays}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: ride.plan.draftDays < 14 ? () => ride.plan.setDraftDays(ride.plan.draftDays + 1) : null,
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                  TextButton(
                    onPressed: () => confirmDeleteRide(context, ride),
                    child: const Text('Delete ride'),
                  ),
                  TextButton(onPressed: ride.plan.cancelPlanning, child: const Text('Cancel')),
                  FilledButton(onPressed: ride.plan.savePlan, child: const Text('Save')),
                ],
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => pickPlanDates(context, ride),
                  icon: const Icon(Icons.calendar_month),
                  label: Text(ride.plan.draftDateLabel.isEmpty ? 'Choose dates' : ride.plan.draftDateLabel),
                ),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var day = 1; day <= ride.plan.draftDays; day++)
                    ride.plan.planDay == day
                        ? FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: dayColor(day)),
                            onPressed: () => ride.plan.openPlanDay(day),
                            child: _dayButtonLabel(ride, day),
                          )
                        : OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: dayColor(day),
                              side: BorderSide(color: dayColor(day)),
                            ),
                            onPressed: () => ride.plan.openPlanDay(day),
                            child: _dayButtonLabel(ride, day),
                          ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _planOverlayButton(
                      label: 'Fuel pumps',
                      icon: Icons.local_gas_station,
                      color: const Color(0xFFE11D2E),
                      on: ride.plan.planPumpsOn,
                      onPressed: ride.plan.togglePlanPumps,
                    ),
                    _planOverlayButton(
                      label: 'Toll nakas',
                      icon: Icons.toll,
                      color: const Color(0xFFB45309),
                      on: ride.plan.planTollsOn,
                      onPressed: ride.plan.togglePlanTolls,
                    ),
                  ],
                ),
              ),
              if (ride.plan.planPumpNote.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(ride.plan.planPumpNote, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                ),
              if (ride.plan.planTollNote.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(ride.plan.planTollNote, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                ),
              Center(
                child: IconButton(
                  tooltip: collapsed ? 'Show plan' : 'Hide plan',
                  visualDensity: VisualDensity.compact,
                  onPressed: onToggle,
                  icon: Icon(collapsed ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up),
                ),
              ),
              AnimatedSize(
                alignment: Alignment.topCenter,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                child: collapsed
                    ? const SizedBox(width: double.infinity)
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (ride.plan.planTimingLabel.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF8FAFC),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: const Color(0xFFE2E8F0)),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                  child: Text(
                                    ride.plan.planTimingLabel,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      color: ride.plan.wholeRide ? const Color(0xFF0F172A) : dayColor(ride.plan.planDay),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          _PlanPlaceList(ride: ride),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlanPlace {
  const _PlanPlace({required this.day, required this.role, required this.name, this.detail});

  final int day;
  final String role;
  final String name;
  final String? detail;
}

List<_PlanPlace> _planPlaces(RideController ride) {
  final places = <_PlanPlace>[];
  for (var day = 1; day <= ride.plan.draftDays; day++) {
    if (day <= 1) {
      if (ride.plan.draftStart != null) {
        places.add(_PlanPlace(
          day: day,
          role: 'Start',
          name: ride.plan.draftStartName.isEmpty ? 'Start' : ride.plan.draftStartName,
        ));
      }
    } else {
      final custom = ride.plan.dayStart(day, draft: true);
      final inherited = ride.plan.dayEnd(day - 1, draft: true);
      if (custom != null) {
        places.add(_PlanPlace(day: day, role: 'Start', name: custom.name));
      } else if (inherited != null) {
        places.add(_PlanPlace(
          day: day,
          role: 'Start',
          name: inherited.name,
          detail: 'Same as day ${day - 1} end',
        ));
      }
    }
    for (final halt in ride.plan.dayStops(day, draft: true)) {
      places.add(_PlanPlace(
        day: day,
        role: 'Halt',
        name: halt.name,
        detail: ride.plan.haltEstimateLabel(day, halt.point),
      ));
    }
    final end = ride.plan.dayEnd(day, draft: true);
    if (end != null) places.add(_PlanPlace(day: day, role: 'End', name: end.name));
  }
  return places;
}

class _PlanPlaceList extends StatelessWidget {
  const _PlanPlaceList({required this.ride});

  final RideController ride;

  @override
  Widget build(BuildContext context) {
    final places = _planPlaces(ride);
    if (places.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 240),
        child: ListView.separated(
          shrinkWrap: true,
          primary: false,
          itemCount: places.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final place = places[index];
            final color = dayColor(place.day);
            return Material(
              color: const Color(0xFFF8FAFC),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: color.withValues(alpha: 0.45)),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => ride.plan.openPlanDay(place.day),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      Container(
                        width: 4,
                        height: 36,
                        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Day ${place.day} · ${place.role}',
                              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: color),
                            ),
                            Text(place.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                            if (place.detail != null)
                              Text(place.detail!, style: const TextStyle(color: Color(0xFF64748B), fontSize: 12)),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right, color: Color(0xFF94A3B8)),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

Widget _planOverlayButton({
  required String label,
  required IconData icon,
  required Color color,
  required bool on,
  required VoidCallback onPressed,
}) {
  return OutlinedButton.icon(
    onPressed: onPressed,
    style: OutlinedButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
      backgroundColor: on ? color.withValues(alpha: 0.12) : Colors.white,
      foregroundColor: const Color(0xFF0F172A),
      side: BorderSide(color: on ? color : const Color(0xFFD7DEE7)),
    ),
    icon: Icon(icon, size: 14, color: color),
    label: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
  );
}

Widget _dayButtonLabel(RideController ride, int day) {
  final date = ride.plan.dateForDay(day, draft: true);
  return Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('Day $day'),
      if (date != null) Text(formatPlanDate(date), style: const TextStyle(fontSize: 11)),
    ],
  );
}

Future<void> pickPlanDates(BuildContext context, RideController ride) async {
  final today = DateTime.now();
  final todayDate = DateTime(today.year, today.month, today.day);
  final current = ride.plan.draftStartDate ?? todayDate;
  final start = DateTime(current.year, current.month, current.day);
  final end = start.add(Duration(days: ride.plan.draftDays - 1));
  final first = start.isBefore(todayDate) ? start : todayDate;
  final lastCandidate = todayDate.add(const Duration(days: 366));
  final last = lastCandidate.isBefore(end) ? end : lastCandidate;
  final picked = await showDateRangePicker(
    context: context,
    firstDate: first,
    lastDate: last,
    initialDateRange: DateTimeRange(start: start, end: end),
    helpText: 'When are you riding?',
    saveText: 'Use these dates',
    builder: (context, child) => PointerInterceptor(child: child ?? const SizedBox.shrink()),
  );
  if (picked == null) return;
  ride.plan.setPlanDates(picked.start, picked.end);
}

Future<void> pickDayClock(BuildContext context, RideController ride, int day, {required bool start}) async {
  final current = start ? ride.plan.dayStartMinute(day) : ride.plan.dayEndMinute(day);
  final initial = current == null
      ? const TimeOfDay(hour: 6, minute: 0)
      : TimeOfDay(hour: current ~/ 60, minute: current % 60);
  final picked = await showTimePicker(
    context: context,
    initialTime: initial,
    helpText: start ? 'When does day $day start?' : 'When does day $day end?',
    builder: (context, child) => PointerInterceptor(child: child ?? const SizedBox.shrink()),
  );
  if (picked == null) return;
  final minute = picked.hour * 60 + picked.minute;
  if (start) {
    ride.plan.setDayClock(day, startMinute: minute);
  } else {
    ride.plan.setDayClock(day, endMinute: minute);
  }
}

Future<void> confirmDeleteRide(BuildContext context, RideController ride) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => PointerInterceptor(
      child: AlertDialog(
        title: const Text('Delete this ride?'),
        content: const Text('The plan, the roads, and the code are removed for the pack.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    ),
  );
  if (ok == true) ride.deleteRide();
}

class _BroadcastRow extends StatefulWidget {
  const _BroadcastRow();

  @override
  State<_BroadcastRow> createState() => _BroadcastRowState();
}

class _BroadcastRowState extends State<_BroadcastRow> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 86,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          dragDevices: const {
            PointerDeviceKind.touch,
            PointerDeviceKind.mouse,
            PointerDeviceKind.trackpad,
            PointerDeviceKind.stylus,
          },
        ),
        child: Listener(
          onPointerSignal: (event) {
            if (event is! PointerScrollEvent || !_scroll.hasClients) return;
            final delta = event.scrollDelta.dx != 0 ? event.scrollDelta.dx : event.scrollDelta.dy;
            final next = (_scroll.offset + delta).clamp(0.0, _scroll.position.maxScrollExtent);
            _scroll.jumpTo(next);
          },
          child: Scrollbar(
            controller: _scroll,
            thumbVisibility: true,
            scrollbarOrientation: ScrollbarOrientation.bottom,
            child: ListView(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 16),
              children: [
                _broadcast(context, 'Fuel', Icons.local_gas_station, NoticeKind.fuel, const Color(0xFFE11D2E)),
                _broadcast(context, 'Chai / Break', Icons.coffee, NoticeKind.chai, const Color(0xFF7C4A2D)),
                _broadcast(context, 'Hazard', Icons.warning_amber, NoticeKind.hazard, const Color(0xFFE6A100)),
                _broadcast(context, 'Slow Pace', Icons.pets, NoticeKind.slow, const Color(0xFF1F9D5E)),
                _broadcast(context, 'Regroup', Icons.radio_button_checked, NoticeKind.regroup, const Color(0xFFE11D2E)),
                _broadcast(context, 'SOS', Icons.campaign, NoticeKind.sos, const Color(0xFFE11D48)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _broadcast(BuildContext context, String label, IconData icon, NoticeKind kind, Color color) {
    final ride = RideScope.of(context);
    final active = ride.radio.notice?.kind == kind || (kind == NoticeKind.fuel && ride.nav.fuelOn);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: OutlinedButton.icon(
        onPressed: ride.ended ? null : () => ride.radio.send(kind),
        style: OutlinedButton.styleFrom(
          backgroundColor: active ? const Color(0xFFF8FAFC) : Colors.white,
          foregroundColor: const Color(0xFF0F172A),
          side: BorderSide(color: active ? color : const Color(0xFFD7DEE7)),
        ),
        icon: Icon(icon, color: color, size: 16),
        label: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
    );
  }
}

class PackPage extends StatelessWidget {
  const PackPage({super.key});

  @override
  Widget build(BuildContext context) {
    final ride = RideScope.of(context);
    if (!ride.onRide) {
      return ListView(
        padding: const EdgeInsets.all(10),
        children: const [_RideCodeCard()],
      );
    }
    final you = ride.pack.packRows.where((row) => row.you).firstOrNull;
    return ListView(
      padding: const EdgeInsets.all(10),
      children: [
        _card(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('RIDING GROUP', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFF64748B), letterSpacing: 0.6)),
                    Text(ride.code, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  ],
                ),
              ),
              if (ride.ended)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(color: const Color(0xFFE8F8EF), borderRadius: BorderRadius.circular(20)),
                  child: const Text('Ride ended', style: TextStyle(color: Color(0xFF067647), fontWeight: FontWeight.w800)),
                )
              else
                Wrap(
                  spacing: 8,
                  children: [
                    if (ride.admin)
                      OutlinedButton(
                        onPressed: () => confirmDeleteRide(context, ride),
                        child: const Text('Delete ride'),
                      ),
                    Semantics(
                      button: true,
                      label: 'END',
                      child: FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB91C1C)),
                        onPressed: ride.endRide,
                        child: const Text('END'),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Pack · ${ride.pack.packRows.length} riders', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 4),
              Text(
                you == null ? 'You are not attached to this ride.' : '${you.name} is on this code as ${you.role}. Distance is from you.',
                style: const TextStyle(color: Color(0xFF64748B)),
              ),
            ],
          ),
        ),
        for (final row in ride.pack.packRows) ...[
          const SizedBox(height: 8),
          _RiderCard(row: row),
        ],
      ],
    );
  }
}

class _RiderCard extends StatelessWidget {
  const _RiderCard({required this.row});

  final PackRow row;

  @override
  Widget build(BuildContext context) {
    final ride = RideScope.of(context);
    final relation = row.you
        ? 'You are the reference for the pack.'
        : row.ahead
            ? '${formatKm(row.km)} ahead of you'
            : '${formatKm(row.km)} behind you';
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: !row.online ? const Color(0xFF94A3B8) : row.you ? const Color(0xFF22C55E) : const Color(0xFF0F172A),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(row.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
              if (!row.you && !ride.ended)
                Semantics(
                  button: true,
                  label: 'Remove ${row.name}',
                  child: OutlinedButton(
                    onPressed: () => ride.pack.removeRider(row.id),
                    child: const Text('Remove'),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            children: [
              if (row.you) const Chip(label: Text('You'), visualDensity: VisualDensity.compact),
              if (row.dropping) const Chip(label: Text('Dropping back'), visualDensity: VisualDensity.compact),
              Chip(label: Text(row.online ? 'Online' : 'Offline'), visualDensity: VisualDensity.compact),
            ],
          ),
          Text(row.role, style: const TextStyle(color: Color(0xFF334155))),
          const SizedBox(height: 6),
          Text(relation, style: const TextStyle(fontWeight: FontWeight.w700)),
          Text(
            !row.online
                ? 'Offline. Last position is still listed.'
                : row.you
                    ? (ride.ended ? 'Ride ended. GPS is off.' : ride.paused ? 'Paused.' : 'Position is live.')
                    : ride.pack.showOthers
                        ? 'Shown on the Ride HUD route.'
                        : 'Hidden on the map.',
            style: const TextStyle(color: Color(0xFF64748B)),
          ),
        ],
      ),
    );
  }
}

class TollPage extends StatelessWidget {
  const TollPage({super.key});

  @override
  Widget build(BuildContext context) {
    final ride = RideScope.of(context);
    return ListView(
      padding: const EdgeInsets.all(10),
      children: [
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Khed-Shivapur Toll Naka', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
              const SizedBox(height: 6),
              Text('${ride.radio.arrived}/2 riders arrived', style: const TextStyle(color: Color(0xFFB45309), fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              const Text('Send Regroup from the Ride HUD as riders roll in.', style: TextStyle(color: Color(0xFF64748B))),
            ],
          ),
        ),
      ],
    );
  }
}

class _RideCodeCard extends StatefulWidget {
  const _RideCodeCard();

  @override
  State<_RideCodeCard> createState() => _RideCodeCardState();
}

class _RideCodeCardState extends State<_RideCodeCard> {
  final TextEditingController _join = TextEditingController();
  final FocusNode _joinFocus = FocusNode();

  @override
  void dispose() {
    _join.dispose();
    _joinFocus.dispose();
    super.dispose();
  }

  void _submitCode(String raw) {
    final joined = RideScope.of(context).joinCode(raw);
    if (joined == null) return;
    _join.text = joined;
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final ride = RideScope.of(context);
    final start = ride.plan.startName.isEmpty ? 'Start not set' : ride.plan.startName;
    final finish = ride.plan.finishName.isEmpty ? 'Finish not set' : ride.plan.finishName;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(ride.onRide ? 'This ride' : 'Start a ride', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 4),
          Text(
            ride.onRide ? ride.code : 'Generate a code, or join one you already have.',
            style: TextStyle(fontSize: ride.onRide ? 22 : 14, fontWeight: FontWeight.w800, color: ride.onRide ? const Color(0xFF0F172A) : const Color(0xFF64748B)),
          ),
          if (ride.onRide) ...[
            const SizedBox(height: 4),
            Text(
              ride.plan.tripDateLabel.isEmpty
                  ? '$start → $finish · ${ride.plan.tripDays} ${ride.plan.tripDays == 1 ? 'day' : 'days'}'
                  : '$start → $finish · ${ride.plan.tripDateLabel}',
              style: const TextStyle(color: Color(0xFF334155)),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(onPressed: ride.generateCode, child: Text(ride.onRide ? 'New code' : 'Generate a code')),
              if (ride.onRide) OutlinedButton(onPressed: ride.leaveRide, child: const Text('Leave ride')),
              if (ride.admin) OutlinedButton(onPressed: () => confirmDeleteRide(context, ride), child: const Text('Delete ride')),
              if (ride.canPlan)
                FilledButton(
                  onPressed: ride.plan.beginPlanning,
                  child: const Text('Plan a ride'),
                ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _join,
            focusNode: _joinFocus,
            keyboardType: TextInputType.text,
            textCapitalization: TextCapitalization.characters,
            textInputAction: TextInputAction.done,
            autocorrect: false,
            enableSuggestions: false,
            style: const TextStyle(fontSize: 16),
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Join a code, ZEN-1234',
              border: OutlineInputBorder(),
            ),
            onTap: () => _joinFocus.requestFocus(),
            onSubmitted: _submitCode,
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(onPressed: () => _submitCode(_join.text), child: const Text('Join')),
          ),
          if (ride.joinNote.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                ride.joinNote,
                style: TextStyle(
                  color: ride.joinNote.startsWith('Joining ') ? const Color(0xFF334155) : const Color(0xFF9A3412),
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          if (ride.onRide) ...[
            const SizedBox(height: 12),
            Text('On ${ride.code}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 2),
            Text(
              '${ride.pack.joinedPhones.length} ${ride.pack.joinedPhones.length == 1 ? 'phone' : 'phones'} on this ride',
              style: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
            ),
            for (final phone in ride.pack.joinedPhones)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  phone.you ? '${phone.label} · this phone' : phone.label,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    color: phone.you ? const Color(0xFF1A73E8) : const Color(0xFF0F172A),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class ToursPage extends StatelessWidget {
  const ToursPage({super.key});

  @override
  Widget build(BuildContext context) {
    final ride = RideScope.of(context);
    final savedRoad = ride.plan.roadFor(ride.plan.ridingDay);
    final start = ride.plan.startName.isEmpty ? 'Start not set' : ride.plan.startName;
    final finish = ride.plan.finishName.isEmpty ? 'Finish not set' : ride.plan.finishName;
    return ListView(
      padding: const EdgeInsets.all(10),
      children: [
        const _RideCodeCard(),
        const SizedBox(height: 8),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(child: Text('Your plan', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
                  if (ride.canPlan)
                    OutlinedButton(
                      onPressed: ride.plan.beginPlanning,
                      child: Text(ride.plan.halts.isEmpty && ride.plan.startPoint == null ? 'Plan a ride' : 'Edit'),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                ride.plan.halts.isEmpty && ride.plan.startPoint == null && ride.plan.finishPoint == null
                    ? 'Nothing saved yet. A long ride can be more than one day. Give each day an end point and the stops in between.'
                    : '$start to $finish.',
                style: const TextStyle(color: Color(0xFF64748B)),
              ),
              if (savedRoad != null) ...[
                const SizedBox(height: 4),
                Text(
                  '${savedRoad.duration} · ${savedRoad.distance} · ${savedRoad.summary}',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ],
              if (ride.plan.shareNote.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(ride.plan.shareNote, style: const TextStyle(color: Color(0xFF9A3412), fontWeight: FontWeight.w800)),
              ],
              for (var day = 1; day <= ride.plan.tripDays; day++) ...[
                const SizedBox(height: 8),
                Text(
                  ride.plan.dateForDay(day) == null ? 'Day $day' : 'Day $day · ${formatPlanDate(ride.plan.dateForDay(day)!)}',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                Text(
                  'End · ${ride.plan.dayEnd(day)?.name ?? 'Not set'}',
                  style: const TextStyle(color: Color(0xFF334155)),
                ),
                Text(
                  ride.plan.dayStops(day).isEmpty ? 'No stops in between' : 'Stops · ${ride.plan.dayStops(day).map((stop) => stop.name).join(', ')}',
                  style: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class RideNav extends StatelessWidget {
  const RideNav({super.key});

  @override
  Widget build(BuildContext context) {
    final ride = RideScope.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              _tab(context, RideTab.hud, 'Ride HUD', Icons.map),
              _tab(context, RideTab.pack, 'Pack (${ride.pack.packRows.length})', Icons.group),
              _tab(context, RideTab.toll, 'Toll Naka', Icons.toll),
              _tab(context, RideTab.tours, 'Tours', Icons.route),
              IconButton(
                tooltip: ride.paused ? 'Resume live tracking' : 'Pause live tracking',
                onPressed: ride.ended ? null : ride.togglePause,
                icon: Icon(ride.paused ? Icons.play_arrow : Icons.pause, color: const Color(0xFF059768)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tab(BuildContext context, RideTab tab, String label, IconData icon) {
    final ride = RideScope.of(context);
    final selected = ride.tab == tab;
    return Expanded(
      child: InkWell(
        onTap: () => ride.selectTab(tab),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: selected ? const Color(0xFF0F172A) : const Color(0xFF8B93A1)),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: selected ? const Color(0xFF0F172A) : const Color(0xFF8B93A1)),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _card({required Widget child}) {
  return Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
    child: child,
  );
}
