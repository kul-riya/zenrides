import 'package:latlong2/latlong.dart';

class RoadHazard {
  const RoadHazard({required this.id, required this.title, required this.detail, this.point});

  final String id;
  final String title;
  final String detail;
  final LatLng? point;
}

class HazardReport {
  const HazardReport({required this.hazards, required this.failures});

  final List<RoadHazard> hazards;
  final List<String> failures;
}

class PlaceHit {
  const PlaceHit({required this.placeId, required this.name, required this.detail});

  final String placeId;
  final String name;
  final String detail;
}

class RouteStep {
  const RouteStep({required this.instruction, required this.point});

  final String instruction;
  final LatLng point;
}

class RouteChoice {
  const RouteChoice({
    required this.summary,
    required this.duration,
    required this.distance,
    required this.points,
    this.durationSeconds = 0,
    this.distanceMeters = 0,
    this.steps = const [],
    this.traffic = false,
  });

  final String summary;
  final String duration;
  final String distance;
  final List<LatLng> points;
  final int durationSeconds;
  final int distanceMeters;
  final List<RouteStep> steps;

  /// True when Google Routes returned this time with live traffic.
  final bool traffic;
}
