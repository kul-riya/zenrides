import 'dart:async';
import 'dart:math';

import 'package:latlong2/latlong.dart';

import '../ride/ride_controller.dart';
import '../ride/ride_repository.dart';

class BroadcastController {
  BroadcastController(this.ride, {required this.rideRepo});

  final RideController ride;
  final RideRepository rideRepo;

  int arrived = 0;
  RideNotice? notice;
  SosFix? sos;
  String? _dismissedSosId;
  DateTime? _dismissedSosAt;
  final Map<String, DateTime> _holdUntil = {};
  SosFix? get visibleSos {
    final alert = sos;
    if (alert == null || ride.pack.removed.contains(alert.id)) return null;
    return alert;
  }

  List<String> get chaiNames {
    final names = <String>[];
    if (ride.pack.youBreaking) names.add(ride.riderName);
    for (final row in ride.pack.packRows) {
      if (!row.you && row.breaking) names.add(row.name);
    }
    return names;
  }

  void send(NoticeKind kind) {
    if (ride.ended) return;
    switch (kind) {
      case NoticeKind.fuel:
        ride.nav.toggleFuel();
        return;
      case NoticeKind.sos:
        raiseSos();
        return;
      case NoticeKind.regroup:
        arrived = min(2, arrived + 1);
        notice = RideNotice(
          kind: kind,
          kicker: 'BROADCAST: REGROUP · You (${ride.youRole})',
          body: 'Regroup. $arrived of 2 riders are at the toll naka.',
        );
      case NoticeKind.chai:
        _holdUntil['you'] = ride.now().add(const Duration(seconds: 4));
        notice = RideNotice(
          kind: NoticeKind.chai,
          kicker: 'BROADCAST: CHAI / BREAK · You (${ride.youRole})',
          body: 'Chai stop. Holding here while the pack closes up.',
        );
      case NoticeKind.hazard:
        notice = RideNotice(
          kind: NoticeKind.hazard,
          kicker: 'BROADCAST: HAZARD · You (${ride.youRole})',
          body: 'Hazard warning. Eyes up, slow the pack, and keep your line.',
        );
      case NoticeKind.slow:
        notice = RideNotice(
          kind: NoticeKind.slow,
          kicker: 'BROADCAST: SLOW PACE · You (${ride.youRole})',
          body: 'Slowing the pack. Ease off and hold the stagger.',
        );
      case NoticeKind.pack:
        break;
    }
    ride.changed();
  }

  void raiseSos({String? id, String? name, LatLng? at}) {
    final point = at ?? ride.you;
    final now = ride.now();
    final alert = SosFix(
      id: id ?? ride.riderId,
      name: name ?? ride.riderName,
      lat: point.latitude,
      lng: point.longitude,
      at: now,
    );
    sos = alert;
    notice = RideNotice(
      kind: NoticeKind.sos,
      kicker: 'BROADCAST: SOS · ${alert.name}',
      body:
          'SOS. Last spot ${alert.lat.toStringAsFixed(5)}, ${alert.lng.toStringAsFixed(5)}.',
    );
    ride.changed();
    if (ride.network && id == null) {
      unawaited(
        rideRepo
            .sendSos(
              code: ride.code,
              id: alert.id,
              name: alert.name,
              lat: alert.lat,
              lng: alert.lng,
              at: now,
            )
            .catchError((_) {}),
      );
    }
  }

  void dismissSos() {
    final alert = sos;
    if (alert != null) {
      _dismissedSosId = alert.id;
      _dismissedSosAt = alert.at;
    }
    sos = null;
    if (notice?.kind == NoticeKind.sos) notice = null;
    ride.changed();
  }

  void dismissNotice() {
    if (notice?.kind == NoticeKind.sos) {
      dismissSos();
      return;
    }
    notice = null;
    ride.changed();
  }

  void debugOfferSos(SosFix alert) {
    if (ride.pack.removed.contains(alert.id) || _sosWasDismissed(alert)) return;
    final current = sos;
    if (current == null || alert.at.isAfter(current.at)) sos = alert;
  }

  bool _sosWasDismissed(SosFix alert) {
    final id = _dismissedSosId;
    final at = _dismissedSosAt;
    if (id == null || at == null || alert.id != id) return false;
    return !alert.at.isAfter(at);
  }

  bool holding(String id) {
    final hold = _holdUntil[id];
    return hold != null && ride.now().isBefore(hold);
  }
}
