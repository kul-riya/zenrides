import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:url_launcher/url_launcher.dart';

import 'ride_controller.dart';
import 'ride_map.dart';

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
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: ColoredBox(
            color: const Color(0xFFEEF1F5),
            child: SafeArea(
              child: Column(
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
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class HudPage extends StatelessWidget {
  const HudPage({super.key});

  @override
  Widget build(BuildContext context) {
    final ride = RideScope.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
          child: Column(
            children: [
              if (ride.planning)
                SizedBox(height: 390, child: PointerInterceptor(child: const _PlannerCard()))
              else
                const _HeadlineCard(),
              if (!ride.planning && ride.notice != null) ...[
                const SizedBox(height: 8),
                _NoticeCard(notice: ride.notice!),
              ],
              if (!ride.planning) ...[
                const SizedBox(height: 8),
                const _TodayCard(),
              ],
              if (!ride.planning && ride.visibleSos != null) ...[
                const SizedBox(height: 8),
                const _SosCard(),
              ],
              if (!ride.planning && ride.nearbyHazards.isNotEmpty) ...[
                const SizedBox(height: 8),
                const _RoadHazardCard(),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        const Expanded(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 10),
            child: ClipRRect(
              borderRadius: BorderRadius.all(Radius.circular(22)),
              child: _BoundMap(),
            ),
          ),
        ),
        if (!ride.planning) const _BroadcastRow(),
      ],
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

class _HeadlineCard extends StatelessWidget {
  const _HeadlineCard();

  @override
  Widget build(BuildContext context) {
    final ride = RideScope.of(context);
    return _card(
      child: Row(
        children: [
          const CircleAvatar(backgroundColor: Color(0xFF0F172A), child: Icon(Icons.navigation, color: Colors.white, size: 18)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ride.ended ? 'Ride ended' : 'Follow the highway for ${ride.routeKm.toStringAsFixed(1)} km',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
                Text(
                  ride.ended ? 'The route is no longer live.' : 'Cruising speed: maintain the pack stagger',
                  style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
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
            onPressed: ride.dismissNotice,
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
    final next = ride.nextHalt;
    final summary = ride.summary;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: Text("Today's plan", style: TextStyle(fontWeight: FontWeight.w800))),
              if (ride.todayHasPlan)
                TextButton(onPressed: ride.endDay, child: const Text('End the day')),
            ],
          ),
          if (next == null)
            Text(
              ride.admin
                  ? (ride.tripDays > 1 ? 'Day ${ride.ridingDay} has no halt yet. Plan the ride from Tours.' : 'No halts saved yet. Plan the ride from Tours.')
                  : 'No halts saved yet. An admin has to plan this ride.',
              style: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
            )
          else
            Text('Next halt · ${next.name} · ${formatKm(ride.kmTo(next.point))} left', style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            ride.chaiNames.isEmpty ? 'Nobody has stopped for chai.' : 'Chai: ${ride.chaiNames.join(', ')}',
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
    final alert = ride.visibleSos!;
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
              TextButton(onPressed: ride.dismissSos, child: const Text('Dismiss')),
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
    final nearby = ride.nearbyHazards;
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

class _PlannerCard extends StatefulWidget {
  const _PlannerCard();

  @override
  State<_PlannerCard> createState() => _PlannerCardState();
}

class _PlannerCardState extends State<_PlannerCard> {
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ride = RideScope.of(context);
    final slotLabel = switch (ride.planSlot) {
      PlanSlot.start => 'the start',
      PlanSlot.finish => 'the finish',
      PlanSlot.dayEnd => 'day ${ride.planDay} end',
      PlanSlot.stop => 'a day ${ride.planDay} stop',
    };
    return _card(
      child: Column(
        children: [
          Expanded(
            child: ListView(
        padding: EdgeInsets.zero,
        children: [
          const Text('Plan the ride', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 4),
          Text(
            'Set the days, the start, and the finish. Each day has an end point and stops in between. Search, or press Select on map and tap the road. This drop is for $slotLabel.',
            style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('Days', style: TextStyle(fontWeight: FontWeight.w800)),
              IconButton(
                onPressed: ride.draftDays > 1 ? () => ride.setDraftDays(ride.draftDays - 1) : null,
                icon: const Icon(Icons.remove_circle_outline),
              ),
              Text('${ride.draftDays}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              IconButton(
                onPressed: ride.draftDays < 14 ? () => ride.setDraftDays(ride.draftDays + 1) : null,
                icon: const Icon(Icons.add_circle_outline),
              ),
            ],
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var day = 1; day <= ride.draftDays; day++)
                ChoiceChip(
                  label: Text('Day $day'),
                  selected: ride.planDay == day,
                  onSelected: (_) => ride.selectPlanDay(day),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ChoiceChip(label: const Text('Start'), selected: ride.planSlot == PlanSlot.start, onSelected: (_) => ride.selectPlanSlot(PlanSlot.start)),
              ChoiceChip(label: const Text('Finish'), selected: ride.planSlot == PlanSlot.finish, onSelected: (_) => ride.selectPlanSlot(PlanSlot.finish)),
              ChoiceChip(label: const Text('Day end'), selected: ride.planSlot == PlanSlot.dayEnd, onSelected: (_) => ride.selectPlanSlot(PlanSlot.dayEnd)),
              ChoiceChip(label: const Text('Stop'), selected: ride.planSlot == PlanSlot.stop, onSelected: (_) => ride.selectPlanSlot(PlanSlot.stop)),
            ],
          ),
          const SizedBox(height: 8),
          if (ride.draftStart != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(ride.draftStartName.isEmpty ? 'Start' : ride.draftStartName),
              subtitle: const Text('Start'),
              trailing: IconButton(onPressed: () => ride.removeDraftHalt('plan-start'), icon: const Icon(Icons.close)),
            ),
          if (ride.draftFinish != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(ride.draftFinishName.isEmpty ? 'Finish' : ride.draftFinishName),
              subtitle: const Text('Finish'),
              trailing: IconButton(onPressed: () => ride.removeDraftHalt('plan-finish'), icon: const Icon(Icons.close)),
            ),
          for (var day = 1; day <= ride.draftDays; day++) ...[
            if (ride.dayEnd(day, draft: true) != null || ride.dayStops(day, draft: true).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Day $day', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
              ),
            if (ride.dayEnd(day, draft: true) case final end?)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(end.name),
                subtitle: const Text('Day end'),
                trailing: IconButton(onPressed: () => ride.removeDraftHalt(end.id), icon: const Icon(Icons.close)),
              ),
            for (final stop in ride.dayStops(day, draft: true))
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(stop.name),
                subtitle: const Text('Stop'),
                trailing: IconButton(onPressed: () => ride.removeDraftHalt(stop.id), icon: const Icon(Icons.close)),
              ),
          ],
          ],
        ),
      ),
          const SizedBox(height: 8),
          TextField(
            controller: _search,
            keyboardType: TextInputType.text,
            textInputAction: TextInputAction.search,
            style: const TextStyle(fontSize: 16),
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Search a place',
              prefixIcon: Icon(Icons.search, size: 18),
              border: OutlineInputBorder(),
            ),
            onChanged: ride.lookUpPlan,
          ),
          if (ride.planNote.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(ride.planNote, style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
            ),
          for (final hit in ride.planHits.take(3))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              title: Text(hit.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
              subtitle: hit.detail.isEmpty ? null : Text(hit.detail, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () {
                _search.text = hit.name;
                ride.choosePlanPlace(hit);
                FocusScope.of(context).unfocus();
              },
            ),
          if (ride.routes.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 72,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: ride.routes.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final route = ride.routes[index];
                  final selected = index == ride.selectedRoute;
                  return Material(
                    color: selected ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => ride.selectRoute(index),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              route.duration.isEmpty ? 'Route ${index + 1}' : route.duration,
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                color: selected ? Colors.white : const Color(0xFF0F172A),
                              ),
                            ),
                            Text(
                              '${route.distance} · ${route.summary}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: selected ? Colors.white70 : const Color(0xFF475569),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: () => ride.armPick(!ride.picking),
                child: Text(ride.picking ? 'Tap the map' : 'Select on map'),
              ),
              OutlinedButton(onPressed: ride.savePlan, child: const Text('Save')),
              TextButton(onPressed: ride.cancelPlanning, child: const Text('Cancel')),
            ],
          ),
        ],
      ),
    );
  }
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
    final active = ride.notice?.kind == kind || (kind == NoticeKind.fuel && ride.fuelOn);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: OutlinedButton.icon(
        onPressed: ride.ended ? null : () => ride.send(kind),
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
    final you = ride.packRows.where((row) => row.you).firstOrNull;
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
        ),
        const SizedBox(height: 8),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Pack · ${ride.packRows.length} riders', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 4),
              Text(
                you == null ? 'You are not attached to this ride.' : '${you.name} is on this code as ${you.role}. Distance is from you.',
                style: const TextStyle(color: Color(0xFF64748B)),
              ),
            ],
          ),
        ),
        for (final row in ride.packRows) ...[
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
                    onPressed: () => ride.removeRider(row.id),
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
                    : ride.showOthers
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
              Text('${ride.arrived}/2 riders arrived', style: const TextStyle(color: Color(0xFFB45309), fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              const Text('Send Regroup from the Ride HUD as riders roll in.', style: TextStyle(color: Color(0xFF64748B))),
            ],
          ),
        ),
      ],
    );
  }
}

