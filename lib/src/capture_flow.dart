import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'labels.dart';
import 'models.dart';

/// Hands-free two-shot capture in one continuous flow: the front camera opens
/// immediately with a short on-screen hint ("show your face") and a visible
/// countdown, the selfie is taken automatically, the back camera opens and
/// counts down again, and the second shot finishes the flow. Location +
/// timestamp are attached and [onComplete] is called — zero taps, no
/// interstitial screens.
///
/// Only one [CameraController] is ever alive, at [resolution] (default
/// medium) with audio disabled — deliberately gentle on old and low-RAM
/// Android/iOS devices.
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
  });

  final ValueChanged<DualShotResult> onComplete;
  final ValueChanged<Object>? onError;
  final ResolutionPreset resolution;

  /// How long the user gets to pose (and to turn the phone around before the
  /// back shot) after each camera opens. [Duration.zero] shoots as soon as
  /// the preview is live.
  ///
  /// ponytail: one delay for both shots — split into front/back durations if
  /// turning the phone around needs longer than posing does.
  final Duration countdown;

  /// Override to translate or reword every user-visible string.
  final DualCaptureLabels labels;

  @override
  State<GuidedDualCaptureFlow> createState() => _GuidedDualCaptureFlowState();
}

enum _Stage { frontShoot, backShoot, finishing, cameraDenied }

class _GuidedDualCaptureFlowState extends State<GuidedDualCaptureFlow>
    with WidgetsBindingObserver {
  List<CameraDescription> _cameras = const [];
  CameraController? _controller;
  _Stage _stage = _Stage.frontShoot;
  XFile? _frontShot;
  bool _busy = false;
  late final Future<Position?> _positionFuture;
  Timer? _countdownTimer;

  /// Seconds still to go before the automatic shot; 0 means none pending.
  int _secondsLeft = 0;

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
      _openCamera(); // straight into the front viewfinder, no tap needed
    }, onError: _fail);
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Old devices reclaim the camera aggressively; release it when backgrounded.
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      // Don't shoot at a pocket: the countdown restarts with the camera.
      _cancelCountdown();
      _disposeController();
    } else if (state == AppLifecycleState.resumed && _controller == null) {
      _openCamera();
    }
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

  /// Detach the preview from the tree in the same frame the controller is
  /// disposed — CameraPreview listens to the controller and rebuilds on its
  /// value changes, so disposing while it is still mounted throws
  /// "buildPreview() was called on a disposed CameraController".
  Future<void> _disposeController() async {
    final controller = _controller;
    if (controller == null) return;
    _controller = null;
    if (mounted) setState(() {});
    await controller.dispose();
  }

  void _fail(Object e) {
    widget.onError?.call(e);
  }

  CameraLensDirection get _neededLens => _stage == _Stage.frontShoot
      ? CameraLensDirection.front
      : CameraLensDirection.back;

  CameraDescription _pick(CameraLensDirection direction) {
    return _cameras.firstWhere(
      (c) => c.lensDirection == direction,
      orElse: () => _cameras.first, // single-camera devices still work
    );
  }

  Future<void> _openCamera() async {
    if (_cameras.isEmpty ||
        _stage == _Stage.finishing ||
        _stage == _Stage.cameraDenied) {
      return;
    }
    try {
      await _disposeController();
      final controller = CameraController(
        _pick(_neededLens),
        widget.resolution,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
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
      final shot = await controller.takePicture();
      await _disposeController();
      if (!mounted) return;
      if (_stage == _Stage.frontShoot) {
        _frontShot = shot;
        setState(() {
          _stage = _Stage.backShoot;
          _busy = false;
        });
        await _openCamera(); // auto-advance — no confirmation screen
      } else {
        setState(() => _stage = _Stage.finishing);
        // The fix has been warming up since the flow opened; if it still
        // isn't in after 2s, take the instant last-known position instead.
        final position = await _positionFuture.timeout(
          const Duration(seconds: 2),
          onTimeout: _lastKnown,
        );
        // User backed out while we waited for the fix — drop the result
        // rather than calling onComplete against a dead context.
        if (!mounted) return;
        widget.onComplete(
          DualShotResult(
            frontPhoto: _frontShot!,
            backPhoto: shot,
            timestamp: DateTime.now(),
            latitude: position?.latitude,
            longitude: position?.longitude,
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      _fail(e);
    }
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
        _Stage.frontShoot || _Stage.backShoot => _viewfinder(),
        _Stage.finishing => _finishing(),
        _Stage.cameraDenied => _denied(),
      },
    );
  }

  Widget _finishing() {
    return SafeArea(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Colors.white),
            const SizedBox(height: 16),
            Text(
              widget.labels.gettingLocation,
              style: const TextStyle(color: Colors.white),
            ),
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

  Widget _viewfinder() {
    final labels = widget.labels;
    final controller = _controller;
    final front = _stage == _Stage.frontShoot;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Full-bleed preview: cover the screen instead of letterboxing.
        if (controller != null && controller.value.isInitialized)
          FittedBox(
            fit: BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: controller.value.previewSize!.height,
              height: controller.value.previewSize!.width,
              child: CameraPreview(controller),
            ),
          )
        else
          const Center(child: CircularProgressIndicator(color: Colors.white)),
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
                        front ? labels.stepOne : labels.stepTwo,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Icon(
                      front ? Icons.face : Icons.photo_camera,
                      color: Colors.white,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        front ? labels.frontPrompt : labels.backPrompt,
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
