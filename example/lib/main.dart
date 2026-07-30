import 'package:adaptive_dual_camera/adaptive_dual_camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData.dark(useMaterial3: true),
    home: const DemoPage(),
  );
}

class DemoPage extends StatefulWidget {
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  final _controller = DualCameraController();

  // One style drives the viewfinder and the result view alike.
  DualLayoutStyle _style = const DualLayoutStyle(
    background: Colors.black,
    paneBorderRadius: BorderRadius.all(Radius.circular(8)),
    insetBorder: Border.fromBorderSide(BorderSide(color: Colors.white24)),
  );

  String? _error;
  bool _starting = true;
  DualCapture? _photo;
  DualRecording? _clip;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      if (!await _controller.requestPermission(microphone: true)) {
        throw PlatformException(
          code: 'permission_denied',
          message: 'Camera or microphone permission denied.',
        );
      }
      await _controller.initialize();
    } on PlatformException catch (e) {
      _fail('${e.code}: ${e.message}');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _fail(String message) {
    if (mounted) setState(() => _error = message);
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _error = null);
    try {
      await action();
    } on PlatformException catch (e) {
      _fail('${e.code}: ${e.message}');
    } on StateError catch (e) {
      _fail(e.message);
    }
  }

  Future<void> _takePhoto() => _run(() async {
    final shot = await _controller.capturePhoto();
    if (mounted) setState(() => _photo = shot);
  });

  Future<void> _toggleRecording() => _run(() async {
    if (_controller.isRecording) {
      final clip = await _controller.stopRecording(
        frontLeadIn: const Duration(seconds: 3),
      );
      if (mounted) setState(() => _clip = clip);
    } else {
      await _controller.startRecording();
    }
  });

  /// Every user-facing string comes from here, so wording and translations are
  /// one object away. Defaults are English; these two are overridden to show
  /// how.
  static const _labels = DualCameraLabels(
    takingBackPhoto: 'Taking back photo…',
    takingFrontPhoto: 'Taking front photo…',
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Adaptive dual camera')),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          if (_starting) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _viewfinder(),
              const SizedBox(height: 12),
              _statusLine(),
              const SizedBox(height: 12),
              _actions(),
              const Divider(height: 32),
              _layoutControls(),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ],
              if (_photo != null) ...[
                const Divider(height: 32),
                Text('Photo · ${_photo!.mode.name}'),
                const SizedBox(height: 8),
                AspectRatio(
                  aspectRatio: 3 / 4,
                  // The very same style object as the viewfinder, so the
                  // result matches what the user framed.
                  child: DualCaptureView(capture: _photo, style: _style),
                ),
              ],
              if (_clip != null) ...[
                const Divider(height: 32),
                Text(
                  'Video · ${_clip!.mode.name} · '
                  '${_clip!.duration.inMilliseconds}ms',
                ),
                Text(
                  'back:  ${_clip!.back.path}',
                  style: const TextStyle(fontSize: 11),
                ),
                Text(
                  'front: ${_clip!.front.path}',
                  style: const TextStyle(fontSize: 11),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _viewfinder() => AspectRatio(
    aspectRatio: 3 / 4,
    child: DualCameraPreview(
      controller: _controller,
      style: _style,
      placeholderBuilder: (context, camera) => ColoredBox(
        color: Colors.white10,
        child: Center(
          child: Text(
            _labels.notLive(camera),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11),
          ),
        ),
      ),
    ),
  );

  Widget _statusLine() {
    // One call covers the capture stage and the retake countdown, in priority
    // order, already localised.
    final message = _labels.statusFor(_controller);
    final pass = _controller.secondPass;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_labels.modeFor(_controller) ?? 'Not initialised'),
        if (message != null) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: pass == null
                        ? null
                        : pass.rolling
                        ? Colors.redAccent
                        : Colors.amberAccent,
                  ),
                ),
              ),
            ],
          ),
        ],
        // Sequential hardware has to retake the front clip after the back one;
        // without progress the app just looks hung.
        if (pass != null) ...[
          const SizedBox(height: 4),
          LinearProgressIndicator(value: pass.progress),
        ],
      ],
    );
  }

  Widget _actions() {
    final busy = _controller.isBusy;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton(
          onPressed: busy ? null : _takePhoto,
          child: const Text('Take both photos'),
        ),
        FilledButton.tonal(
          onPressed: (busy && !_controller.isRecording)
              ? null
              : _toggleRecording,
          child: Text(_controller.isRecording ? 'Stop recording' : 'Record'),
        ),
        if (_controller.mode == DualCaptureMode.sequential)
          OutlinedButton(
            onPressed: busy
                ? null
                : () => _run(
                    () => _controller.switchTo(
                      _controller.activeCamera == DualCamera.back
                          ? DualCamera.front
                          : DualCamera.back,
                    ),
                  ),
            child: const Text('Switch live camera'),
          ),
      ],
    );
  }

  /// Every one of these edits the single [DualLayoutStyle] above, which both
  /// the viewfinder and the result view read.
  Widget _layoutControls() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Layout', style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      SegmentedButton<DualLayout>(
        segments: const [
          ButtonSegment(value: DualLayout.pictureInPicture, label: Text('PiP')),
          ButtonSegment(value: DualLayout.sideBySide, label: Text('Side')),
          ButtonSegment(value: DualLayout.stacked, label: Text('Stack')),
          ButtonSegment(value: DualLayout.primaryOnly, label: Text('One')),
        ],
        selected: {_style.layout},
        onSelectionChanged: (s) => _restyle(_style.copyWith(layout: s.first)),
      ),
      const SizedBox(height: 8),
      _row(
        'Primary',
        SegmentedButton<DualCamera>(
          segments: const [
            ButtonSegment(value: DualCamera.back, label: Text('Back')),
            ButtonSegment(value: DualCamera.front, label: Text('Front')),
          ],
          selected: {_style.primary},
          onSelectionChanged: (s) =>
              _restyle(_style.copyWith(primary: s.first)),
        ),
      ),
      const SizedBox(height: 8),
      // contain shows the whole frame; cover fills the pane and crops.
      _row(
        'Fit',
        SegmentedButton<BoxFit>(
          segments: const [
            ButtonSegment(value: BoxFit.contain, label: Text('Contain')),
            ButtonSegment(value: BoxFit.cover, label: Text('Cover')),
            ButtonSegment(value: BoxFit.fill, label: Text('Fill')),
          ],
          selected: {_style.fit},
          onSelectionChanged: (s) => _restyle(_style.copyWith(fit: s.first)),
        ),
      ),
      if (_style.layout == DualLayout.pictureInPicture) ...[
        const SizedBox(height: 8),
        _row(
          'Inset',
          SegmentedButton<Alignment>(
            segments: const [
              ButtonSegment(value: Alignment.topLeft, label: Text('TL')),
              ButtonSegment(value: Alignment.topRight, label: Text('TR')),
              ButtonSegment(value: Alignment.bottomLeft, label: Text('BL')),
              ButtonSegment(value: Alignment.bottomRight, label: Text('BR')),
            ],
            selected: {_style.insetAlignment},
            onSelectionChanged: (s) =>
                _restyle(_style.copyWith(insetAlignment: s.first)),
          ),
        ),
        const SizedBox(height: 8),
        Text('Inset size · ${(_style.insetScale * 100).round()}%'),
        Slider(
          value: _style.insetScale,
          min: 0.15,
          max: 0.6,
          onChanged: (v) => _restyle(_style.copyWith(insetScale: v)),
        ),
      ],
    ],
  );

  Widget _row(String label, Widget control) => Row(
    children: [
      SizedBox(width: 64, child: Text('$label:')),
      Expanded(child: control),
    ],
  );

  void _restyle(DualLayoutStyle style) => setState(() => _style = style);
}
