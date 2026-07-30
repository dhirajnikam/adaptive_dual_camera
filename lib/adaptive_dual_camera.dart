/// Front and back capture with one API — simultaneously where the hardware
/// allows it, sequentially everywhere else.
library;

import 'adaptive_dual_camera_platform_interface.dart';
import 'src/controller.dart';
import 'src/models.dart';

export 'src/controller.dart' show DualCameraController;
export 'src/labels.dart' show DualCameraLabels;
export 'src/layout.dart'
    show DualLayout, DualLayoutBuilder, DualLayoutStyle, DualLayoutView;
export 'src/models.dart'
    show
        DualCamera,
        DualCameraStatus,
        DualCapture,
        DualCaptureMode,
        DualCaptureStage,
        DualFeed,
        DualMedia,
        DualRecording,
        DualSecondPass,
        DualSession,
        DualStorage;
export 'src/widgets.dart'
    show DualCameraFeed, DualCameraPreview, DualCaptureView;

/// One-shot capture, no preview and no lifecycle to manage.
///
/// Each call opens the camera(s), captures, and closes them again — convenient,
/// but it pays the open cost every time. If you're showing a viewfinder or
/// capturing more than once, use [DualCameraController] directly.
class AdaptiveDualCamera {
  const AdaptiveDualCamera({this.storage = const DualStorage()});

  /// Where captures are moved to once written. See [DualStorage].
  final DualStorage storage;

  /// Whether this device can run both cameras at once.
  Future<bool> isSimultaneousSupported() =>
      AdaptiveDualCameraPlatform.instance.isSimultaneousSupported();

  /// Prompts for camera permission (and the microphone, if [microphone]) when
  /// undecided. Returns whether everything asked for is granted.
  Future<bool> requestPermission({bool microphone = false}) =>
      AdaptiveDualCameraPlatform.instance.requestPermission(
        microphone: microphone,
      );

  /// Takes one photo per camera.
  Future<DualCapture> capture({bool forceSequential = false}) =>
      _withController(
        forceSequential: forceSequential,
        (controller) => controller.capturePhoto(),
      );

  /// Records [duration] of video per camera.
  ///
  /// On sequential hardware this takes roughly `2 * duration + frontLeadIn`:
  /// the back clip, a pause for the user to turn around, then the front clip.
  /// With no preview on screen there's nothing to show a countdown in, so
  /// [frontLeadIn] defaults to zero here — use [DualCameraController] directly
  /// if you want to surface it. See [DualRecording].
  Future<DualRecording> record(
    Duration duration, {
    bool audio = true,
    bool forceSequential = false,
    Duration frontLeadIn = Duration.zero,
  }) => _withController(forceSequential: forceSequential, (controller) async {
    await controller.startRecording(audio: audio);
    await Future<void>.delayed(duration);
    return controller.stopRecording(frontLeadIn: frontLeadIn);
  });

  Future<T> _withController<T>(
    Future<T> Function(DualCameraController) body, {
    required bool forceSequential,
  }) async {
    final controller = DualCameraController(storage: storage);
    try {
      await controller.initialize(forceSequential: forceSequential);
      return await body(controller);
    } finally {
      await controller.dispose();
    }
  }
}
