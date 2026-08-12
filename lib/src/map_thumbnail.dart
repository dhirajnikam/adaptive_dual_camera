import 'dart:math';

import 'package:flutter/material.dart';

/// A small static map of a lat/long: one OpenStreetMap tile with a marker.
///
/// No maps SDK, no API key — just Web Mercator math and a 256 px tile over
/// HTTP, so it stays light on old devices and degrades to a plain icon when
/// offline.
class MapThumbnail extends StatelessWidget {
  const MapThumbnail({
    super.key,
    required this.latitude,
    required this.longitude,
    this.zoom = defaultZoom,
  });

  final double latitude;
  final double longitude;

  /// 0 (whole world) … 19 (street level).
  final int zoom;

  static const int defaultZoom = 15;

  /// Sent with every tile request. OpenStreetMap's tile usage policy throttles
  /// — and sometimes blocks — clients that don't identify themselves, and
  /// Dart's default `Dart/3.x (dart:io)` counts as one: that is the usual
  /// reason a tile takes seconds to appear. Set it to your own app once at
  /// startup:
  ///
  /// ```dart
  /// MapThumbnail.userAgent = 'my_app/1.4 (support@example.com)';
  /// ```
  static String userAgent =
      'adaptive_dual_camera (+https://github.com/dhirajnikam/adaptive_dual_camera)';

  /// Headers for a tile fetch. Used here and by [saveComposedDualShot]'s
  /// precache, so both requests hit the same cache entry and the same policy.
  static Map<String, String> get tileHeaders => {'User-Agent': userAgent};

  /// URL of the OSM tile shown for a location. Also used by
  /// `saveComposedDualShot` to precache the exact on-screen tile before
  /// snapshotting.
  static String tileUrl(
    double latitude,
    double longitude, [
    int zoom = defaultZoom,
  ]) {
    final scale = 1 << zoom;
    final tileX = ((longitude + 180) / 360 * scale).floor().clamp(0, scale - 1);
    final latRad = latitude * pi / 180;
    final tileY = ((1 - log(tan(latRad) + 1 / cos(latRad)) / pi) / 2 * scale)
        .floor()
        .clamp(0, scale - 1);
    return 'https://tile.openstreetmap.org/$zoom/$tileX/$tileY.png';
  }

  @override
  Widget build(BuildContext context) {
    final scale = 1 << zoom;
    final x = (longitude + 180) / 360 * scale;
    final latRad = latitude * pi / 180;
    final y = (1 - log(tan(latRad) + 1 / cos(latRad)) / pi) / 2 * scale;
    final tileX = x.floor().clamp(0, scale - 1);
    final tileY = y.floor().clamp(0, scale - 1);

    return Stack(
      fit: StackFit.expand,
      children: [
        Image.network(
          tileUrl(latitude, longitude, zoom),
          headers: tileHeaders,
          fit: BoxFit.cover,
          // A blank square reads as "broken" while the tile is in flight;
          // hold the placeholder until the first frame decodes.
          frameBuilder: (context, child, frame, _) =>
              frame == null ? _placeholder(context) : child,
          errorBuilder: (context, _, _) =>
              _placeholder(context, icon: Icons.map_outlined),
        ),
        Align(
          // Fractional position of the point within its tile.
          alignment: FractionalOffset(x - tileX, y - tileY),
          child: const Icon(Icons.place, color: Colors.red, size: 24),
        ),
        const Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: EdgeInsets.all(2),
            child: Text(
              '© OpenStreetMap',
              style: TextStyle(fontSize: 7, color: Colors.black54),
            ),
          ),
        ),
      ],
    );
  }

  Widget _placeholder(BuildContext context, {IconData? icon}) => Container(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: icon == null ? null : Icon(icon),
  );
}
