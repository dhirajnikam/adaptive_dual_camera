import 'dart:io';
import 'dart:typed_data';

import 'package:adaptive_dual_camera/adaptive_dual_camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 1x1 transparent PNG.
final Uint8List _kPng = Uint8List.fromList(<int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
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

  testWidgets('shows back photo full-bleed, selfie card, map and details', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DualShotView(result: result)),
      ),
    );
    await tester.pump(); // let the map tile request fail into its fallback

    expect(find.text('18.520430, 73.856743'), findsOneWidget);
    expect(find.text('2026-08-06 14:05'), findsOneWidget);
    expect(find.byType(MapThumbnail), findsOneWidget);

    // Back photo fills the view; the selfie is a small card over it.
    final photos = find.byWidgetPredicate(
      (w) => w is Image && w.image is! NetworkImage,
    );
    expect(photos, findsNWidgets(2));
    final backSize = tester.getSize(photos.first);
    final frontSize = tester.getSize(photos.last);
    expect(frontSize.width, lessThan(backSize.width / 2));
  });

  testWidgets('map can be turned off', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DualShotView(result: result, showMap: false)),
      ),
    );
    expect(find.byType(MapThumbnail), findsNothing);
  });

  testWidgets('shows fallback when location missing', (tester) async {
    final noGeo = DualShotResult(
      frontPhoto: result.frontPhoto,
      backPhoto: result.backPhoto,
      timestamp: result.timestamp,
    );
    expect(noGeo.hasLocation, isFalse);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DualShotView(result: noGeo)),
      ),
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

  testWidgets('style moves the selfie and recolors the text', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DualShotView(
            result: result,
            showMap: false,
            style: DualShotStyle.light.copyWith(
              selfieAlignment: Alignment.topLeft,
              selfieWidth: 120,
            ),
          ),
        ),
      ),
    );

    final selfie = find
        .byWidgetPredicate((w) => w is Image && w.image is! NetworkImage)
        .last;
    final screen = tester.getSize(find.byType(DualShotView));
    expect(tester.getSize(selfie).width, 120);
    expect(tester.getTopLeft(selfie).dx, lessThan(screen.width / 2));

    final coords = tester.widget<Text>(find.text('18.520430, 73.856743'));
    expect(coords.style!.color, DualShotStyle.light.textColor);
  });

  test('tileUrl computes the OSM tile for a location', () {
    expect(
      MapThumbnail.tileUrl(0, 0, 0),
      'https://tile.openstreetmap.org/0/0/0.png',
    );
    expect(
      MapThumbnail.tileUrl(10, 10, 1),
      'https://tile.openstreetmap.org/1/1/0.png',
    );
    // Pune at the default zoom, precomputed by hand.
    expect(
      MapThumbnail.tileUrl(18.520430, 73.856743),
      'https://tile.openstreetmap.org/15/23106/14668.png',
    );
  });

  test('formatTimestamp zero-pads', () {
    expect(formatTimestamp(DateTime(2026, 1, 2, 3, 4)), '2026-01-02 03:04');
  });
}
