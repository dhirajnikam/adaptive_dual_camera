# adaptive_dual_camera

[![pub package](https://img.shields.io/pub/v/adaptive_dual_camera.svg)](https://pub.dev/packages/adaptive_dual_camera)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Front and back capture — photos and video — behind one API.

Devices that can hold both cameras open do it simultaneously (Android
concurrent cameras, iOS multi-cam). Everything else runs one camera at a time
and the plugin sequences it for you, telling your UI exactly what it's doing so
the user isn't left staring at a frozen screen. Same calls, same result types
either way; `mode` tells you which happened.

|  | Simultaneous | Sequential |
| --- | --- | --- |
| Hardware | Android API 30+ w/ concurrent pair, iOS A12+ | Everything else |
| Preview | Both feeds live | One live; the other slot is yours to fill |
| Photos | Both shutters fire together | Back, then front — a moment apart |
| Video | Both clips, same moment | Back clip, then the front clip is **retaken** |

## Quick start

```dart
import 'package:adaptive_dual_camera/adaptive_dual_camera.dart';

final controller = DualCameraController();
await controller.requestPermission(microphone: true);
await controller.initialize();

// Live viewfinder, laid out however you like.
DualCameraPreview(controller: controller, layout: DualLayout.pictureInPicture);

final photo = await controller.capturePhoto();   // DualCapture: back + front JPEGs
await controller.startRecording();
final clip = await controller.stopRecording();   // DualRecording: back + front MP4s

await controller.dispose();
```

No viewfinder needed? `AdaptiveDualCamera().capture()` and `.record(duration)`
open, capture and close in one call.

## Telling the user what's happening

`DualCameraController` is a `ChangeNotifier`. On sequential hardware one
`capturePhoto()` shoots the back camera, then the front, and `stage` reports
which one is in flight:

```dart
ListenableBuilder(
  listenable: controller,
  builder: (context, _) => Text(switch (controller.stage) {
    DualCaptureStage.idle  => '',
    DualCaptureStage.both  => 'Capturing…',
    DualCaptureStage.back  => 'Taking back photo…',
    DualCaptureStage.front => 'Taking front photo…',
  }),
)
```

The live preview follows along, and `capturePhoto()` leaves it on whichever
camera it started on.

### Video on sequential hardware

The front camera can't record until the back one stops, so `stopRecording()`
switches over and **retakes the same duration**. That's a two-take experience,
and `secondPass` is what makes it liveable: a countdown the user can turn the
phone around during, then the retake with progress.

```dart
final clip = await controller.stopRecording(
  frontLeadIn: const Duration(seconds: 3), // 0 to go straight into the retake
);
```

```dart
final pass = controller.secondPass;   // null unless a retake is running
if (pass != null) {
  Text(pass.rolling
      ? 'Recording front camera — ${pass.remaining.inSeconds}s left'
      : 'Turn the camera around · starts in ${pass.remaining.inSeconds}…');
  LinearProgressIndicator(value: pass.progress);
}
```

Budget `frontLeadIn + duration` on top of the recording you just took, and
check `recording.mode` before treating the two clips as the same moment.

`isSimultaneous` can also flip to false mid-session: some devices advertise a
concurrent pair for stills but can't configure two video streams.
`startRecording()` drops to one camera when that happens and the controller
adopts the new mode, so the retake path kicks in automatically.

## Customising the UI

Every visual knob lives on one `DualLayoutStyle`. `DualCameraPreview` (live
feeds), `DualCaptureView` (results) and `DualLayoutView` (any two widgets) all
take it — build the style once and the viewfinder and its output look identical.

```dart
const style = DualLayoutStyle(
  layout: DualLayout.pictureInPicture,
  insetAlignment: Alignment.bottomLeft,
  insetScale: 0.35,
  background: Colors.black,
);

DualCameraPreview(controller: controller, style: style);
DualCaptureView(capture: shot, style: style);   // same framing, same look
```

| Setting | Default | Does |
| --- | --- | --- |
| `layout` | `pictureInPicture` | Also `sideBySide`, `stacked`, `primaryOnly` |
| `primary` | `back` | Which camera gets the large pane |
| `fit` | `contain` | How a feed fills its pane — see below |
| `alignment` | `center` | Where it sits when `fit` leaves room |
| `background` | none | Fills the space `contain` leaves around a feed |
| `paneBorderRadius` | none | Rounds the main panes |
| `gap` | `4` | Space between panes in split layouts |
| `insetAlignment` | `topRight` | Corner for the floating PiP feed |
| `insetScale` | `0.3` | Its width, as a fraction of the shortest side |
| `insetAspectRatio` | `3/4` | Its shape — the inset is a definite box, not content-sized |
| `insetMargin` / `insetBorderRadius` / `insetBorder` | 12pt / 12r / none | The rest of the PiP inset |
| `clipBehavior` | `hardEdge` | Whether the inset can overhang |

`copyWith` is there for building one off another.

Per-widget, outside the style:

| Widget | Extra |
| --- | --- |
| `DualCameraPreview` | `placeholderBuilder` — what to draw for a camera that isn't live |
| `DualCaptureView` | `imageBuilder` (render each file yourself — video thumbnails, heroes, …), `errorBuilder` |
| all three | `builder` — full override, receives the two built feed widgets |

```dart
DualCameraPreview(
  controller: controller,
  builder: (context, back, front) => Column(
    children: [Expanded(child: back), Expanded(child: front)],
  ),
)
```

Going fully custom? `controller.feedFor(camera)` gives you a `DualFeed`; drop it
into `DualCameraFeed`, or use `feed.textureId` with a raw `Texture` widget.

### Customising the text

The plugin renders no text itself, but it knows what needs saying.
`DualCameraLabels` holds every string with English defaults; override any
subset for wording or localisation.

```dart
const labels = DualCameraLabels(
  takingBackPhoto: 'Rückkamera…',
  retakeCountdown: 'Dreh das Handy um · noch {seconds}',
);

ListenableBuilder(
  listenable: controller,
  builder: (context, _) {
    final message = labels.statusFor(controller);   // null when idle
    return message == null ? const SizedBox() : Text(message);
  },
)
```

`statusFor` collapses the capture stage and the retake countdown into the one
line worth showing, and puts the retake first — that's the step the user has to
act on. `modeFor(controller)` describes the hardware, and `notLive(camera)`
fills a `placeholderBuilder`. `{seconds}` and `{camera}` are substituted;
`copyWith` builds one set from another.

### Nothing gets cropped by default

`fit` defaults to `BoxFit.contain`, so the **whole frame is always visible** —
a 9:16 feed in a 3:4 pane is letterboxed rather than having its edges cut off.
Set `background` to fill those bars.

```dart
const DualLayoutStyle(fit: BoxFit.cover)    // edge-to-edge instead; crops
```

This applies to live feeds and to captured photos alike. The PiP inset also has
a fixed `insetAspectRatio` so it can't stretch to whatever the content
measures — the feed fits inside that box under the same `fit` rule.

## API

**`DualCameraController({storage})`**

| Member | Does |
| --- | --- |
| `initialize({forceSequential})` | Opens the camera(s) and starts the preview stream(s) |
| `requestPermission({microphone})` | Prompts when undecided; returns whether everything asked for is granted |
| `switchTo(camera)` | Moves the live feed. Sequential only; no-op otherwise |
| `capturePhoto()` | One photo per camera |
| `startRecording({audio})` | Starts recording |
| `stopRecording({frontLeadIn})` | Stops, running the retake on sequential hardware |
| `dispose()` | Closes the cameras and frees the textures |
| `mode` / `isSimultaneous` | What the hardware is actually doing |
| `status` | `uninitialized`, `ready`, `capturing`, `recording`, `disposed` |
| `stage` | `idle`, `both`, `back`, `front` — which camera is being captured |
| `activeCamera` / `feedFor(camera)` | The live feed(s) |
| `isRecording` / `recordedDuration` | Recording state |
| `secondPass` | Retake countdown and progress, or null |

**`AdaptiveDualCamera({storage})`** (no preview, no lifecycle) —
`isSimultaneousSupported()`, `requestPermission({microphone})`,
`capture({forceSequential})`,
`record(duration, {audio, forceSequential, frontLeadIn})`.

## Where captures are stored

By default the native side writes into the app's **cache directory**:

```
<app cache>/adc_back_1738291043211900.jpg      photos
<app cache>/adc_front_1738291043788400.mp4     clips
```

`adc_<camera>_<nanoseconds>.<ext>` — unique per capture, never overwritten, and
**never cleaned up**. The OS can evict cache files whenever it likes, so treat
them as temporary: move or delete what you want to keep.

To have the plugin file them for you, pass a `DualStorage`. Each capture is
moved as soon as it lands, before `capturePhoto()` / `stopRecording()` returns:

```dart
DualCameraController(
  storage: DualStorage(
    directory: await getApplicationDocumentsDirectory(),  // your own dependency
    nameBuilder: (camera, media, at) =>
        '${at.toIso8601String().replaceAll(':', '-')}_${camera.name}'
        '${media == DualMedia.photo ? '.jpg' : '.mp4'}',
  ),
)
```

| Field | Does |
| --- | --- |
| `directory` | Where captures are moved to. Created if missing. Null keeps them in the cache |
| `nameBuilder` | `(DualCamera, DualMedia, DateTime) => String`, extension included. Null keeps the generated name |

Either alone is enough — set only `nameBuilder` to rename in place. The plugin
doesn't depend on `path_provider`; pass whatever `Directory` your app already
has. `AdaptiveDualCamera(storage: ...)` takes the same thing.

Throws `PlatformException`:

| Code | Meaning |
| --- | --- |
| `permission_denied` | Camera (or microphone, for `audio: true`) not granted |
| `not_initialized` | Native call before `initialize()` |
| `no_camera` | Device is missing a front or back camera |
| `busy` | Capture or switch requested mid-recording |
| `camera_lost` | Camera disconnected or failed to open |
| `capture_failed` | Everything else; `message` has the detail |

Misuse of the controller itself (capture before initialize, double initialize,
stop without start) throws `StateError`.

## Setup

**Android** — nothing for photos; the plugin's manifest contributes `CAMERA`.
For video **with audio**, add to your app's manifest:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
```

The plugin deliberately doesn't declare it, so photo-only apps aren't listed as
requesting the microphone. Requires `minSdk 24`.

**iOS** — add to `Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>Takes photos and video with the front and back cameras.</string>
<key>NSMicrophoneUsageDescription</key>
<string>Records audio alongside the back camera video.</string>
```

Requires iOS 13.0.

## Behaviour notes

- **Audio is on the back clip only.** Two recorders can't share the microphone;
  the front clip is always silent.
- Simultaneous photos are capped at 1440p (Android) or the largest multi-cam
  format (iOS) — a hardware constraint of running two cameras. Sequential
  photos go up to ~12MP. Video is 720p on both paths.
- **Low-RAM (Android Go) devices always run sequential**, even when the
  hardware advertises a concurrent pair — a second open camera costs tens of
  MB — and photos are capped at ~8MP. Preview stays 720p everywhere.
- Both shutters in simultaneous mode fire back to back, a few milliseconds
  apart, not on a shared hardware trigger.
- Preview rotation assumes a portrait-locked UI. Wrap `DualCameraFeed` in your
  own `RotatedBox` if your camera screen rotates.
- There's no preview widget for a *disposed* controller — call `initialize()`
  again on a fresh instance.

## Tests

```bash
flutter analyze                                        # package + example
flutter test                                           # 83 Dart tests
cd example && flutter test                             # 6 widget tests
cd example/android && ./gradlew :adaptive_dual_camera:testDebugUnitTest
cd example && flutter test integration_test            # needs a device
```

What's covered:

| Suite | Covers |
| --- | --- |
| `test/adaptive_dual_camera_method_channel_test.dart` | Method-channel encoding and decoding: session/feed payloads, mirrored defaults, an unknown `mode` degrading to sequential rather than crashing, null results raising `capture_failed` |
| `test/dual_camera_controller_test.dart` | Orchestration against a fake platform — the back-then-front photo order and the `stage` values it emits, preview restore, the sequential video retake with lead-in and progress, mid-session degradation, state guards, single release on dispose |
| `test/dual_layout_test.dart` | `DualLayoutStyle` defaults and `copyWith`, every layout, `primary` swapping, PiP inset sizing and alignment, backgrounds, `builder` override, `DualCaptureView` sources and `errorBuilder`, preview placeholders, `DualCameraFeed` rotate-then-mirror order, and that `contain` fits the whole frame while `cover` overflows and clips |
| `test/storage_and_labels_test.dart` | `DualStorage` against a platform that writes real files — default cache placement, relocation into a created directory, `nameBuilder` for photos and clips, no leftovers behind; and `DualCameraLabels` substitution, retake-over-stage priority, and `copyWith` |
| `test/adaptive_dual_camera_test.dart` | The one-shot facade: open → capture → release, including release on failure |
| `example/test/widget_test.dart` | The demo UI end to end against a mocked channel, including the "Taking back photo…" → "Taking front photo…" sequence, the retake countdown, and the layout/fit controls reaching the live feed |
| `android/src/test/…` | Kotlin: unknown methods are rejected rather than swallowed |
| `example/integration_test/` | On-device: the capability probe answers, and the controller refuses to capture before `initialize()` |

The capture paths themselves need real camera hardware — a device, a granted
permission, and something to point at. The suites above cover the Dart
orchestration and the platform contract around them, not the pixels.

## License

MIT — see [LICENSE](LICENSE).
