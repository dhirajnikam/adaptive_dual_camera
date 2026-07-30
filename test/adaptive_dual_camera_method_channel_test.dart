import 'package:adaptive_dual_camera/adaptive_dual_camera.dart';
import 'package:adaptive_dual_camera/adaptive_dual_camera_method_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final platform = MethodChannelAdaptiveDualCamera();
  const channel = MethodChannel('adaptive_dual_camera');
  final calls = <MethodCall>[];

  /// Answers every method with [replies] keyed by method name.
  void mockNative(Map<String, Object?> replies) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return replies[call.method];
        });
  }

  Map<String, Object?> feed(int id) => {
    'textureId': id,
    'width': 720,
    'height': 1280,
    'sensorOrientation': 90,
  };

  setUp(calls.clear);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('initialize', () {
    test('decodes a simultaneous session with both feeds', () async {
      mockNative({
        'initialize': {
          'mode': 'simultaneous',
          'feeds': {'back': feed(1), 'front': feed(2)},
        },
      });

      final session = await platform.initialize();

      expect(session.mode, DualCaptureMode.simultaneous);
      expect(session.feeds[DualCamera.back]!.textureId, 1);
      expect(session.feeds[DualCamera.front]!.textureId, 2);
      expect(calls.single.arguments, {'forceSequential': false});
    });

    test('decodes a sequential session with one feed', () async {
      mockNative({
        'initialize': {
          'mode': 'sequential',
          'feeds': {'back': feed(1)},
        },
      });

      final session = await platform.initialize(forceSequential: true);

      expect(session.mode, DualCaptureMode.sequential);
      expect(session.feeds.keys, [DualCamera.back]);
      expect(calls.single.arguments, {'forceSequential': true});
    });

    test('front feeds default to mirrored, back feeds do not', () async {
      mockNative({
        'initialize': {
          'mode': 'simultaneous',
          'feeds': {'back': feed(1), 'front': feed(2)},
        },
      });

      final session = await platform.initialize();

      expect(session.feeds[DualCamera.front]!.mirrored, isTrue);
      expect(session.feeds[DualCamera.back]!.mirrored, isFalse);
    });

    test('an explicit mirrored flag from native wins', () async {
      mockNative({
        'initialize': {
          'mode': 'simultaneous',
          'feeds': {
            'front': {...feed(2), 'mirrored': false},
          },
        },
      });

      final session = await platform.initialize();

      expect(session.feeds[DualCamera.front]!.mirrored, isFalse);
    });

    test(
      'an unrecognised mode is treated as sequential, not a crash',
      () async {
        mockNative({
          'initialize': {'mode': 'something-new', 'feeds': <String, Object?>{}},
        });

        expect((await platform.initialize()).mode, DualCaptureMode.sequential);
      },
    );

    test('a null result throws instead of returning garbage', () async {
      mockNative(const {});

      await expectLater(
        platform.initialize(),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'capture_failed',
          ),
        ),
      );
    });
  });

  test('activate names the camera it wants live', () async {
    mockNative({
      'activate': {
        'mode': 'sequential',
        'feeds': {'front': feed(2)},
      },
    });

    final session = await platform.activate(DualCamera.front);

    expect(session.feeds.keys, [DualCamera.front]);
    expect(calls.single.arguments, {'camera': 'front'});
  });

  group('capturePhoto', () {
    test('sends the requested cameras and decodes what came back', () async {
      mockNative({
        'capturePhoto': {
          'mode': 'simultaneous',
          'back': '/cache/back.jpg',
          'front': '/cache/front.jpg',
        },
      });

      final shot = await platform.capturePhoto(cameras: DualCamera.values);

      expect(shot.mode, DualCaptureMode.simultaneous);
      expect(shot.files[DualCamera.back]!.path, '/cache/back.jpg');
      expect(shot.files[DualCamera.front]!.path, '/cache/front.jpg');
      expect(calls.single.arguments, {
        'cameras': ['back', 'front'],
      });
    });

    test('a single-camera shot returns only that file', () async {
      mockNative({
        'capturePhoto': {'mode': 'sequential', 'back': '/cache/back.jpg'},
      });

      final shot = await platform.capturePhoto(cameras: [DualCamera.back]);

      expect(shot.files.keys, [DualCamera.back]);
      expect(calls.single.arguments, {
        'cameras': ['back'],
      });
    });
  });

  group('recording', () {
    test(
      'startRecording returns the session the native side settled on',
      () async {
        mockNative({
          'startRecording': {
            'mode': 'sequential',
            'feeds': {'back': feed(1)},
          },
        });

        final session = await platform.startRecording(
          cameras: DualCamera.values,
          audio: false,
        );

        expect(session.mode, DualCaptureMode.sequential);
        expect(calls.single.arguments, {
          'cameras': ['back', 'front'],
          'audio': false,
        });
      },
    );

    test('stopRecording decodes whichever clips exist', () async {
      mockNative({
        'stopRecording': {'back': '/cache/back.mp4'},
      });

      final clips = await platform.stopRecording();

      expect(clips.keys, [DualCamera.back]);
      expect(clips[DualCamera.back]!.path, '/cache/back.mp4');
    });
  });

  test('requestPermission forwards the microphone flag', () async {
    mockNative({'requestPermission': true});

    expect(await platform.requestPermission(microphone: true), isTrue);
    expect(calls.single.arguments, {'microphone': true});
  });

  test(
    'isSimultaneousSupported defaults to false when native says null',
    () async {
      mockNative(const {});
      expect(await platform.isSimultaneousSupported(), isFalse);
    },
  );
}
