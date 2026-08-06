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
