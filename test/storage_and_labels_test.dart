import 'dart:io';

import 'package:adaptive_dual_camera/adaptive_dual_camera.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_platform.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('adc_storage'));
  tearDown(() => temp.deleteSync(recursive: true));

  /// A platform that writes real files, so relocation can actually be checked.
  DiskPlatform disk({bool simultaneous = true}) =>
      DiskPlatform(temp, simultaneous: simultaneous);

  group('DualStorage', () {
    test('leaves captures where the native side put them by default', () async {
      final platform = disk();
      final controller = DualCameraController(platform: platform);
      await controller.initialize();

      final shot = await controller.capturePhoto();

      expect(shot.back.parent.path, temp.path);
      expect(shot.back.existsSync(), isTrue);
      expect(shot.back.path, contains('adc_back_'));
    });

    test('moves photos into the requested directory', () async {
      final target = Directory('${temp.path}/albums/today');
      final controller = DualCameraController(
        platform: disk(),
        storage: DualStorage(directory: target),
      );
      await controller.initialize();

      final shot = await controller.capturePhoto();

      // Created on demand, and the originals are gone.
      expect(target.existsSync(), isTrue);
      expect(shot.back.parent.path, target.path);
      expect(shot.front.parent.path, target.path);
      expect(shot.back.existsSync(), isTrue);
      expect(shot.front.readAsStringSync(), 'front-photo');
      expect(
        File('${temp.path}/adc_back_0.jpg').existsSync(),
        isFalse,
        reason: 'the cache copy should not be left behind',
      );
    });

    test('nameBuilder controls the filename and gets the media kind', () async {
      final seen = <String>[];
      final controller = DualCameraController(
        platform: disk(),
        storage: DualStorage(
          nameBuilder: (camera, media, at) {
            seen.add('${camera.name}/${media.name}');
            return '${camera.name}-shot.${media == DualMedia.photo ? 'jpg' : 'mp4'}';
          },
        ),
      );
      await controller.initialize();

      final shot = await controller.capturePhoto();

      expect(seen, ['back/photo', 'front/photo']);
      expect(shot.back.uri.pathSegments.last, 'back-shot.jpg');
      expect(shot.front.uri.pathSegments.last, 'front-shot.jpg');
      expect(shot.back.readAsStringSync(), 'back-photo');
    });

    test('renames video clips too', () async {
      final controller = DualCameraController(
        platform: disk(),
        storage: DualStorage(
          nameBuilder: (camera, media, at) => '${camera.name}.${media.name}',
        ),
      );
      await controller.initialize();

      await controller.startRecording();
      final clip = await controller.stopRecording(frontLeadIn: Duration.zero);

      expect(clip.back.uri.pathSegments.last, 'back.video');
      expect(clip.front.uri.pathSegments.last, 'front.video');
      expect(clip.back.existsSync(), isTrue);
    });

    test('sequential captures are relocated the same way', () async {
      final target = Directory('${temp.path}/out');
      final controller = DualCameraController(
        platform: disk(simultaneous: false),
        storage: DualStorage(directory: target),
      );
      await controller.initialize();

      final shot = await controller.capturePhoto();

      expect(shot.mode, DualCaptureMode.sequential);
      expect(shot.back.parent.path, target.path);
      expect(shot.front.parent.path, target.path);
    });

    test('isDefault is only true when nothing would change', () {
      expect(const DualStorage().isDefault, isTrue);
      expect(DualStorage(directory: temp).isDefault, isFalse);
      expect(DualStorage(nameBuilder: (c, m, a) => 'x').isDefault, isFalse);
    });
  });

  group('DualCameraLabels', () {
    const labels = DualCameraLabels();

    Future<DualCameraController> ready({bool simultaneous = true}) async {
      final controller = DualCameraController(
        platform: FakePlatform(simultaneous: simultaneous),
      );
      await controller.initialize();
      return controller;
    }

    test('says nothing while idle', () async {
      expect(labels.statusFor(await ready()), isNull);
    });

    test('names the camera being photographed', () async {
      final platform = FakePlatform(simultaneous: false);
      final controller = DualCameraController(platform: platform);
      final seen = <String>[];
      controller.addListener(() {
        final message = labels.statusFor(controller);
        if (message != null && (seen.isEmpty || seen.last != message)) {
          seen.add(message);
        }
      });
      await controller.initialize();

      await controller.capturePhoto();

      expect(seen, ['Taking back photo…', 'Taking front photo…']);
    });

    test('switches wording between photo and video', () async {
      final controller = await ready();

      await controller.startRecording();
      expect(labels.statusFor(controller), 'Recording…');

      await controller.stopRecording(frontLeadIn: Duration.zero);
      expect(labels.statusFor(controller), isNull);
    });

    test('describes the hardware mode', () async {
      expect(labels.modeFor(await ready()), 'Both cameras live');
      expect(
        labels.modeFor(await ready(simultaneous: false)),
        'One camera at a time · live: back',
      );
      expect(
        labels.modeFor(DualCameraController(platform: FakePlatform())),
        isNull,
      );
    });

    test('substitutes {camera} in placeholders', () {
      expect(labels.notLive(DualCamera.front), 'front not live');
      expect(
        const DualCameraLabels(
          frontCamera: 'Selfie',
          cameraNotLive: '{camera} is off',
        ).notLive(DualCamera.front),
        'Selfie is off',
      );
    });

    test('substitutes {seconds} in the retake strings', () async {
      final controller = DualCameraController(
        platform: FakePlatform(simultaneous: false),
      );
      final seen = <String>[];
      controller.addListener(() {
        final message = labels.statusFor(controller);
        if (message != null && (seen.isEmpty || seen.last != message)) {
          seen.add(message);
        }
      });
      await controller.initialize();

      await controller.startRecording();
      await controller.stopRecording(
        frontLeadIn: const Duration(milliseconds: 500),
      );

      // Countdown first, then the retake — both with a number substituted in.
      expect(
        seen.any(
          (m) =>
              m.startsWith('Turn the camera around') &&
              !m.contains('{seconds}'),
        ),
        isTrue,
      );
      expect(seen.any((m) => m.contains('left')), isTrue);
    });

    test('the retake message wins over the capture stage', () async {
      // Both are "front"; the user needs the actionable one.
      final controller = DualCameraController(
        platform: FakePlatform(simultaneous: false),
      );
      String? duringRetake;
      controller.addListener(() {
        if (controller.secondPass != null) {
          duringRetake ??= labels.statusFor(controller);
        }
      });
      await controller.initialize();
      await controller.startRecording();
      await controller.stopRecording(
        frontLeadIn: const Duration(milliseconds: 200),
      );

      expect(duringRetake, isNot('Recording front camera…'));
      expect(duringRetake, startsWith('Turn the camera around'));
    });

    test('copyWith overrides one string and keeps the rest', () {
      final custom = labels.copyWith(takingBackPhoto: 'Rückkamera…');

      expect(custom.takingBackPhoto, 'Rückkamera…');
      expect(custom.takingFrontPhoto, labels.takingFrontPhoto);
    });
  });
}

/// A fake platform that writes real files, so storage moves can be verified.
class DiskPlatform extends FakePlatform {
  DiskPlatform(this.root, {super.simultaneous});

  final Directory root;
  int _n = 0;

  File _write(DualCamera camera, String ext, String body) {
    final file = File('${root.path}/adc_${camera.name}_${_n++}.$ext')
      ..writeAsStringSync(body);
    return file;
  }

  @override
  Future<({DualCaptureMode mode, Map<DualCamera, File> files})> capturePhoto({
    required List<DualCamera> cameras,
  }) async {
    final base = await super.capturePhoto(cameras: cameras);
    return (
      mode: base.mode,
      files: {
        for (final camera in cameras)
          camera: _write(camera, 'jpg', '${camera.name}-photo'),
      },
    );
  }

  @override
  Future<Map<DualCamera, File>> stopRecording() async {
    final base = await super.stopRecording();
    return {
      for (final camera in base.keys)
        camera: _write(camera, 'mp4', '${camera.name}-video'),
    };
  }
}
