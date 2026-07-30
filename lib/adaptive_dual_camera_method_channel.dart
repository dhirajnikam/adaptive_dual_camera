import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'adaptive_dual_camera_platform_interface.dart';
import 'src/models.dart';

/// An implementation of [AdaptiveDualCameraPlatform] that uses method channels.
class MethodChannelAdaptiveDualCamera extends AdaptiveDualCameraPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('adaptive_dual_camera');

  @override
  Future<bool> isSimultaneousSupported() async =>
      await methodChannel.invokeMethod<bool>('isSimultaneousSupported') ??
      false;

  @override
  Future<bool> requestPermission({bool microphone = false}) async =>
      await methodChannel.invokeMethod<bool>('requestPermission', {
        'microphone': microphone,
      }) ??
      false;

  @override
  Future<DualSession> initialize({bool forceSequential = false}) async =>
      _session(
        await methodChannel.invokeMapMethod<String, dynamic>('initialize', {
          'forceSequential': forceSequential,
        }),
      );

  @override
  Future<DualSession> activate(DualCamera camera) async => _session(
    await methodChannel.invokeMapMethod<String, dynamic>('activate', {
      'camera': camera.name,
    }),
    'activate',
  );

  @override
  Future<({DualCaptureMode mode, Map<DualCamera, File> files})> capturePhoto({
    required List<DualCamera> cameras,
  }) async {
    final result = await methodChannel.invokeMapMethod<String, dynamic>(
      'capturePhoto',
      {
        'cameras': [for (final camera in cameras) camera.name],
      },
    );
    if (result == null) throw _blank('capturePhoto');
    return (mode: _mode(result['mode']), files: _files(result));
  }

  @override
  Future<DualSession> startRecording({
    required List<DualCamera> cameras,
    bool audio = true,
  }) async => _session(
    await methodChannel.invokeMapMethod<String, dynamic>('startRecording', {
      'cameras': [for (final camera in cameras) camera.name],
      'audio': audio,
    }),
    'startRecording',
  );

  @override
  Future<Map<DualCamera, File>> stopRecording() async {
    final result = await methodChannel.invokeMapMethod<String, dynamic>(
      'stopRecording',
    );
    if (result == null) throw _blank('stopRecording');
    return _files(result);
  }

  @override
  Future<void> release() => methodChannel.invokeMethod<void>('release');

  // --- decoding -----------------------------------------------------------

  Map<DualCamera, File> _files(Map<String, dynamic> result) => {
    for (final camera in DualCamera.values)
      if (result[camera.name] is String)
        camera: File(result[camera.name] as String),
  };

  DualSession _session(
    Map<String, dynamic>? result, [
    String method = 'initialize',
  ]) {
    if (result == null) throw _blank(method);
    final feeds = (result['feeds'] as Map?) ?? const {};
    return DualSession(
      mode: _mode(result['mode']),
      feeds: {
        for (final camera in DualCamera.values)
          if (feeds[camera.name] != null)
            camera: _feed(
              Map<String, dynamic>.from(feeds[camera.name] as Map),
              mirrored: camera == DualCamera.front,
            ),
      },
    );
  }

  DualFeed _feed(Map<String, dynamic> raw, {required bool mirrored}) =>
      DualFeed(
        textureId: (raw['textureId'] as num).toInt(),
        width: (raw['width'] as num).toInt(),
        height: (raw['height'] as num).toInt(),
        sensorOrientation: (raw['sensorOrientation'] as num?)?.toInt() ?? 0,
        mirrored: raw['mirrored'] as bool? ?? mirrored,
      );

  // Anything other than the exact simultaneous marker means one camera at a
  // time — the conservative reading if a future native build adds a mode.
  DualCaptureMode _mode(Object? raw) => raw == 'simultaneous'
      ? DualCaptureMode.simultaneous
      : DualCaptureMode.sequential;

  PlatformException _blank(String method) => PlatformException(
    code: 'capture_failed',
    message: 'Native $method returned no result.',
  );
}
