import 'controller.dart';
import 'models.dart';

/// Every string the plugin can put in front of a user, in one overridable set.
///
/// Nothing here is shown automatically — the plugin renders no text of its
/// own. [statusFor] turns the controller's current state into the one line
/// worth showing, and you decide how to display it:
///
/// ```dart
/// ListenableBuilder(
///   listenable: controller,
///   builder: (context, _) {
///     final message = labels.statusFor(controller);
///     return message == null ? const SizedBox() : Text(message);
///   },
/// )
/// ```
///
/// Override any subset for wording or localisation:
///
/// ```dart
/// const labels = DualCameraLabels(
///   takingBackPhoto: 'Rückkamera…',
///   retakeCountdown: 'Dreh das Handy um · noch {seconds}',
/// );
/// ```
///
/// `{seconds}` and `{camera}` are substituted where noted.
class DualCameraLabels {
  const DualCameraLabels({
    this.backCamera = 'back',
    this.frontCamera = 'front',
    this.takingBothPhotos = 'Taking photos…',
    this.takingBackPhoto = 'Taking back photo…',
    this.takingFrontPhoto = 'Taking front photo…',
    this.recordingBoth = 'Recording…',
    this.recordingBack = 'Recording back camera…',
    this.recordingFront = 'Recording front camera…',
    this.retakeCountdown =
        'Turn the camera around · front clip starts in {seconds}…',
    this.retakeRecording = 'Recording front camera — {seconds}s left',
    this.cameraNotLive = '{camera} not live',
    this.bothCamerasLive = 'Both cameras live',
    this.oneCameraLive = 'One camera at a time · live: {camera}',
  });

  /// Names for each camera. Substituted into `{camera}`.
  final String backCamera;
  final String frontCamera;

  final String takingBothPhotos;
  final String takingBackPhoto;
  final String takingFrontPhoto;

  final String recordingBoth;
  final String recordingBack;
  final String recordingFront;

  /// Sequential video retake. `{seconds}` is the whole seconds remaining.
  final String retakeCountdown;
  final String retakeRecording;

  /// Placeholder for a camera that isn't streaming. `{camera}` substituted.
  final String cameraNotLive;

  /// Descriptions of the hardware mode. `{camera}` substituted into the latter.
  final String bothCamerasLive;
  final String oneCameraLive;

  String cameraName(DualCamera camera) =>
      camera == DualCamera.back ? backCamera : frontCamera;

  /// The one line worth showing right now, or null when nothing is happening.
  ///
  /// The retake countdown and progress take priority over the capture stage,
  /// because that's the step the user has to act on.
  String? statusFor(DualCameraController controller) {
    final pass = controller.secondPass;
    if (pass != null) {
      final seconds = (pass.remaining.inMilliseconds / 1000).ceil();
      return _seconds(
        pass.rolling ? retakeRecording : retakeCountdown,
        seconds,
      );
    }

    final recording = controller.isRecording;
    return switch (controller.stage) {
      DualCaptureStage.idle => null,
      DualCaptureStage.both => recording ? recordingBoth : takingBothPhotos,
      DualCaptureStage.back => recording ? recordingBack : takingBackPhoto,
      DualCaptureStage.front => recording ? recordingFront : takingFrontPhoto,
    };
  }

  /// Describes what the hardware is doing, or null before initialisation.
  String? modeFor(DualCameraController controller) => switch (controller.mode) {
    null => null,
    DualCaptureMode.simultaneous => bothCamerasLive,
    DualCaptureMode.sequential => _camera(
      oneCameraLive,
      controller.activeCamera,
    ),
  };

  /// The placeholder text for a camera that isn't streaming.
  String notLive(DualCamera camera) => _camera(cameraNotLive, camera);

  String _camera(String template, DualCamera camera) =>
      template.replaceAll('{camera}', cameraName(camera));

  String _seconds(String template, int seconds) =>
      template.replaceAll('{seconds}', '$seconds');

  DualCameraLabels copyWith({
    String? backCamera,
    String? frontCamera,
    String? takingBothPhotos,
    String? takingBackPhoto,
    String? takingFrontPhoto,
    String? recordingBoth,
    String? recordingBack,
    String? recordingFront,
    String? retakeCountdown,
    String? retakeRecording,
    String? cameraNotLive,
    String? bothCamerasLive,
    String? oneCameraLive,
  }) => DualCameraLabels(
    backCamera: backCamera ?? this.backCamera,
    frontCamera: frontCamera ?? this.frontCamera,
    takingBothPhotos: takingBothPhotos ?? this.takingBothPhotos,
    takingBackPhoto: takingBackPhoto ?? this.takingBackPhoto,
    takingFrontPhoto: takingFrontPhoto ?? this.takingFrontPhoto,
    recordingBoth: recordingBoth ?? this.recordingBoth,
    recordingBack: recordingBack ?? this.recordingBack,
    recordingFront: recordingFront ?? this.recordingFront,
    retakeCountdown: retakeCountdown ?? this.retakeCountdown,
    retakeRecording: retakeRecording ?? this.retakeRecording,
    cameraNotLive: cameraNotLive ?? this.cameraNotLive,
    bothCamerasLive: bothCamerasLive ?? this.bothCamerasLive,
    oneCameraLive: oneCameraLive ?? this.oneCameraLive,
  );
}
