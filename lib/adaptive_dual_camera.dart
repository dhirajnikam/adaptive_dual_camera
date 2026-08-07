/// Hands-free front + back photo capture with location + timestamp —
/// simultaneous where the hardware allows it, sequential where it doesn't.
///
/// Capture is pure Dart on top of the official `camera` and `geolocator`
/// plugins. The only native code in the package is a capability probe
/// ([DualCameraSupport]) that reports whether the device can run both
/// cameras at once.
library;

export 'package:camera/camera.dart' show ResolutionPreset, XFile;

export 'src/capture_flow.dart';
export 'src/labels.dart';
export 'src/map_thumbnail.dart';
export 'src/models.dart';
export 'src/result_view.dart';
export 'src/support.dart';
