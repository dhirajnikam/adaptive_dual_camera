import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'labels.dart';
import 'map_thumbnail.dart';
import 'models.dart';

/// Visual knobs for [DualShotView]: where the selfie sits, how big it is,
/// and the colors of the info bar. Everything the composed (and saved)
/// image looks like, in one const-able object.
class DualShotStyle {
  const DualShotStyle({
    this.selfieAlignment = Alignment.topRight,
    this.selfieWidth = 88,
    this.selfieRadius = 10,
    this.selfieBorderColor = Colors.white,
    this.barColor = Colors.black54,
    this.textColor = Colors.white,
    this.barRadius = 0,
  });

  /// Corner (or edge) the selfie card floats in.
  final Alignment selfieAlignment;

  /// Selfie card width; height is a fixed 3:4 portrait.
  final double selfieWidth;

  /// Corner radius of the selfie card.
  final double selfieRadius;

  /// Border color of the selfie card.
  final Color selfieBorderColor;

  /// Background of the info bar (map + coordinates + timestamp).
  final Color barColor;

  /// Primary text color; secondary text derives from it at 70% opacity.
  final Color textColor;

  /// 0 = classic full-width bar flush with the bottom edge; > 0 floats the
  /// bar inset from the edges with rounded corners.
  final double barRadius;

  /// Full-width translucent black bar — the GPS-camera default.
  static const classic = DualShotStyle();

  /// Dark rounded card floating above the bottom edge.
  static const floating = DualShotStyle(
    barRadius: 16,
    barColor: Color(0xCC1C1C1E),
  );

  /// Light rounded card for bright, airy shots.
  static const light = DualShotStyle(
    barRadius: 16,
    barColor: Color(0xE6FFFFFF),
    textColor: Color(0xDE000000),
  );

  DualShotStyle copyWith({
    Alignment? selfieAlignment,
    double? selfieWidth,
    double? selfieRadius,
    Color? selfieBorderColor,
    Color? barColor,
    Color? textColor,
    double? barRadius,
  }) {
    return DualShotStyle(
      selfieAlignment: selfieAlignment ?? this.selfieAlignment,
      selfieWidth: selfieWidth ?? this.selfieWidth,
      selfieRadius: selfieRadius ?? this.selfieRadius,
      selfieBorderColor: selfieBorderColor ?? this.selfieBorderColor,
      barColor: barColor ?? this.barColor,
      textColor: textColor ?? this.textColor,
      barRadius: barRadius ?? this.barRadius,
    );
  }
}

/// Renders a [DualShotResult] GPS-camera style: the back photo fills the
/// view, the selfie floats as a card, and a translucent bar holds the map,
/// coordinates and timestamp. Pass a [DualShotStyle] to move the selfie,
/// resize it, or recolor the bar — the saved image follows whatever is on
/// screen.
class DualShotView extends StatelessWidget {
  const DualShotView({
    super.key,
    required this.result,
    this.showMap = true,
    this.labels = const DualCaptureLabels(),
    this.style = DualShotStyle.classic,
  });

  final DualShotResult result;

  /// Set false to skip the OpenStreetMap thumbnail (e.g. offline apps).
  final bool showMap;

  /// Override to translate or reword every user-visible string.
  final DualCaptureLabels labels;

  /// Layout and colors; see [DualShotStyle.classic], [DualShotStyle.floating]
  /// and [DualShotStyle.light] for ready-made looks.
  final DualShotStyle style;

  @override
  Widget build(BuildContext context) {
    // Decode at display size instead of full camera resolution — much faster
    // to load and far less memory on old devices.
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final backWidth = (MediaQuery.sizeOf(context).width * dpr).round();

    return Stack(
      fit: StackFit.expand,
      children: [
        Image.file(
          File(result.backPhoto.path),
          fit: BoxFit.cover,
          cacheWidth: backWidth,
        ),
        // Selfie card.
        Padding(
          // ponytail: fixed 100px bottom inset clears the info bar for
          // bottom alignments; measure the bar if styles ever grow taller.
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 100),
          child: Align(
            alignment: style.selfieAlignment,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(style.selfieRadius),
                border: Border.all(color: style.selfieBorderColor, width: 2),
                boxShadow: const [
                  BoxShadow(color: Colors.black45, blurRadius: 8),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(style.selfieRadius - 2),
                child: Image.file(
                  File(result.frontPhoto.path),
                  width: style.selfieWidth,
                  height: style.selfieWidth * 4 / 3,
                  fit: BoxFit.cover,
                  cacheHeight: (style.selfieWidth * 4 / 3 * dpr).round(),
                ),
              ),
            ),
          ),
        ),
        // Bottom info bar.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            margin: style.barRadius > 0 ? const EdgeInsets.all(12) : null,
            decoration: BoxDecoration(
              color: style.barColor,
              borderRadius: BorderRadius.circular(style.barRadius),
            ),
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                if (showMap && result.hasLocation) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 64,
                      height: 64,
                      child: MapThumbnail(
                        latitude: result.latitude!,
                        longitude: result.longitude!,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        result.hasLocation
                            ? '${result.latitude!.toStringAsFixed(6)}, '
                                  '${result.longitude!.toStringAsFixed(6)}'
                            : labels.locationUnavailable,
                        style: TextStyle(
                          color: style.textColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        formatTimestamp(result.timestamp),
                        style: TextStyle(
                          color: style.textColor.withValues(alpha: 0.7),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Saves the composed layout as ONE image file (PNG), next to the captured
/// photos in the app's cache. Wrap the on-screen [DualShotView] in a
/// [RepaintBoundary] with [boundaryKey]:
///
/// ```dart
/// final key = GlobalKey();
/// RepaintBoundary(key: key, child: DualShotView(result: result))
/// ...
/// final file = await saveComposedDualShot(key, result);
/// ```
///
/// It snapshots whatever is on screen, so the PNG matches the view's
/// [DualShotStyle] exactly. [pixelRatio] trades file size for sharpness.
///
/// The cache directory can be evicted by the OS — copy the file somewhere
/// permanent if the user is meant to keep it.
Future<File> saveComposedDualShot(
  GlobalKey boundaryKey,
  DualShotResult result, {
  double pixelRatio = 2,
}) async {
  if (result.hasLocation) {
    // Wait for the map tile to arrive and paint before snapshotting, so a
    // quick save doesn't capture an empty map square. Offline the precache
    // fails fast and the on-screen fallback icon is captured instead.
    // ponytail: also waits when showMap is false — worst case one wasted
    // tile fetch capped at 3s; thread showMap through if that ever matters.
    await precacheImage(
      NetworkImage(MapThumbnail.tileUrl(result.latitude!, result.longitude!)),
      boundaryKey.currentContext!,
      onError: (_, _) {},
    ).timeout(const Duration(seconds: 3), onTimeout: () {});
    await WidgetsBinding.instance.endOfFrame;
  }
  final boundary =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: pixelRatio);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(
      '${File(result.backPhoto.path).parent.path}'
      '${Platform.pathSeparator}DUAL_${result.timestamp.millisecondsSinceEpoch}.png',
    );
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    return file;
  } finally {
    image.dispose();
  }
}

/// `2026-08-06 14:05` — stdlib only, no intl dependency.
String formatTimestamp(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}
