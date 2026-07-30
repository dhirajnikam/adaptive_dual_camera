import 'dart:io';

import 'package:adaptive_dual_camera/adaptive_dual_camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_platform.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
    home: Scaffold(body: SizedBox(width: 300, height: 400, child: child)),
  );

  Widget layoutView(
    DualLayout layout, {
    DualCamera primary = DualCamera.back,
  }) => DualLayoutView(
    back: const Text('BACK'),
    front: const Text('FRONT'),
    style: DualLayoutStyle(layout: layout, primary: primary),
  );

  group('DualLayoutStyle', () {
    test('defaults to contain so nothing is cropped', () {
      expect(const DualLayoutStyle().fit, BoxFit.contain);
    });

    test('copyWith changes one thing and keeps the rest', () {
      const base = DualLayoutStyle(
        layout: DualLayout.stacked,
        insetScale: 0.5,
        background: Color(0xFF102030),
      );

      final tweaked = base.copyWith(fit: BoxFit.cover);

      expect(tweaked.fit, BoxFit.cover);
      expect(tweaked.layout, DualLayout.stacked);
      expect(tweaked.insetScale, 0.5);
      expect(tweaked.background, const Color(0xFF102030));
    });

    test('rejects an out-of-range inset', () {
      expect(() => DualLayoutStyle(insetScale: 0), throwsAssertionError);
      expect(() => DualLayoutStyle(insetScale: 1.5), throwsAssertionError);
      expect(() => DualLayoutStyle(insetAspectRatio: 0), throwsAssertionError);
    });
  });

  group('DualLayoutView', () {
    for (final layout in [
      DualLayout.pictureInPicture,
      DualLayout.sideBySide,
      DualLayout.stacked,
    ]) {
      testWidgets('$layout shows both feeds', (tester) async {
        await tester.pumpWidget(host(layoutView(layout)));

        expect(find.text('BACK'), findsOneWidget);
        expect(find.text('FRONT'), findsOneWidget);
      });
    }

    testWidgets('primaryOnly builds just the primary', (tester) async {
      await tester.pumpWidget(host(layoutView(DualLayout.primaryOnly)));

      expect(find.text('BACK'), findsOneWidget);
      expect(find.text('FRONT'), findsNothing);
    });

    testWidgets('primary: front swaps which one is large', (tester) async {
      await tester.pumpWidget(
        host(layoutView(DualLayout.primaryOnly, primary: DualCamera.front)),
      );

      expect(find.text('FRONT'), findsOneWidget);
      expect(find.text('BACK'), findsNothing);
    });

    testWidgets('the PiP inset is a definite box, not content-sized', (
      tester,
    ) async {
      await tester.pumpWidget(host(layoutView(DualLayout.pictureInPicture)));

      final inset = tester.getSize(
        find.ancestor(of: find.text('FRONT'), matching: find.byType(ClipRRect)),
      );

      // insetScale 0.3 of the 300pt shortest side...
      expect(inset.width, closeTo(300 * 0.3, 0.01));
      // ...and the height comes from insetAspectRatio (3/4), not the Text.
      expect(inset.height, closeTo(300 * 0.3 / (3 / 4), 0.01));
    });

    testWidgets('insetScale and insetAspectRatio resize the inset', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          DualLayoutView(
            back: const Text('BACK'),
            front: const Text('FRONT'),
            style: const DualLayoutStyle(insetScale: 0.5, insetAspectRatio: 1),
          ),
        ),
      );

      final inset = tester.getSize(
        find.ancestor(of: find.text('FRONT'), matching: find.byType(ClipRRect)),
      );

      expect(inset.width, closeTo(150, 0.01));
      expect(inset.height, closeTo(150, 0.01));
    });

    testWidgets('insetAlignment moves the floating feed', (tester) async {
      Future<Offset> cornerFor(Alignment alignment) async {
        await tester.pumpWidget(
          host(
            DualLayoutView(
              back: const Text('BACK'),
              front: const Text('FRONT'),
              style: DualLayoutStyle(insetAlignment: alignment),
            ),
          ),
        );
        return tester.getTopLeft(find.text('FRONT'));
      }

      final topLeft = await cornerFor(Alignment.topLeft);
      final bottomRight = await cornerFor(Alignment.bottomRight);

      expect(bottomRight.dx, greaterThan(topLeft.dx));
      expect(bottomRight.dy, greaterThan(topLeft.dy));
    });

    testWidgets('background backs every pane', (tester) async {
      await tester.pumpWidget(
        host(
          DualLayoutView(
            back: const Text('BACK'),
            front: const Text('FRONT'),
            style: const DualLayoutStyle(
              layout: DualLayout.sideBySide,
              background: Color(0xFF102030),
            ),
          ),
        ),
      );

      final boxes = tester
          .widgetList<ColoredBox>(find.byType(ColoredBox))
          .where((b) => b.color == const Color(0xFF102030));
      expect(boxes.length, 2);
    });

    testWidgets('no background means no ColoredBox of our own', (tester) async {
      await tester.pumpWidget(host(layoutView(DualLayout.sideBySide)));

      expect(
        find.descendant(
          of: find.byType(DualLayoutView),
          matching: find.byType(ColoredBox),
        ),
        findsNothing,
      );
    });

    testWidgets('builder takes over completely', (tester) async {
      await tester.pumpWidget(
        host(
          DualLayoutView(
            back: const Text('BACK'),
            front: const Text('FRONT'),
            // Style says PiP, but the builder wins.
            style: const DualLayoutStyle(layout: DualLayout.pictureInPicture),
            builder: (context, back, front) =>
                Column(children: [const Text('CUSTOM'), back, front]),
          ),
        ),
      );

      expect(find.text('CUSTOM'), findsOneWidget);
      expect(find.text('BACK'), findsOneWidget);
      expect(find.text('FRONT'), findsOneWidget);
    });
  });

  group('DualCaptureView', () {
    final capture = DualCapture(
      back: File('/cache/back.jpg'),
      front: File('/cache/front.jpg'),
      mode: DualCaptureMode.simultaneous,
    );

    testWidgets('renders each file through imageBuilder', (tester) async {
      await tester.pumpWidget(
        host(
          DualCaptureView(
            capture: capture,
            style: const DualLayoutStyle(layout: DualLayout.sideBySide),
            imageBuilder: (context, camera, file) =>
                Text('${camera.name}:${file.path}'),
          ),
        ),
      );

      expect(find.text('back:/cache/back.jpg'), findsOneWidget);
      expect(find.text('front:/cache/front.jpg'), findsOneWidget);
    });

    testWidgets('photos default to contain so they are not cropped', (
      tester,
    ) async {
      await tester.pumpWidget(host(DualCaptureView(capture: capture)));

      final images = tester.widgetList<Image>(find.byType(Image));
      expect(images, isNotEmpty);
      expect(images.every((i) => i.fit == BoxFit.contain), isTrue);
    });

    testWidgets('style.fit reaches the images', (tester) async {
      await tester.pumpWidget(
        host(
          DualCaptureView(
            capture: capture,
            style: const DualLayoutStyle(fit: BoxFit.cover),
          ),
        ),
      );

      final images = tester.widgetList<Image>(find.byType(Image));
      expect(images.every((i) => i.fit == BoxFit.cover), isTrue);
    });

    testWidgets('errorBuilder is wired into each image, tagged per camera', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          DualCaptureView(
            capture: capture,
            style: const DualLayoutStyle(layout: DualLayout.sideBySide),
            errorBuilder: (context, camera, error) =>
                Text('broken ${camera.name}'),
          ),
        ),
      );

      // Driving a real decode failure means real filesystem timing; invoke the
      // callback the way Image would instead.
      final images = find.byType(Image);
      expect(images, findsNWidgets(2));
      final rendered = [
        for (var i = 0; i < 2; i++)
          tester.widget<Image>(images.at(i)).errorBuilder!(
            tester.element(images.at(i)),
            'boom',
            null,
          ),
      ];

      expect(rendered.whereType<Text>().map((t) => t.data), [
        'broken back',
        'broken front',
      ]);
    });

    testWidgets('without errorBuilder a broken image renders nothing', (
      tester,
    ) async {
      await tester.pumpWidget(host(DualCaptureView(capture: capture)));

      final image = tester.widget<Image>(find.byType(Image).first);
      final fallback = image.errorBuilder!(
        tester.element(find.byType(Image).first),
        'boom',
        null,
      );

      expect(fallback, isA<SizedBox>());
    });

    testWidgets('accepts a raw file pair, e.g. video clips', (tester) async {
      await tester.pumpWidget(
        host(
          DualCaptureView(
            files: {
              DualCamera.back: File('/cache/back.mp4'),
              DualCamera.front: File('/cache/front.mp4'),
            },
            style: const DualLayoutStyle(layout: DualLayout.stacked),
            imageBuilder: (context, camera, file) => Text(file.path),
          ),
        ),
      );

      expect(find.text('/cache/back.mp4'), findsOneWidget);
      expect(find.text('/cache/front.mp4'), findsOneWidget);
    });

    test('rejects being given both sources at once', () {
      expect(
        () => DualCaptureView(capture: capture, files: const {}),
        throwsAssertionError,
      );
    });
  });

  group('DualCameraPreview', () {
    testWidgets('draws a placeholder for a camera that is not live', (
      tester,
    ) async {
      final controller = DualCameraController(
        platform: FakePlatform(simultaneous: false),
      );
      await controller.initialize();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        host(
          DualCameraPreview(
            controller: controller,
            style: const DualLayoutStyle(layout: DualLayout.sideBySide),
            placeholderBuilder: (context, camera) => Text('no ${camera.name}'),
          ),
        ),
      );

      // Back is live, so it gets a Texture; front is dark.
      expect(find.text('no front'), findsOneWidget);
      expect(find.text('no back'), findsNothing);
      expect(find.byType(Texture), findsOneWidget);
    });

    testWidgets('draws both textures on simultaneous hardware', (tester) async {
      final controller = DualCameraController(
        platform: FakePlatform(simultaneous: true),
      );
      await controller.initialize();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        host(
          DualCameraPreview(
            controller: controller,
            style: const DualLayoutStyle(layout: DualLayout.sideBySide),
          ),
        ),
      );

      expect(find.byType(Texture), findsNWidgets(2));
    });

    testWidgets('style.fit reaches the live feeds', (tester) async {
      final controller = DualCameraController(
        platform: FakePlatform(simultaneous: true),
      );
      await controller.initialize();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        host(
          DualCameraPreview(
            controller: controller,
            style: const DualLayoutStyle(
              layout: DualLayout.sideBySide,
              fit: BoxFit.cover,
            ),
          ),
        ),
      );

      final feeds = tester.widgetList<DualCameraFeed>(
        find.byType(DualCameraFeed),
      );
      expect(feeds.length, 2);
      expect(feeds.every((f) => f.fit == BoxFit.cover), isTrue);
    });

    testWidgets('follows the controller when the live camera switches', (
      tester,
    ) async {
      final controller = DualCameraController(
        platform: FakePlatform(simultaneous: false),
      );
      await controller.initialize();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        host(
          DualCameraPreview(
            controller: controller,
            style: const DualLayoutStyle(layout: DualLayout.sideBySide),
            placeholderBuilder: (context, camera) => Text('no ${camera.name}'),
          ),
        ),
      );
      expect(find.text('no front'), findsOneWidget);

      await controller.switchTo(DualCamera.front);
      await tester.pump();

      expect(find.text('no back'), findsOneWidget);
      expect(find.text('no front'), findsNothing);
    });
  });

  group('DualCameraFeed', () {
    testWidgets('mirrors and rotates according to the feed', (tester) async {
      await tester.pumpWidget(
        host(
          const DualCameraFeed(
            feed: DualFeed(
              textureId: 7,
              width: 1280,
              height: 720,
              sensorOrientation: 270,
              mirrored: true,
            ),
          ),
        ),
      );

      expect(find.byType(Texture), findsOneWidget);
      expect(find.byType(RotatedBox), findsOneWidget);
      expect(
        tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns,
        3,
      );
      // Rotation must be inside the mirror, not the other way round.
      expect(
        find.ancestor(
          of: find.byType(RotatedBox),
          matching: find.byType(Transform),
        ),
        findsWidgets,
      );
    });

    testWidgets('an upright unmirrored feed adds no transforms', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const DualCameraFeed(
            feed: DualFeed(
              textureId: 7,
              width: 720,
              height: 1280,
              sensorOrientation: 0,
              mirrored: false,
            ),
          ),
        ),
      );

      expect(find.byType(RotatedBox), findsNothing);
    });

    testWidgets('contain shows the whole frame; cover fills and crops', (
      tester,
    ) async {
      const feed = DualFeed(
        textureId: 7,
        width: 720,
        height: 1280,
        sensorOrientation: 0,
        mirrored: false,
      );

      // A 9:16 feed in a 300x400 (3:4) pane. FittedBox scales with a
      // transform, so measure the painted rect, not the child's own size.
      await tester.pumpWidget(
        host(const DualCameraFeed(feed: feed, fit: BoxFit.contain)),
      );
      final contained = tester.getRect(find.byType(Texture));

      await tester.pumpWidget(
        host(const DualCameraFeed(feed: feed, fit: BoxFit.cover)),
      );
      final covered = tester.getRect(find.byType(Texture));

      // Contain fits the whole frame inside the pane — nothing cropped.
      expect(contained.width, lessThanOrEqualTo(300 + 0.01));
      expect(contained.height, lessThanOrEqualTo(400 + 0.01));
      expect(contained.height, closeTo(400, 0.01));
      expect(contained.width, closeTo(400 * 720 / 1280, 0.01));

      // Cover fills the pane and overflows, so the sides get clipped away.
      expect(covered.width, closeTo(300, 0.01));
      expect(covered.height, greaterThan(400));
    });

    test('displayAspectRatio swaps for sideways sensors', () {
      const upright = DualFeed(
        textureId: 0,
        width: 720,
        height: 1280,
        sensorOrientation: 0,
        mirrored: false,
      );
      const sideways = DualFeed(
        textureId: 0,
        width: 1280,
        height: 720,
        sensorOrientation: 90,
        mirrored: false,
      );

      expect(upright.displayAspectRatio, 720 / 1280);
      expect(sideways.displayAspectRatio, 720 / 1280);
    });
  });
}
