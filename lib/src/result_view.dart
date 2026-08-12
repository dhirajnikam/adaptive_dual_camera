import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'labels.dart';
import 'map_thumbnail.dart';
import 'models.dart';

/// Visual knobs for [DualShotView]: the proportions of the two rows, the size
/// of the thumbnails, and the colors of the footer. Everything the composed
/// (and saved) image looks like, in one const-able object.
class DualShotStyle {
  const DualShotStyle({
    this.footerHeight = 96,
    this.thumbnailRadius = 8,
    this.thumbnailBorderColor,
    this.footerColor = const Color(0xFF1C1C1E),
    this.textColor = Colors.white,
    this.gap = 8,
    this.showMapInFooter = true,
  });

  /// Height of the bottom row. The back photo takes whatever is left.
  final double footerHeight;

  /// Corner radius of the selfie and map thumbnails.
  final double thumbnailRadius;

  /// Optional hairline around the thumbnails; null for none.
  final Color? thumbnailBorderColor;

  /// Footer background.
  final Color footerColor;

  /// Primary text; the timestamp uses it at 70% opacity.
  final Color textColor;

  /// Spacing between the footer's cells and around its edges.
  final double gap;

  /// Set false to drop the map cell but keep the coordinates — the offline
  /// middle ground between a full map and no location at all.
  final bool showMapInFooter;

  /// Dark footer, the default.
  static const dark = DualShotStyle();

  /// Light footer for bright, airy shots.
  static const light = DualShotStyle(
    footerColor: Color(0xFFF2F2F7),
    textColor: Color(0xDE000000),
  );

  /// Taller footer with bigger type — easier to read at a glance, and what
  /// you want if the image will be viewed as a thumbnail.
  static const tall = DualShotStyle(footerHeight: 128, gap: 12);

  DualShotStyle copyWith({
    double? footerHeight,
    double? thumbnailRadius,
    Color? thumbnailBorderColor,
    Color? footerColor,
    Color? textColor,
    double? gap,
    bool? showMapInFooter,
  }) {
    return DualShotStyle(
      footerHeight: footerHeight ?? this.footerHeight,
      thumbnailRadius: thumbnailRadius ?? this.thumbnailRadius,
      thumbnailBorderColor: thumbnailBorderColor ?? this.thumbnailBorderColor,
      footerColor: footerColor ?? this.footerColor,
      textColor: textColor ?? this.textColor,
      gap: gap ?? this.gap,
      showMapInFooter: showMapInFooter ?? this.showMapInFooter,
    );
  }
}

/// Renders a [DualShotResult] as
/// `Column[back photo, Row[front photo, map, lat/long/timestamp]]`.
///
/// The card takes its shape from the back photo: full photo at its own
/// aspect ratio, footer below. When the parent's box is shorter than that,
/// the whole card scales down together rather than cropping the photo — a
/// cover-fit here used to shave the top and bottom off every 16:9 shot,
/// which read as "the footer ate the bottom of my photo".
///
/// The layout is the same whether the two photos were taken simultaneously or
/// one after the other — [DualShotResult.wasSimultaneous] changes nothing
/// here on purpose, so a mixed fleet of devices produces one consistent
/// image.
class DualShotView extends StatefulWidget {
  const DualShotView({
    super.key,
    required this.result,
    this.showMap = true,
    this.labels = const DualCaptureLabels(),
    this.style = DualShotStyle.dark,
    this.boundaryKey,
    this.backAspect,
  });

  final DualShotResult result;

  /// Set false to skip the OpenStreetMap thumbnail (e.g. offline apps).
  final bool showMap;

  /// Override to translate or reword every user-visible string.
  final DualCaptureLabels labels;

  /// Sizes and colors; see [DualShotStyle.dark], [DualShotStyle.light] and
  /// [DualShotStyle.tall].
  final DualShotStyle style;

  /// Key for [saveComposedDualShot]. Placed on a [RepaintBoundary] around
  /// the card itself (photo + footer, nothing else), so the saved image has
  /// no empty margins from whatever box the view happens to be centered in.
  final GlobalKey? boundaryKey;

  /// Back photo width/height, if the caller already knows it. The view learns
  /// it from the decode otherwise, which means one reflow from the 3:4
  /// placeholder — pass it to skip that. [composeDualShot] does, because a
  /// snapshot can't wait for a reflow it can't see.
  final double? backAspect;

