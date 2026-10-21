import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

export 'package:geolocator/geolocator.dart' show LocationPermission, Position;

/// Wraps the device GPS so RideController never calls Geolocator directly.
abstract class LocationService {
  Future<LocationPermission> ensurePermission();
  Future<Position> currentPosition();
  Stream<Position> positionStream();
}

/// Geolocator everywhere. On Android, the stream also runs as a foreground
/// service with a persistent notification (geolocator_android starts that
/// service itself, no native code needed here), so tracking survives a
/// locked screen. Other platforms, including web, get the plain
/// foreground-only stream Geolocator already gives them there.
class DeviceLocationService implements LocationService {
  const DeviceLocationService();

  @override
  Future<LocationPermission> ensurePermission() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission;
  }

  @override
  Future<Position> currentPosition() => Geolocator.getCurrentPosition();

  @override
  Stream<Position> positionStream() {
    return Geolocator.getPositionStream(locationSettings: _settings());
  }

  LocationSettings _settings() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 0);
    }
    return AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'ZenRides is tracking this ride',
        notificationText: 'The pack can see you until you pause or end the ride.',
        notificationChannelName: 'Ride tracking',
      ),
    );
  }
}
