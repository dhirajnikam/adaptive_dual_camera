import 'dart:io';

import 'package:adaptive_dual_camera/adaptive_dual_camera.dart';
import 'package:adaptive_dual_camera/adaptive_dual_camera_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Stands in for the native side, recording what it was asked to do.
///
/// [simultaneous] is a `var` on purpose: real hardware can advertise a
/// concurrent pair and then fail to configure two video streams, and
/// [degradeOnVideo] reproduces exactly that.
class FakePlatform
    with MockPlatformInterfaceMixin
    implements AdaptiveDualCameraPlatform {
  FakePlatform({
    this.simultaneous = true,
    this.degradeOnVideo = false,
    this.permission = true,
  });

  bool simultaneous;

  /// Drop to one camera the moment a two-camera recording is requested.
  final bool degradeOnVideo;

  final bool permission;

  /// Every call, in order, for assertions about orchestration.
  final List<String> log = [];

  DualCamera live = DualCamera.back;
  List<DualCamera> recordingCameras = const [];
  bool released = false;

  DualCaptureMode get _mode =>
      simultaneous ? DualCaptureMode.simultaneous : DualCaptureMode.sequential;

  DualFeed _feed(DualCamera camera) => DualFeed(
    textureId: camera.index,
    width: 720,
    height: 1280,
    sensorOrientation: 0,
    mirrored: camera == DualCamera.front,
  );

  DualSession _session() => DualSession(
    mode: _mode,
    feeds: simultaneous
        ? {for (final camera in DualCamera.values) camera: _feed(camera)}
        : {live: _feed(live)},
  );

  @override
  Future<bool> isSimultaneousSupported() async => simultaneous;

  @override
  Future<bool> requestPermission({bool microphone = false}) async {
    log.add('requestPermission(microphone: $microphone)');
    return permission;
  }

  @override
  Future<DualSession> initialize({bool forceSequential = false}) async {
    log.add('initialize(forceSequential: $forceSequential)');
    if (forceSequential) simultaneous = false;
    return _session();
  }

  @override
  Future<DualSession> activate(DualCamera camera) async {
    log.add('activate(${camera.name})');
    live = camera;
    return _session();
  }

  @override
  Future<({DualCaptureMode mode, Map<DualCamera, File> files})> capturePhoto({
    required List<DualCamera> cameras,
  }) async {
    log.add('capturePhoto(${cameras.map((c) => c.name).join('+')})');
    return (
      mode: _mode,
      files: {
        for (final camera in cameras) camera: File('/cache/${camera.name}.jpg'),
      },
    );
  }

  @override
  Future<DualSession> startRecording({
    required List<DualCamera> cameras,
    bool audio = true,
  }) async {
    log.add(
      'startRecording(${cameras.map((c) => c.name).join('+')}, audio: $audio)',
    );
    if (degradeOnVideo && cameras.length > 1) {
      simultaneous = false;
      live = DualCamera.back;
    }
    recordingCameras = simultaneous && cameras.length > 1
        ? cameras
        : [cameras.first];
    return _session();
  }

  @override
  Future<Map<DualCamera, File>> stopRecording() async {
    log.add('stopRecording()');
    final files = {
      for (final camera in recordingCameras)
        camera: File('/cache/${camera.name}.mp4'),
    };
    recordingCameras = const [];
    return files;
  }

  @override
  Future<void> release() async {
    log.add('release()');
    released = true;
  }
}
