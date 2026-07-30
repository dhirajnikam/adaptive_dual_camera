package com.dhirajnikam.adaptive_dual_camera

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.mockito.Mockito
import kotlin.test.Test

/*
 * Unit test of the Kotlin portion of this plugin's implementation.
 *
 * The capture paths need a real CameraManager and Activity, so they are covered
 * by the example app's integration test on a device instead. What is checkable
 * here is that unknown methods are rejected rather than silently swallowed.
 *
 * Once you have built the plugin's example app, you can run these tests from the command
 * line by running `./gradlew testDebugUnitTest` in the `example/android/` directory, or
 * you can run them directly from IDEs that support JUnit such as Android Studio.
 */

internal class AdaptiveDualCameraPluginTest {
    @Test
    fun onMethodCall_unknownMethod_reportsNotImplemented() {
        val plugin = AdaptiveDualCameraPlugin()

        val call = MethodCall("thisMethodDoesNotExist", null)
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(call, mockResult)

        Mockito.verify(mockResult).notImplemented()
    }
}
