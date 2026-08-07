import 'package:camera/camera.dart' show XFile;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What a running native session exposes: one Flutter texture per camera,
/// plus the rotation Dart has to apply to each preview.
class NativeDualPreview {
  const NativeDualPreview({
    required this.frontTextureId,
    required this.backTextureId,
    required this.frontRotation,
    required this.backRotation,
    this.frontWidth = 1080,
    this.frontHeight = 1440,
    this.backWidth = 1080,
    this.backHeight = 1440,
  });

  final int frontTextureId;
  final int backTextureId;

  /// Sensor rotation in degrees; 0 on iOS, where the connection already
  /// delivers portrait frames.
  final int frontRotation;
  final int backRotation;

  /// Texture dimensions in pixels, BEFORE the rotation above is applied —
  /// Android reports the sensor-oriented preview size here. The previews
  /// must be laid out at this aspect or the image is stretched. iOS omits
  /// them and gets the 3:4 portrait default its connection delivers.
  final int frontWidth;
  final int frontHeight;
  final int backWidth;
  final int backHeight;
}

/// The simultaneous capture path, which is the package's only native code.
///
/// Android runs a CameraX concurrent session
/// (`CameraManager.getConcurrentCameraIds` decides support); iOS runs an
/// `AVCaptureMultiCamSession` (A12 / iOS 13 and later). Each camera's preview
/// arrives as a Flutter texture and each still is written as its own JPEG —
/// there is no native compositor, because Dart composes the final layout so
/// that both capture paths produce the same image.
///
/// The sequential path does not come through here at all; it is the official
/// `camera` plugin, in pure Dart.
///
/// Anywhere the plugin isn't registered — web, desktop, a unit test — support
/// is reported as `false` rather than throwing, so callers never have to
/// guard the call.
class DualCameraSupport {
  const DualCameraSupport._();

  static const _channel = MethodChannel('adaptive_dual_camera/support');

  /// Cached because the answer is a hardware fact that cannot change while
  /// the app is running, and the flow asks on every capture.
  static bool? _cached;

  /// True when the device can hold both cameras open at once.
  ///
  /// A true answer is not a promise: the cameras can still be busy, hot, or
  /// claimed by another app. [startSimultaneous] is what actually settles it,
  /// and the flow falls back to sequential if that fails.
  static Future<bool> supportsSimultaneousCapture() async {
    if (_cached != null) return _cached!;
    try {
      final supported = await _channel.invokeMethod<bool>(
        'supportsConcurrentCameras',
      );
      return _cached = supported ?? false;
    } on MissingPluginException {
      return _cached = false; // unsupported platform, or a test
    } on PlatformException catch (e) {
      debugPrint('adaptive_dual_camera: support probe failed: $e');
      return _cached = false;
    }
  }

  /// Settle the OS camera permission before [startSimultaneous] binds the
  /// cameras natively — nothing else on the simultaneous path ever shows the
  /// dialog (the `camera` plugin only asks when *it* opens a camera, which
  /// the native session bypasses). Returns false only on an explicit denial.
  static Future<bool> ensureCameraPermission() async {
    try {
      // Only an explicit false is a denial; a null answer (older native
      // implementation, or a test) lets the start attempt settle it.
      return await _channel.invokeMethod<bool>('ensureCameraPermission') !=
          false;
    } on MissingPluginException {
      return true; // no native side — the `camera` plugin will ask instead
    } on PlatformException {
      return true;
    }
  }

  /// Bring both cameras up and start streaming into two textures.
  ///
  /// Returns null when the session can't be established, which is the signal
  /// to fall back to the sequential flow. Never throws.
  static Future<NativeDualPreview?> startSimultaneous() async {
    try {
      final info = await _channel.invokeMapMethod<String, dynamic>(
        'startConcurrent',
      );
      if (info == null) return null;
      return NativeDualPreview(
        frontTextureId: info['frontTextureId'] as int,
        backTextureId: info['backTextureId'] as int,
        frontRotation: (info['frontRotation'] as int?) ?? 0,
        backRotation: (info['backRotation'] as int?) ?? 0,
        frontWidth: (info['frontWidth'] as int?) ?? 1080,
        frontHeight: (info['frontHeight'] as int?) ?? 1440,
        backWidth: (info['backWidth'] as int?) ?? 1080,
        backHeight: (info['backHeight'] as int?) ?? 1440,
      );
    } catch (e) {
      // A device that claimed support and then failed to deliver it. The
      // native side has already released whatever it opened. Say why in
      // debug builds — this used to vanish silently, which made "why did it
      // fall back?" undiagnosable.
      debugPrint('adaptive_dual_camera: startConcurrent failed: $e');
      return null;
    }
  }

  /// Fire both shutters together. Returns `(front, back)`, or null if either
  /// half failed — a half-simultaneous result is worse than none.
  static Future<({XFile front, XFile back})?> captureBoth() async {
    try {
      final paths = await _channel.invokeMapMethod<String, dynamic>(
        'captureBoth',
      );
      if (paths == null) return null;
      final front = paths['frontPath'] as String?;
      final back = paths['backPath'] as String?;
      if (front == null || back == null) return null;
      return (front: XFile(front), back: XFile(back));
    } catch (_) {
      return null;
    }
  }

  /// Release both cameras. Safe to call when nothing is running.
  static Future<void> stopSimultaneous() async {
    try {
      await _channel.invokeMethod<void>('stopConcurrent');
    } catch (_) {
      // Nothing to release, or the engine is already gone.
    }
  }

  /// Forget the cached support answer. Only useful in tests.
  @visibleForTesting
  static void resetCache() => _cached = null;
}
