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
          fit: BoxFit.cover,
          errorBuilder: (context, _, _) => Container(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: const Icon(Icons.map_outlined),
          ),
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
}
