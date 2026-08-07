/// Every user-visible string in one place, so apps can translate or reword
/// them. Defaults are English.
class DualCaptureLabels {
  const DualCaptureLabels({
    this.stepOne = '1 / 2',
    this.stepTwo = '2 / 2',
    this.frontPrompt = 'Show your face',
    this.backPrompt = 'Point at what you want to capture',
    this.frontCountdown = 'Taking your selfie…',
    this.backCountdown = 'Turn the phone around — back photo next',
    this.capturing = 'Capturing…',
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

  /// Under the countdown before the automatic selfie.
  final String frontCountdown;

  /// Under the countdown before the automatic back shot — the moment the
  /// user has to turn the phone around.
  final String backCountdown;

  /// Under the spinner while the shot is actually being taken.
  final String capturing;

  final String gettingLocation;
  final String cameraDenied;
  final String retry;
  final String locationUnavailable;
}
