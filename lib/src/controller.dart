import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../adaptive_dual_camera_platform_interface.dart';
import 'models.dart';

/// Owns the camera session behind [DualCameraPreview].
///
/// Call [initialize] once, read [feedFor] to draw the live feeds, then
/// [capturePhoto] / [startRecording] / [stopRecording]. Call [dispose] when
/// the screen goes away — the cameras stay open until you do.
///
/// A [ChangeNotifier], so `ListenableBuilder` rebuilds on every status, feed
/// and [stage] change. On sequential hardware [stage] is what tells your user
/// which camera is being captured right now.
class DualCameraController extends ChangeNotifier {
  DualCameraController({
    AdaptiveDualCameraPlatform? platform,
    this.storage = const DualStorage(),
  }) : _platform = platform ?? AdaptiveDualCameraPlatform.instance;

  final AdaptiveDualCameraPlatform _platform;

  /// Where captures are moved to once the native side has written them.
  /// Defaults to leaving them in the cache directory — see [DualStorage].
  final DualStorage storage;

  DualCameraStatus _status = DualCameraStatus.uninitialized;
  DualCaptureMode? _mode;
  Map<DualCamera, DualFeed> _feeds = const {};
  DualCamera _activeCamera = DualCamera.back;
  DualCaptureStage _stage = DualCaptureStage.idle;
  Stopwatch? _recordingClock;
  DualSecondPass? _secondPass;
  Timer? _ticker;

  DualCameraStatus get status => _status;

  bool get isInitialized =>
      _status != DualCameraStatus.uninitialized &&
      _status != DualCameraStatus.disposed;

  bool get isBusy =>
      _status == DualCameraStatus.capturing ||
      _status == DualCameraStatus.recording;

  /// Null until [initialize] completes.
  DualCaptureMode? get mode => _mode;

  /// Whether both cameras are live at the same time on this device.
  ///
  /// Can flip to false mid-session: some devices advertise a concurrent pair
  /// for stills but can't configure two video streams, and [startRecording]
  /// drops to one camera when that happens.
  bool get isSimultaneous => _mode == DualCaptureMode.simultaneous;

  /// The feed for [camera], or null when that camera isn't currently live.
  ///
  /// In [DualCaptureMode.sequential] only [activeCamera] has a feed; render a
  /// placeholder for the other one.
  DualFeed? feedFor(DualCamera camera) => _feeds[camera];

  /// The camera currently streaming in sequential mode. Meaningless when
  /// [isSimultaneous] — both are live.
  DualCamera get activeCamera => _activeCamera;

  /// Which camera the in-flight photo or recording is on. [DualCaptureStage.idle]
  /// when nothing is running.
  DualCaptureStage get stage => _stage;

  bool get isRecording => _status == DualCameraStatus.recording;

  /// How long the current recording has been running.
  Duration get recordedDuration => _recordingClock?.elapsed ?? Duration.zero;

  /// Non-null only while sequential hardware is retaking the front clip.
  ///
  /// Ticks roughly ten times a second so a countdown and a progress bar can
  /// follow it. See [stopRecording].
  DualSecondPass? get secondPass => _secondPass;

  /// Opens the camera(s) and starts the preview stream(s).
  ///
  /// Set [forceSequential] to take the one-at-a-time path on hardware that
  /// could do better — useful for exercising the fallback.
  ///
  /// Throws `PlatformException(code: 'permission_denied')` if camera
  /// permission hasn't been granted; call [requestPermission] first.
  Future<void> initialize({bool forceSequential = false}) async {
    if (_status != DualCameraStatus.uninitialized) {
      throw StateError('initialize() called while $_status.');
    }
    _apply(await _platform.initialize(forceSequential: forceSequential));
    _activeCamera = _feeds.isEmpty ? DualCamera.back : _feeds.keys.first;
    _set(DualCameraStatus.ready);
  }

  /// Prompts for camera permission (and the microphone, if [microphone]) when
  /// undecided. Returns whether everything asked for is granted.
  Future<bool> requestPermission({bool microphone = false}) =>
      _platform.requestPermission(microphone: microphone);

  /// Switches which camera is live. Sequential mode only — a no-op when both
  /// feeds are already running.
  Future<void> switchTo(DualCamera camera) async {
    _requireReady('switchTo');
    await _activate(camera);
  }

