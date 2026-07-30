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
* Low-RAM (Android Go) devices always take the sequential path and cap stills
  at ~8MP, so a second camera pipeline never competes for memory.
