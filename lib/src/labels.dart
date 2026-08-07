/// Every user-visible string in one place, so apps can translate or reword
/// them. Defaults are English.
class DualCaptureLabels {
  const DualCaptureLabels({
    this.stepOne = '1 / 2',
    this.stepTwo = '2 / 2',
    this.bothStep = 'Both cameras',
    this.frontPrompt = 'Show your face',
    this.backPrompt = 'Point at what you want to capture',
    this.bothPrompt = 'Show your face and what is in front of you',
    this.frontCountdown = 'Taking your selfie…',
    this.backCountdown = 'Turn the phone around — back photo next',
    this.bothCountdown = 'Both photos at once — hold still…',
    this.capturing = 'Capturing…',
    this.openingCameras = 'Opening cameras…',
    this.simultaneousUnavailable =
        'This phone can\'t use both cameras at once — '
        'taking the photos one after the other',
    this.gettingLocation = 'Getting location…',
    this.cameraDenied =
        'Camera access is needed to take pictures.\nPlease allow camera access and try again.',
    this.retry = 'Try again',
    this.locationUnavailable = 'Location unavailable',
  });

  final String stepOne;
  final String stepTwo;

  /// Replaces the "1 / 2" step chip when both cameras fire together — there
  /// are no steps to count.
  final String bothStep;

  final String frontPrompt;
  final String backPrompt;

  /// Banner hint in simultaneous mode, where the user has to satisfy both
  /// cameras at the same time.
  final String bothPrompt;

  /// Under the countdown before the automatic selfie.
  final String frontCountdown;

  /// Under the countdown before the automatic back shot — the moment the
  /// user has to turn the phone around.
  final String backCountdown;

  /// Under the countdown in simultaneous mode.
  final String bothCountdown;

  /// Under the spinner while the shot is actually being taken.
  final String capturing;

  /// While the flow is deciding whether this device can run both cameras.
  final String openingCameras;

  /// Shown once, over the first viewfinder, when the app asked for
  /// [DualCaptureMode.auto] but the device can only shoot sequentially.
  final String simultaneousUnavailable;

  final String gettingLocation;
  final String cameraDenied;
  final String retry;
  final String locationUnavailable;
}