  /// Takes one photo per camera.
  ///
  /// Simultaneous hardware shoots both at once. Everything else shoots the
  /// back camera, then the front, moving the live preview with it and
  /// reporting each step through [stage] — watch it to tell your user which
  /// photo is being taken. The preview is left on whichever camera it started on.
  Future<DualCapture> capturePhoto() async {
    _requireReady('capturePhoto');
    _set(DualCameraStatus.capturing);
    final restore = _activeCamera;
    try {
      if (isSimultaneous) {
        _to(DualCaptureStage.both);
        final shot = await _platform.capturePhoto(cameras: DualCamera.values);
        return _placePhotos(
          DualCapture(
            back: _require(shot.files, DualCamera.back, 'photo'),
            front: _require(shot.files, DualCamera.front, 'photo'),
            mode: shot.mode,
          ),
        );
      }

      final taken = <DualCamera, File>{};
      for (final camera in DualCamera.values) {
        _to(
          camera == DualCamera.back
              ? DualCaptureStage.back
              : DualCaptureStage.front,
        );
        await _activate(camera);
        final shot = await _platform.capturePhoto(cameras: [camera]);
        taken[camera] = _require(shot.files, camera, 'photo');
      }
      return _placePhotos(
        DualCapture(
          back: taken[DualCamera.back]!,
          front: taken[DualCamera.front]!,
          mode: DualCaptureMode.sequential,
        ),
      );
    } finally {
      _stage = DualCaptureStage.idle;
      if (_status != DualCameraStatus.disposed) {
        await _activate(restore);
        _set(DualCameraStatus.ready);
      }
    }
  }

  /// Starts recording.
  ///
  /// Simultaneous hardware records both cameras at once. Everything else
  /// records the **back camera only** for now; [stopRecording] then re-records
  /// the front for the same duration. [stage] says which one is rolling.
  ///
  /// [audio] adds a microphone track to the back clip. The front clip is
  /// always silent — two recorders can't share the mic. Requires microphone
  /// permission; call `requestPermission(microphone: true)` first.
  Future<void> startRecording({bool audio = true}) async {
    _requireReady('startRecording');
    if (!isSimultaneous) await _activate(DualCamera.back);
    final cameras = isSimultaneous
        ? DualCamera.values
        : const [DualCamera.back];
    // The native side can degrade to one camera here, so trust what comes back
    // rather than what we asked for.
    _apply(await _platform.startRecording(cameras: cameras, audio: audio));
    _recordingClock = Stopwatch()..start();
    _stage = isSimultaneous ? DualCaptureStage.both : DualCaptureStage.back;
    _set(DualCameraStatus.recording);
  }

  /// Stops recording and returns both clips.
  ///
  /// On simultaneous hardware this returns as soon as both clips are written.
  ///
  /// On sequential hardware it does **not**: the front camera can only record
  /// after the back one, so this switches over and retakes the same duration.
  /// The whole retake is reported through [secondPass] — first a [frontLeadIn]
  /// countdown so the user can turn the phone around and get ready, then the
  /// recording itself with progress — and [stage] stays on
  /// [DualCaptureStage.front] throughout. Budget `frontLeadIn + duration` on
  /// top of the recording you just took.
  ///
  /// Pass `frontLeadIn: Duration.zero` to go straight into the retake.
  Future<DualRecording> stopRecording({
    Duration frontLeadIn = const Duration(seconds: 3),
  }) async {
    if (_status != DualCameraStatus.recording) {
      throw StateError('stopRecording() called while not recording.');
    }
    final duration = (_recordingClock!..stop()).elapsed;

    try {
      final first = await _platform.stopRecording();

      if (isSimultaneous) {
        return _placeClips(
          DualRecording(
            back: _require(first, DualCamera.back, 'recording'),
            front: _require(first, DualCamera.front, 'recording'),
            mode: DualCaptureMode.simultaneous,
            duration: duration,
          ),
        );
      }

      final back = _require(first, DualCamera.back, 'recording');

      // Second pass: swap to the front camera, let the user get set, retake.
      _to(DualCaptureStage.front);
      await _activate(DualCamera.front);
      await _countdown(frontLeadIn, rolling: false);
      if (_status == DualCameraStatus.disposed) {
        throw StateError('Controller was disposed during the front retake.');
      }
      await _platform.startRecording(
        cameras: const [DualCamera.front],
        audio: false,
      );
      await _countdown(duration, rolling: true);
      final second = await _platform.stopRecording();

      return _placeClips(
        DualRecording(
          back: back,
          front: _require(second, DualCamera.front, 'recording'),
          mode: DualCaptureMode.sequential,
          duration: duration,
        ),
      );
    } finally {
      _ticker?.cancel();
      _ticker = null;
      _secondPass = null;
      _recordingClock = null;
      _stage = DualCaptureStage.idle;
      if (_status != DualCameraStatus.disposed) _set(DualCameraStatus.ready);
    }
  }

