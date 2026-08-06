import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'labels.dart';
import 'map_thumbnail.dart';
import 'models.dart';

/// Renders a [DualShotResult] GPS-camera style: the back photo fills the
/// view, the selfie floats as a card in the top-right, and a translucent
/// bar along the bottom holds the map, coordinates and timestamp.
class DualShotView extends StatelessWidget {
  const DualShotView({
    super.key,
    required this.result,
    this.showMap = true,
    this.labels = const DualCaptureLabels(),
  });

  final DualShotResult result;

  /// Set false to skip the OpenStreetMap thumbnail (e.g. offline apps).
  final bool showMap;

  /// Override to translate or reword every user-visible string.
  final DualCaptureLabels labels;

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
        Positioned(
          top: 12,
          right: 12,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: const [
                BoxShadow(color: Colors.black45, blurRadius: 8),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(
                File(result.frontPhoto.path),
                width: 88,
                height: 117,
                fit: BoxFit.cover,
                cacheHeight: (117 * dpr).round(),
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
            color: Colors.black54,
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
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        formatTimestamp(result.timestamp),
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12),
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
  final boundary = boundaryKey.currentContext!.findRenderObject()!
      as RenderRepaintBoundary;
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
