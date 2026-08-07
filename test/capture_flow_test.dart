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
/// [concurrent] models the hardware split this package cares about: true for
/// a device that can hold front and back open at once, false for one that
/// refuses the second camera.
class _FakeCameraPlatform extends CameraPlatform {
  _FakeCameraPlatform(this.dir, {this.concurrent = false});

  final Directory dir;
  final bool concurrent;
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
    if (!concurrent && _open.isNotEmpty) {
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

  /// Swap in hardware that can (or can't) run both cameras at once. Call
  /// before pumping the flow.
  void useCamera({required bool concurrent}) {
    camera = _FakeCameraPlatform(dir, concurrent: concurrent);
    CameraPlatform.instance = camera;
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

  testWidgets('sequential hardware: counts down twice, no taps', (
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

    // Counting down towards the selfie, unprompted.
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

  testWidgets('concurrent hardware: one countdown, both shutters together', (
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

    // Both cameras came up, so there is one shared countdown, not two.
    expect(camera.peakOpen, 2);
    expect(find.text('Both photos at once — hold still…'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await flush(tester);

    expect(camera.shotLenses, hasLength(2));
    expect(camera.shotLenses.toSet(), {
      CameraLensDirection.front,
      CameraLensDirection.back,
    });
    expect(result, isNotNull);
    expect(result!.wasSimultaneous, isTrue);
  });

  testWidgets('mode: sequential skips the probe on concurrent hardware', (
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

    expect(camera.peakOpen, 1);
    expect(find.text('Taking your selfie…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await flush(tester);
  });

  testWidgets('countdown labels are overridable', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: GuidedDualCaptureFlow(
          countdown: const Duration(seconds: 3),
          labels: const DualCaptureLabels(
            frontCountdown: 'सेल्फ़ी ले रहे हैं…',
          ),
          onComplete: (_) {},
        ),
      ),
    );
    await flush(tester);

    expect(find.text('सेल्फ़ी ले रहे हैं…'), findsOneWidget);
    // Leave no pending timer behind.
    await tester.pump(const Duration(seconds: 3));
    await flush(tester);
  });
}
