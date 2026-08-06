import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'labels.dart';
import 'models.dart';

/// Guided two-shot capture in one continuous flow: the front camera opens
/// immediately with a short on-screen hint ("show your face"), one tap takes
/// the selfie, the back camera opens automatically, a second tap finishes.
/// Location + timestamp are attached and [onComplete] is called — two taps
/// total, no interstitial screens.
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
  });

  final ValueChanged<DualShotResult> onComplete;
  final ValueChanged<Object>? onError;
  final ResolutionPreset resolution;

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
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Old devices reclaim the camera aggressively; release it when backgrounded.
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _disposeController();
    } else if (state == AppLifecycleState.resumed && _controller == null) {
      _openCamera();
    }
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
      if (mounted) setState(() {});
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
        widget.onComplete(DualShotResult(
          frontPhoto: _frontShot!,
          backPhoto: shot,
          timestamp: DateTime.now(),
          latitude: position?.latitude,
          longitude: position?.longitude,
        ));
      }
    } catch (e) {
      setState(() => _busy = false);
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
    setState(() =>
        _stage = _frontShot == null ? _Stage.frontShoot : _Stage.backShoot);
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
            Text(widget.labels.gettingLocation,
                style: const TextStyle(color: Colors.white)),
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
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        front ? labels.stepOne : labels.stepTwo,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Icon(front ? Icons.face : Icons.photo_camera,
                        color: Colors.white, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        front ? labels.frontPrompt : labels.backPrompt,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 15),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // Bottom scrim: front-shot thumbnail + ring shutter.
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
                    _ShutterButton(
                        enabled: !_busy &&
                            controller != null &&
                            controller.value.isInitialized,
                        onPressed: _shoot),
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

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({required this.enabled, required this.onPressed});

  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onPressed : null,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 4),
        ),
        padding: const EdgeInsets.all(5),
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: enabled ? Colors.white : Colors.white38,
          ),
        ),
      ),
    );
  }
}
