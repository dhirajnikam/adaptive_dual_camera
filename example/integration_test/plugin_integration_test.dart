// Runs on a real device/simulator, so it can talk to the host side of the plugin.
//
// Capture itself needs a granted camera permission and a human to point the
// phone at something, so the automated checks stay on the parts that must
// answer on every device without one.
//
// For more information about Flutter integration tests, please see
// https://flutter.dev/to/integration-testing

import 'package:adaptive_dual_camera/adaptive_dual_camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('isSimultaneousSupported answers without throwing', (
    tester,
  ) async {
    final supported = await AdaptiveDualCamera().isSimultaneousSupported();
    expect(supported, isA<bool>());
  });

  testWidgets('the controller refuses to capture before initialize', (
    tester,
  ) async {
    final controller = DualCameraController();
    addTearDown(controller.dispose);

    expect(controller.capturePhoto(), throwsStateError);
    expect(controller.status, DualCameraStatus.uninitialized);
  });

  testWidgets('initialize opens the cameras and dispose releases them', (
    tester,
  ) async {
    // Needs a pre-granted camera permission (adb shell pm grant …); skips
    // cleanly on devices that haven't, so CI without a grant still passes.
    final controller = DualCameraController();

    try {
      await controller.initialize();
    } on Object catch (e) {
      await controller.dispose();
      final denied =
          e.toString().contains('permission_denied') ||
          e.toString().contains('no_camera');
      if (denied) {
        markTestSkipped('Camera permission not granted on this device.');
        return;
      }
      rethrow;
    }

    expect(controller.status, DualCameraStatus.ready);
    expect(controller.mode, isNotNull);
    expect(controller.feedFor(controller.activeCamera), isNotNull);

    await controller.dispose();
    expect(controller.status, DualCameraStatus.disposed);
  });
}
