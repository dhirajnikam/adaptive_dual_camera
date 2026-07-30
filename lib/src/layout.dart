import 'package:flutter/widgets.dart';

import 'models.dart';

/// Built-in arrangements for a back/front pair.
enum DualLayout {
  /// Secondary feed floats over the primary one.
  pictureInPicture,

  /// Two equal panes, left and right.
  sideBySide,

  /// Two equal panes, top and bottom.
  stacked,

  /// Primary only; the secondary widget isn't built.
  primaryOnly,
}

/// Signature for taking full control of the arrangement.
typedef DualLayoutBuilder =
    Widget Function(BuildContext context, Widget back, Widget front);

/// Every visual knob for a back/front pair, in one place.
///
/// [DualLayoutView], [DualCameraPreview] and [DualCaptureView] all take one of
/// these, so a viewfinder and the result it produces can be configured
/// identically — build the style once and pass it to both.
///
/// ```dart
/// const style = DualLayoutStyle(
///   layout: DualLayout.pictureInPicture,
///   insetAlignment: Alignment.bottomLeft,
///   background: Colors.black,
/// );
///
/// DualCameraPreview(controller: controller, style: style);
/// DualCaptureView(capture: shot, style: style);
/// ```
class DualLayoutStyle {
  const DualLayoutStyle({
    this.layout = DualLayout.pictureInPicture,
    this.primary = DualCamera.back,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.background,
    this.paneBorderRadius,
    this.gap = 4,
    this.insetAlignment = Alignment.topRight,
    this.insetScale = 0.3,
    this.insetAspectRatio = 3 / 4,
    this.insetMargin = const EdgeInsets.all(12),
    this.insetBorderRadius = const BorderRadius.all(Radius.circular(12)),
    this.insetBorder,
    this.clipBehavior = Clip.hardEdge,
  }) : assert(insetScale > 0 && insetScale <= 1),
       assert(insetAspectRatio > 0);

  /// Which arrangement to use.
  final DualLayout layout;

  /// Which camera gets the large pane. The other is the inset / second pane.
  final DualCamera primary;

  /// How each feed fills its pane.
  ///
  /// Defaults to [BoxFit.contain] so nothing is ever cropped — a portrait feed
  /// in a landscape pane is letterboxed with [background] rather than having
  /// its edges cut off. Use [BoxFit.cover] for an edge-to-edge look that
  /// crops instead.
  final BoxFit fit;

  /// Where a feed sits in its pane when [fit] leaves spare room.
  final Alignment alignment;

  /// Fills the space [BoxFit.contain] leaves around a feed. Transparent if null.
  final Color? background;

  /// Rounds the main panes. The inset has its own [insetBorderRadius].
  final BorderRadius? paneBorderRadius;

  /// Space between panes in [DualLayout.sideBySide] and [DualLayout.stacked].
  final double gap;

  /// Where the floating feed sits in [DualLayout.pictureInPicture].
  final Alignment insetAlignment;

  /// Floating feed's width as a fraction of the widget's shortest side.
  final double insetScale;

  /// Shape of the floating feed. Its width comes from [insetScale]; this sets
  /// the height, so the inset is a definite box rather than whatever the
  /// content happens to measure.
  final double insetAspectRatio;

  /// Space between the floating feed and the edges.
  final EdgeInsets insetMargin;

  final BorderRadius insetBorderRadius;

  /// Optional outline around the floating feed.
  final BoxBorder? insetBorder;

  final Clip clipBehavior;

