import 'dart:async';
import 'dart:io';

import 'package:adaptive_dual_camera/adaptive_dual_camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 1x1 transparent PNG — enough for `Image.file` to decode a thumbnail.
final Uint8List _kPng = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// A camera that always initializes and hands back a real (tiny) file, so the
/// flow can be driven with no device. Records which lens each shot came from.
///
/// This fake only ever serves the *sequential* path — simultaneous capture
/// goes through the native channel — so it refuses a second concurrent open,
/// which is exactly the invariant that path has to respect.
class _FakeCameraPlatform extends CameraPlatform {
  _FakeCameraPlatform(this.dir);

  final Directory dir;
  final List<CameraLensDirection> shotLenses = <CameraLensDirection>[];
  final Map<int, CameraLensDirection> _lensOf = <int, CameraLensDirection>{};
  final Set<int> _open = <int>{};
  int _nextId = 0;

  /// How many cameras were ever open at the same moment.
  int peakOpen = 0;

  // CameraController awaits `.first` on the error stream, so it has to stay
  // open for the life of the test — an empty (or closed) stream completes
  // with "Bad state: No element".
  final _errors = StreamController<CameraErrorEvent>.broadcast();
  final _orientation =
      StreamController<DeviceOrientationChangedEvent>.broadcast();

  @override
  Future<List<CameraDescription>> availableCameras() async => const [
    CameraDescription(
      name: 'front',
      lensDirection: CameraLensDirection.front,
      sensorOrientation: 90,
    ),
    CameraDescription(
      name: 'back',
      lensDirection: CameraLensDirection.back,
      sensorOrientation: 90,
    ),
  ];