  @override
  State<DualShotView> createState() => _DualShotViewState();
}

class _DualShotViewState extends State<DualShotView> {
  /// Back photo width/height as decoded (EXIF applied); 3:4 until known.
  late double _backAspect = widget.backAspect ?? 3 / 4;

  ImageProvider? _backProvider;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  DualShotResult get result => widget.result;
  DualShotStyle get style => widget.style;
  DualCaptureLabels get labels => widget.labels;

  bool get _mapVisible =>
      widget.showMap && style.showMapInFooter && result.hasLocation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Decode at display size instead of full camera resolution — much faster
    // to load and far less memory on old devices. The same provider drives
    // both the on-screen Image and the aspect lookup, so it decodes once.
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final provider = ResizeImage(
      FileImage(File(result.backPhoto.path)),
      width: (MediaQuery.sizeOf(context).width * dpr).round(),
    );
    if (provider == _backProvider) return;
    _backProvider = provider;
    _stream?.removeListener(_listener!);
    _listener = ImageStreamListener((info, _) {
      final aspect = info.image.width / info.image.height;
      info.dispose();
      if (mounted && aspect != _backAspect) {
        setState(() => _backAspect = aspect);
      }
    }, onError: (_, _) {});
    _stream = provider.resolve(ImageConfiguration.empty)
      ..addListener(_listener!);
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener!);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cell = style.footerHeight - style.gap * 2;

    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth.isFinite ? box.maxWidth : 360.0;
        return FittedBox(
          fit: BoxFit.scaleDown,
          child: RepaintBoundary(
            key: widget.boundaryKey,
            child: SizedBox(
              width: width,
              height: width / _backAspect + style.footerHeight,
              child: Column(
                children: [
                  Expanded(
                    child: SizedBox(
                      width: double.infinity,
                      // The box above matches the photo's aspect exactly, so
                      // this cover neither crops nor letterboxes. Gapless so
                      // the aspect settling or a style switch never flashes
                      // an empty frame.
                      child: Image(
                        image: _backProvider!,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                      ),
                    ),
                  ),
                  SizedBox(
                    height: style.footerHeight,
                    child: Container(
                      color: style.footerColor,
                      padding: EdgeInsets.all(style.gap),
                      child: Row(
                        children: [
                          _framed(
                            child: Image.file(
                              File(result.frontPhoto.path),
                              width: cell * 3 / 4,
                              height: cell,
                              fit: BoxFit.cover,
                              cacheHeight: (cell * dpr).round(),
                            ),
                          ),
                          SizedBox(width: style.gap),
                          if (_mapVisible) ...[
                            _framed(
                              child: SizedBox(
                                width: cell,
                                height: cell,
                                child: MapThumbnail(
                                  latitude: result.latitude!,
                                  longitude: result.longitude!,
                                ),
                              ),
                            ),
                            SizedBox(width: style.gap),
                          ],
                          Expanded(child: _details()),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _framed({required Widget child}) {
    final clipped = ClipRRect(
      borderRadius: BorderRadius.circular(style.thumbnailRadius),
      child: child,
    );
    final border = style.thumbnailBorderColor;
    if (border == null) return clipped;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(style.thumbnailRadius),
        border: Border.all(color: border),
      ),
      child: clipped,
    );
  }

  Widget _details() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (result.hasLocation) ...[
          _line(
            Icons.place,
            '${result.latitude!.toStringAsFixed(6)}, '
            '${result.longitude!.toStringAsFixed(6)}',
            bold: true,
          ),
          const SizedBox(height: 4),
        ] else ...[
          _line(Icons.location_off, labels.locationUnavailable, bold: true),
          const SizedBox(height: 4),
        ],
        _line(Icons.schedule, formatTimestamp(result.timestamp)),
      ],
    );
  }

  Widget _line(IconData icon, String text, {bool bold = false}) {
    final color = bold
        ? style.textColor
        : style.textColor.withValues(alpha: 0.7);
    return Row(
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      ],
    );
  }
}

/// Saves the composed layout as ONE image file (PNG), next to the captured
/// photos in the app's cache. Hand the key to [DualShotView.boundaryKey] —
/// it sits on a boundary around the card itself, so the saved image is
/// exactly photo + footer with no margins from the surrounding box:
///
/// ```dart
/// final key = GlobalKey();
/// DualShotView(result: result, boundaryKey: key)
/// ...
/// final file = await saveComposedDualShot(key, result);
/// ```
///
/// (Wrapping the whole view in your own [RepaintBoundary] still works, but
/// captures whatever empty space surrounds the centered card.)
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
    // ponytail: also waits when the map is hidden — worst case one wasted
    // tile fetch capped at 3s; thread the flag through if that ever matters.
    await precacheImage(
      NetworkImage(
        MapThumbnail.tileUrl(result.latitude!, result.longitude!),
        // Same headers as the on-screen tile, or OSM throttles this one too.
        headers: MapThumbnail.tileHeaders,
      ),
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

/// Composes a [DualShotResult] into one PNG without showing anything — the
/// no-UI counterpart to [saveComposedDualShot], for apps that want the
/// finished image straight out of `GuidedDualCaptureFlow.onComplete` instead
/// of building a result page first:
///
/// ```dart
/// GuidedDualCaptureFlow(
///   onComplete: (result) async {
///     final file = await composeDualShot(context, result,
///         style: DualShotStyle.light);
///   },
/// )
/// ```
///
/// It renders the same [DualShotView] the on-screen path renders — same
/// [style], [showMap] and [labels] knobs — so the PNG is byte-for-byte what a
/// result page would have saved. [width] is the card's logical width and
/// defaults to the screen's, which is what an on-screen save uses.
///
/// [context] must still be mounted and under an [Overlay] (any [Navigator]
/// route is). The card is inserted just off the left edge for one frame:
/// laid out and painted, so there is a layer to snapshot, but never visible.
Future<File> composeDualShot(
  BuildContext context,
  DualShotResult result, {
  DualShotStyle style = DualShotStyle.dark,
  bool showMap = true,
  DualCaptureLabels labels = const DualCaptureLabels(),
  double? width,
  double pixelRatio = 2,
}) async {
  // Decode the back photo first: the card takes its shape from that aspect
  // and normally learns it a frame or two after mounting. A snapshot can't
  // wait for a reflow it can't observe, so it would compose against the 3:4
  // placeholder and cover-crop a 16:9 shot.
  final aspect = await _decodedAspect(File(result.backPhoto.path));
  if (!context.mounted) {
    throw StateError('composeDualShot: context unmounted before rendering');
  }
  final cardWidth = width ?? MediaQuery.sizeOf(context).width;
  final boundaryKey = GlobalKey();
  final entry = OverlayEntry(
    builder: (context) => Positioned(
      left: -cardWidth - 8,
      top: 0,
      width: cardWidth,
      child: DualShotView(
        result: result,
        style: style,
        showMap: showMap,
        labels: labels,
        boundaryKey: boundaryKey,
        backAspect: aspect,
      ),
    ),
  );
  Overlay.of(context, rootOverlay: true).insert(entry);
  try {
    await WidgetsBinding.instance.endOfFrame; // built, laid out, painted
    return await saveComposedDualShot(
      boundaryKey,
      result,
      pixelRatio: pixelRatio,
    );
  } finally {
    entry.remove();
  }
}

/// An image file's width/height as the framework decodes it (EXIF applied, so
/// it agrees with what [DualShotView] will lay out). Null if it won't decode —
/// the view's own 3:4 placeholder then stands.
Future<double?> _decodedAspect(File file) {
  final completer = Completer<double?>();
  final stream = FileImage(file).resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  void settle(double? aspect) {
    stream.removeListener(listener);
    if (!completer.isCompleted) completer.complete(aspect);
  }

  listener = ImageStreamListener((info, _) {
    settle(info.image.width / info.image.height);
    info.dispose();
  }, onError: (_, _) => settle(null));
  stream.addListener(listener);
  return completer.future;
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// `7 Aug 2026, 2:05 PM` — stdlib only, no intl dependency.
///
/// ponytail: English month names and a 12-hour clock, because the package has
/// no locale to work from. Apps that need a localized stamp should format the
/// timestamp themselves with `intl` and pass it in.
String formatTimestamp(DateTime t) {
  final hour12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final minute = t.minute.toString().padLeft(2, '0');
  final meridiem = t.hour < 12 ? 'AM' : 'PM';
  return '${t.day} ${_months[t.month - 1]} ${t.year}, $hour12:$minute $meridiem';
}
