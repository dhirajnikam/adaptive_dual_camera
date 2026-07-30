// Widget-level tests for the example app. There's no host implementation under
// `flutter test`, so the method channel is mocked and only the Flutter side is
// exercised.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adaptive_dual_camera/adaptive_dual_camera.dart';
import 'package:adaptive_dual_camera_example/main.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 1x1 PNG, so `Image.file` in the result view has something real to decode.
const _pixel =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('adaptive_dual_camera');
  late Directory temp;
  late String imagePath;

  setUpAll(() {
    temp = Directory.systemTemp.createTempSync('adc_example_test');
    final file = File('${temp.path}/shot.png')
      ..writeAsBytesSync(base64Decode(_pixel));
    imagePath = file.path;
  });

  tearDownAll(() => temp.deleteSync(recursive: true));

  Map<String, Object?> feed(int id) => {
    'textureId': id,
    'width': 720,
    'height': 1280,
    'sensorOrientation': 0,
  };

  /// The demo page is a tall scroller; give it room so nothing is lazily
  /// skipped below the fold.
  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(500, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MyApp());
    await tester.pump();
    await tester.pump();
  }

  /// Mocks a device that can only run one camera at a time.
  void mockSequentialDevice() {
    var live = 'back';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
          switch (call.method) {
            case 'requestPermission':
              return true;
            case 'initialize':
              return {
                'mode': 'sequential',
                'feeds': {live: feed(1)},
              };
            case 'activate':
              live = args['camera'] as String;
              return {
                'mode': 'sequential',
                'feeds': {live: feed(1)},
              };
            case 'capturePhoto':
              final camera = (args['cameras'] as List).first as String;
              return {'mode': 'sequential', camera: imagePath};
            default:
              return null;
          }
        });
  }

  setUp(mockSequentialDevice);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('reports the fallback and offers the layout controls', (
    tester,
  ) async {
    await pumpApp(tester);

    expect(find.textContaining('One camera at a time'), findsOneWidget);
    expect(find.text('Take both photos'), findsOneWidget);
    expect(find.text('Switch live camera'), findsOneWidget);
    // The layout customisation surface.
    for (final label in ['PiP', 'Side', 'Stack', 'One']) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('the inset control only applies to picture-in-picture', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(find.text('TL'), findsOneWidget);

    await tester.tap(find.text('Side'));
    await tester.pump();

    expect(find.text('TL'), findsNothing);
  });

  testWidgets('the fit control reaches the live feed', (tester) async {
    await pumpApp(tester);

    // Default is contain, so the whole frame is visible.
    expect(
      tester.widget<DualCameraFeed>(find.byType(DualCameraFeed)).fit,
      BoxFit.contain,
    );

    await tester.tap(find.text('Cover'));
    await tester.pump();

    expect(
      tester.widget<DualCameraFeed>(find.byType(DualCameraFeed)).fit,
      BoxFit.cover,
    );
  });

  testWidgets('switching the live camera updates the status line', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(find.textContaining('live: back'), findsOneWidget);

    await tester.tap(find.text('Switch live camera'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('live: front'), findsOneWidget);
  });

  testWidgets('walks the user through the front-camera retake', (tester) async {
    var live = 'back';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
          switch (call.method) {
            case 'requestPermission':
              return true;
            case 'initialize':
              return {
                'mode': 'sequential',
                'feeds': {live: feed(1)},
              };
            case 'activate':
              live = args['camera'] as String;
              return {
                'mode': 'sequential',
                'feeds': {live: feed(1)},
              };
            case 'startRecording':
              return {
                'mode': 'sequential',
                'feeds': {live: feed(1)},
              };
            case 'stopRecording':
              return {live: '/cache/$live.mp4'};
            default:
              return null;
          }
        });

    await pumpApp(tester);
    await tester.tap(find.text('Record'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Recording back camera'), findsOneWidget);

    await tester.tap(find.text('Stop recording'));
    await tester.pump();
    await tester.pump();

    // The example asks for a 3s lead-in before the retake.
    expect(find.textContaining('Turn the camera around'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    // The banner switches from countdown to a running clock.
    expect(find.textContaining('s left'), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.textContaining('Video · sequential'), findsOneWidget);
    expect(find.textContaining('Turn the camera around'), findsNothing);
  });

  testWidgets('tells the user which photo is being taken', (tester) async {
    await pumpApp(tester);

    // Hold each shot open so the in-flight message is observable.
    var gate = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
          switch (call.method) {
            case 'capturePhoto':
              await gate.future;
              final camera = (args['cameras'] as List).first as String;
              return {'mode': 'sequential', camera: imagePath};
            case 'activate':
              final camera = args['camera'] as String;
              return {
                'mode': 'sequential',
                'feeds': {camera: feed(1)},
              };
            default:
              return null;
          }
        });

    await tester.tap(find.text('Take both photos'));
    await tester.pump();
    expect(find.text('Taking back photo…'), findsOneWidget);
    expect(find.text('Taking front photo…'), findsNothing);

    // Let the back shot land; the controller moves on to the front one.
    gate.complete();
    gate = Completer<void>();
    await tester.pump();
    await tester.pump();
    expect(find.text('Taking front photo…'), findsOneWidget);
    expect(find.text('Taking back photo…'), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();

    expect(find.textContaining('Photo · sequential'), findsOneWidget);
    // Message clears once both photos are in.
    expect(find.textContaining('Taking '), findsNothing);
  });
}
