import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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
              if (ride.planning) const _PlannerCard() else const _HeadlineCard(),
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
                  ride.ended
                      ? 'Ride ended'
                      : ride.routeKm > 0
                          ? 'Follow the route for ${ride.routeKm.toStringAsFixed(1)} km'
                          : ride.gpsFix != null
                              ? 'Location set on the map'
                              : 'Waiting for a GPS fix',
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

class _PlannerCardState extends State<_PlannerCard> with TickerProviderStateMixin {
  TabController? _days;
  final List<TabController> _retire = [];
  bool _slotOpen = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ride = RideScope.of(context);
    final count = ride.draftDays;
    final index = (ride.planDay - 1).clamp(0, count - 1);
    final current = _days;
    if (current == null || current.length != count) {
      current?.removeListener(_onDayTab);
      final next = TabController(length: count, vsync: this, initialIndex: index);
      next.addListener(_onDayTab);
      _days = next;
      if (current != null) {
        _retire.add(current);
        WidgetsBinding.instance.addPostFrameCallback((_) => _dropRetired());
      }
      return;
    }
    if (current.index != index) current.index = index;
  }

  void _onDayTab() {
    final days = _days;
    if (days == null || days.indexIsChanging) return;
    final ride = RideScope.of(context);
    final day = days.index + 1;
    if (ride.planDay != day) ride.selectPlanDay(day);
  }

  void _dropRetired() {
    if (!mounted) return;
    for (final old in _retire) {
      old.dispose();
    }
    _retire.clear();
  }

  @override
  void dispose() {
    _days?.removeListener(_onDayTab);
    _days?.dispose();
    for (final old in _retire) {
      old.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ride = RideScope.of(context);
    final days = _days;
    final placed = _placed(ride);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text('Days', style: TextStyle(fontWeight: FontWeight.w800)),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: ride.draftDays > 1 ? () => ride.setDraftDays(ride.draftDays - 1) : null,
                icon: const Icon(Icons.remove_circle_outline),
              ),
              Text('${ride.draftDays}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: ride.draftDays < 14 ? () => ride.setDraftDays(ride.draftDays + 1) : null,
                icon: const Icon(Icons.add_circle_outline),
              ),
              const Spacer(),
              TextButton(onPressed: ride.cancelPlanning, child: const Text('Cancel')),
              FilledButton(onPressed: ride.savePlan, child: const Text('Save')),
            ],
          ),
          if (days != null)
            Material(
              color: Colors.transparent,
              child: TabBar(
                controller: days,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [for (var day = 1; day <= ride.draftDays; day++) Tab(text: 'Day $day')],
              ),
            ),
          InkWell(
            onTap: () => setState(() => _slotOpen = !_slotOpen),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Placing ${_slotName(ride.planSlot, ride.planDay)}',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  Icon(_slotOpen ? Icons.expand_less : Icons.expand_more),
                ],
              ),
            ),
          ),
          if (_slotOpen)
            for (final slot in PlanSlot.values)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                selected: ride.planSlot == slot,
                title: Text(_slotName(slot, ride.planDay)),
                onTap: () {
                  ride.selectPlanSlot(slot);
                  setState(() => _slotOpen = false);
                },
              ),
          if (placed.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 132),
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: placed,
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonal(
              onPressed: () => ride.armPick(!ride.picking),
              child: Text(ride.picking ? 'Tap the map' : 'Select on map'),
            ),
          ),
        ],
        ),
      ),
    );
  }

  List<Widget> _placed(RideController ride) {
    final tiles = <Widget>[];
    if (ride.draftStart != null) {
      tiles.add(_haltTile(
        ride.draftStartName.isEmpty ? 'Start' : ride.draftStartName,
        'Start',
        () => ride.removeDraftHalt('plan-start'),
      ));
    }
    if (ride.draftFinish != null) {
      tiles.add(_haltTile(
        ride.draftFinishName.isEmpty ? 'Finish' : ride.draftFinishName,
        'Finish',
        () => ride.removeDraftHalt('plan-finish'),
      ));
    }
    final end = ride.dayEnd(ride.planDay, draft: true);
    if (end != null) tiles.add(_haltTile(end.name, 'Day end', () => ride.removeDraftHalt(end.id)));
    for (final stop in ride.dayStops(ride.planDay, draft: true)) {
      tiles.add(_haltTile(stop.name, 'Stop', () => ride.removeDraftHalt(stop.id)));
    }
    return tiles;
  }

  Widget _haltTile(String title, String kind, VoidCallback onRemove) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
      subtitle: Text(kind),
      trailing: IconButton(onPressed: onRemove, icon: const Icon(Icons.close)),
    );
  }
}

String _slotName(PlanSlot slot, int day) => switch (slot) {
      PlanSlot.start => 'Start',
      PlanSlot.finish => 'Finish',
      PlanSlot.dayEnd => 'Day $day end',
      PlanSlot.stop => 'Day $day stop',
    };

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
