import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:latlong2/latlong.dart';

import 'maps_bridge.dart';
import 'ride_api.dart';
import 'ride_controller.dart';

class RideMap extends StatefulWidget {
  const RideMap({super.key, required this.ride});

  final RideController ride;

  @override
  State<RideMap> createState() => _RideMapState();
}

class _RideMapState extends State<RideMap> {
  final MapController _map = MapController();
  gmaps.GoogleMapController? _google;
  final Map<int, gmaps.BitmapDescriptor> _riderIcons = {};
  gmaps.BitmapDescriptor? _fuelIcon;
  gmaps.BitmapDescriptor? _tollIcon;
  final Map<int, gmaps.BitmapDescriptor> _arrows = {};
  final Set<int> _arrowJobs = {};
  double _cameraBearing = 0;
  bool _follow = false;
  int _seenPumps = 0;
  int _seenRoute = 0;
  int _seenNav = 0;
  int _seenPlan = 0;
  bool _ready = false;
  bool _programmatic = false;
  bool _askingPin = false;

  RideController get ride => widget.ride;

  @override
  void initState() {
    super.initState();
    ride.addListener(_onRide);
    if (kIsWeb) {
      _loadRiderIcons();
      _loadFuelIcon();
      _loadTollIcon();
      _ensureArrow(0);
    }
  }