  @override
  Future<int> createCameraWithSettings(
    CameraDescription description,
    MediaSettings? mediaSettings,
  ) async {
    _lensOf[++_nextId] = description.lensDirection;
    return _nextId;
  }

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {
    if (_open.isNotEmpty) {
      throw CameraException(
        'CameraAccessError',
        'Another camera is already in use.',
      );
    }
    _open.add(cameraId);
    peakOpen = peakOpen > _open.length ? peakOpen : _open.length;
  }

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream<CameraInitializedEvent>.value(
        CameraInitializedEvent(
          cameraId,
          1280,
          720,
          ExposureMode.auto,
          false,
          FocusMode.auto,
          false,
        ),
      );

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) => _errors.stream;

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      _orientation.stream;

  @override
  Widget buildPreview(int cameraId) => const SizedBox.expand();

  @override
  Future<XFile> takePicture(int cameraId) async {
    shotLenses.add(_lensOf[cameraId]!);
    final file = File('${dir.path}/shot${shotLenses.length}.png')
      ..writeAsBytesSync(_kPng);
    return XFile(file.path);
  }

  @override
  Future<void> dispose(int cameraId) async => _open.remove(cameraId);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late _FakeCameraPlatform camera;

  /// Method calls the flow made to the native (simultaneous) plugin.
  late List<String> nativeCalls;

  /// Swap in hardware that can (or can't) run both cameras at once.
  ///
  /// Two independent knobs, because the interesting device is the liar:
  /// [claimsSupport] is what the native probe reports, [concurrent] is
  /// whether the native session can actually be started. The [camera] plugin
  /// fake only ever serves the sequential path now — simultaneous capture is
  /// entirely native.
  void useCamera({
    required bool concurrent,
    bool? claimsSupport,
    bool cameraPermission = true,
  }) {
    camera = _FakeCameraPlatform(dir);
    CameraPlatform.instance = camera;
    DualCameraSupport.resetCache();
    nativeCalls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('adaptive_dual_camera/support'),
          (call) async {
            nativeCalls.add(call.method);
            switch (call.method) {
              case 'supportsConcurrentCameras':
                return claimsSupport ?? concurrent;
              case 'ensureCameraPermission':
                return cameraPermission;
              case 'startConcurrent':
                if (!concurrent) {
                  throw PlatformException(
                    code: 'startFailed',
                    message: 'No concurrent camera combination',
                  );
                }
                return <String, dynamic>{
                  'backTextureId': 1,
                  'frontTextureId': 2,
                  'backRotation': 90,
                  'frontRotation': 270,
                };
              case 'captureBoth':
                final back = File('${dir.path}/native_back.jpg')
                  ..writeAsBytesSync(_kPng);
                final front = File('${dir.path}/native_front.jpg')
                  ..writeAsBytesSync(_kPng);
                return <String, dynamic>{
                  'backPath': back.path,
                  'frontPath': front.path,
                };
              default:
                return null;
            }
          },
        );
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('capture_flow_test');
    useCamera(concurrent: false);
    // Geolocator's real channel never answers under fake async, which would
    // hang the flow. Report location services off — the documented degraded
    // path, and the one worth proving the capture survives.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter.baseflow.com/geolocator'),
          (call) async =>
              call.method == 'isLocationServiceEnabled' ? false : null,
        );
  });

  tearDown(() => dir.deleteSync(recursive: true));

  /// Flush the async gaps (takePicture → dispose → reopen → locate) without
  /// advancing far enough to tick the 1-second countdown.
  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 5));
    }
  }

  testWidgets('sequential hardware: one tap, then two automatic shots', (
    tester,
  ) async {
    DualShotResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: GuidedDualCaptureFlow(
          countdown: const Duration(seconds: 3),
          onComplete: (r) => result = r,
        ),
      ),
    );
    // Let availableCameras() resolve and the front camera initialize.
    await flush(tester);

    // The first page waits for the user instead of firing on its own.
    expect(find.text('Tap when ready'), findsOneWidget);
    expect(find.text('3'), findsNothing);
    expect(camera.shotLenses, isEmpty);
    await tester.tap(find.byIcon(Icons.camera_alt));
    await tester.pump();

    // Counting down towards the selfie.
    expect(find.text('3'), findsOneWidget);
    expect(find.text('Taking your selfie…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('2'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('1'), findsOneWidget);

    // Last tick fires the shutter itself and swings to the back camera.
    await tester.pump(const Duration(seconds: 1));
    await flush(tester);
    expect(camera.shotLenses, [CameraLensDirection.front]);
    expect(
      find.text('Turn the phone around — back photo next'),
      findsOneWidget,
    );
    expect(find.text('3'), findsOneWidget); // full delay to turn around
    // No second tap: the back page counts down on its own.
    expect(find.text('Tap when ready'), findsNothing);

    // Second countdown, second automatic shot, flow completes.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await flush(tester);
    expect(camera.shotLenses, [
      CameraLensDirection.front,
      CameraLensDirection.back,
    ]);
    expect(result, isNotNull);
    expect(result!.wasSimultaneous, isFalse);
    expect(camera.peakOpen, 1); // never two pipelines at once
    // No location plugin under test — the capture still succeeds without one.
    expect(result!.hasLocation, isFalse);
  });

  testWidgets('concurrent hardware: native session, one countdown', (
    tester,
  ) async {
    useCamera(concurrent: true);
    DualShotResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: GuidedDualCaptureFlow(
          countdown: const Duration(seconds: 3),
          onComplete: (r) => result = r,
        ),
      ),
    );
    await flush(tester);

    // The native session owns both cameras, so the `camera` plugin is never
    // opened at all — meaning nobody else asks for camera permission, so the
    // flow itself must, and before the bind.
    expect(
      nativeCalls.indexOf('ensureCameraPermission'),
      lessThan(nativeCalls.indexOf('startConcurrent')),
    );
    expect(nativeCalls, contains('startConcurrent'));
    expect(camera.peakOpen, 0);
    // Both previews are native textures, not CameraPreviews.
    expect(find.byType(Texture), findsNWidgets(2));
    expect(find.text('Tap when ready'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.camera_alt));
    await tester.pump();

    // One shared countdown for both shutters.
    expect(find.text('Both photos at once — hold still…'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await flush(tester);

    expect(nativeCalls, contains('captureBoth'));
    expect(camera.shotLenses, isEmpty); // no plugin shutter was used
    expect(result, isNotNull);
    expect(result!.wasSimultaneous, isTrue);
    expect(result!.frontPhoto.path, endsWith('native_front.jpg'));
    expect(result!.backPhoto.path, endsWith('native_back.jpg'));
  });

  testWidgets('mode: sequential never touches the native session', (
    tester,
  ) async {
    useCamera(concurrent: true);
    await tester.pumpWidget(
      MaterialApp(
        home: GuidedDualCaptureFlow(
          countdown: const Duration(seconds: 3),
          mode: DualCaptureMode.sequential,
          onComplete: (_) {},
        ),
      ),
    );
    await flush(tester);

    expect(nativeCalls, isEmpty);
    expect(camera.peakOpen, 1);
    // Explicitly sequential: no notice, because nothing was denied.
    expect(find.textContaining("can't use both cameras"), findsNothing);
    await tester.tap(find.byIcon(Icons.camera_alt));
    await tester.pump();
    expect(find.text('Taking your selfie…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await flush(tester);
  });

  testWidgets('camera permission denied: retry screen, no native session', (
    tester,
  ) async {
    useCamera(concurrent: true, cameraPermission: false);
    await tester.pumpWidget(
      MaterialApp(
        home: GuidedDualCaptureFlow(
          countdown: const Duration(seconds: 3),
          onComplete: (_) {},
        ),
      ),
    );
    await flush(tester);

    expect(
      find.textContaining('Camera access is needed'),
      findsOneWidget,
    );
    expect(find.text('Try again'), findsOneWidget);
    expect(nativeCalls, isNot(contains('startConcurrent')));
    expect(camera.peakOpen, 0);
  });

  testWidgets('auto on a device that cannot do it says so', (tester) async {
    useCamera(concurrent: false);
    await tester.pumpWidget(
      MaterialApp(
        home: GuidedDualCaptureFlow(
          countdown: const Duration(seconds: 3),
          onComplete: (_) {},
        ),
      ),
    );
    await flush(tester);

    expect(find.textContaining("can't use both cameras"), findsOneWidget);
    // The platform said no, so the native session was never even started.
    expect(nativeCalls, ['supportsConcurrentCameras']);
    expect(camera.peakOpen, 1);
    await tester.pump(const Duration(seconds: 3));
    await flush(tester);
  });

  testWidgets('a device that claims support but fails falls back', (
    tester,
  ) async {
    // The liar: the probe says yes, starting the session then fails.
    useCamera(concurrent: false, claimsSupport: true);
    DualShotResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: GuidedDualCaptureFlow(
          countdown: const Duration(seconds: 3),
          onComplete: (r) => result = r,
        ),
      ),
    );
    await flush(tester);

    expect(nativeCalls, contains('startConcurrent'));
    expect(find.textContaining("can't use both cameras"), findsOneWidget);
    expect(find.text('Tap when ready'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.camera_alt));
    await tester.pump();
    expect(find.text('Taking your selfie…'), findsOneWidget);

    // And it still delivers both photos the long way round.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
      await flush(tester);
    }
    expect(result, isNotNull);
    expect(result!.wasSimultaneous, isFalse);
    expect(camera.shotLenses, [
      CameraLensDirection.front,
      CameraLensDirection.back,
    ]);
  });

  testWidgets('countdown labels are overridable', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: GuidedDualCaptureFlow(
          countdown: const Duration(seconds: 3),
          labels: const DualCaptureLabels(
            tapToStart: 'तैयार हों तो टैप करें',
            frontCountdown: 'सेल्फ़ी ले रहे हैं…',
          ),
          onComplete: (_) {},
        ),
      ),
    );
    await flush(tester);

    expect(find.text('तैयार हों तो टैप करें'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.camera_alt));
    await tester.pump();
    expect(find.text('सेल्फ़ी ले रहे हैं…'), findsOneWidget);
    // Leave no pending timer behind.
    await tester.pump(const Duration(seconds: 3));
    await flush(tester);
  });
}
