import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'labels.dart';
import 'models.dart';

/// Hands-free two-shot capture, using both cameras at once where the hardware
/// allows it and one after the other where it doesn't.
///
/// * **Simultaneous** (Android devices with concurrent-camera support, iPhone
///   XS/A12 and later): both previews are live at once — back full-bleed with
///   the selfie inset — a countdown runs, and the two photos are taken
///   together, milliseconds apart.
/// * **Sequential** (everything else): the front camera opens, counts down and
///   shoots itself, then the back camera does the same.
///
/// Either way the user taps nothing, [onComplete] receives the same
/// [DualShotResult], and [DualShotView] renders it identically —
/// [DualShotResult.wasSimultaneous] is the only tell.
///
/// Support is probed by actually opening the second camera rather than by
/// asking the platform, because that is the thing that has to work; a device
/// that advertises concurrency but fails to deliver it falls back cleanly.
/// Pass [DualCaptureMode.sequential] to skip the probe entirely, which is the
/// right call on old and low-RAM phones.
///
/// Permissions: the camera plugin requests camera access on first use; a
/// denial shows a retry screen ([DualCaptureLabels.cameraDenied]). Location
/// is requested in parallel and degrades to a null lat/long instead of
/// failing the capture.
class GuidedDualCaptureFlow extends StatefulWidget {
  const GuidedDualCaptureFlow({
    super.key,
    required this.onComplete,
    this.onError,
    this.resolution = ResolutionPreset.medium,
    this.labels = const DualCaptureLabels(),
    this.countdown = const Duration(seconds: 3),
    this.mode = DualCaptureMode.auto,
  });

  final ValueChanged<DualShotResult> onComplete;
  final ValueChanged<Object>? onError;
  final ResolutionPreset resolution;

  /// Whether to try both cameras at once. See [DualCaptureMode].
  final DualCaptureMode mode;

  /// How long the user gets to pose (and, in sequential mode, to turn the
  /// phone around) after each camera opens. [Duration.zero] shoots as soon as
  /// the preview is live.
  ///
  /// ponytail: one delay for every shot — split it if turning the phone
  /// around needs longer than posing does.
  final Duration countdown;

  /// Override to translate or reword every user-visible string.
  final DualCaptureLabels labels;

  @override
  State<GuidedDualCaptureFlow> createState() => _GuidedDualCaptureFlowState();
}

enum _Stage {
  /// Deciding between simultaneous and sequential.
  probing,

  /// Both previews live, one countdown, both shots.
  bothShoot,

  /// One camera at a time.
  frontShoot,
  backShoot,

  finishing,
  cameraDenied,
}

/// A camera that hasn't opened within this long is treated as unavailable —
/// some devices hang rather than refuse when asked for a second pipeline.
const _openTimeout = Duration(seconds: 6);

