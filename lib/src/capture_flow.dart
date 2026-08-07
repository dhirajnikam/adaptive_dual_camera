import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'labels.dart';
import 'models.dart';
import 'support.dart';

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
/// Support is decided in two steps: [DualCameraSupport] asks the platform
/// (`getConcurrentCameraIds` / `AVCaptureMultiCamSession`), and if the answer
/// is yes the flow still confirms by opening both cameras — hardware that
/// advertises concurrency but drops a pipeline falls back cleanly. Devices
/// that say no are never asked to open a second camera at all.
///
/// When the device can't do it, the sequential viewfinder says so once
/// ([DualCaptureLabels.simultaneousUnavailable]) rather than silently
/// behaving differently from the same app on someone else's phone. Query it
/// yourself up front with
/// [DualCameraSupport.supportsSimultaneousCapture].
///
/// Pass [DualCaptureMode.sequential] to skip all of this, which is the right
/// call on old and low-RAM phones.
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

  /// The live camera in sequential mode. Null in simultaneous mode, which is
  /// driven by the native session rather than the `camera` plugin.
  CameraController? _controller;

  /// The two texture ids the native session streams into; null in sequential
  /// mode.
  NativeDualPreview? _nativePreview;

  _Stage _stage = _Stage.probing;
  XFile? _frontShot;
  bool _busy = false;
  late final Future<Position?> _positionFuture;
  Timer? _countdownTimer;

  /// Seconds still to go before the automatic shot; 0 means none pending.
  int _secondsLeft = 0;

  /// Set when the caller asked for [DualCaptureMode.auto] but this device
  /// can't deliver it — drives the one-time notice on the viewfinder.
  bool _simultaneousUnavailable = false;

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
    if (_nativePreview != null) DualCameraSupport.stopSimultaneous();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Old devices reclaim the camera aggressively; release it when backgrounded.
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      // Don't shoot at a pocket: the countdown restarts with the camera.
      _cancelCountdown();
      _releaseCameras();
    } else if (state == AppLifecycleState.resumed &&
        _controller == null &&
        _nativePreview == null) {
      _simultaneous ? _openBoth() : _openCamera();
    }
  }

  /// Pick the capture mode once, at the start: ask the platform, and if it
  /// says yes confirm by actually opening both cameras. Anything short of
  /// that runs the one-at-a-time flow.
  Future<void> _start() async {
    final hasBothLenses =
        _cameras.any((c) => c.lensDirection == CameraLensDirection.front) &&
        _cameras.any((c) => c.lensDirection == CameraLensDirection.back);
    if (widget.mode == DualCaptureMode.auto && hasBothLenses) {
      final platformSaysYes =
          await DualCameraSupport.supportsSimultaneousCapture();
      if (!mounted) return;
      if (platformSaysYes) {
        if (await _openBoth()) return;
        if (!mounted) return;
      }
      // Either the device never claimed concurrency, or it claimed it and
      // then failed the attempt. Both are worth telling the user about.
      _simultaneousUnavailable = true;
    }
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

  /// Detach previews from the tree in the same frame the camera is released —
  /// CameraPreview listens to its controller and rebuilds on value changes,
  /// so disposing while it is still mounted throws "buildPreview() was called
  /// on a disposed CameraController". Textures need the same treatment: a
  /// Texture widget pointing at an unregistered id renders garbage.
  Future<void> _releaseCameras() async {
    final controller = _controller;
    final hadNative = _nativePreview != null;
    if (controller == null && !hadNative) return;
    _controller = null;
    _nativePreview = null;
    if (mounted) setState(() {});
    await controller?.dispose();
    if (hadNative) await DualCameraSupport.stopSimultaneous();
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

  /// Hand the simultaneous path to the native session. Returns false — with
  /// both cameras released — on any device that won't actually do it.
  Future<bool> _openBoth() async {
    await _releaseCameras();
    final preview = await DualCameraSupport.startSimultaneous().timeout(
      _openTimeout,
      onTimeout: () => null, // a device that hangs is a device that can't
    );
    if (preview == null) return false;
    if (!mounted) {
      await DualCameraSupport.stopSimultaneous();
      return false;
    }
    _nativePreview = preview;
    setState(() => _stage = _Stage.bothShoot);
    _startCountdown();
    return true;
  }

  Future<void> _openCamera() async {
    if (_cameras.isEmpty ||
        _stage == _Stage.finishing ||
        _stage == _Stage.cameraDenied) {
      return;
    }
    try {
      await _releaseCameras();
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
    if (_busy) return;
    if (_simultaneous) {
      _cancelCountdown();
      setState(() => _busy = true);
      // Both shutters at once, fired by the native session — this is the
      // whole point of the mode.
      final shots = await DualCameraSupport.captureBoth();
      await _releaseCameras();
      if (!mounted) return;
      if (shots == null) {
        // The session died mid-capture. Rather than strand the user, start
        // the sequential flow over — they still end up with both photos.
        _simultaneousUnavailable = true;
        setState(() {
          _stage = _Stage.frontShoot;
          _busy = false;
        });
        await _openCamera();
        return;
      }
      await _finish(front: shots.front, back: shots.back, simultaneous: true);
      return;
    }

    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    _cancelCountdown();
    setState(() => _busy = true);
    try {
      final shot = await controller.takePicture();
      await _releaseCameras();
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

  /// Full-bleed preview from the `camera` plugin (sequential path): cover the
  /// screen instead of letterboxing.
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

  /// Preview from the native concurrent session (simultaneous path). The
  /// texture carries raw sensor frames on Android, so the rotation the
  /// platform reported has to be applied here; iOS reports 0 because the
  /// capture connection already delivers portrait.
  Widget _texturePreview(int textureId, int rotation) {
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: RotatedBox(
        quarterTurns: (rotation ~/ 90) % 4,
        // Sized so FittedBox has an intrinsic box to scale; the aspect is
        // corrected by the cover fit.
        child: SizedBox(
          width: 1080,
          height: 1440,
          child: Texture(textureId: textureId),
        ),
      ),
    );
  }

  Widget _viewfinder() {
    final labels = widget.labels;
    final controller = _controller;
    final native = _nativePreview;
    final front = _stage == _Stage.frontShoot;
    final live = controller != null && controller.value.isInitialized;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (native != null)
          _texturePreview(native.backTextureId, native.backRotation)
        else if (live)
          _preview(controller)
        else
          const Center(child: CircularProgressIndicator(color: Colors.white)),
        // Simultaneous mode: the selfie runs as an inset, previewing the
        // arrangement the saved image will have.
        if (native != null)
          Positioned(
            top: 90,
            right: 16,
            width: 96,
            height: 128,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: _texturePreview(
                native.frontTextureId,
                native.frontRotation,
              ),
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
        // Auto was asked for and this device can't do it — say so instead of
        // quietly behaving differently from the same app on another phone.
        if (_simultaneousUnavailable && front)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(top: 64, left: 16, right: 16),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.info_outline,
                        color: Colors.white70,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          labels.simultaneousUnavailable,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
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
