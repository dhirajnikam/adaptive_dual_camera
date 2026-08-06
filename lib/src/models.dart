import 'package:camera/camera.dart';

/// Everything one guided capture session produces.
class DualShotResult {
  const DualShotResult({
    required this.frontPhoto,
    required this.backPhoto,
    required this.timestamp,
    this.latitude,
    this.longitude,
  });

  final XFile frontPhoto;
  final XFile backPhoto;
  final DateTime timestamp;

  /// Null when location is off, denied, or timed out — the shot still succeeds.
  final double? latitude;
  final double? longitude;

  bool get hasLocation => latitude != null && longitude != null;
}
