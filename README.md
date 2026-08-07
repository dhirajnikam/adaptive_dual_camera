# adaptive_dual_camera

Hands-free front + back photo capture with location and timestamp —
**simultaneously where the hardware allows it, one after the other where it
doesn't**, and the same result layout either way.

Pure Dart — this package ships **no native code** of its own. It composes the
official [`camera`](https://pub.dev/packages/camera) and
[`geolocator`](https://pub.dev/packages/geolocator) plugins, so it runs
anywhere they do (Android 5.0+ / SDK 21, iOS 12+), including old and low-RAM
phones: previews default to `ResolutionPreset.medium` and audio is never
opened.

## The flow

Zero taps, no interstitial screens. Which path runs is decided once, at the
start, by trying to open both cameras:

**Simultaneous** — Android devices with concurrent-camera support (Pixel 6+,
Galaxy S22+, …), iPhone XS / A12 and later:

1. Both previews come up at once: back full-bleed with the selfie inset.
2. One countdown runs, then **both shutters fire together** — the two photos
   are milliseconds apart.

**Sequential** — everything else:

1. The front camera opens, counts down, and takes the selfie itself.
2. The back camera opens by itself, prompts *"Turn the phone around"*, counts
   down again, and fires.

Either way, lat/long (fetched in parallel while shooting; falls back to last
known, then to none) and a timestamp are attached, and you get one
`DualShotResult`. `result.wasSimultaneous` tells you which path ran — useful
if your app needs the two shots to prove "same moment".

### How support is detected

By **actually opening the second camera**, not by asking the platform. A
device that advertises concurrency but drops one pipeline when the other
opens is caught by the probe and falls back cleanly. The cost is one extra
camera-open at startup on devices that can't do it.

Pass `mode: DualCaptureMode.sequential` to skip the probe entirely — the
right call on old and low-RAM phones, where a second camera pipeline
competes for memory.

```dart
GuidedDualCaptureFlow(
  mode: DualCaptureMode.sequential,       // never open two at once
  countdown: const Duration(seconds: 5),  // more time to turn around
  onComplete: (result) => ...,
)
```

## The result layout

`DualShotView` renders every result the same way, whichever path produced it:

```
┌────────────────────────────┐
│                            │
│        back photo          │
│                            │
├──────┬──────┬──────────────┤
│front │ map  │ lat, long    │
│      │      │ 7 Aug 2026…  │
└──────┴──────┴──────────────┘
```

`Column[back photo, Row[front photo, map, lat/long + timestamp]]`. The map is
a single OpenStreetMap tile with a marker (`MapThumbnail`) — no maps SDK, no
API key. Pass `showMap: false` for offline apps. Timestamps are formatted
human-readably (`7 Aug 2026, 2:05 PM`) with no `intl` dependency.

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

// Display (same widget for both capture paths):
DualShotView(result: result)
```

## Customizing the layout

Pass a `DualShotStyle` to resize the footer or recolor it. Three ready-made
looks:

| Preset | Look |
|---|---|
| `DualShotStyle.dark` | Dark footer under the photo (the default). |
| `DualShotStyle.light` | Light footer with dark text, for airy shots. |
| `DualShotStyle.tall` | Taller footer with more breathing room. |

`copyWith` adjusts any single knob:

```dart
DualShotView(
  result: result,
  style: DualShotStyle.light.copyWith(
    footerHeight: 120,
    thumbnailBorderColor: Colors.black12,
  ),
)
```

Every field:

| Field | Default | What it does |
|---|---|---|
| `footerHeight` | `96` | Height of the bottom row; the back photo takes the rest. |
| `thumbnailRadius` | `8` | Corner radius of the selfie and map thumbnails. |
| `thumbnailBorderColor` | `null` | Optional hairline around the thumbnails. |
| `footerColor` | `#1C1C1E` | Footer background. |
| `textColor` | `Colors.white` | Primary text; the timestamp uses it at 70% opacity. |
| `gap` | `8` | Spacing between footer cells and around its edges. |
| `showMapInFooter` | `true` | Drop the map cell but keep the coordinates. |

## Saving as one image

Wrap the view in a `RepaintBoundary` and call `saveComposedDualShot` — it
snapshots exactly what is on screen, so the PNG matches the style you chose,
and lands next to the captured photos in the app cache.

```dart
final viewKey = GlobalKey();

RepaintBoundary(
  key: viewKey,
  child: DualShotView(result: result, style: DualShotStyle.light),
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

- Pass `mode: DualCaptureMode.sequential` to guarantee **one
  `CameraController` at a time** — no concurrency probe, no second pipeline
  competing for memory. In `auto` mode a device that can't run both cameras
  ends up here anyway, but only after paying for the probe.
- `ResolutionPreset.medium` by default — pass `ResolutionPreset.low` to go lower.
- `enableAudio: false`, JPEG output.
- Cameras are released when the app is backgrounded and reopened on resume;
  the countdown restarts rather than firing at a pocket.
- Location uses `LocationAccuracy.low` with a 10-second cap.
- `DualShotView` decodes both photos at display size, not full camera
  resolution.

## Credits

The simultaneous-capture support matrix (Android concurrent cameras via
`CameraManager.getConcurrentCameraIds`, iOS `AVCaptureMultiCamSession` on
A12+) follows the ground covered by
[`dual_cameras`](https://github.com/RomanSlack/dual_cameras) by Roman Slack —
a native, GPU-composited dual-camera *video* recorder. This package stays
pure Dart and stills-only, so it probes the same capability empirically
instead of through platform channels.
