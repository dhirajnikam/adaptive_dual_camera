# adaptive_dual_camera_example

Demonstrates the full `adaptive_dual_camera` API:

- **Hands-free capture** — `GuidedDualCaptureFlow` counts down and takes the
  selfie by itself, switches to the back camera, counts down again, shoots
  again, then stamps location + timestamp. The user never taps a shutter.
- **Localization** — a language toggle (English / हिन्दी) swaps the
  `DualCaptureLabels` object; every visible string changes.
- **Old-device tuning** — a resolution picker (`low` / `medium` / `high`)
  passed straight to the flow.
- **Result display** — `DualShotView` renders the shot GPS-camera style: back
  photo full-bleed, selfie as a floating card, and an info bar with the map
  thumbnail, coordinates and timestamp.
- **Customizable layout** — the result page has two pickers: a `DualShotStyle`
  preset (Classic / Float / Light) and the selfie corner. The preview updates
  live.
- **Save as one image** — the Save button calls `saveComposedDualShot`, which
  writes the composed layout — styled exactly as previewed — to a PNG and
  shows its path in a SnackBar.
- **Error handling** — capture errors surface in a SnackBar; a denied camera
  permission shows the flow's built-in retry screen.

Run it on a real device (cameras don't exist in emulators the same way):

```sh
flutter run
```
