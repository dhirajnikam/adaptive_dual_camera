# adaptive_dual_camera

Guided front-then-back photo capture with location and timestamp.

Pure Dart — this package ships **no native code** of its own. It composes the
official [`camera`](https://pub.dev/packages/camera) and
[`geolocator`](https://pub.dev/packages/geolocator) plugins, so it runs
anywhere they do (Android 5.0+ / SDK 21, iOS 12+), including old and low-RAM
phones: only one camera controller is ever alive, previews default to
`ResolutionPreset.medium`, and audio is never opened.

## The flow

Two taps total, no interstitial screens:

1. The front camera opens immediately with a hint banner: *"Show your
   face"* → tap the shutter.
2. The back camera opens automatically: *"Point at what you want to
   capture"* → tap again.
3. Lat/long (fetched in parallel while shooting; falls back to last known,
   then to none) and a timestamp are attached, and you get a
   `DualShotResult`.

`DualShotView` renders the result GPS-camera style:

```
┌──────────────────────┐
│ back photo   ┌─────┐ │
│  (full)      │front│ │
│              └─────┘ │
│ ┌────┐ lat, long     │
│ │map │ timestamp     │
│ └────┴───────────────┤
└──────────────────────┘
```

The map is a single OpenStreetMap tile with a marker (`MapThumbnail`) — no
maps SDK, no API key. Pass `showMap: false` for offline apps.

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

## Customizing the layout

Pass a `DualShotStyle` to move the selfie, resize it, or recolor the info
bar. Three ready-made looks:

| Preset | Look |
|---|---|
| `DualShotStyle.classic` | Full-width translucent black bar flush with the bottom edge (the default). |
| `DualShotStyle.floating` | Dark rounded card inset from the edges. |
| `DualShotStyle.light` | Bright rounded card with dark text, for airy shots. |

`copyWith` adjusts any single knob:

```dart
DualShotView(
  result: result,
  style: DualShotStyle.floating.copyWith(
    selfieAlignment: Alignment.topLeft,
    selfieWidth: 120,
  ),
)
```

Every field:

| Field | Default | What it does |
|---|---|---|
| `selfieAlignment` | `Alignment.topRight` | Corner (or edge) the selfie card floats in. |
| `selfieWidth` | `88` | Selfie card width; height is a fixed 3:4 portrait. |
| `selfieRadius` | `10` | Corner radius of the selfie card. |
| `selfieBorderColor` | `Colors.white` | Border color of the selfie card. |
| `barColor` | `Colors.black54` | Background of the info bar. |
| `textColor` | `Colors.white` | Primary text; the timestamp uses it at 70% opacity. |
| `barRadius` | `0` | `0` = full-width bar on the bottom edge; `> 0` floats it inset with rounded corners. |

## Saving as one image

Wrap the view in a `RepaintBoundary` and call `saveComposedDualShot` — it
snapshots exactly what is on screen, so the PNG matches the style you chose,
and lands next to the captured photos in the app cache.

```dart
final viewKey = GlobalKey();

RepaintBoundary(
  key: viewKey,
  child: DualShotView(result: result, style: DualShotStyle.floating),
)

// later, e.g. from a Save button:
final file = await saveComposedDualShot(viewKey, result);
// → …/DUAL_1754467500000.png
```

Pass `pixelRatio:` (default `2`) to trade file size against sharpness. When
the result has a location, the call first precaches the map tile (capped at
3 seconds) so a quick tap doesn't snapshot an empty map square; offline it
captures the fallback icon instead.

The file goes to the cache directory the `camera` plugin wrote the photos
to. Cache can be evicted by the OS — copy it somewhere permanent (or hand it
to a gallery/share plugin) if the user is meant to keep it.

## Localization

Every user-visible string lives in `DualCaptureLabels` — pass your own to
translate or reword:

```dart
GuidedDualCaptureFlow(
  labels: const DualCaptureLabels(
    frontPrompt: 'अपना चेहरा दिखाएँ',
    backPrompt: 'जिसे कैप्चर करना है उस ओर कैमरा करें',
  ),
  onComplete: ...,
)
```

## Permissions

Camera permission is requested automatically on first use; if denied, the
flow shows a retry screen (`DualCaptureLabels.cameraDenied`). Location
permission is requested before the fix; if denied or unavailable the capture
still succeeds with `latitude`/`longitude` as `null`.

Declare in your app:

**Android** (`android/app/src/main/AndroidManifest.xml`):

```xml
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<!-- for the map thumbnail -->
<uses-permission android:name="android.permission.INTERNET" />
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
