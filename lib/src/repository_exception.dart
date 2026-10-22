/// Thrown by every feature repository (auth, pack, ride, navigation) so
/// callers never need to know which backend call failed.
class RideApiException implements Exception {
  RideApiException(this.message);
  final String message;
  @override
  String toString() => message;
}
