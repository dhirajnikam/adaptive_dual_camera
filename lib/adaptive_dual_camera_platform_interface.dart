import 'dart:io';

import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'adaptive_dual_camera_method_channel.dart';
import 'src/models.dart';

abstract class AdaptiveDualCameraPlatform extends PlatformInterface {
  /// Constructs a AdaptiveDualCameraPlatform.
  AdaptiveDualCameraPlatform() : super(token: _token);

  static final Object _token = Object();

  static AdaptiveDualCameraPlatform _instance =
      MethodChannelAdaptiveDualCamera();

  /// The default instance of [AdaptiveDualCameraPlatform] to use.
  ///
  /// Defaults to [MethodChannelAdaptiveDualCamera].
  static AdaptiveDualCameraPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [AdaptiveDualCameraPlatform] when
  /// they register themselves.
  static set instance(AdaptiveDualCameraPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<bool> isSimultaneousSupported() {
    throw UnimplementedError(
      'isSimultaneousSupported() has not been implemented.',
    );
  }

  Future<bool> requestPermission({bool microphone = false}) {
    throw UnimplementedError('requestPermission() has not been implemented.');
  }

  Future<DualSession> initialize({bool forceSequential = false}) {
    throw UnimplementedError('initialize() has not been implemented.');
  }

  /// Points the single live session at [camera]. Sequential mode only.
  Future<DualSession> activate(DualCamera camera) {
    throw UnimplementedError('activate() has not been implemented.');
  }

  /// Shoots [cameras] in one native round trip. Multi-camera requests are only
  /// honoured in simultaneous mode; sequential callers pass one at a time so
  /// they can report progress between shots.
  Future<({DualCaptureMode mode, Map<DualCamera, File> files})> capturePhoto({
    required List<DualCamera> cameras,
  }) {
    throw UnimplementedError('capturePhoto() has not been implemented.');
  }

  /// Returns the session as it stands once recording starts — the native side
  /// may have dropped to a single camera if two video streams wouldn't configure.
  Future<DualSession> startRecording({
    required List<DualCamera> cameras,
    bool audio = true,
  }) {
    throw UnimplementedError('startRecording() has not been implemented.');
  }

  Future<Map<DualCamera, File>> stopRecording() {
    throw UnimplementedError('stopRecording() has not been implemented.');
  }

  Future<void> release() {
    throw UnimplementedError('release() has not been implemented.');
  }
}
