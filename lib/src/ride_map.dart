import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:latlong2/latlong.dart';

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
  gmaps.BitmapDescriptor? _hazardIcon;
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

  RideController get ride => widget.ride;

  @override
  void initState() {
    super.initState();
    ride.addListener(_onRide);
    if (kIsWeb) {
      _loadRiderIcons();
      _loadFuelIcon();
      _loadHazardIcon();
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
    if (ride.gpsLocked && !_gpsWasLocked) _follow = true;
    _gpsWasLocked = ride.gpsLocked;
    if (ride.pumpFit != _seenPumps && ride.pumps.isNotEmpty && _fit(ride.pumps.map((pump) => pump.point).toList())) {
      _seenPumps = ride.pumpFit;
      _follow = false;
    }
    if (ride.routeFit != _seenRoute && ride.routes.isNotEmpty) {
      final chosen = ride.routes[ride.selectedRoute.clamp(0, ride.routes.length - 1)];
      if (_fit(chosen.points)) {
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
    if (_ready && _follow && !ride.planning) {
      if (ride.navigating) {
        _moveTo(ride.you, zoom: 17, bearing: ride.bearing, tilt: 50);
      } else {
        _moveTo(ride.you);
      }
    }
    if (kIsWeb) _ensureArrow(((_screenHeading() / 5).round() * 5) % 360);
    setState(() {});
  }

  bool _fit(List<LatLng> points) {
    if (points.length < 2) return false;
    if (kIsWeb && _google == null) return false;
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

  Future<void> _loadHazardIcon() async {
    final icon = await _badgeMarker(Icons.warning_amber, const Color(0xFFC2410C));
    if (!mounted) return;
    setState(() => _hazardIcon = icon);
  }

  Future<void> _loadFuelIcon() async {
    final icon = await _badgeMarker(Icons.local_gas_station, const Color(0xFFE11D2E));
    if (!mounted) return;
    setState(() => _fuelIcon = icon);
  }

  Future<gmaps.BitmapDescriptor> _badgeMarker(IconData icon, Color color) async {
    const size = 96.0;
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
    painter.paint(canvas, Offset((size - painter.width) / 2, (size - painter.height) / 2));
    final image = await recorder.endRecording().toImage(size.toInt(), size.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return gmaps.BitmapDescriptor.bytes(bytes!.buffer.asUint8List(), width: 42, height: 42);
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
    for (final halt in ride.visibleHalts) {
      markers.add(gmaps.Marker(
        markerId: gmaps.MarkerId(halt.id),
        position: _g(halt.point),
        infoWindow: gmaps.InfoWindow(title: halt.name),
        icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(gmaps.BitmapDescriptor.hueOrange),
      ));
    }
    for (final pump in ride.pumps) {
      markers.add(gmaps.Marker(
        markerId: gmaps.MarkerId(pump.id),
        position: _g(pump.point),
        infoWindow: gmaps.InfoWindow(title: pump.name),
        icon: _fuelIcon ?? gmaps.BitmapDescriptor.defaultMarkerWithHue(gmaps.BitmapDescriptor.hueRose),
      ));
    }
    if (ride.routes.isNotEmpty) {
      final chosen = ride.routes[ride.selectedRoute.clamp(0, ride.routes.length - 1)];
      final end = chosen.points.last;
      markers.add(gmaps.Marker(
        markerId: const gmaps.MarkerId('destination'),
        position: _g(end),
        infoWindow: gmaps.InfoWindow(title: ride.destinationName),
        icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(gmaps.BitmapDescriptor.hueViolet),
      ));
    }
    for (final rider in ride.mapRiders) {
      if (rider.you) {
        final deg = ((_screenHeading() / 5).round() * 5) % 360;
        markers.add(gmaps.Marker(
          markerId: gmaps.MarkerId(rider.id),
          position: _g(rider.point),
          infoWindow: const gmaps.InfoWindow(title: 'YOU'),
          icon: _arrows[deg] ??
              _arrows[0] ??
              gmaps.BitmapDescriptor.defaultMarkerWithHue(gmaps.BitmapDescriptor.hueAzure),
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
    for (final hazard in ride.roadHazards) {
      final point = hazard.point;
      if (point == null) continue;
      markers.add(gmaps.Marker(
        markerId: gmaps.MarkerId('hazard-${hazard.id}'),
        position: _g(point),
        infoWindow: gmaps.InfoWindow(title: hazard.title, snippet: hazard.detail),
        icon: _hazardIcon ?? gmaps.BitmapDescriptor.defaultMarkerWithHue(gmaps.BitmapDescriptor.hueOrange),
        zIndexInt: 3,
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
    if (ride.routes.isEmpty) {
      if (ride.planning) return {};
      return {
        gmaps.Polyline(
          polylineId: const gmaps.PolylineId('route'),
          color: const Color(0xFF2563EB),
          width: 5,
          points: [for (final point in RideController.route) _g(point)],
        ),
      };
    }
    if (ride.navigating) {
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
    return {
      for (var i = 0; i < ride.routes.length; i++)
        gmaps.Polyline(
          polylineId: gmaps.PolylineId('drive-$i'),
          color: i == ride.selectedRoute ? const Color(0xFF1D4ED8) : const Color(0xFF94A3B8),
          width: i == ride.selectedRoute ? 6 : 4,
          zIndex: i == ride.selectedRoute ? 2 : 1,
          consumeTapEvents: true,
          onTap: () => ride.selectRoute(i),
          points: [for (final point in ride.routes[i].points) _g(point)],
        ),
    };
  }

  List<Polyline> _mapLines() {
    if (ride.routes.isEmpty) {
      if (ride.planning) return [];
      return [
        Polyline(points: RideController.route, color: const Color(0xFF1E3A8A), strokeWidth: 6),
        Polyline(points: RideController.route, color: const Color(0xFF2563EB), strokeWidth: 3),
      ];
    }
    return [
      for (var i = 0; i < ride.routes.length; i++)
        Polyline(
          points: ride.routes[i].points,
          color: i == ride.selectedRoute ? const Color(0xFF1D4ED8) : const Color(0xFF94A3B8),
          strokeWidth: i == ride.selectedRoute ? 5 : 3,
        ),
    ];
  }

  Widget _googleMap(SosFix? sos) {
    return gmaps.GoogleMap(
      initialCameraPosition: gmaps.CameraPosition(target: _g(ride.you), zoom: RideController.overviewZoom),
      onMapCreated: (controller) {
        _google = controller;
        _ready = true;
      },
      onTap: (point) {
        if (ride.picking) ride.dropHalt(LatLng(point.latitude, point.longitude));
      },
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final sos = ride.visibleSos;
    return Stack(
      children: [
        if (kIsWeb)
          _googleMap(sos)
        else
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: ride.you,
            initialZoom: RideController.overviewZoom,
            onMapReady: () => _ready = true,
            onTap: (_, point) {
              if (ride.picking) ride.dropHalt(point);
            },
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
                for (final halt in ride.visibleHalts)
                  _pin(halt.point, _label(halt.name, const Color(0xFFB45309))),
                for (final pump in ride.pumps)
                  _pin(
                    pump.point,
                    _dot(const Color(0xFFE11D2E), Icons.local_gas_station, pump.name),
                  ),
                for (final rider in ride.mapRiders)
                  if (!rider.you)
                    _pin(
                      rider.point,
                      _dot(riderMarks[rider.mark].color, riderMarks[rider.mark].icon, rider.name),
                    ),
                for (final hazard in ride.roadHazards)
                  if (hazard.point != null)
                    _pin(
                      hazard.point!,
                      _dot(const Color(0xFFC2410C), Icons.warning_amber, hazard.title),
                    ),
                if (sos != null)
                  _pin(
                    LatLng(sos.lat, sos.lng),
                    _label('SOS', const Color(0xFFC81E1E)),
                  ),
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
        if (!ride.planning && ride.navigating)
          Positioned(
            left: 8,
            right: 8,
            top: 8,
            child: _NavBanner(ride: ride),
          )
        else if (!ride.planning)
          Positioned(
            left: 8,
            right: 8,
            top: 8,
            child: PointerInterceptor(child: _DirectionsSearch(ride: ride)),
          ),
        if (ride.planning && ride.picking)
          const Positioned(
            left: 8,
            top: 8,
            child: DecoratedBox(
              decoration: BoxDecoration(color: Color(0xFF0F172A), borderRadius: BorderRadius.all(Radius.circular(16))),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Text('Tap the road', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12)),
              ),
            ),
          ),
        if (!ride.planning && !ride.navigating)
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
                ride.gpsSeeking ? 'GPS…' : (ride.gpsFix == null ? 'GPS off' : 'GPS live'),
                ride.requestGps,
              ),
            ],
          ),
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
        else if (ride.routes.isNotEmpty)
          Positioned(
            left: 8,
            right: 72,
            bottom: 8,
            child: _RouteChoices(ride: ride),
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
        if (!ride.planning)
        Positioned(
          right: 12,
          bottom: ride.navigating ? 58 : (ride.routes.isNotEmpty ? 156 : 16),
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
          child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800)),
        ),
        const SizedBox(height: 2),
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2))),
      ],
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
  String _sig = '';

  RideController get ride => widget.ride;

  @override
  void initState() {
    super.initState();
    ride.addListener(_sync);
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

class _RouteChoices extends StatelessWidget {
  const _RouteChoices({required this.ride});

  final RideController ride;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
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
            color: selected ? const Color(0xFF0F172A) : Colors.white,
            elevation: 2,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => ride.selectRoute(index),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      route.duration.isEmpty ? 'Route ${index + 1}' : route.duration,
                      style: TextStyle(fontWeight: FontWeight.w900, color: selected ? Colors.white : const Color(0xFF0F172A)),
                    ),
                    Text(
                      '${route.distance} · ${route.summary}',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: selected ? Colors.white70 : const Color(0xFF64748B)),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
          ),
        ),
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
