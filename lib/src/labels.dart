/// Every user-visible string in one place, so apps can translate or reword
/// them. Defaults are English.
class DualCaptureLabels {
  const DualCaptureLabels({
    this.stepOne = 'Step 1 of 2',
    this.stepTwo = 'Step 2 of 2',
    this.frontPrompt =
        'First we\'ll take a picture with the front camera.\nShow your face.',
    this.backPrompt = 'Now point the back camera at what you want to capture.',
    this.ready = 'I\'m ready',
    this.loadingCameras = 'Loading cameras…',
    this.gettingLocation = 'Getting location…',
    this.cameraDenied =
        'Camera access is needed to take pictures.\nPlease allow camera access and try again.',
    this.retry = 'Try again',
    this.locationUnavailable = 'Location unavailable',
  });

  final String stepOne;
  final String stepTwo;
  final String frontPrompt;
  final String backPrompt;
  final String ready;
  final String loadingCameras;
  final String gettingLocation;
  final String cameraDenied;
  final String retry;
  final String locationUnavailable;
}
