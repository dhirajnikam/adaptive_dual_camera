import 'dart:io';

import 'package:adaptive_dual_camera/adaptive_dual_camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_platform.dart';

void main() {
  /// Builds a controller wired to [platform] and records every [stage] it
  /// passes through, so the "taking back photo / taking front photo" messaging
  /// can be asserted rather than assumed.
  ({DualCameraController controller, List<DualCaptureStage> stages}) harness(
    FakePlatform platform,
  ) {
    final controller = DualCameraController(platform: platform);
    final stages = <DualCaptureStage>[];
    controller.addListener(() {
      if (stages.isEmpty || stages.last != controller.stage) {
        stages.add(controller.stage);
      }
    });
    return (controller: controller, stages: stages);
  }

  group('initialize', () {
    test('adopts the mode and feeds the platform reports', () async {
      final platform = FakePlatform(simultaneous: true);
      final controller = DualCameraController(platform: platform);

      await controller.initialize();

      expect(controller.mode, DualCaptureMode.simultaneous);
      expect(controller.isSimultaneous, isTrue);
      expect(controller.status, DualCameraStatus.ready);
      expect(controller.feedFor(DualCamera.back), isNotNull);
      expect(controller.feedFor(DualCamera.front), isNotNull);
    });

    test('sequential hardware exposes only the live camera', () async {
      final controller = DualCameraController(
        platform: FakePlatform(simultaneous: false),
      );

      await controller.initialize();

      expect(controller.mode, DualCaptureMode.sequential);
      expect(controller.activeCamera, DualCamera.back);
      expect(controller.feedFor(DualCamera.back), isNotNull);
      expect(controller.feedFor(DualCamera.front), isNull);
    });

    test('forceSequential takes the fallback on capable hardware', () async {
      final platform = FakePlatform(simultaneous: true);
      final controller = DualCameraController(platform: platform);

      await controller.initialize(forceSequential: true);

      expect(controller.mode, DualCaptureMode.sequential);
      expect(platform.log.first, 'initialize(forceSequential: true)');
    });

    test('refuses a second initialize', () async {
      final controller = DualCameraController(platform: FakePlatform());
      await controller.initialize();
      expect(controller.initialize(), throwsStateError);
    });
  });

  group('capturePhoto', () {
    test(
      'simultaneous shoots both in one call and reports stage both',
      () async {
        final platform = FakePlatform(simultaneous: true);
        final h = harness(platform);
        await h.controller.initialize();
        h.stages.clear();

        final shot = await h.controller.capturePhoto();

        expect(shot.mode, DualCaptureMode.simultaneous);
        expect(shot.back.path, '/cache/back.jpg');
        expect(shot.front.path, '/cache/front.jpg');
        expect(platform.log, contains('capturePhoto(back+front)'));
        expect(h.stages, contains(DualCaptureStage.both));
        expect(h.stages, isNot(contains(DualCaptureStage.front)));
      },
    );

    test('sequential shoots back then front, announcing each', () async {
      final platform = FakePlatform(simultaneous: false);
      final h = harness(platform);
      await h.controller.initialize();
      h.stages.clear();

      final shot = await h.controller.capturePhoto();

      expect(shot.mode, DualCaptureMode.sequential);
      expect(shot.back.path, '/cache/back.jpg');
      expect(shot.front.path, '/cache/front.jpg');

      // The whole point: the UI can say which photo is being taken, in order.
      final announced = h.stages
          .where((s) => s != DualCaptureStage.idle)
          .toList();
      expect(announced, [DualCaptureStage.back, DualCaptureStage.front]);

      expect(platform.log, [
        'initialize(forceSequential: false)',
        'capturePhoto(back)',
        'activate(front)',
        'capturePhoto(front)',
        'activate(back)',
      ]);
    });

    test('leaves the preview on the camera it started on', () async {
      final platform = FakePlatform(simultaneous: false);
      final controller = DualCameraController(platform: platform);
      await controller.initialize();
      await controller.switchTo(DualCamera.front);

      await controller.capturePhoto();

      expect(controller.activeCamera, DualCamera.front);
      expect(platform.log, [
        'initialize(forceSequential: false)',
        'activate(front)',
        // Shoots back first regardless, then front...
        'activate(back)',
        'capturePhoto(back)',
        'activate(front)',
        'capturePhoto(front)',
        // ...and the restore is a no-op because front is where it ended up.
      ]);
    });

    test('goes back to ready and idle afterwards', () async {
      final controller = DualCameraController(platform: FakePlatform());
      await controller.initialize();

      await controller.capturePhoto();

      expect(controller.status, DualCameraStatus.ready);
      expect(controller.stage, DualCaptureStage.idle);
    });

    test('throws before initialize', () {
      final controller = DualCameraController(platform: FakePlatform());
      expect(controller.capturePhoto(), throwsStateError);
    });
  });

  group('recording', () {
    test('simultaneous records both at once and returns both clips', () async {
      final platform = FakePlatform(simultaneous: true);
      final h = harness(platform);
      await h.controller.initialize();

      await h.controller.startRecording();
      expect(h.controller.isRecording, isTrue);
      expect(h.controller.stage, DualCaptureStage.both);

      final clip = await h.controller.stopRecording(frontLeadIn: Duration.zero);

      expect(clip.mode, DualCaptureMode.simultaneous);
      expect(clip.back.path, '/cache/back.mp4');
      expect(clip.front.path, '/cache/front.mp4');
      expect(platform.log, contains('startRecording(back+front, audio: true)'));
      // One pass only — no second recording on capable hardware.
      expect(
        platform.log.where((c) => c.startsWith('startRecording')).length,
        1,
      );
    });

    test(
      'sequential records back, then re-records front for the same length',
      () async {
        final platform = FakePlatform(simultaneous: false);
        final h = harness(platform);
        await h.controller.initialize();

        await h.controller.startRecording();
        expect(h.controller.stage, DualCaptureStage.back);

        final clip = await h.controller.stopRecording(
          frontLeadIn: Duration.zero,
        );

        expect(clip.mode, DualCaptureMode.sequential);
        expect(clip.back.path, '/cache/back.mp4');
        expect(clip.front.path, '/cache/front.mp4');
        expect(platform.log, [
          'initialize(forceSequential: false)',
          'startRecording(back, audio: true)',
          'stopRecording()',
          'activate(front)',
          'startRecording(front, audio: false)',
          'stopRecording()',
        ]);
        // The front pass was announced while it ran.
        expect(h.stages, contains(DualCaptureStage.front));
      },
    );

    test('follows the native side when it degrades mid-recording', () async {
      // Advertises a concurrent pair, then can't configure two video streams.
      final platform = FakePlatform(simultaneous: true, degradeOnVideo: true);
      final controller = DualCameraController(platform: platform);
      await controller.initialize();
      expect(controller.isSimultaneous, isTrue);

      await controller.startRecording();
      expect(
        controller.isSimultaneous,
        isFalse,
        reason: 'controller must adopt the mode the native side came back with',
      );

      final clip = await controller.stopRecording(frontLeadIn: Duration.zero);

      expect(clip.mode, DualCaptureMode.sequential);
      expect(clip.back.path, '/cache/back.mp4');
      expect(clip.front.path, '/cache/front.mp4');
    });

    test('audio: false is passed through', () async {
      final platform = FakePlatform(simultaneous: true);
      final controller = DualCameraController(platform: platform);
      await controller.initialize();

      await controller.startRecording(audio: false);
      await controller.stopRecording(frontLeadIn: Duration.zero);

      expect(
        platform.log,
        contains('startRecording(back+front, audio: false)'),
      );
    });

    test('the front retake reports a lead-in, then progress', () async {
      final platform = FakePlatform(simultaneous: false);
      final controller = DualCameraController(platform: platform);
      final passes = <DualSecondPass>[];
      controller.addListener(() {
        final pass = controller.secondPass;
        if (pass != null) passes.add(pass);
      });
      await controller.initialize();

      await controller.startRecording();
      expect(controller.secondPass, isNull, reason: 'not retaking yet');

      await controller.stopRecording(
        frontLeadIn: const Duration(milliseconds: 250),
      );

      // Counts down first...
      expect(passes.first.rolling, isFalse);
      expect(passes.first.total, const Duration(milliseconds: 250));
      expect(passes.first.progress, 0);
      // ...then rolls.
      expect(passes.any((p) => p.rolling), isTrue);
      expect(passes.last.progress, 1);
      // And clears once the clip is in.
      expect(controller.secondPass, isNull);
    });

    test('simultaneous hardware never reports a retake', () async {
      final controller = DualCameraController(
        platform: FakePlatform(simultaneous: true),
      );
      await controller.initialize();

      await controller.startRecording();
      final clip = await controller.stopRecording(
        frontLeadIn: const Duration(seconds: 30),
      );

      // The 30s lead-in is irrelevant: there's nothing to retake.
      expect(clip.mode, DualCaptureMode.simultaneous);
      expect(controller.secondPass, isNull);
    });

    test('stopRecording throws when not recording', () async {
      final controller = DualCameraController(platform: FakePlatform());
      await controller.initialize();
      expect(controller.stopRecording(), throwsStateError);
    });

    test('a missing clip surfaces as a PlatformException', () async {
      final platform = _NoClipsPlatform();
      final controller = DualCameraController(platform: platform);
      await controller.initialize();
      await controller.startRecording();

      await expectLater(
        controller.stopRecording(),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'capture_failed',
          ),
        ),
      );
      expect(
        controller.status,
        DualCameraStatus.ready,
        reason: 'a failed stop must not leave the controller stuck recording',
      );
    });
  });

  group('switchTo', () {
    test('moves the live feed on sequential hardware', () async {
      final controller = DualCameraController(
        platform: FakePlatform(simultaneous: false),
      );
      await controller.initialize();

      await controller.switchTo(DualCamera.front);

      expect(controller.activeCamera, DualCamera.front);
      expect(controller.feedFor(DualCamera.front), isNotNull);
      expect(controller.feedFor(DualCamera.back), isNull);
    });

    test('is a no-op when both cameras are already live', () async {
      final platform = FakePlatform(simultaneous: true);
      final controller = DualCameraController(platform: platform);
      await controller.initialize();

      await controller.switchTo(DualCamera.front);

      expect(platform.log, isNot(contains('activate(front)')));
    });
  });

  test('dispose releases the native session once', () async {
    final platform = FakePlatform();
    final controller = DualCameraController(platform: platform);
    await controller.initialize();

    await controller.dispose();
    await controller.dispose();

    expect(platform.released, isTrue);
    expect(platform.log.where((c) => c == 'release()').length, 1);
    expect(controller.status, DualCameraStatus.disposed);
  });
}

/// Reports a recording that produced no files at all.
class _NoClipsPlatform extends FakePlatform {
  @override
  Future<Map<DualCamera, File>> stopRecording() async {
    log.add('stopRecording()');
    recordingCameras = const [];
    return const {};
  }
}
