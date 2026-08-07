import 'package:adaptive_dual_camera/adaptive_dual_camera.dart';
import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Adaptive dual camera',
    theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
    darkTheme: ThemeData(
      colorSchemeSeed: Colors.teal,
      brightness: Brightness.dark,
      useMaterial3: true,
    ),
    home: const HomePage(),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // Medium suits most phones; low keeps very old devices smooth.
  ResolutionPreset _resolution = ResolutionPreset.medium;

  // Auto uses both cameras at once where the hardware allows it.
  DualCaptureMode _mode = DualCaptureMode.auto;

  /// Null until the native probe answers.
  bool? _supportsSimultaneous;

  @override
  void initState() {
    super.initState();
    DualCameraSupport.supportsSimultaneousCapture().then((supported) {
      if (mounted) setState(() => _supportsSimultaneous = supported);
    });
  }

  Future<void> _startCapture() async {
    final result = await Navigator.of(context).push<DualShotResult>(
      MaterialPageRoute(
        // Every user-visible string is yours to supply: pass
        // `labels: DualCaptureLabels(...)` to reword or translate them.
        builder: (context) => GuidedDualCaptureFlow(
          resolution: _resolution,
          mode: _mode,
          onComplete: (r) => Navigator.of(context).pop(r),
          onError: (e) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('Capture error: $e')));
          },
        ),
      ),
    );
    if (result != null && mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (context) => ResultPage(result: result)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Adaptive dual camera')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _HowItWorksCard(),
          const SizedBox(height: 16),
          Text(
            'Camera resolution',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          SegmentedButton<ResolutionPreset>(
            segments: const [
              ButtonSegment(value: ResolutionPreset.low, label: Text('Low')),
              ButtonSegment(
                value: ResolutionPreset.medium,
                label: Text('Medium'),
              ),
              ButtonSegment(value: ResolutionPreset.high, label: Text('High')),
            ],
            selected: {_resolution},
            onSelectionChanged: (s) => setState(() => _resolution = s.first),
          ),
          const SizedBox(height: 4),
          Text(
            'Pick Low on very old phones.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Text('Capture mode', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<DualCaptureMode>(
            segments: const [
              ButtonSegment(
                value: DualCaptureMode.auto,
                label: Text('Auto'),
                icon: Icon(Icons.flip_camera_android),
              ),
              ButtonSegment(
                value: DualCaptureMode.sequential,
                label: Text('Sequential'),
                icon: Icon(Icons.looks_two),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
          const SizedBox(height: 4),
          // What the native probe says about *this* device.
          switch (_supportsSimultaneous) {
            null => Text(
              'Checking whether this device can use both cameras at once…',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            true => Text(
              'This device supports both cameras at once. Auto will use it.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Colors.green.shade700),
            ),
            false => Text(
              'This device cannot run both cameras at once, so Auto will '
              'take the photos one after the other.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Colors.orange.shade800),
            ),
          },
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _startCapture,
            icon: const Icon(Icons.camera_alt),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('Start guided capture'),
            ),
          ),
        ],
      ),
    );
  }
}

class _HowItWorksCard extends StatelessWidget {
  const _HowItWorksCard();

  @override
  Widget build(BuildContext context) {
    const steps = [
      (
        Icons.flip_camera_android,
        'Both cameras at once where the phone supports it',
      ),
      (Icons.looks_two, 'Otherwise selfie first, then the back photo'),
      (Icons.place, 'Same layout either way — one tap starts it'),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'How it works',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            for (final (icon, text) in steps)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(icon, size: 20),
                    const SizedBox(width: 12),
                    Expanded(child: Text(text)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Shows the composed result and can save it as one image.
class ResultPage extends StatefulWidget {
  const ResultPage({super.key, required this.result});

  final DualShotResult result;

  @override
  State<ResultPage> createState() => _ResultPageState();
}

class _ResultPageState extends State<ResultPage> {
  final _viewKey = GlobalKey();
  bool _saving = false;
  bool _showMap = true;
  DualShotStyle _preset = DualShotStyle.dark;

  DualShotStyle get _style => _preset;

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final file = await saveComposedDualShot(_viewKey, widget.result);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Saved: ${file.path}')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Your capture')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Expanded(
                child: Card(
                  clipBehavior: Clip.antiAlias,
                  margin: EdgeInsets.zero,
                  child: DualShotView(
                    result: widget.result,
                    style: _style,
                    showMap: _showMap,
                    boundaryKey: _viewKey,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // Which path the device actually took — the layout above is
              // identical either way.
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    widget.result.wasSimultaneous
                        ? Icons.flip_camera_android
                        : Icons.looks_two,
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    widget.result.wasSimultaneous
                        ? 'Both cameras fired together'
                        : 'Cameras fired one after the other',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Customize the layout; the saved image matches the preview.
              Row(
                children: [
                  SegmentedButton<DualShotStyle>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: DualShotStyle.dark,
                        label: Text('Dark'),
                      ),
                      ButtonSegment(
                        value: DualShotStyle.light,
                        label: Text('Light'),
                      ),
                      ButtonSegment(
                        value: DualShotStyle.tall,
                        label: Text('Tall'),
                      ),
                    ],
                    selected: {_preset},
                    onSelectionChanged: (s) =>
                        setState(() => _preset = s.first),
                  ),
                  const Spacer(),
                  IconButton.filledTonal(
                    tooltip: _showMap ? 'Hide map' : 'Show map',
                    isSelected: _showMap,
                    icon: const Icon(Icons.map_outlined),
                    selectedIcon: const Icon(Icons.map),
                    onPressed: () => setState(() => _showMap = !_showMap),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.replay),
                      label: const Text('Retake'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: const Icon(Icons.save_alt),
                      label: Text(_saving ? 'Saving…' : 'Save'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
