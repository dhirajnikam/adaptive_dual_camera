import 'dart:io';

import 'package:flutter/material.dart';

import 'labels.dart';
import 'models.dart';

/// Renders a [DualShotResult] as:
/// Column[ back photo, Row[ front photo, lat / long / timestamp ] ].
class DualShotView extends StatelessWidget {
  const DualShotView({
    super.key,
    required this.result,
    this.footerHeight = 120,
    this.labels = const DualCaptureLabels(),
  });

  final DualShotResult result;
  final double footerHeight;

  /// Override to translate or reword every user-visible string.
  final DualCaptureLabels labels;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Image.file(
            File(result.backPhoto.path),
            fit: BoxFit.cover,
            width: double.infinity,
          ),
        ),
        SizedBox(
          height: footerHeight,
          child: Row(
            children: [
              AspectRatio(
                aspectRatio: 3 / 4,
                child: Image.file(
                  File(result.frontPhoto.path),
                  fit: BoxFit.cover,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.place, size: 16),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              result.hasLocation
                                  ? '${result.latitude!.toStringAsFixed(6)}, '
                                      '${result.longitude!.toStringAsFixed(6)}'
                                  : labels.locationUnavailable,
                              style: Theme.of(context).textTheme.bodySmall,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Icon(Icons.schedule, size: 16),
                          const SizedBox(width: 4),
                          Text(
                            formatTimestamp(result.timestamp),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// `2026-08-06 14:05` — stdlib only, no intl dependency.
String formatTimestamp(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}
