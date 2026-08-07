## 0.4.0

* **Simultaneous capture where the hardware allows it.** On devices that can
  run both cameras at once (Android concurrent-camera devices, iPhone XS/A12
  and later) the flow now brings up both previews — back full-bleed with the
  selfie inset — runs one countdown, and fires **both shutters together**, so
  the two photos are milliseconds apart instead of seconds. Everything else
  keeps the one-at-a-time flow.
* Support is probed by actually opening the second camera rather than by
  asking the platform, so a device that advertises concurrency but can't
  deliver it falls back cleanly. New `mode:` parameter
  (`DualCaptureMode.auto`, the default, or `.sequential`) skips the probe —
  use `sequential` on old and low-RAM phones.
* `DualShotResult.wasSimultaneous` reports which path ran, for apps that need
  the two shots to prove "same moment".
* **`DualShotView` relaid out — breaking.** It is now
  `Column[back photo, Row[front photo, map, lat/long + timestamp]]` instead of
  the GPS-camera overlay, and it is identical for both capture paths, so a
  mixed fleet of devices produces one consistent image.
* **Human-readable timestamps — breaking.** `formatTimestamp` now returns
  `7 Aug 2026, 2:05 PM` rather than `2026-08-07 14:05`. Still stdlib-only, so
  it is English and 12-hour; format it yourself with `intl` if you need a
  localized stamp.
* `DualShotStyle` reworked for the new layout: `footerHeight`,
  `thumbnailRadius`, `thumbnailBorderColor`, `footerColor`, `textColor`,
  `gap`, `showMapInFooter`, with `dark` / `light` / `tall` presets. The
  0.2.0 fields (`selfieAlignment`, `barRadius`, …) described an overlay that
  no longer exists and are gone.
* `DualCaptureLabels` gains `bothStep`, `bothPrompt`, `bothCountdown` and
  `openingCameras` for the simultaneous path.
* Example app: a capture-mode picker, a map toggle, and a line reporting
  which path the device actually took.

## 0.3.0

* **Hands-free capture — behavior change.** `GuidedDualCaptureFlow` no longer
  waits for shutter taps. Each camera opens, a countdown runs on screen, and
  the photo is taken automatically: selfie, then back photo, then done. Zero
  taps for the whole flow.
* New `countdown` parameter (default 3 seconds) sets how long the user gets
  to pose and to turn the phone around; `Duration.zero` shoots as soon as the
  preview is live.
* The shutter button is replaced by a countdown ring that shows the seconds
  remaining, then a spinner while the shot is taken.
* `DualCaptureLabels` gains `frontCountdown`, `backCountdown` and
  `capturing` for the new on-screen text. Existing labels are unchanged, so
  only apps that want the new strings translated need to touch them.
* Backgrounding mid-count cancels the countdown and restarts it with the
  camera on resume, so the app never shoots at the inside of a pocket.
* Tests: a fake `CameraPlatform` drives the whole flow, proving both photos
  are captured with no taps (`camera_platform_interface` is now a
  dev dependency).

## 0.2.0

* New `DualShotStyle`: customize the composed layout — selfie corner
  (`selfieAlignment`), size, corner radius and border color, plus the info
  bar's color, text color and shape. Ready-made looks: `classic` (full-width
  translucent bar, the previous default), `floating` (dark rounded card) and
  `light` (bright rounded card). `copyWith` for tweaks. The saved image
  (`saveComposedDualShot`) follows whatever style is on screen.
* Example app: pick a style preset and selfie corner on the result page
  before saving.
* Fix: `GuidedDualCaptureFlow` no longer calls `setState` after being
  disposed when a capture fails, and no longer fires `onComplete` if the
  user backs out while the location fix is finishing.

## 0.1.1

* `DualShotView` redesigned GPS-camera style: the back photo fills the view,
  the selfie floats as a bordered card top-right, and a translucent bottom
  bar holds the map, coordinates and timestamp.
* New `saveComposedDualShot(boundaryKey, result)`: saves the composed layout
  as one PNG next to the captured photos in the app cache.
* The finishing step waits at most 2 seconds for the in-flight GPS fix, then
  uses the instant last-known position — "Getting location…" no longer stalls.