  @override
  void didUpdateWidget(RideMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ride != ride) {
      oldWidget.ride.removeListener(_onRide);
      ride.addListener(_onRide);
    }
  }

  @override
  void dispose() {
    ride.removeListener(_onRide);
    _map.dispose();
    super.dispose();
  }

  bool _gpsWasLocked = false;

  void _onRide() {
    if (!mounted) return;
    if (ride.gpsLocked && !_gpsWasLocked && ride.navigating) _follow = true;
    _gpsWasLocked = ride.gpsLocked;
    if (ride.pumpFit != _seenPumps && ride.pumps.isNotEmpty && _fit(ride.pumps.map((pump) => pump.point).toList())) {
      _seenPumps = ride.pumpFit;
      _follow = false;
    }
    final focus = _focusPoints();
    if (ride.routeFit != _seenRoute && focus.length >= 2) {
      if (_fit(focus)) {
        _seenRoute = ride.routeFit;
        _follow = false;
      }
    }
    if (ride.navFit != _seenNav && ride.navigating) {
      _seenNav = ride.navFit;
      _follow = true;
    }
    if (ride.planning && ride.planFit != _seenPlan && _ready) {
      _seenPlan = ride.planFit;
      _follow = false;
      _showWidePlan();
    }
    if (_ready && _follow && ride.navigating) {
      _moveTo(ride.you, zoom: 17, bearing: ride.bearing, tilt: 50);
    }
    if (kIsWeb) _ensureArrow(((_screenHeading() / 5).round() * 5) % 360);
    setState(() {});
  }

  List<LatLng> _focusPoints() {
    if (ride.planning) {
      final planned = [for (final path in ride.planPaths) ...path.points];
      if (planned.length >= 2) return planned;
    }
    if (ride.showHudRoute) {
      return ride.routes[ride.selectedRoute.clamp(0, ride.routes.length - 1)].points;
    }
    return const [];
  }

  void _frameRoute() {
    final focus = _focusPoints();
    if (focus.length < 2) return;
    if (_fit(focus)) {
      _seenRoute = ride.routeFit;
      _follow = false;
    }
  }

  bool _fit(List<LatLng> points) {
    if (points.length < 2) return false;
    if (kIsWeb && _google == null) return false;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || box.size.shortestSide < 80) return false;
    var south = points.first.latitude;
    var north = south;
    var west = points.first.longitude;
    var east = west;
    for (final point in points) {
      south = min(south, point.latitude);
      north = max(north, point.latitude);
      west = min(west, point.longitude);
      east = max(east, point.longitude);
    }
    // A span this wide is a bad fit. It zooms out until the world is drawn more than once.
    if (north - south > 50 || east - west > 50) return false;
    if (kIsWeb) {
      _programmatic = true;
      _google?.moveCamera(
        gmaps.CameraUpdate.newLatLngBounds(
          gmaps.LatLngBounds(
            southwest: gmaps.LatLng(south, west),
            northeast: gmaps.LatLng(north, east),
          ),
          48,
        ),
      );
      return true;
    }
    _map.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds(LatLng(south, west), LatLng(north, east)),
        padding: const EdgeInsets.all(36),
      ),
    );
    return true;
  }

  void _showWidePlan() {
    final points = [ride.you, ...ride.visibleHalts.map((halt) => halt.point)];
    if (points.isEmpty) return;
    var south = points.first.latitude;
    var north = south;
    var west = points.first.longitude;
    var east = west;
    for (final point in points) {
      south = min(south, point.latitude);
      north = max(north, point.latitude);
      west = min(west, point.longitude);
      east = max(east, point.longitude);
    }
    const minSpan = 3.0;
    if (north - south < minSpan) {
      final extra = (minSpan - (north - south)) / 2;
      south -= extra;
      north += extra;
    }
    if (east - west < minSpan) {
      final extra = (minSpan - (east - west)) / 2;
      west -= extra;
      east += extra;
    }
    _follow = false;
    if (kIsWeb) {
      if (_google == null) return;
      _programmatic = true;
      _google?.moveCamera(
        gmaps.CameraUpdate.newLatLngBounds(
          gmaps.LatLngBounds(
            southwest: gmaps.LatLng(south, west),
            northeast: gmaps.LatLng(north, east),
          ),
          48,
        ),
      );
      return;
    }
    _map.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds(LatLng(south, west), LatLng(north, east)),
        padding: const EdgeInsets.all(28),
      ),
    );
  }

  void _recenter() {
    _follow = true;
    if (ride.navigating) {
      _moveTo(ride.you, zoom: 17, bearing: ride.bearing, tilt: 50);
    } else {
      _moveTo(ride.you, zoom: RideController.recenterZoom);
    }
    setState(() {});
  }

  void _moveTo(LatLng point, {double? zoom, double bearing = 0, double tilt = 0}) {
    _cameraBearing = bearing;
    if (kIsWeb) {
      _programmatic = true;
      final target = gmaps.LatLng(point.latitude, point.longitude);
      final camera = zoom == null
          ? gmaps.CameraUpdate.newLatLng(target)
          : gmaps.CameraUpdate.newCameraPosition(
              gmaps.CameraPosition(target: target, zoom: zoom, bearing: bearing, tilt: tilt),
            );
      _google?.moveCamera(camera);
      return;
    }
    _map.move(point, zoom ?? _map.camera.zoom);
  }

  gmaps.LatLng _g(LatLng point) => gmaps.LatLng(point.latitude, point.longitude);

  Future<void> _loadRiderIcons() async {
    for (var i = 0; i < riderMarks.length; i++) {
      final icon = await _badgeMarker(riderMarks[i].icon, riderMarks[i].color);
      if (!mounted) return;
      setState(() => _riderIcons[i] = icon);
    }
  }

  Future<void> _loadFuelIcon() async {
    final icon = await _badgeMarker(Icons.local_gas_station, const Color(0xFFE11D2E), size: 24);
    if (!mounted) return;
    setState(() => _fuelIcon = icon);
  }

  Future<void> _loadTollIcon() async {
    final icon = await _badgeMarker(Icons.toll, const Color(0xFFB45309), size: 24);
    if (!mounted) return;
    setState(() => _tollIcon = icon);
  }

  Future<gmaps.BitmapDescriptor> _badgeMarker(IconData icon, Color color, {double size = 42}) async {
    const canvasSize = 96.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawCircle(const Offset(48, 48), 44, Paint()..color = color);
    canvas.drawCircle(
      const Offset(48, 48),
      44,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6,
    );
    final painter = TextPainter(textDirection: TextDirection.ltr)
      ..text = TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: const TextStyle(fontFamily: 'MaterialIcons', fontSize: 58, color: Colors.white),
      );
    painter.layout();
    painter.paint(canvas, Offset((canvasSize - painter.width) / 2, (canvasSize - painter.height) / 2));
    final image = await recorder.endRecording().toImage(canvasSize.toInt(), canvasSize.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return gmaps.BitmapDescriptor.bytes(bytes!.buffer.asUint8List(), width: size, height: size);
  }

  double _screenHeading() {
    final delta = ride.travelHeading - _cameraBearing;
    return (delta % 360 + 360) % 360;
  }

  void _ensureArrow(int degrees) {
    if (_arrows.containsKey(degrees) || !_arrowJobs.add(degrees)) return;
    unawaited(() async {
      final icon = await _arrowIcon(degrees.toDouble());
      _arrowJobs.remove(degrees);
      if (!mounted) return;
      setState(() => _arrows[degrees] = icon);
    }());
  }

  Future<gmaps.BitmapDescriptor> _arrowIcon(double degrees) async {
    const size = 128.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.translate(size / 2, size / 2);
    canvas.rotate(degrees * pi / 180);
    canvas.translate(-size / 2, -size / 2);
    paintNavArrow(canvas, size);
    final image = await recorder.endRecording().toImage(size.toInt(), size.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return gmaps.BitmapDescriptor.bytes(bytes!.buffer.asUint8List(), width: 40, height: 40);
  }

  Set<gmaps.Marker> _googleMarkers(SosFix? sos) {
    final markers = <gmaps.Marker>{};
    for (final halt in ride.mapHalts) {
      markers.add(gmaps.Marker(
        markerId: gmaps.MarkerId(halt.id),
        position: _g(halt.point),
        infoWindow: gmaps.InfoWindow(title: halt.name),
        icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(gmaps.BitmapDescriptor.hueOrange),
      ));
    }
    for (final pump in ride.shownPumps) {
      markers.add(gmaps.Marker(
        markerId: gmaps.MarkerId(pump.id),
        position: _g(pump.point),
        infoWindow: gmaps.InfoWindow(title: pump.name),
        icon: _fuelIcon ?? gmaps.BitmapDescriptor.defaultMarkerWithHue(gmaps.BitmapDescriptor.hueRose),
      ));
    }
    if (ride.planning) {
      for (final toll in ride.planTolls) {
        markers.add(gmaps.Marker(
          markerId: gmaps.MarkerId('toll-${toll.id}'),
          position: _g(toll.point),
          infoWindow: gmaps.InfoWindow(title: toll.name),
          onTap: () => ride.pickToll(toll),
          icon: _tollIcon ?? gmaps.BitmapDescriptor.defaultMarkerWithHue(gmaps.BitmapDescriptor.hueOrange),
        ));
      }
    }
    if (ride.showHudRoute) {
      final chosen = ride.routes[ride.selectedRoute.clamp(0, ride.routes.length - 1)];
      final end = chosen.points.last;
      final covered = ride.visibleHalts.any((halt) => const Distance().as(LengthUnit.Meter, halt.point, end) < 400);
      if (!covered) {
        markers.add(gmaps.Marker(
          markerId: const gmaps.MarkerId('destination'),
          position: _g(end),
          infoWindow: gmaps.InfoWindow(title: ride.destinationName),
          icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(gmaps.BitmapDescriptor.hueViolet),
        ));
      }
    }
    for (final rider in ride.mapRiders) {
      if (rider.you) {
        // The parked stand-in is not a real fix. Drawing it on open put an arrow
        // on the map before anyone had a location.
        if (ride.gpsFix == null) continue;
        final deg = ((_screenHeading() / 5).round() * 5) % 360;
        final arrow = _arrows[deg] ?? _arrows[0];
        // A missing arrow used to fall back to Google's red pin, which showed up
        // as a second dot next to the rider.
        if (arrow == null) continue;
        markers.add(gmaps.Marker(
          markerId: gmaps.MarkerId(rider.id),
          position: _g(rider.point),
          infoWindow: const gmaps.InfoWindow(title: 'YOU'),
          icon: arrow,
          anchor: const Offset(0.5, 0.5),
          zIndexInt: 4,
        ));
        continue;
      }
      markers.add(gmaps.Marker(
        markerId: gmaps.MarkerId(rider.id),
        position: _g(rider.point),
        infoWindow: gmaps.InfoWindow(title: rider.name),
        icon: _riderIcons[rider.mark] ??
            gmaps.BitmapDescriptor.defaultMarkerWithHue(gmaps.BitmapDescriptor.hueOrange),
      ));
    }
    if (sos != null) {
      markers.add(gmaps.Marker(
        markerId: const gmaps.MarkerId('sos'),
        position: gmaps.LatLng(sos.lat, sos.lng),
        infoWindow: gmaps.InfoWindow(title: 'SOS ${sos.name}'),
        icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(gmaps.BitmapDescriptor.hueRed),
      ));
    }
    return markers;
  }

  Set<gmaps.Polyline> _googleLines() {
    if (ride.showHudRoute) {
      final chosen = ride.routes[ride.selectedRoute.clamp(0, ride.routes.length - 1)];
      return {
        gmaps.Polyline(
          polylineId: const gmaps.PolylineId('drive-live'),
          color: const Color(0xFF1A73E8),
          width: 8,
          points: [for (final point in chosen.points) _g(point)],
        ),
      };
    }
    if (ride.planning && ride.planPaths.isNotEmpty) {
      final paths = ride.planPaths;
      return {
        for (final path in paths)
          gmaps.Polyline(
            polylineId: gmaps.PolylineId('day-${path.day}-${path.alternative ?? 'saved'}'),
            color: path.selected ? dayColor(path.day) : dayColor(path.day).withValues(alpha: 0.35),
            width: path.selected ? (path.day == ride.planDay ? 6 : 5) : 4,
            zIndex: path.selected ? (path.day == ride.planDay ? 3 : 1) : 0,
            consumeTapEvents: true,
            onTap: () => ride.openPlannedDay(path.day, alternative: path.alternative),
            points: [for (final point in path.points) _g(point)],
          ),
      };
    }
    return {};
  }

  List<Polyline> _mapLines() {
    if (ride.showHudRoute) {
      final chosen = ride.routes[ride.selectedRoute.clamp(0, ride.routes.length - 1)];
      return [Polyline(points: chosen.points, color: const Color(0xFF1D4ED8), strokeWidth: 5)];
    }
    if (ride.planning && ride.planPaths.isNotEmpty) {
      final paths = [...ride.planPaths]..sort((a, b) {
          final aRank = a.selected ? (a.day == ride.planDay ? 2 : 1) : 0;
          final bRank = b.selected ? (b.day == ride.planDay ? 2 : 1) : 0;
          return aRank.compareTo(bRank);
        });
      return [
        for (final path in paths)
          Polyline(
            points: path.points,
            color: path.selected ? dayColor(path.day) : dayColor(path.day).withValues(alpha: 0.35),
            strokeWidth: path.selected ? (path.day == ride.planDay ? 5 : 4) : 3,
          ),
      ];
    }
    return [];
  }

  Widget _googleMap(SosFix? sos) {
    return gmaps.GoogleMap(
      initialCameraPosition: gmaps.CameraPosition(target: _g(ride.you), zoom: RideController.overviewZoom),
      onMapCreated: (controller) {
        _google = controller;
        _ready = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _frameRoute();
        });
      },
      onTap: (point) => _onMapTap(LatLng(point.latitude, point.longitude)),
      onCameraMove: (position) => _cameraBearing = position.bearing,
      onCameraMoveStarted: () {
        if (!_programmatic) _follow = false;
      },
      onCameraIdle: () => _programmatic = false,
      markers: _googleMarkers(sos),
      polylines: _googleLines(),
      zoomControlsEnabled: false,
      myLocationButtonEnabled: false,
      mapToolbarEnabled: false,
      minMaxZoomPreference: const gmaps.MinMaxZoomPreference(3, 20),
      cameraTargetBounds: gmaps.CameraTargetBounds(
        gmaps.LatLngBounds(
          southwest: const gmaps.LatLng(-85, -179.9),
          northeast: const gmaps.LatLng(85, 179.9),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sos = ride.visibleSos;
    return Stack(
      children: [
        if (kIsWeb && MapsBridge.scriptReady)
          _googleMap(sos)
        else
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: ride.you,
            initialZoom: RideController.overviewZoom,
            minZoom: 3,
            onMapReady: () {
              _ready = true;
              _frameRoute();
            },
            onTap: (_, point) => _onMapTap(point),
            onPositionChanged: (_, hasGesture) {
              if (hasGesture) _follow = false;
            },
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.zenrides.joe',
            ),
            PolylineLayer(polylines: _mapLines()),
            MarkerLayer(
              markers: [
                for (final halt in ride.mapHalts)
                  _pin(halt.point, _label(halt.name, const Color(0xFFB45309))),
                for (final pump in ride.shownPumps) _spot(pump.point, const Color(0xFFE11D2E), Icons.local_gas_station, pump.name),
                if (ride.planning)
                  for (final toll in ride.planTolls)
                    _spot(
                      toll.point,
                      const Color(0xFFB45309),
                      Icons.toll,
                      toll.name,
                      onTap: () => ride.pickToll(toll),
                    ),
                for (final rider in ride.mapRiders)
                  if (!rider.you)
                    _pin(
                      rider.point,
                      _dot(riderMarks[rider.mark].color, riderMarks[rider.mark].icon, rider.name),
                    ),
                if (sos != null)
                  _pin(
                    LatLng(sos.lat, sos.lng),
                    _label('SOS', const Color(0xFFC81E1E)),
                  ),
                if (ride.gpsFix != null)
                  Marker(
                    point: ride.you,
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    child: Transform.rotate(
                      angle: ride.travelHeading * pi / 180,
                      child: CustomPaint(
                        size: const Size(40, 40),
                        painter: const _NavArrowPainter(),
                      ),
                    ),
                  ),
              ],
            ),
            const RichAttributionWidget(
              attributions: [
                TextSourceAttribution('OpenStreetMap'),
              ],
            ),
          ],
        ),
        if (ride.planning && ride.planScreen == PlanScreen.map)
          Positioned(
            left: 8,
            top: 8,
            child: PointerInterceptor(
              child: Material(
                color: Colors.white,
                elevation: 2,
                shape: const CircleBorder(),
                child: IconButton(
                  tooltip: 'Back',
                  onPressed: ride.closeMapPick,
                  icon: const Icon(Icons.arrow_back),
                ),
              ),
            ),
          ),
        if (ride.planning && ride.planScreen != PlanScreen.day)
          Positioned(
            left: ride.planScreen == PlanScreen.map ? 64 : 8,
            right: ride.planScreen == PlanScreen.map ? 8 : 108,
            top: 8,
            child: PointerInterceptor(child: _PlanSearch(ride: ride)),
          )
        else if (!ride.planning && ride.navigating)
          Positioned(
            left: 8,
            right: 108,
            top: 8,
            child: _NavBanner(ride: ride),
          )
        else if (!ride.planning)
          Positioned(
            left: 8,
            right: 108,
            top: 8,
            child: PointerInterceptor(child: _DirectionsSearch(ride: ride)),
          ),
        if (ride.planning && ride.planScreen == PlanScreen.overview)
          Positioned(
            right: 8,
            top: 8,
            child: PointerInterceptor(child: _dayBadge(ride)),
          ),
        if (!ride.planning && !ride.navigating && !ride.searchFocused && ride.suggestions.isEmpty)
        Positioned(
          left: 8,
          top: 64,
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _chip(
                ride.showOthers ? 'Hide Other Bikes' : 'Show Other Bikes',
                ride.toggleOthers,
                icon: ride.showOthers ? Icons.visibility_off : Icons.visibility,
              ),
              _chip(
                ride.gpsSeeking ? 'GPS…' : (ride.gpsLocked ? 'GPS live' : 'GPS off'),
                ride.requestGps,
              ),
            ],
          ),
        ),
        if (!ride.planning && !ride.gpsLocked && !ride.ended)
          Positioned(
            left: 8,
            top: ride.navigating ? 64 : (ride.gpsReason.isEmpty ? 108 : 148),
            child: PointerInterceptor(child: _note('Tap the map to set where you are')),
          ),
        if (!ride.planning && ride.gpsReason.isNotEmpty)
          Positioned(
            left: 8,
            top: 108,
            child: _note(ride.gpsReason),
          ),
        if (!ride.planning && ride.navigating)
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: _NavFooter(ride: ride),
          )
        else if (ride.planning && ride.routes.isNotEmpty && ride.roadFitsDay)
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: PointerInterceptor(child: _RouteChoices(ride: ride)),
          )
        else if (ride.showHudRoute)
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: PointerInterceptor(child: _RouteChoices(ride: ride)),
          )
        else if (!ride.planning && ride.fuelNote.isNotEmpty)
          Positioned(
            left: 8,
            bottom: 36,
            child: _note(ride.fuelNote),
          ),
        if (ride.ended)
          const Positioned(
            left: 8,
            top: 108,
            child: DecoratedBox(
              decoration: BoxDecoration(color: Color(0xFF0F172A), borderRadius: BorderRadius.all(Radius.circular(20))),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text('Route not live', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        if (ride.planning && ride.pickedToll != null && ride.planScreen != PlanScreen.day)
          Positioned(
            left: 12,
            right: 12,
            bottom: 16,
            child: PointerInterceptor(child: _TollHaltCard(ride: ride, toll: ride.pickedToll!)),
          ),
        if (!ride.planning)
        Positioned(
          right: 12,
          bottom: ride.navigating ? 58 : (ride.showHudRoute || (ride.planning && ride.routes.isNotEmpty && ride.roadFitsDay) ? 156 : 16),
          child: Semantics(
            button: true,
            label: 'Recenter',
            child: FilledButton.tonal(
              onPressed: _recenter,
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: const Color(0xFF0F172A),
                elevation: 2,
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.navigation, size: 16),
                  SizedBox(width: 6),
                  Text('Recenter', style: TextStyle(fontWeight: FontWeight.w800)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Marker _spot(LatLng point, Color color, IconData icon, String name, {VoidCallback? onTap}) {
    final iconBox = Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 1)),
      child: Icon(icon, size: 9, color: Colors.white),
    );
    return Marker(
      point: point,
      width: onTap == null ? 16 : 28,
      height: onTap == null ? 16 : 28,
      alignment: Alignment.center,
      child: Tooltip(
        message: name,
        child: onTap == null
            ? iconBox
            : GestureDetector(
                onTap: onTap,
                behavior: HitTestBehavior.opaque,
                child: Center(child: iconBox),
              ),
      ),
    );
  }

  Marker _pin(LatLng point, Widget child) {
    return Marker(
      point: point,
      width: 96,
      height: 48,
      alignment: Alignment.topCenter,
      child: child,
    );
  }

  Widget _dot(Color color, IconData icon, String name) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle, border: Border.all(color: Colors.white)),
          child: Icon(icon, size: 11, color: Colors.white),
        ),
        Text(name, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: Color(0xFF9A3412))),
      ],
    );
  }

  Widget _label(String text, Color color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800),
          ),
        ),
        const SizedBox(height: 2),
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2))),
      ],
    );
  }

  Widget _dayBadge(RideController ride) {
    final day = ride.planning ? ride.planDay : ride.ridingDay;
    final total = ride.planning ? ride.draftDays : ride.tripDays;
    final label = total > 1 ? 'Day $day of $total' : 'Day $day';
    return Material(
      color: Colors.white,
      elevation: 2,
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
      ),
    );
  }

  Widget _chip(String label, VoidCallback onTap, {IconData? icon}) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 14), const SizedBox(width: 4)],
              Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }

  void _onMapTap(LatLng point) {
    if (ride.planning && ride.planScreen == PlanScreen.map && ride.picking) {
      ride.dropHalt(point);
      return;
    }
    if (ride.planning) ride.showWholeRide();
    if (ride.picking) {
      ride.dropHalt(point);
      return;
    }
    if (!ride.gpsLocked && !ride.planning) unawaited(_offerPin(point));
  }

  Future<void> _offerPin(LatLng point) async {
    if (_askingPin || !mounted || ride.gpsLocked || ride.planning || ride.ended) return;
    _askingPin = true;
    final when = TimeOfDay.now().format(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => PointerInterceptor(
        child: AlertDialog(
          title: const Text('Set your location?'),
          content: Text('Mark this spot as where you are at $when.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Set location')),
          ],
        ),
      ),
    );
    _askingPin = false;
    if (ok == true && mounted) ride.placeYou(point);
  }

  Widget _note(String text) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 220),
      child: DecoratedBox(
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.95), borderRadius: BorderRadius.circular(8)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(text, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF9F1239))),
        ),
      ),
    );
  }
}