  /// Closes the cameras and frees the preview textures.
  @override
  Future<void> dispose() async {
    if (_status == DualCameraStatus.disposed) return;
    _status = DualCameraStatus.disposed;
    _ticker?.cancel();
    _ticker = null;
    _secondPass = null;
    _feeds = const {};
    _recordingClock = null;
    _stage = DualCaptureStage.idle;
    super.dispose();
    await _platform.release();
  }

  // --- internals ----------------------------------------------------------

  /// Runs out [total], publishing [secondPass] about ten times a second.
  Future<void> _countdown(Duration total, {required bool rolling}) async {
    void publish(Duration elapsed) {
      _secondPass = DualSecondPass(
        rolling: rolling,
        elapsed: elapsed,
        total: total,
      );
      _ping();
    }

    publish(Duration.zero);
    if (total <= Duration.zero) return;

    final clock = Stopwatch()..start();
    _ticker?.cancel();
    _ticker = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => publish(clock.elapsed),
    );
    try {
      await Future<void>.delayed(total);
    } finally {
      _ticker?.cancel();
      _ticker = null;
    }
    publish(total);
  }

  Future<void> _activate(DualCamera camera) async {
    if (isSimultaneous || _activeCamera == camera) return;
    _apply(await _platform.activate(camera));
    _activeCamera = camera;
    notifyListeners();
  }

  void _apply(DualSession session) {
    _mode = session.mode;
    _feeds = session.feeds;
  }

  void _to(DualCaptureStage stage) {
    _stage = stage;
    _ping();
  }

  void _set(DualCameraStatus status) {
    _status = status;
    _ping();
  }

  /// A timer can outlive [dispose]; notifying a disposed notifier throws.
  void _ping() {
    if (_status != DualCameraStatus.disposed) notifyListeners();
  }

  File _require(Map<DualCamera, File> files, DualCamera camera, String what) {
    final file = files[camera];
    if (file == null) {
      throw PlatformException(
        code: 'capture_failed',
        message: 'The ${camera.name} camera produced no $what.',
      );
    }
    return file;
  }

  /// Moves a freshly written capture to wherever [storage] wants it.
  Future<File> _place(File source, DualCamera camera, DualMedia media) async {
    if (storage.isDefault) return source;

    final directory = storage.directory ?? source.parent;
    await directory.create(recursive: true);

    final name =
        storage.nameBuilder?.call(camera, media, DateTime.now()) ??
        source.uri.pathSegments.last;
    final target = '${directory.path}${Platform.pathSeparator}$name';
    if (target == source.path) return source;

    try {
      return await source.rename(target);
    } on FileSystemException {
      // rename() can't cross filesystems; fall back to a copy.
      final copy = await source.copy(target);
      await source.delete();
      return copy;
    }
  }

  Future<DualCapture> _placePhotos(DualCapture shot) async {
    if (storage.isDefault) return shot;
    return DualCapture(
      back: await _place(shot.back, DualCamera.back, DualMedia.photo),
      front: await _place(shot.front, DualCamera.front, DualMedia.photo),
      mode: shot.mode,
    );
  }

  Future<DualRecording> _placeClips(DualRecording clip) async {
    if (storage.isDefault) return clip;
    return DualRecording(
      back: await _place(clip.back, DualCamera.back, DualMedia.video),
      front: await _place(clip.front, DualCamera.front, DualMedia.video),
      mode: clip.mode,
      duration: clip.duration,
    );
  }

  void _requireReady(String method) {
    if (_status == DualCameraStatus.disposed) {
      throw StateError('$method() called on a disposed controller.');
    }
    if (_status == DualCameraStatus.uninitialized) {
      throw StateError('$method() called before initialize().');
    }
    if (isBusy) {
      throw StateError('$method() called while already $_status.');
    }
  }
}
