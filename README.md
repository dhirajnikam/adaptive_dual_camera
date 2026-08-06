# adaptive_dual_camera

Guided front-then-back photo capture with location and timestamp.

Pure Dart — this package ships **no native code** of its own. It composes the
official [`camera`](https://pub.dev/packages/camera) and
[`geolocator`](https://pub.dev/packages/geolocator) plugins, so it runs
anywhere they do (Android 5.0+ / SDK 21, iOS 12+), including old and low-RAM
phones: only one camera controller is ever alive, previews default to
`ResolutionPreset.medium`, and audio is never opened.

## The flow

1. The user is told: *"First we'll take a picture with the front camera. Show
   your face."* → front photo.
2. Then: *"Now point the back camera at what you want to capture."* → back
   photo.
3. Lat/long (low accuracy, 10 s cap, falls back to last known, then to none)
   and a timestamp are attached, and you get a `DualShotResult`.

`DualShotView` renders the result exactly as:

```
Column [
  back photo,
  Row [ front photo, (lat, long, timestamp) ]
]
```

## Usage

```dart
// Capture:
Navigator.of(context).push(MaterialPageRoute(
  builder: (context) => GuidedDualCaptureFlow(
    onComplete: (result) => Navigator.of(context).pop(result),
    onError: (e) => debugPrint('$e'),
    // resolution: ResolutionPreset.low,   // for very old devices
  ),
));

// Display:
DualShotView(result: result)
```

### Localization

Every user-visible string lives in `DualCaptureLabels` — pass your own to
translate or reword:

```dart
GuidedDualCaptureFlow(
  labels: const DualCaptureLabels(
    frontPrompt: 'पहले फ्रंट कैमरे से फोटो लेंगे।\nअपना चेहरा दिखाएँ।',
    ready: 'तैयार हूँ',
  ),
  onComplete: ...,
)
```

### Permissions

Camera permission is requested automatically on first use; if denied, the
flow shows a retry screen (`DualCaptureLabels.cameraDenied`). Location
permission is requested before the fix; if denied or unavailable the capture
still succeeds with `latitude`/`longitude` as `null`.

Declare in your app:

**Android** (`android/app/src/main/AndroidManifest.xml`):

```xml
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
```

**iOS** (`ios/Runner/Info.plist`):

```xml
<key>NSCameraUsageDescription</key>
<string>Takes photos with the front and back cameras.</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>Stamps each capture with its location.</string>
```

## Old / low-end devices

- One `CameraController` at a time; each is disposed before the next opens.
- `ResolutionPreset.medium` by default — pass `ResolutionPreset.low` to go lower.
- `enableAudio: false`, JPEG output.
- The camera is released when the app is backgrounded and reopened on resume.
- Location uses `LocationAccuracy.low` with a 10-second cap.