class _GuidedDualCaptureFlowState extends State<GuidedDualCaptureFlow>
    with WidgetsBindingObserver {
  List<CameraDescription> _cameras = const [];

  /// The live camera in sequential mode; the *back* camera in simultaneous
  /// mode, where [_frontController] runs alongside it.
  CameraController? _controller;
  CameraController? _frontController;

  _Stage _stage = _Stage.probing;
  XFile? _frontShot;
  bool _busy = false;
  late final Future<Position?> _positionFuture;
  Timer? _countdownTimer;

  /// Seconds still to go before the automatic shot; 0 means none pending.
  int _secondsLeft = 0;

  bool get _simultaneous => _stage == _Stage.bothShoot;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Start the GPS fix now — it warms up while the user takes both photos,
    // so the finishing step usually awaits an already-resolved future.
    _positionFuture = _locate();
    availableCameras().then((cams) {
      if (!mounted) return;
      _cameras = cams;
      _start();
    }, onError: _fail);
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    _frontController?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Old devices reclaim the camera aggressively; release it when backgrounded.
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      // Don't shoot at a pocket: the countdown restarts with the camera.
      _cancelCountdown();
      _disposeControllers();
    } else if (state == AppLifecycleState.resumed && _controller == null) {
      _simultaneous ? _openBoth() : _openCamera();
    }
  }

  /// Pick the capture mode once, at the start: try both cameras together and
  /// keep them if they come up, otherwise run the one-at-a-time flow.
  Future<void> _start() async {
    final canTryBoth =
        widget.mode == DualCaptureMode.auto &&
        _cameras.any((c) => c.lensDirection == CameraLensDirection.front) &&
        _cameras.any((c) => c.lensDirection == CameraLensDirection.back);
    if (canTryBoth && await _openBoth()) return;
    if (!mounted) return;
    setState(() => _stage = _Stage.frontShoot);
    await _openCamera();
  }

  void _cancelCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _secondsLeft = 0;
  }

  /// Counts down out loud on screen, then takes the shot itself. Restarted
  /// from scratch every time a camera opens, so backgrounding mid-count
  /// gives the user the full delay again rather than an instant capture.
  void _startCountdown() {
    _cancelCountdown();
    final seconds = widget.countdown.inSeconds;
    if (seconds <= 0) {
      _shoot();
      return;
    }
    setState(() => _secondsLeft = seconds);
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) {
        _cancelCountdown();
        _shoot();
      }
    });
  }

  /// Detach previews from the tree in the same frame the controllers are
  /// disposed — CameraPreview listens to its controller and rebuilds on value
  /// changes, so disposing while it is still mounted throws
  /// "buildPreview() was called on a disposed CameraController".
  Future<void> _disposeControllers() async {
    final back = _controller;
    final front = _frontController;
    if (back == null && front == null) return;
    _controller = null;
    _frontController = null;
    if (mounted) setState(() {});
    await back?.dispose();
    await front?.dispose();
  }

  void _fail(Object e) {
    widget.onError?.call(e);
  }

  CameraDescription _pick(CameraLensDirection direction) {
    return _cameras.firstWhere(
      (c) => c.lensDirection == direction,
      orElse: () => _cameras.first, // single-camera devices still work
    );
  }

  CameraController _newController(CameraLensDirection lens) => CameraController(
    _pick(lens),
    widget.resolution,
    enableAudio: false,
    imageFormatGroup: ImageFormatGroup.jpeg,
  );

  /// Try to hold both cameras open at once. Returns false — having cleaned up
  /// after itself — on any device that won't do it.
  Future<bool> _openBoth() async {
    await _disposeControllers();
    CameraController? back;
    CameraController? front;
    try {
      back = _newController(CameraLensDirection.back);
      await back.initialize().timeout(_openTimeout);
      front = _newController(CameraLensDirection.front);
      await front.initialize().timeout(_openTimeout);
      // Opening the second camera can knock the first one over instead of
      // throwing, so confirm both are still healthy before committing.
      if (!back.value.isInitialized ||
          !front.value.isInitialized ||
          back.value.hasError ||
          front.value.hasError) {
        throw CameraException(
          'concurrentUnavailable',
          'The device dropped one camera when the other opened.',
        );
      }
      if (!mounted) throw CameraException('disposed', 'Flow left the tree.');
      _controller = back;
      _frontController = front;
      setState(() => _stage = _Stage.bothShoot);
      _startCountdown();
      return true;
    } on CameraException catch (e) {
      await back?.dispose();
      await front?.dispose();
      if (e.code.toLowerCase().contains('denied')) {
        if (mounted) setState(() => _stage = _Stage.cameraDenied);
        _fail(e);
        return true; // handled: the retry screen owns the flow now
      }
      return false; // not concurrent-capable — the caller goes sequential
    } catch (_) {
      await back?.dispose();
      await front?.dispose();
      return false;
    }
  }

  Future<void> _openCamera() async {
    if (_cameras.isEmpty ||
        _stage == _Stage.finishing ||
        _stage == _Stage.cameraDenied) {
      return;
    }
    try {
      await _disposeControllers();
      final controller = _newController(
        _stage == _Stage.frontShoot
            ? CameraLensDirection.front
            : CameraLensDirection.back,
      );
      _controller = controller;
      await controller.initialize();
      if (!mounted) return;
      setState(() {});
      _startCountdown(); // hands-free: the preview is live, so start counting
    } on CameraException catch (e) {
      _controller = null;
      if (e.code.toLowerCase().contains('denied')) {
        if (mounted) setState(() => _stage = _Stage.cameraDenied);
      }
      _fail(e);
    } catch (e) {
      _controller = null;
      _fail(e);
    }
  }

  Future<void> _shoot() async {
    final controller = _controller;
    if (_busy || controller == null || !controller.value.isInitialized) return;
    _cancelCountdown();
    setState(() => _busy = true);
    try {
      if (_simultaneous) {
        // Both shutters at once — this is the whole point of the mode.
        final shots = await Future.wait([
          controller.takePicture(),
          _frontController!.takePicture(),
        ]);
        await _disposeControllers();
        if (!mounted) return;
        await _finish(front: shots[1], back: shots[0], simultaneous: true);
        return;
      }
      final shot = await controller.takePicture();
      await _disposeControllers();
      if (!mounted) return;
      if (_stage == _Stage.frontShoot) {
        _frontShot = shot;
        setState(() {
          _stage = _Stage.backShoot;
          _busy = false;
        });
        await _openCamera(); // auto-advance — no confirmation screen
      } else {
        await _finish(front: _frontShot!, back: shot, simultaneous: false);
      }
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      _fail(e);
    }
  }

  /// Attach location + timestamp and hand the result over. Shared by both
  /// paths so they cannot drift apart.
  Future<void> _finish({
    required XFile front,
    required XFile back,
    required bool simultaneous,
  }) async {
    setState(() => _stage = _Stage.finishing);
    // The fix has been warming up since the flow opened; if it still isn't in
    // after 2s, take the instant last-known position instead.
    final position = await _positionFuture.timeout(
      const Duration(seconds: 2),
      onTimeout: _lastKnown,
    );
    // User backed out while we waited for the fix — drop the result rather
    // than calling onComplete against a dead context.
    if (!mounted) return;
    widget.onComplete(
      DualShotResult(
        frontPhoto: front,
        backPhoto: back,
        timestamp: DateTime.now(),
        latitude: position?.latitude,
        longitude: position?.longitude,
        wasSimultaneous: simultaneous,
      ),
    );
  }

  Future<Position?> _locate() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          // ponytail: low accuracy + 10s cap — fast fix on old GPS chips;
          // raise to LocationAccuracy.high if callers need street-level.
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 10),
        ),
      );
    } catch (_) {
      return _lastKnown();
    }
  }

  Future<Position?> _lastKnown() async {
    try {
      return await Geolocator.getLastKnownPosition();
    } catch (_) {
      return null;
    }
  }

  void _retryCamera() {
    setState(
      () => _stage = _frontShot == null ? _Stage.frontShoot : _Stage.backShoot,
    );
    _openCamera();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: switch (_stage) {
        _Stage.probing => _waiting(widget.labels.openingCameras),
        _Stage.bothShoot ||
        _Stage.frontShoot ||
        _Stage.backShoot => _viewfinder(),
        _Stage.finishing => _waiting(widget.labels.gettingLocation),
        _Stage.cameraDenied => _denied(),
      },
    );
  }

  Widget _waiting(String message) {
    return SafeArea(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Colors.white),
            const SizedBox(height: 16),
            Text(message, style: const TextStyle(color: Colors.white)),
          ],
        ),
      ),
    );
  }

  Widget _denied() {
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography, size: 64, color: Colors.white),
              const SizedBox(height: 24),
              Text(
                widget.labels.cameraDenied,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _retryCamera,
                child: Text(widget.labels.retry),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Full-bleed preview: cover the screen instead of letterboxing.
  Widget _preview(CameraController controller) {
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: controller.value.previewSize!.height,
        height: controller.value.previewSize!.width,
        child: CameraPreview(controller),
      ),
    );
  }

  Widget _viewfinder() {
    final labels = widget.labels;
    final controller = _controller;
    final front = _stage == _Stage.frontShoot;
    final live = controller != null && controller.value.isInitialized;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (live)
          _preview(controller)
        else
          const Center(child: CircularProgressIndicator(color: Colors.white)),
        // Simultaneous mode: the selfie runs as an inset, previewing the
        // arrangement the saved image will have.
        if (_simultaneous && _frontController?.value.isInitialized == true)
          Positioned(
            top: 90,
            right: 16,
            width: 96,
            height: 128,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: _preview(_frontController!),
            ),
          ),
        // Top scrim: step chip + one-line hint.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black87, Colors.transparent],
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        _simultaneous
                            ? labels.bothStep
                            : (front ? labels.stepOne : labels.stepTwo),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Icon(
                      _simultaneous
                          ? Icons.flip_camera_android
                          : (front ? Icons.face : Icons.photo_camera),
                      color: Colors.white,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _simultaneous
                            ? labels.bothPrompt
                            : (front ? labels.frontPrompt : labels.backPrompt),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // Bottom scrim: front-shot thumbnail + countdown.
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Colors.black87, Colors.transparent],
              ),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (_frontShot != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(
                            File(_frontShot!.path),
                            width: 48,
                            height: 64,
                            fit: BoxFit.cover,
                            cacheHeight: 128,
                          ),
                        ),
                      ),
                    _CountdownRing(
                      secondsLeft: _secondsLeft,
                      label: _busy || _secondsLeft == 0
                          ? labels.capturing
                          : _simultaneous
                          ? labels.bothCountdown
                          : (front
                                ? labels.frontCountdown
                                : labels.backCountdown),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The old shutter's spot, now showing what the camera is about to do on its
/// own: a big number ticking down, or a spinner while the shot is taken.
class _CountdownRing extends StatelessWidget {
  const _CountdownRing({required this.secondsLeft, required this.label});

  final int secondsLeft;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 72,
          height: 72,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black26,
            border: Border.all(color: Colors.white, width: 4),
          ),
          child: secondsLeft > 0
              ? Text(
                  '$secondsLeft',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                  ),
                )
              : const SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 3,
                  ),
                ),
        ),
        const SizedBox(height: 10),
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
      ],
    );
  }
}
