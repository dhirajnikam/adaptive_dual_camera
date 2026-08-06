/// Every user-visible string in one place, so apps can translate or reword
/// them. Defaults are English.
class DualCaptureLabels {
  const DualCaptureLabels({
    this.stepOne = '1 / 2',
    this.stepTwo = '2 / 2',
    this.frontPrompt = 'Show your face',
    this.backPrompt = 'Point at what you want to capture',
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
  final String gettingLocation;
  final String cameraDenied;
  final String retry;
  final String locationUnavailable;
}
