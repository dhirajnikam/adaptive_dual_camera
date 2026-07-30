import 'dart:io';

/// Which physical camera a value refers to.
enum DualCamera { back, front }

/// How a capture was actually produced.
enum DualCaptureMode {
  /// Both cameras were open at once (Android concurrent cameras / iOS multi-cam).
  simultaneous,

  /// One camera at a time.
  sequential,
}

/// One front photo and one back photo.
class DualCapture {
  const DualCapture({
    required this.front,
    required this.back,
    required this.mode,
  });

  /// JPEG in the app's cache directory. Delete it when you're done.
  final File front;

  /// JPEG in the app's cache directory. Delete it when you're done.
  final File back;

  final DualCaptureMode mode;

  bool get isSimultaneous => mode == DualCaptureMode.simultaneous;

  File operator [](DualCamera camera) =>
      camera == DualCamera.back ? back : front;

  @override
  String toString() =>
      'DualCapture(${mode.name}, back: ${back.path}, front: ${front.path})';
}

/// One front clip and one back clip.
///
/// In [DualCaptureMode.sequential] the two clips cover *different* moments:
/// the back clip is the recording session, the front clip is re-recorded for
/// the same duration immediately afterwards. Only [DualCaptureMode.simultaneous]
/// clips are of the same instant.
class DualRecording {
  const DualRecording({
    required this.front,
    required this.back,
    required this.mode,
    required this.duration,
  });

  /// MP4 in the app's cache directory. Silent — see [back].
  final File front;

  /// MP4 in the app's cache directory. Carries the audio track, if any.
  final File back;

  final DualCaptureMode mode;

  /// How long the back clip ran. The front clip targets the same length.
  final Duration duration;

  bool get isSimultaneous => mode == DualCaptureMode.simultaneous;

  File operator [](DualCamera camera) =>
      camera == DualCamera.back ? back : front;

  @override
  String toString() =>
      'DualRecording(${mode.name}, ${duration.inMilliseconds}ms, '
      'back: ${back.path}, front: ${front.path})';
}

/// What the controller is doing right now.
enum DualCameraStatus { uninitialized, ready, capturing, recording, disposed }

/// Which camera(s) the current operation is working on.
///
/// On sequential hardware one `capturePhoto()` goes [back] then [front], and
/// one record cycle does the same — drive your "Taking back photo…" /
/// "Recording front…" messaging off this. Always [both] on simultaneous
/// hardware, where there is no intermediate step to report.
enum DualCaptureStage {
  idle,
  both,
  back,
  front;

  /// The camera being worked on, or null for [idle] and [both].
  DualCamera? get camera => switch (this) {
    DualCaptureStage.back => DualCamera.back,
    DualCaptureStage.front => DualCamera.front,
    _ => null,
  };
}

/// What a captured file holds.
enum DualMedia { photo, video }

/// Where captures end up, and what they're called.
///
/// By default the native side writes into the app's **cache directory** as
/// `adc_<camera>_<nanoseconds>.jpg` / `.mp4` and nothing ever cleans up — the
/// OS may evict cache files, so treat them as temporary and move or delete
/// what you want to keep.
///
/// Set [directory] to have the plugin relocate each capture as soon as it
/// lands, and [nameBuilder] to control the filename:
///
/// ```dart
/// DualCameraController(
///   storage: DualStorage(
///     directory: await getApplicationDocumentsDirectory(), // your own dep
///     nameBuilder: (camera, media, at) =>
///         '${at.toIso8601String().replaceAll(':', '-')}_${camera.name}'
///         '${media == DualMedia.photo ? '.jpg' : '.mp4'}',
///   ),
/// );
/// ```
///
/// The plugin deliberately doesn't depend on `path_provider` — pass whatever
/// [Directory] your app already knows about.
class DualStorage {
  const DualStorage({this.directory, this.nameBuilder});

  /// Created if missing. Null leaves captures in the cache directory.
  final Directory? directory;

  /// Builds a filename, extension included. Null keeps the generated one.
  final String Function(DualCamera camera, DualMedia media, DateTime at)?
  nameBuilder;

  /// Whether this would move or rename anything.
  bool get isDefault => directory == null && nameBuilder == null;
}

/// Progress through the front-camera retake on sequential hardware.
///
/// Sequential video can't capture both cameras at once, so the front clip is
/// recorded after the back one. This is what drives the UI through that: a
/// lead-in the user can get ready during, then the retake itself.
class DualSecondPass {
  const DualSecondPass({
    required this.rolling,
    required this.elapsed,
    required this.total,
  });

  /// False while counting down to the retake, true once the front camera is
  /// actually recording.
  final bool rolling;

  final Duration elapsed;

  /// The lead-in length while counting down, then the back clip's length.
  final Duration total;

  Duration get remaining {
    final left = total - elapsed;
    return left.isNegative ? Duration.zero : left;
  }

  /// 0..1 through the current step.
  double get progress => total <= Duration.zero
      ? 1
      : (elapsed.inMicroseconds / total.inMicroseconds).clamp(0.0, 1.0);

  @override
  String toString() =>
      'DualSecondPass(${rolling ? 'recording' : 'lead-in'}, '
      '${elapsed.inMilliseconds}/${total.inMilliseconds}ms)';
}

/// What the native side reports after opening cameras.
class DualSession {
  const DualSession({required this.mode, required this.feeds});

  final DualCaptureMode mode;

  /// Live feeds, keyed by camera. In [DualCaptureMode.sequential] only one
  /// camera is live at a time, so this holds a single entry.
  final Map<DualCamera, DualFeed> feeds;

  @override
  String toString() =>
      'DualSession(${mode.name}, live: ${feeds.keys.map((c) => c.name)})';
}

/// A live camera feed's texture and the geometry needed to draw it upright.
class DualFeed {
  const DualFeed({
    required this.textureId,
    required this.width,
    required this.height,
    required this.sensorOrientation,
    required this.mirrored,
  });

  final int textureId;

  /// Native buffer size, in sensor orientation (before [sensorOrientation] is applied).
  final int width;
  final int height;

  /// Degrees the texture must be rotated clockwise to appear upright in portrait.
  final int sensorOrientation;

  /// Whether the feed should be flipped horizontally (selfie view).
  final bool mirrored;

  /// Aspect ratio after rotation, ready for an [AspectRatio] widget.
  double get displayAspectRatio {
    final sideways = sensorOrientation % 180 != 0;
    return sideways ? height / width : width / height;
  }

  @override
  String toString() =>
      'DualFeed($textureId, ${width}x$height, ${sensorOrientation}deg'
      '${mirrored ? ', mirrored' : ''})';
}