class _DirectionsSearch extends StatefulWidget {
  const _DirectionsSearch({required this.ride});

  final RideController ride;

  @override
  State<_DirectionsSearch> createState() => _DirectionsSearchState();
}

class _DirectionsSearchState extends State<_DirectionsSearch> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();
  String _sig = '';

  RideController get ride => widget.ride;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
    ride.addListener(_sync);
  }

  void _onFocus() {
    ride.setSearchFocused(_focus.hasFocus);
  }

  @override
  void didUpdateWidget(_DirectionsSearch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ride != ride) {
      oldWidget.ride.removeListener(_sync);
      ride.addListener(_sync);
    }
  }

  @override
  void dispose() {
    ride.removeListener(_sync);
    _focus.removeListener(_onFocus);
    ride.setSearchFocused(false);
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  void _sync() {
    if (!mounted) return;
    final sig = '${ride.destinationName}|${ride.searchNote}|${ride.suggestions.map((hit) => hit.placeId).join()}';
    if (sig == _sig) return;
    _sig = sig;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: Colors.white,
          elevation: 2,
          borderRadius: BorderRadius.circular(24),
          child: TextField(
            controller: _text,
            focusNode: _focus,
            keyboardType: TextInputType.text,
            textInputAction: TextInputAction.search,
            style: const TextStyle(fontSize: 16),
            decoration: InputDecoration(
              hintText: 'Where to?',
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _text.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      onPressed: () {
                        _text.clear();
                        ride.clearDirections();
                        setState(() {});
                      },
                      icon: const Icon(Icons.close, size: 18),
                    ),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onChanged: (value) {
              setState(() {});
              ride.lookUp(value);
            },
          ),
        ),
        if (ride.searchNote.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Text(ride.searchNote, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
              ),
            ),
          ),
        if (ride.suggestions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Material(
              color: Colors.white,
              elevation: 3,
              borderRadius: BorderRadius.circular(16),
              child: Column(
                children: [
                  for (final hit in ride.suggestions)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.place_outlined, size: 18),
                      title: Text(hit.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                      subtitle: hit.detail.isEmpty ? null : Text(hit.detail, maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () {
                        _text.text = hit.name;
                        _sig = '';
                        ride.choosePlace(hit);
                        FocusScope.of(context).unfocus();
                      },
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _PlanSearch extends StatefulWidget {
  const _PlanSearch({required this.ride});

  final RideController ride;

  @override
  State<_PlanSearch> createState() => _PlanSearchState();
}

class _PlanSearchState extends State<_PlanSearch> {
  final TextEditingController _text = TextEditingController();
  String _sig = '';

  RideController get ride => widget.ride;

  @override
  void initState() {
    super.initState();
    ride.addListener(_sync);
  }

  @override
  void didUpdateWidget(_PlanSearch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ride != ride) {
      oldWidget.ride.removeListener(_sync);
      ride.addListener(_sync);
    }
  }

  @override
  void dispose() {
    ride.removeListener(_sync);
    _text.dispose();
    super.dispose();
  }

  void _sync() {
    if (!mounted) return;
    final sig = '${ride.planSlot}|${ride.planDay}|${ride.visiblePlanNote}|${ride.wholeRide}|${ride.planHits.map((hit) => hit.placeId).join()}';
    if (sig == _sig) return;
    _sig = sig;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final hint = switch (ride.planSlot) {
      PlanSlot.start => 'Search the start',
      PlanSlot.dayStart => 'Search day ${ride.planDay} start',
      PlanSlot.finish => 'Search the finish',
      PlanSlot.dayEnd => 'Search day ${ride.planDay} end',
      PlanSlot.stop => 'Search a day ${ride.planDay} stop',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: Colors.white,
          elevation: 2,
          borderRadius: BorderRadius.circular(24),
          child: TextField(
            controller: _text,
            keyboardType: TextInputType.text,
            textInputAction: TextInputAction.search,
            style: const TextStyle(fontSize: 16),
            decoration: InputDecoration(
              hintText: hint,
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _text.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      onPressed: () {
                        _text.clear();
                        ride.lookUpPlan('');
                        setState(() {});
                      },
                      icon: const Icon(Icons.close, size: 18),
                    ),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onChanged: (value) {
              setState(() {});
              ride.lookUpPlan(value);
            },
          ),
        ),
        if (ride.visiblePlanNote.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Text(ride.visiblePlanNote, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
              ),
            ),
          ),
        if (ride.planHits.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Material(
              color: Colors.white,
              elevation: 3,
              borderRadius: BorderRadius.circular(16),
              child: Column(
                children: [
                  for (final hit in ride.planHits.take(4))
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.place_outlined, size: 18),
                      title: Text(hit.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                      subtitle: hit.detail.isEmpty ? null : Text(hit.detail, maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () {
                        _text.text = hit.name;
                        _sig = '';
                        ride.choosePlanPlace(hit);
                        FocusScope.of(context).unfocus();
                      },
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _RouteChip extends StatelessWidget {
  const _RouteChip({required this.title, required this.detail});

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF0F172A),
      elevation: 2,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, maxLines: 1, style: const TextStyle(fontWeight: FontWeight.w900, color: Colors.white)),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  detail,
                  softWrap: false,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white70),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RouteChoices extends StatelessWidget {
  const _RouteChoices({required this.ride});

  final RideController ride;

  @override
  Widget build(BuildContext context) {
    final index = ride.selectedRoute.clamp(0, ride.routes.length - 1);
    final route = ride.routes[index];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RouteChip(
          title: route.duration.isEmpty ? 'Route ${index + 1}' : route.duration,
          detail: '${route.distance} · ${route.summary}',
        ),
        if (ride.routes.length > 1) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: ride.routes.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, other) {
                final alt = ride.routes[other];
                final selected = other == index;
                final label = alt.duration.isEmpty ? 'Route ${other + 1}' : alt.duration;
                return Material(
                  color: selected ? const Color(0xFF0F172A) : Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => ride.selectRoute(other),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Center(
                        child: Text(
                          label,
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            color: selected ? Colors.white : const Color(0xFF0F172A),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
        const SizedBox(height: 8),
        if (!ride.planning)
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF1A73E8),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
            ),
            onPressed: ride.startNavigation,
            icon: const Icon(Icons.navigation),
            label: const Text('Start', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          ),
        ),
      ],
    );
  }
}

class _NavBanner extends StatelessWidget {
  const _NavBanner({required this.ride});

  final RideController ride;

  @override
  Widget build(BuildContext context) {
    final step = ride.nextStep;
    final pump = ride.nearestPumpMeters;
    return Material(
      color: const Color(0xFF1A73E8),
      elevation: 3,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ride.navArrived
                  ? 'Arrived · ${ride.destinationName}'
                  : '${formatKm(_metersToStep(ride) / 1000)}  ·  ${step?.instruction ?? 'Continue to ${ride.destinationName}'}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800, height: 1.15),
            ),
            if (pump != null)
              Text(
                'Nearest petrol  ${formatKm(pump / 1000)}',
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
              ),
          ],
        ),
      ),
    );
  }
}

double _metersToStep(RideController ride) {
  final step = ride.nextStep;
  if (step == null) return ride.remainingKm * 1000;
  const distance = Distance();
  return distance.as(LengthUnit.Meter, ride.you, step.point);
}

class _NavFooter extends StatelessWidget {
  const _NavFooter({required this.ride});

  final RideController ride;

  @override
  Widget build(BuildContext context) {
    final label = ride.navArrived
        ? 'Done · ${ride.destinationName}'
        : '${ride.remainingMinutes} min · ${formatKm(ride.remainingKm)} · ${ride.arrivalLabel}';
    return Material(
      color: Colors.white,
      elevation: 4,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: Row(
          children: [
            Expanded(
              child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFF188038))),
            ),
            IconButton(
              tooltip: 'Exit',
              visualDensity: VisualDensity.compact,
              onPressed: ride.stopNavigation,
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

void paintNavArrow(Canvas canvas, double size) {
  canvas.save();
  canvas.scale(size / 96);
  final path = ui.Path()
    ..moveTo(48, 4)
    ..lineTo(88, 88)
    ..lineTo(48, 68)
    ..lineTo(8, 88)
    ..close();
  canvas.drawShadow(path, const Color(0x661A73E8), 3, false);
  canvas.drawPath(
    path,
    Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeJoin = StrokeJoin.round,
  );
  canvas.drawPath(path, Paint()..color = const Color(0xFF1A73E8));
  canvas.restore();
}

class _TollHaltCard extends StatelessWidget {
  const _TollHaltCard({required this.ride, required this.toll});

  final RideController ride;
  final TollPlaza toll;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 6,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.toll, color: Color(0xFFB45309), size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    toll.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Add this toll naka as a halt on the plan.',
              style: TextStyle(color: Color(0xFF64748B), fontSize: 13),
            ),
            Row(
              children: [
                TextButton(onPressed: ride.dismissToll, child: const Text('Not now')),
                const Spacer(),
                FilledButton(onPressed: ride.addTollAsHalt, child: const Text('Add as halt')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class RiderMark {
  const RiderMark(this.color, this.icon);

  final Color color;
  final IconData icon;
}

const riderMarks = <RiderMark>[
  RiderMark(Color(0xFFE11D48), Icons.two_wheeler),
  RiderMark(Color(0xFF7C3AED), Icons.pedal_bike),
  RiderMark(Color(0xFF0F766E), Icons.electric_scooter),
  RiderMark(Color(0xFFC2410C), Icons.sports_motorsports),
  RiderMark(Color(0xFF0369A1), Icons.directions_bike),
  RiderMark(Color(0xFFA16207), Icons.moped),
];

class _NavArrowPainter extends CustomPainter {
  const _NavArrowPainter();

  @override
  void paint(Canvas canvas, Size size) => paintNavArrow(canvas, size.shortestSide);

  @override
  bool shouldRepaint(_NavArrowPainter oldDelegate) => false;
}
