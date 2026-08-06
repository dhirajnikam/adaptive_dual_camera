import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'labels.dart';
import 'models.dart';

/// Guided two-shot capture: prompts for a front (selfie) photo, then a back
/// photo, then attaches location + timestamp and calls [onComplete].
///
/// Only one [CameraController] is ever alive, at [resolution] (default
/// medium) with audio disabled — deliberately gentle on old and low-RAM
/// Android/iOS devices.
///
/// Permissions: the camera plugin requests camera access on first use; a
/// denial shows a retry screen ([DualCaptureLabels.cameraDenied]). Location
/// permission is requested before the final fix and degrades to a null
/// lat/long instead of failing the capture.
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

enum _Stage {
  frontPrompt,
  frontShoot,
  backPrompt,
  backShoot,
  finishing,
  cameraDenied,
}

class _GuidedDualCaptureFlowState extends State<GuidedDualCaptureFlow>
    with WidgetsBindingObserver {
  List<CameraDescription> _cameras = const [];
  CameraController? _controller;
  _Stage _stage = _Stage.frontPrompt;
  XFile? _frontShot;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    availableCameras().then((cams) {
      if (mounted) setState(() => _cameras = cams);
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
    final controller = _controller;
    if (controller == null) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      controller.dispose();
      _controller = null;
    } else if (state == AppLifecycleState.resumed) {
      _openCamera();
    }
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
    try {
      await _controller?.dispose();
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
      await controller.dispose();
      _controller = null;
      if (!mounted) return;
      if (_stage == _Stage.frontShoot) {
        _frontShot = shot;
        setState(() {
          _stage = _Stage.backPrompt;
          _busy = false;
        });
      } else {
        setState(() => _stage = _Stage.finishing);
        final position = await _locate();
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
      try {
        return await Geolocator.getLastKnownPosition();
      } catch (_) {
        return null;
      }
    }
  }

  void _advanceFromPrompt() {
    setState(() => _stage =
        _stage == _Stage.frontPrompt ? _Stage.frontShoot : _Stage.backShoot);
    _openCamera();
  }

  void _retryCamera() {
    // Return to the prompt for whichever shot we were on.
    setState(() => _stage =
        _frontShot == null ? _Stage.frontPrompt : _Stage.backPrompt);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    final labels = widget.labels;
    switch (_stage) {
      case _Stage.frontPrompt:
        return _message(labels.stepOne, labels.frontPrompt, Icons.face,
            button: labels.ready, onPressed: _advanceFromPrompt);
      case _Stage.backPrompt:
        return _message(labels.stepTwo, labels.backPrompt, Icons.photo_camera,
            button: labels.ready, onPressed: _advanceFromPrompt);
      case _Stage.cameraDenied:
        return _message(null, labels.cameraDenied, Icons.no_photography,
            button: labels.retry, onPressed: _retryCamera);
      case _Stage.frontShoot:
      case _Stage.backShoot:
        return _viewfinder();
      case _Stage.finishing:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Colors.white),
              const SizedBox(height: 16),
              Text(labels.gettingLocation,
                  style: const TextStyle(color: Colors.white)),
            ],
          ),
        );
    }
  }

  Widget _message(String? step, String message, IconData icon,
      {required String button, required VoidCallback onPressed}) {
    final waiting = _cameras.isEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 72, color: Colors.white),
            const SizedBox(height: 24),
            if (step != null) ...[
              Text(step,
                  style: const TextStyle(color: Colors.white54, fontSize: 14)),
              const SizedBox(height: 8),
            ],
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 18),
            ),
            const SizedBox(height: 32),
            FilledButton(
              onPressed: waiting ? null : onPressed,
              child: Text(waiting ? widget.labels.loadingCameras : button),
            ),
          ],
        ),
      ),
    );
  }

  Widget _viewfinder() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(
          child: CircularProgressIndicator(color: Colors.white));
    }
    return Stack(
      alignment: Alignment.bottomCenter,
      children: [
        Center(child: CameraPreview(controller)),
        Padding(
          padding: const EdgeInsets.only(bottom: 32),
          child: FloatingActionButton.large(
            onPressed: _busy ? null : _shoot,
            backgroundColor: Colors.white,
            child: const Icon(Icons.camera_alt, color: Colors.black),
          ),
        ),
      ],
    );
  }
}