  DualLayoutStyle copyWith({
    DualLayout? layout,
    DualCamera? primary,
    BoxFit? fit,
    Alignment? alignment,
    Color? background,
    BorderRadius? paneBorderRadius,
    double? gap,
    Alignment? insetAlignment,
    double? insetScale,
    double? insetAspectRatio,
    EdgeInsets? insetMargin,
    BorderRadius? insetBorderRadius,
    BoxBorder? insetBorder,
    Clip? clipBehavior,
  }) => DualLayoutStyle(
    layout: layout ?? this.layout,
    primary: primary ?? this.primary,
    fit: fit ?? this.fit,
    alignment: alignment ?? this.alignment,
    background: background ?? this.background,
    paneBorderRadius: paneBorderRadius ?? this.paneBorderRadius,
    gap: gap ?? this.gap,
    insetAlignment: insetAlignment ?? this.insetAlignment,
    insetScale: insetScale ?? this.insetScale,
    insetAspectRatio: insetAspectRatio ?? this.insetAspectRatio,
    insetMargin: insetMargin ?? this.insetMargin,
    insetBorderRadius: insetBorderRadius ?? this.insetBorderRadius,
    insetBorder: insetBorder ?? this.insetBorder,
    clipBehavior: clipBehavior ?? this.clipBehavior,
  );
}

/// Arranges any two widgets as a back/front pair.
///
/// Both [DualCameraPreview] and [DualCaptureView] render through this, so a
/// viewfinder and its result can share one [DualLayoutStyle]. You can also use
/// it directly with widgets of your own.
///
/// For arrangements the presets don't cover, pass [builder] — [style]'s layout
/// settings are then ignored.
class DualLayoutView extends StatelessWidget {
  const DualLayoutView({
    super.key,
    required this.back,
    required this.front,
    this.style = const DualLayoutStyle(),
    this.builder,
  });

  final Widget back;
  final Widget front;

  final DualLayoutStyle style;

  /// Full override. Receives the two feed widgets already built.
  final DualLayoutBuilder? builder;

  Widget get _primary => style.primary == DualCamera.back ? back : front;

  Widget get _secondary => style.primary == DualCamera.back ? front : back;

  /// Backdrop for whatever space [DualLayoutStyle.fit] leaves around a feed.
  Widget _pane(Widget child) {
    Widget pane = child;
    if (style.background != null) {
      pane = ColoredBox(color: style.background!, child: pane);
    }
    if (style.paneBorderRadius != null) {
      pane = ClipRRect(borderRadius: style.paneBorderRadius!, child: pane);
    }
    return pane;
  }

  @override
  Widget build(BuildContext context) {
    final builder = this.builder;
    if (builder != null) return builder(context, back, front);

    switch (style.layout) {
      case DualLayout.primaryOnly:
        return _pane(_primary);

      case DualLayout.sideBySide:
        return Row(
          children: [
            Expanded(child: _pane(_primary)),
            SizedBox(width: style.gap),
            Expanded(child: _pane(_secondary)),
          ],
        );

      case DualLayout.stacked:
        return Column(
          children: [
            Expanded(child: _pane(_primary)),
            SizedBox(height: style.gap),
            Expanded(child: _pane(_secondary)),
          ],
        );

      case DualLayout.pictureInPicture:
        return LayoutBuilder(
          builder: (context, constraints) {
            // Scale off the shortest side so the inset stays square-ish in
            // both orientations instead of stretching with the long edge.
            final shortest = constraints.biggest.shortestSide;
            return Stack(
              fit: StackFit.expand,
              clipBehavior: style.clipBehavior,
              children: [
                _pane(_primary),
                Padding(
                  padding: style.insetMargin,
                  child: Align(
                    alignment: style.insetAlignment,
                    child: SizedBox(
                      width: shortest * style.insetScale,
                      // A definite box: without this the inset would take its
                      // height from the content and the feed could spill or
                      // collapse.
                      child: AspectRatio(
                        aspectRatio: style.insetAspectRatio,
                        child: _inset(_secondary),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
    }
  }

  Widget _inset(Widget child) {
    Widget inset = ClipRRect(
      borderRadius: style.insetBorderRadius,
      child: _pane(child),
    );
    if (style.insetBorder != null) {
      inset = DecoratedBox(
        decoration: BoxDecoration(
          border: style.insetBorder,
          borderRadius: style.insetBorderRadius,
        ),
        child: inset,
      );
    }
    return inset;
  }
}