class ToursPage extends StatefulWidget {
  const ToursPage({super.key});

  @override
  State<ToursPage> createState() => _ToursPageState();
}

class _ToursPageState extends State<ToursPage> {
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
    final start = ride.startName.isEmpty ? 'Start not set' : ride.startName;
    final finish = ride.finishName.isEmpty ? 'Finish not set' : ride.finishName;
    return ListView(
      padding: const EdgeInsets.all(10),
      children: [
        _card(
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
                Text('$start → $finish · ${ride.tripDays} ${ride.tripDays == 1 ? 'day' : 'days'}', style: const TextStyle(color: Color(0xFF334155))),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(onPressed: ride.generateCode, child: Text(ride.onRide ? 'New code' : 'Generate a code')),
                  if (ride.onRide) OutlinedButton(onPressed: ride.leaveRide, child: const Text('Leave ride')),
                  if (ride.admin) FilledButton.tonal(onPressed: ride.beginPlanning, child: const Text('Plan the ride')),
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
                  '${ride.joinedPhones.length} ${ride.joinedPhones.length == 1 ? 'phone' : 'phones'} on this ride',
                  style: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
                ),
                for (final phone in ride.joinedPhones)
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
        ),
        const SizedBox(height: 8),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(child: Text('Your plan', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
                  if (ride.admin) OutlinedButton(onPressed: ride.beginPlanning, child: const Text('Edit')),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                ride.halts.isEmpty && ride.startPoint == null && ride.finishPoint == null
                    ? 'Nothing saved yet. A long ride can be more than one day. Give each day an end point and the stops in between.'
                    : '$start to $finish.',
                style: const TextStyle(color: Color(0xFF64748B)),
              ),
              if (ride.chosen != null) ...[
                const SizedBox(height: 4),
                Text(
                  '${ride.chosen!.duration} · ${ride.chosen!.distance} · ${ride.chosen!.summary}',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ],
              if (ride.shareNote.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(ride.shareNote, style: const TextStyle(color: Color(0xFF9A3412), fontWeight: FontWeight.w800)),
              ],
              for (var day = 1; day <= ride.tripDays; day++) ...[
                const SizedBox(height: 8),
                Text('Day $day', style: const TextStyle(fontWeight: FontWeight.w800)),
                Text(
                  'End · ${ride.dayEnd(day)?.name ?? 'Not set'}',
                  style: const TextStyle(color: Color(0xFF334155)),
                ),
                Text(
                  ride.dayStops(day).isEmpty ? 'No stops in between' : 'Stops · ${ride.dayStops(day).map((stop) => stop.name).join(', ')}',
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
              _tab(context, RideTab.pack, 'Pack (${ride.packRows.length})', Icons.group),
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
