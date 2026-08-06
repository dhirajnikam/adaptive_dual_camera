/// Guided front-then-back photo capture with location + timestamp.
///
/// Pure Dart on top of the official `camera` and `geolocator` plugins —
/// this package ships no native code of its own.
library;

export 'package:camera/camera.dart' show ResolutionPreset, XFile;

export 'src/capture_flow.dart';
export 'src/labels.dart';
export 'src/models.dart';
export 'src/result_view.dart';
