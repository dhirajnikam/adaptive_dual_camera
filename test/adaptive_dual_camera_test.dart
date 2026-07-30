import 'dart:io';

import 'package:adaptive_dual_camera/adaptive_dual_camera.dart';
import 'package:adaptive_dual_camera/adaptive_dual_camera_method_channel.dart';
import 'package:adaptive_dual_camera/adaptive_dual_camera_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_platform.dart';

void main() {
  late FakePlatform platform;

  setUp(() {
    platform = FakePlatform();
    AdaptiveDualCameraPlatform.instance = platform;
  });

  test('$MethodChannelAdaptiveDualCamera is the default instance', () {
    // Read before setUp swapped it out, via a fresh look at the concrete type.
    expect(
      MethodChannelAdaptiveDualCamera(),
      isInstanceOf<AdaptiveDualCameraPlatform>(),
    );
  });

  test('capture opens, shoots and closes in one call', () async {
    final shot = await AdaptiveDualCamera().capture();

    expect(shot.mode, DualCaptureMode.simultaneous);
    expect(shot.back.path, '/cache/back.jpg');
    expect(platform.log, [
      'initialize(forceSequential: false)',
      'capturePhoto(back+front)',
      'release()',
    ]);
  });

  test(
    'the same call falls back to sequential on incapable hardware',
    () async {
      AdaptiveDualCameraPlatform.instance = platform = FakePlatform(
        simultaneous: false,
      );

      final shot = await AdaptiveDualCamera().capture();

      // Identical shape either way — that's the whole point of the API.
      expect(shot.mode, DualCaptureMode.sequential);
      expect(shot.back.path, '/cache/back.jpg');
      expect(shot.front.path, '/cache/front.jpg');
    },
  );

  test('record captures a clip per camera and releases', () async {
    final clip = await AdaptiveDualCamera().record(Duration.zero);

    expect(clip.mode, DualCaptureMode.simultaneous);
    expect(clip.back.path, '/cache/back.mp4');
    expect(clip.front.path, '/cache/front.mp4');
    expect(platform.released, isTrue);
  });

  test('the session is released even when the capture blows up', () async {
    AdaptiveDualCameraPlatform.instance = platform = _ExplodingPlatform();

    await expectLater(
      AdaptiveDualCamera().capture(),
      throwsA(isA<StateError>()),
    );
    expect(platform.released, isTrue);
  });

  test('isSimultaneousSupported passes the hardware answer through', () async {
    AdaptiveDualCameraPlatform.instance = FakePlatform(simultaneous: false);
    expect(await AdaptiveDualCamera().isSimultaneousSupported(), isFalse);
  });

  test('requestPermission forwards the microphone flag', () async {
    await AdaptiveDualCamera().requestPermission(microphone: true);
    expect(platform.log, contains('requestPermission(microphone: true)'));
  });
}

class _ExplodingPlatform extends FakePlatform {
  @override
  Future<({DualCaptureMode mode, Map<DualCamera, File> files})> capturePhoto({
    required List<DualCamera> cameras,
  }) async => throw StateError('boom');
}
