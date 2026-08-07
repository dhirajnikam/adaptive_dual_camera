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
  });

  final int frontTextureId;
  final int backTextureId;

  /// Sensor rotation in degrees; 0 on iOS, where the connection already
  /// delivers portrait frames.
  final int frontRotation;
  final int backRotation;
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
    } on PlatformException {
      return _cached = false;
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
      );
    } catch (_) {
      // A device that claimed support and then failed to deliver it. The
      // native side has already released whatever it opened.
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
