# adaptive_dual_camera

Hands-free front + back photo capture with location and timestamp —
**simultaneously where the hardware allows it, one after the other where it
doesn't**, and the same result layout either way.

One capture, one finished image: `result.composedPhoto` is the composed PNG
(back photo, selfie, map, stamp), and the two raw photos come with it.

Two engines, one result:

| Path | Runs on | Built from |
|---|---|---|
| **Simultaneous** | Devices with concurrent-camera hardware | This package's native code — CameraX concurrent session (Android), `AVCaptureMultiCamSession` (iOS) |
| **Sequential** | Everything else | Pure Dart on the official [`camera`](https://pub.dev/packages/camera) plugin |

Location comes from [`geolocator`](https://pub.dev/packages/geolocator) on
both paths, and both hand back the same `DualShotResult` rendered by the same
widget. The sequential path stays gentle on old and low-RAM phones: one
camera open at a time, `ResolutionPreset.medium` by default, audio never
opened.

## The flow

One tap, no interstitial screens: the first viewfinder waits for a shutter
tap so nobody gets photographed before they're ready, and everything after
that tap is automatic. Which path runs is decided once, at the start, by
trying to open both cameras:

**Simultaneous** — Android devices with concurrent-camera support (Pixel 6+,
Galaxy S22+, …), iPhone XS / A12 and later:

1. Both previews come up at once: back full-bleed with the selfie inset.
2. Tap the shutter; one countdown runs, then **both shutters fire
   together** — the two photos are milliseconds apart.

**Sequential** — everything else:

1. The front camera opens; tap the shutter and it counts down and takes the
   selfie itself.
2. The back camera opens by itself, prompts *"Turn the phone around"*, counts
   down and fires — no second tap, your hands are busy.

Either way, lat/long (fetched in parallel while shooting, and left null if no
fix arrives — never a stale last-known one, which would stamp a location the
photo wasn't taken at) and a timestamp are attached, the layout is composed,
and you get one `DualShotResult`:

| Field | What it is |
|---|---|
| `composedPhoto` | The finished layout as one PNG — what most apps save, upload or share. Null only if you passed `compose: null` or composing failed. |
| `backPhoto`, `frontPhoto` | The two raw camera files, always both. |
| `latitude`, `longitude` | Null when location is off, denied or too slow — the capture still succeeds. |
| `timestamp` | When the shot was taken. |
| `wasSimultaneous` | Which path ran — useful if your app needs the two shots to prove "same moment". |

### How the path is chosen

Two steps, because a hardware flag is a claim and not a guarantee:

1. **Ask the platform.** Android checks the `FEATURE_CAMERA_CONCURRENT`
   system feature — the same gate CameraX's concurrent binding uses.
   (`getConcurrentCameraIds()` is deliberately not consulted: plenty of
   hardware that streams front+back fine returns an empty set there.) iOS
   checks `AVCaptureMultiCamSession.isMultiCamSupported`.
2. **Then actually start the session.** If it fails, the flow releases both
   cameras and runs sequentially instead.

When simultaneous isn't available, the first viewfinder says so
(`DualCaptureLabels.simultaneousUnavailable`) rather than quietly behaving
differently from the same app on someone else's phone. Query it yourself up
front to adapt your own UI:

```dart
final canDoBoth = await DualCameraSupport.supportsSimultaneousCapture();
```

Pass `mode: DualCaptureMode.sequential` to skip all of this — the right call
on old and low-RAM phones, where a second camera pipeline competes for
memory. In that mode the native session is never touched at all.

```dart
GuidedDualCaptureFlow(
  mode: DualCaptureMode.sequential,       // never open two at once
  countdown: const Duration(seconds: 5),  // more time to turn around
  onComplete: (result) => ...,
)
```

## The result layout

This is what `result.composedPhoto` contains, and what `DualShotView` renders
on screen — the same either way, whichever path produced the photos:

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

**Slow tiles?** Identify your app. OSM's tile policy throttles clients that
don't send a real `User-Agent`, and Dart's default (`Dart/3.x (dart:io)`) is
one of them — the single biggest reason a tile takes seconds:

```dart
void main() {
  MapThumbnail.userAgent = 'my_app/1.4 (support@example.com)';
  runApp(const MyApp());
}
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

// The finished layout, already composed as one PNG — nothing else to call:
final file = File(result.composedPhoto!.path);

// Or render it yourself (same widget for both capture paths):
DualShotView(result: result)
```

`result.composedPhoto` is the whole point of the flow: `result.backPhoto` on
its own is just the back camera's shot, so the flow renders the layout — back
photo, selfie, map, stamp — before it completes and hands you the file. Pass
`compose: DualShotStyle.light` (or any style, see below) to change how it
looks, or `compose: null` to skip it and keep only the two raw photos.
A compose that fails leaves `composedPhoto` null and reports through
`onError`; the capture itself still succeeds.

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

### Out of the box

Nothing to call: `result.composedPhoto` is already the composed PNG, styled
by the flow's `compose:` argument.

### Composing one yourself

`composeDualShot` renders the layout off-screen and hands you the PNG — for a
second file at another size or style (e.g. a small one to upload), or after
`compose: null`:

```dart
final file = await composeDualShot(
  context,
  result,
  style: DualShotStyle.light,   // same knobs as the on-screen view
  // showMap: false, width: 1080, pixelRatio: 3,
);
```

It renders the same `DualShotView`, so the file matches what a result page
would have saved. `context` must still be mounted and under a `Navigator`.

### From a result screen

Hand a key to `DualShotView.boundaryKey` and call `saveComposedDualShot` —
it snapshots the card exactly (full photo + footer, no surrounding margins),
so the PNG matches the style you chose, and lands next to the captured
photos in the app cache.

```dart
final viewKey = GlobalKey();

DualShotView(
  result: result,
  style: DualShotStyle.light,
  boundaryKey: viewKey,
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

Camera permission is requested automatically on first use — by the plugin
itself on the simultaneous path, by the `camera` plugin on the sequential
one; if denied, the flow shows a retry screen
(`DualCaptureLabels.cameraDenied`). Location permission is requested only
after a camera is live (the OS shows one permission dialog at a time); if
denied or unavailable the capture still succeeds with
`latitude`/`longitude` as `null`.

### What you must declare

`CAMERA` is declared by this package's own manifest and merges into your app
automatically. Everything else is yours to add.

**Android** (`android/app/src/main/AndroidManifest.xml`):

```xml
<!-- location stamp; geolocator declares none of these itself -->
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<!-- for the map thumbnail -->
<uses-permission android:name="android.permission.INTERNET" />
```

**iOS** (`ios/Runner/Info.plist`) — both are required; an app that reaches the
camera without `NSCameraUsageDescription` is killed by the OS on the spot:

```xml
<key>NSCameraUsageDescription</key>
<string>Takes photos with the front and back cameras.</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>Stamps each capture with its location.</string>
```

No microphone entry is needed: audio is never opened on either path.

### What gets merged in that you may not want

The `camera` plugin's manifest adds `RECORD_AUDIO` (and
`WRITE_EXTERNAL_STORAGE` up to API 28) to every app that depends on it, even
though this package always passes `enableAudio: false`. If you'd rather not
declare a microphone permission on the store listing, strip it:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">
    <uses-permission android:name="android.permission.RECORD_AUDIO"
        tools:node="remove" />
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

## What the native code does (and doesn't)

The plugin's Kotlin and Swift cover the simultaneous path only:

- Report concurrent-camera support.
- Run one concurrent session, publishing each camera as a Flutter texture.
- Fire both shutters together and write two JPEGs.

There is deliberately **no native compositor**. Each camera produces its own
file, and Dart composes the final layout — which is what lets the
simultaneous and sequential paths produce a pixel-identical result. The
sequential path never enters native code at all.

### Requirements

- **Flutter 3.44+** (the Android plugin uses Built-in Kotlin).
- **Android**: `minSdk 21`; concurrent capture itself needs API 30+ hardware
  that reports a front+back combination. CameraX 1.4.1 is pulled in by the
  plugin.
- **iOS**: deployment target 12.0; simultaneous needs iOS 13+ on an A12 or
  later device.

