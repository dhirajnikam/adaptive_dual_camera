# adaptive_dual_camera_example

Demonstrates the full `adaptive_dual_camera` API:

- **Guided capture** — `GuidedDualCaptureFlow` prompts for a front (selfie)
  photo, then a back photo, then stamps location + timestamp.
- **Localization** — a language toggle (English / हिन्दी) swaps the
  `DualCaptureLabels` object; every visible string changes.
- **Old-device tuning** — a resolution picker (`low` / `medium` / `high`)
  passed straight to the flow.
- **Result display** — `DualShotView` renders
  Column[back photo, Row[front photo, lat/long/timestamp]], with a retake
  button.
- **Error handling** — capture errors surface in a SnackBar; a denied camera
  permission shows the flow's built-in retry screen.

Run it on a real device (cameras don't exist in emulators the same way):

```sh
flutter run
```
