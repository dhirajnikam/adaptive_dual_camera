import 'dart:io';

import 'package:flutter/widgets.dart';

import 'controller.dart';
import 'layout.dart';
import 'models.dart';

/// Draws one live camera feed, rotated and mirrored so it looks right.
///
/// Assumes a portrait-locked UI: rotation comes from the sensor only.
/// ponytail: no device-rotation listener. Wrap it in your own `RotatedBox` if
/// you support a rotating camera screen.
class DualCameraFeed extends StatelessWidget {
  const DualCameraFeed({
    super.key,
    required this.feed,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.background,
  });

  final DualFeed feed;

  /// How the feed fills its slot. [BoxFit.contain] (the default) shows the
  /// whole frame, letterboxed; [BoxFit.cover] fills the slot and crops.
  final BoxFit fit;

  final Alignment alignment;

  /// Fills whatever space [fit] leaves around the frame.
  final Color? background;

  @override
  Widget build(BuildContext context) {
    Widget texture = Texture(textureId: feed.textureId);

    // Rotate upright first, then mirror — mirroring the *displayed* image is
    // what reads as a selfie view. Flipping before rotation is not the same
    // thing for 90/270 degree sensors.
    if (feed.sensorOrientation % 360 != 0) {
      texture = RotatedBox(
        quarterTurns: (feed.sensorOrientation ~/ 90) % 4,
        child: texture,
      );
    }
    if (feed.mirrored) {
      texture = Transform.scale(scaleX: -1, child: texture);
    }

    // FittedBox needs the frame's shape; the texture itself has no intrinsic
    // size, so hand it one that carries only the aspect ratio.
    Widget framed = ClipRect(
      child: FittedBox(
        fit: fit,
        alignment: alignment,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: feed.displayAspectRatio,
          height: 1,
          child: texture,
        ),
      ),
    );

    if (background != null) {
      framed = ColoredBox(color: background!, child: framed);
    }
    return framed;
  }
}

/// Live viewfinder for both cameras.
///
/// Everything visual lives on [DualLayoutStyle], which [DualCaptureView] takes
/// too — build one style and the viewfinder and its result look the same:
///
/// ```dart
/// DualCameraPreview(
///   controller: controller,
///   style: const DualLayoutStyle(
///     layout: DualLayout.pictureInPicture,
///     insetAlignment: Alignment.bottomLeft,
///     background: Color(0xFF000000),
///   ),
/// )
/// ```
///
/// On sequential hardware only [DualCameraController.activeCamera] is live;
/// the other slot gets [placeholderBuilder].
class DualCameraPreview extends StatelessWidget {
  const DualCameraPreview({
    super.key,
    required this.controller,
    this.style = const DualLayoutStyle(),
    this.builder,
    this.placeholderBuilder,
  });

  final DualCameraController controller;

  final DualLayoutStyle style;

  /// Full control of the arrangement. Receives the two feed widgets.
  final DualLayoutBuilder? builder;

  /// Drawn in place of a camera that isn't live (sequential hardware, or
  /// before [DualCameraController.initialize] finishes). Defaults to nothing.
  final Widget Function(BuildContext, DualCamera)? placeholderBuilder;

  Widget _slot(BuildContext context, DualCamera camera) {
    final feed = controller.feedFor(camera);
    if (feed == null) {
      return placeholderBuilder?.call(context, camera) ??
          const SizedBox.expand();
    }
    // Background is applied once, by DualLayoutView, so it also backs the
    // placeholder and any custom children.
    return DualCameraFeed(
      feed: feed,
      fit: style.fit,
      alignment: style.alignment,
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => DualLayoutView(
      back: _slot(context, DualCamera.back),
      front: _slot(context, DualCamera.front),
      style: style,
      builder: builder,
    ),
  );
}

/// Shows a finished [DualCapture] — or any back/front file pair — using the
/// same [DualLayoutStyle] as [DualCameraPreview].
///
/// Photos are drawn with [BoxFit.contain] by default, so the whole frame is
/// visible rather than cropped to the pane. Switch [DualLayoutStyle.fit] to
/// [BoxFit.cover] if you'd rather fill the space.
///
/// Pass [capture] for photos, or [files] to lay out anything else — video
/// thumbnails, a [DualRecording]'s clips fed to your own player, and so on.
class DualCaptureView extends StatelessWidget {
  const DualCaptureView({
    super.key,
    this.capture,
    this.files,
    this.style = const DualLayoutStyle(),
    this.builder,
    this.imageBuilder,
    this.errorBuilder,
  }) : assert(
         (capture == null) != (files == null),
         'Pass exactly one of capture or files.',
       );

  /// A photo pair. Rendered with [Image.file] unless [imageBuilder] is given.
  final DualCapture? capture;

  /// An arbitrary back/front file pair — e.g. `{DualCamera.back: recording.back}`.
  /// Needs [imageBuilder] unless the files are images.
  final Map<DualCamera, File>? files;

  final DualLayoutStyle style;

  final DualLayoutBuilder? builder;

  /// Renders one file. Supply this for video clips, cached decoding, heroes, …
  final Widget Function(BuildContext, DualCamera, File)? imageBuilder;

  /// Drawn when a file can't be decoded. Defaults to nothing.
  final Widget Function(BuildContext, DualCamera, Object)? errorBuilder;

  Widget _slot(BuildContext context, DualCamera camera) {
    final file = capture?[camera] ?? files?[camera];
    if (file == null) return const SizedBox.expand();

    // Background is applied once, by DualLayoutView.
    return imageBuilder?.call(context, camera, file) ??
        Image.file(
          file,
          fit: style.fit,
          alignment: style.alignment,
          key: ValueKey(file.path),
          errorBuilder: (context, error, stack) =>
              errorBuilder?.call(context, camera, error) ??
              const SizedBox.expand(),
        );
  }

  @override
  Widget build(BuildContext context) => DualLayoutView(
    back: _slot(context, DualCamera.back),
    front: _slot(context, DualCamera.front),
    style: style,
    builder: builder,
  );
}
