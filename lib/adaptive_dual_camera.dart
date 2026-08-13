/// Hands-free front + back photo capture with location + timestamp —
/// simultaneous where the hardware allows it, sequential where it doesn't.
///
/// One capture gives you [DualShotResult.composedPhoto]: the finished layout
/// as a single PNG — back photo with the selfie, map and stamp under it —
/// plus the two raw photos it was built from.
///
/// Two engines, one result. The simultaneous path is this package's only
/// native code ([DualCameraSupport]): a CameraX concurrent session on
/// Android, an `AVCaptureMultiCamSession` on iOS. Everywhere else capture is
/// pure Dart on the official `camera` plugin, one lens at a time. Location
/// comes from `geolocator` on both, and both compose the same layout.
library;

export 'package:camera/camera.dart' show ResolutionPreset, XFile;

export 'src/capture_flow.dart';
export 'src/labels.dart';
export 'src/map_thumbnail.dart';
export 'src/models.dart';
export 'src/result_view.dart';
export 'src/support.dart';
