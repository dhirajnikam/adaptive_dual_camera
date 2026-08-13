import 'package:camera/camera.dart';

/// How the two photos should be taken.
enum DualCaptureMode {
  /// Try both cameras at once; fall back to one-after-the-other when the
  /// device can't run them concurrently. The default.
  auto,

  /// Never open two cameras at once. Safest on old and low-RAM phones, where
  /// a second camera pipeline competes for memory.
  sequential,
}

/// Everything one guided capture session produces.
class DualShotResult {
  const DualShotResult({
    required this.frontPhoto,
    required this.backPhoto,
    required this.timestamp,
    this.latitude,
    this.longitude,
    this.wasSimultaneous = false,
    this.composedPhoto,
  });

  final XFile frontPhoto;
  final XFile backPhoto;
  final DateTime timestamp;

  /// The finished layout as one PNG — back photo with the selfie, map and
  /// stamp under it, exactly what [DualShotView] renders. The flow composes
  /// it before handing the result over; null only when
  /// [GuidedDualCaptureFlow.compose] was set to null, or composing failed
  /// (the two photos above are still good).
  final XFile? composedPhoto;

  DualShotResult withComposed(XFile composed) => DualShotResult(
    frontPhoto: frontPhoto,
    backPhoto: backPhoto,
    timestamp: timestamp,
    latitude: latitude,
    longitude: longitude,
    wasSimultaneous: wasSimultaneous,
    composedPhoto: composed,
  );

  /// True when the device ran both cameras at once, so the two photos are
  /// milliseconds apart rather than seconds. Apps that need the shots to
  /// prove "same moment" should check this.
  final bool wasSimultaneous;

  /// Null when location is off, denied, or timed out — the shot still succeeds.
  final double? latitude;
  final double? longitude;

  bool get hasLocation => latitude != null && longitude != null;
}
