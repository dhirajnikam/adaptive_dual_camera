import 'dart:io';
import 'dart:typed_data';

import 'package:adaptive_dual_camera/adaptive_dual_camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 1x1 transparent PNG.
final Uint8List _kPng = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

void main() {
  late Directory dir;
  late DualShotResult result;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('dual_shot_test');
    final front = File('${dir.path}/front.png')..writeAsBytesSync(_kPng);
    final back = File('${dir.path}/back.png')..writeAsBytesSync(_kPng);
    result = DualShotResult(
      frontPhoto: XFile(front.path),
      backPhoto: XFile(back.path),
      timestamp: DateTime(2026, 8, 6, 14, 5),
      latitude: 18.520430,
      longitude: 73.856743,
    );
  });

  tearDown(() => dir.deleteSync(recursive: true));

  testWidgets('lays out back photo above front photo + geo row',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: DualShotView(result: result))),
    );

    expect(find.text('18.520430, 73.856743'), findsOneWidget);
    expect(find.text('2026-08-06 14:05'), findsOneWidget);

    // Back photo (in the Column, above) must sit higher than the front
    // photo (inside the footer Row).
    final images = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(images.length, 2);
    final backY = tester.getTopLeft(find.byType(Image).first).dy;
    final frontY = tester.getTopLeft(find.byType(Image).last).dy;
    expect(backY, lessThan(frontY));
  });

  testWidgets('shows fallback when location missing', (tester) async {
    final noGeo = DualShotResult(
      frontPhoto: result.frontPhoto,
      backPhoto: result.backPhoto,
      timestamp: result.timestamp,
    );
    expect(noGeo.hasLocation, isFalse);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: DualShotView(result: noGeo))),
    );
    expect(find.text('Location unavailable'), findsOneWidget);
  });

  testWidgets('labels are overridable for localization', (tester) async {
    final noGeo = DualShotResult(
      frontPhoto: result.frontPhoto,
      backPhoto: result.backPhoto,
      timestamp: result.timestamp,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DualShotView(
            result: noGeo,
            labels: const DualCaptureLabels(
              locationUnavailable: 'स्थान उपलब्ध नहीं',
            ),
          ),
        ),
      ),
    );
    expect(find.text('स्थान उपलब्ध नहीं'), findsOneWidget);
  });

  test('formatTimestamp zero-pads', () {
    expect(formatTimestamp(DateTime(2026, 1, 2, 3, 4)), '2026-01-02 03:04');
  });
}