* One-go capture flow: the interstitial "I'm ready" screens are gone. The
  front camera opens immediately with a hint banner over the viewfinder,
  the back camera opens automatically after the selfie — two taps total.
  Redesigned viewfinder: full-bleed preview, gradient scrims, step chip,
  ring shutter, and the front shot shown as a thumbnail during the back
  shot. `DualCaptureLabels` lost `ready`/`loadingCameras` and its prompts
  are now short one-liners.
* New `MapThumbnail`: a real map in the result footer — one OpenStreetMap
  tile with a marker, no maps SDK and no API key. `DualShotView` shows it
  next to the front photo when location is available; pass `showMap: false`
  to skip it (offline apps). Apps need the `INTERNET` permission on Android.
* `DualShotView` design pass: themed footer surface, rounded thumbnails,
  clearer coordinate/time typography.
* Much faster location + result display:
  * The GPS fix now starts as soon as the flow opens and runs in parallel
    while the user takes both photos — the "Getting location…" step usually
    completes instantly instead of waiting up to 10 seconds.
  * `DualShotView` decodes photos at display size (`cacheWidth`/`cacheHeight`)
    instead of full camera resolution — quicker to appear and far less memory
    on old devices.

## 0.1.0

* **Complete rewrite — breaking.** The method-channel plugin and all native
  Kotlin/Swift code are gone. The package is now pure Dart on top of the
  official `camera` and `geolocator` plugins.
* New guided flow `GuidedDualCaptureFlow`: prompts the user for a front
  (selfie) photo, then a back photo, then attaches lat/long + timestamp and
  returns a `DualShotResult`.
* New `DualShotView`: renders the result as
  Column[back photo, Row[front photo, lat/long/timestamp]].
* All user-visible strings are overridable via `DualCaptureLabels` for
  localization.
* Camera permission denial shows an in-flow retry screen; location denial
  degrades to a null lat/long instead of failing the capture.
* Tuned for old and low-RAM devices: one camera controller at a time,
  medium-resolution default, no audio, camera released on backgrounding,
  low-accuracy location with a 10-second cap.

## 0.0.4

* Fix crashes when switching the live camera and previews drawn sideways,
  mirrored wrong or stretched. The Android preview now streams into
  `SurfaceProducer` (the engine's supported external-texture API, Impeller
  included) instead of the deprecated `createSurfaceTexture()`. Each feed
  reports `handlesRotation`; `DualCameraFeed` only rotates/mirrors in Dart
  when the engine hands out raw sensor-oriented buffers, so frames are never
  double-transformed.
* Closing a camera no longer rebuilds a capture session on the way out —
  switching cameras is faster and no longer races the camera HAL.
* The preview survives backgrounding: when the engine tears the preview
  surface down the camera stops streaming, and it reconfigures onto the fresh
  surface when the app returns.
* Requires Flutter 3.27 or newer.

## 0.0.3

* Fix `initialize()` throwing `Can't create handler inside thread … Looper.prepare()`
  on Android: Flutter's texture registry must be used from the platform main
  thread, and the plugin was calling it from its worker. Texture create/release
  now hop to the main thread; an integration test covers the full
  initialize → preview → dispose cycle on a device.

## 0.0.2

* Low-RAM (Android Go) devices always take the sequential path and cap stills
  at ~8MP, so a second camera pipeline never competes for memory.

## 0.0.1

* `DualCameraController` — live front/back preview textures, `capturePhoto()`
  and `startRecording()`/`stopRecording()`.
* Simultaneous capture via Android concurrent cameras (API 30+) and iOS
  `AVCaptureMultiCamSession` (A12+), falling back to one camera at a time
  everywhere else. Sequential video records the back clip, then re-records the
  front for the same duration.
* `stage` reports which camera a sequential capture is on, so apps can say
  "Taking back photo…" / "Taking front photo…".
* `DualLayoutStyle` — one object holding every visual knob, shared by
  `DualLayoutView`, `DualCameraPreview` and `DualCaptureView` so a viewfinder
  and its result are configured identically. Picture-in-picture, side-by-side,
  stacked and primary-only arrangements, or a `builder` for anything else.
* Feeds and photos default to `BoxFit.contain`, so the whole frame is visible
  rather than cropped, with `background` filling the letterbox.
* `DualCameraLabels` — every user-facing string with English defaults and a
  `statusFor(controller)` that picks the right one, for wording and localisation.
* `DualStorage` — captures land in the cache directory by default; set a
  `directory` and/or `nameBuilder` to have them filed automatically.
* `AdaptiveDualCamera.capture()` / `.record()` for one-shot use without a preview.
