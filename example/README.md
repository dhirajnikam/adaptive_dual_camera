# adaptive_dual_camera_example

Demonstrates the full `adaptive_dual_camera` API:

- **Hands-free capture** — `GuidedDualCaptureFlow` counts down and takes both
  photos by itself. The user never taps a shutter.
- **Simultaneous vs sequential** — a capture-mode picker (Auto / Sequential).
  On Auto the flow tries both cameras at once and falls back on its own; the
  result page reports which path the device actually took.
- **Localization** — a language toggle (English / हिन्दी) swaps the
  `DualCaptureLabels` object; every visible string changes.
- **Old-device tuning** — a resolution picker (`low` / `medium` / `high`)
  passed straight to the flow, plus Sequential mode for low-RAM phones.
- **Result display** — `DualShotView` renders
  `Column[back photo, Row[front photo, map, lat/long + timestamp]]`,
  identically for both capture paths.
- **Customizable layout** — a `DualShotStyle` preset picker (Dark / Light /
  Tall) and a map toggle. The preview updates live.
- **Save as one image** — the Save button calls `saveComposedDualShot`, which
  writes the composed layout — styled exactly as previewed — to a PNG and
  shows its path in a SnackBar.
- **Error handling** — capture errors surface in a SnackBar; a denied camera
  permission shows the flow's built-in retry screen.

Run it on a real device (cameras don't exist in emulators the same way, and
concurrent-camera support in particular needs real hardware):

```sh
flutter run
```
