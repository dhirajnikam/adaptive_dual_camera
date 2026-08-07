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

  testWidgets('lays out Column[back, Row[front, map, details]]', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DualShotView(result: result)),
      ),
    );
    await tester.pump(); // let the map tile request fail into its fallback

    expect(find.text('18.520430, 73.856743'), findsOneWidget);
    expect(find.text('6 Aug 2026, 2:05 PM'), findsOneWidget);
    expect(find.byType(MapThumbnail), findsOneWidget);

    final photos = find.byWidgetPredicate(
      (w) => w is Image && w.image is! NetworkImage,
    );
    expect(photos, findsNWidgets(2));
    final back = tester.getRect(photos.first);
    final front = tester.getRect(photos.last);
    final map = tester.getRect(find.byType(MapThumbnail));
    final coords = tester.getRect(find.text('18.520430, 73.856743'));

    // Column: the back photo sits entirely above the footer row.
    expect(back.bottom, lessThanOrEqualTo(front.top));
    expect(back.width, tester.getSize(find.byType(DualShotView)).width);
    // Row: front photo, then map, then the text — left to right, and all
    // three below the back photo rather than overlaid on it.
    expect(front.left, lessThan(map.left));
    expect(map.left, lessThan(coords.left));
    for (final r in [front, map, coords]) {
      expect(r.top, greaterThanOrEqualTo(back.bottom));
    }
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

  testWidgets('style resizes the footer and recolors the text', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DualShotView(
            result: result,
            showMap: false,
            style: DualShotStyle.light.copyWith(footerHeight: 140),
          ),
        ),
      ),
    );

    final selfie = find
        .byWidgetPredicate((w) => w is Image && w.image is! NetworkImage)
        .last;
    // Footer is 140 tall with a default 8 gap top and bottom, so the
    // thumbnail fills 124 of it.
    expect(tester.getSize(selfie).height, 124);

    final coords = tester.widget<Text>(find.text('18.520430, 73.856743'));
    expect(coords.style!.color, DualShotStyle.light.textColor);
  });

  testWidgets('simultaneous and sequential results render identically', (
    tester,
  ) async {
    Future<List<Rect>> layoutOf(bool simultaneous) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DualShotView(
              result: DualShotResult(
                frontPhoto: result.frontPhoto,
                backPhoto: result.backPhoto,
                timestamp: result.timestamp,
                latitude: result.latitude,
                longitude: result.longitude,
                wasSimultaneous: simultaneous,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return [
        ...find
            .byWidgetPredicate((w) => w is Image && w.image is! NetworkImage)
            .evaluate()
            .map((e) => tester.getRect(find.byWidget(e.widget))),
        tester.getRect(find.byType(MapThumbnail)),
        tester.getRect(find.text('6 Aug 2026, 2:05 PM')),
      ];
    }

    expect(await layoutOf(true), await layoutOf(false));
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

  test('formatTimestamp is human readable around the clock', () {
    expect(formatTimestamp(DateTime(2026, 1, 2, 3, 4)), '2 Jan 2026, 3:04 AM');
    expect(
      formatTimestamp(DateTime(2026, 12, 31, 0, 5)), //
      '31 Dec 2026, 12:05 AM',
    );
    expect(
      formatTimestamp(DateTime(2026, 6, 9, 12, 0)),
      '9 Jun 2026, 12:00 PM',
    );
    expect(
      formatTimestamp(DateTime(2026, 6, 9, 23, 59)),
      '9 Jun 2026, 11:59 PM',
    );
  });
}
