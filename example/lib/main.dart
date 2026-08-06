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

/// Demonstrates [DualCaptureLabels]: every user-visible string is
/// overridable, so translation is just another labels object.
const _localizedLabels = <String, DualCaptureLabels>{
  'English': DualCaptureLabels(),
  'हिन्दी': DualCaptureLabels(
    stepOne: 'चरण 1 / 2',
    stepTwo: 'चरण 2 / 2',
    frontPrompt: 'पहले फ्रंट कैमरे से फोटो लेंगे।\nअपना चेहरा दिखाएँ।',
    backPrompt: 'अब बैक कैमरे को उस ओर करें जिसे कैप्चर करना है।',
    ready: 'तैयार हूँ',
    loadingCameras: 'कैमरे लोड हो रहे हैं…',
    gettingLocation: 'स्थान प्राप्त हो रहा है…',
    cameraDenied: 'फोटो लेने के लिए कैमरे की अनुमति चाहिए।\nकृपया अनुमति देकर फिर से कोशिश करें।',
    retry: 'फिर से कोशिश करें',
    locationUnavailable: 'स्थान उपलब्ध नहीं',
  ),
};

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _language = 'English';

  // Medium suits most phones; low keeps very old devices smooth.
  ResolutionPreset _resolution = ResolutionPreset.medium;

  DualCaptureLabels get _labels => _localizedLabels[_language]!;

  Future<void> _startCapture() async {
    final result = await Navigator.of(context).push<DualShotResult>(
      MaterialPageRoute(
        builder: (context) => GuidedDualCaptureFlow(
          labels: _labels,
          resolution: _resolution,
          onComplete: (r) => Navigator.of(context).pop(r),
          onError: (e) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Capture error: $e')),
            );
          },
        ),
      ),
    );
    if (result != null && mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => ResultPage(result: result, labels: _labels),
        ),
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
          Text('Language', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: [
              for (final language in _localizedLabels.keys)
                ButtonSegment(value: language, label: Text(language)),
            ],
            selected: {_language},
            onSelectionChanged: (s) => setState(() => _language = s.first),
          ),
          const SizedBox(height: 16),
          Text('Camera resolution',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<ResolutionPreset>(
            segments: const [
              ButtonSegment(
                  value: ResolutionPreset.low, label: Text('Low')),
              ButtonSegment(
                  value: ResolutionPreset.medium, label: Text('Medium')),
              ButtonSegment(
                  value: ResolutionPreset.high, label: Text('High')),
            ],
            selected: {_resolution},
            onSelectionChanged: (s) => setState(() => _resolution = s.first),
          ),
          const SizedBox(height: 4),
          Text(
            'Pick Low on very old phones.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
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
      (Icons.face, 'Front photo — you are prompted to show your face'),
      (Icons.photo_camera, 'Back photo — point at your subject'),
      (Icons.place, 'Location + timestamp are stamped automatically'),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('How it works',
                style: Theme.of(context).textTheme.titleMedium),
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

/// Shows the composed result — back photo on top, front photo + geo/time
/// footer below — plus the raw data underneath.
class ResultPage extends StatelessWidget {
  const ResultPage({super.key, required this.result, required this.labels});

  final DualShotResult result;
  final DualCaptureLabels labels;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Your capture')),
      body: Column(
        children: [
          Expanded(child: DualShotView(result: result, labels: labels)),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'front: ${result.frontPhoto.path}\n'
                    'back:  ${result.backPhoto.path}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.replay),
                    label: const Text('Retake'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
