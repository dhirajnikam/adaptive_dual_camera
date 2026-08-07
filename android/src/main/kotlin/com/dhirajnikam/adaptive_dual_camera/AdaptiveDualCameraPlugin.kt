package com.dhirajnikam.adaptive_dual_camera

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.flutter.view.TextureRegistry

/**
 * The package's only native code, and it covers only the simultaneous path:
 * report whether this device can hold both cameras open, and if so run that
 * concurrent session. The sequential path is pure Dart on top of the
 * official `camera` plugin and never reaches this class.
 */
class AdaptiveDualCameraPlugin :
  FlutterPlugin,
  MethodChannel.MethodCallHandler,
  ActivityAware,
  PluginRegistry.RequestPermissionsResultListener {
  private var channel: MethodChannel? = null
  private var context: Context? = null
  private var textures: TextureRegistry? = null
  private var session: ConcurrentCaptureSession? = null
  private var activityBinding: ActivityPluginBinding? = null

  /** The one in-flight camera-permission request; resolved by the OS dialog. */
  private var pendingPermission: ((Boolean) -> Unit)? = null

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    textures = binding.textureRegistry
    channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
      it.setMethodCallHandler(this)
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    session?.stop()
    session = null
    channel?.setMethodCallHandler(null)
    channel = null
    context = null
    textures = null
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "supportsConcurrentCameras" -> result.success(supportsConcurrentCameras())

      "ensureCameraPermission" -> ensureCameraPermission { result.success(it) }

      "startConcurrent" -> {
        val ctx = context
        val registry = textures
        if (ctx == null || registry == null) {
          result.error("unavailable", "Plugin is detached", null)
          return
        }
        session?.stop()
        val fresh = ConcurrentCaptureSession(ctx, registry)
        session = fresh
        fresh.start(
          onReady = { result.success(it) },
          onError = {
            session = null
            result.error("startFailed", it.message, null)
          },
        )
      }

      "captureBoth" -> {
        val running = session
        if (running == null) {
          result.error("notRunning", "No concurrent session", null)
          return
        }
        running.captureBoth(
          onResult = { result.success(it) },
          onError = { result.error("captureFailed", it.message, null) },
        )
      }

      "stopConcurrent" -> {
        session?.stop()
        session = null
        result.success(null)
      }

      else -> result.notImplemented()
    }
  }

  /**
   * The exact gate CameraX's concurrent `bindToLifecycle` uses: the
   * FEATURE_CAMERA_CONCURRENT system feature. `getConcurrentCameraIds()` is
   * NOT consulted — devices (and the emulator) that stream front+back
   * happily often return an empty set there, and CameraX never reads it
   * before binding, so requiring it produced false "unsupported" answers.
   * Devices that overclaim the feature are caught by the second gate:
   * actually starting the session.
   */
  private fun supportsConcurrentCameras(): Boolean {
    val ctx = context ?: return false
    return try {
      ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_CONCURRENT)
    } catch (_: Throwable) {
      false
    }
  }

  /**
   * The native session binds CameraX directly, so nothing else on the
   * simultaneous path ever shows the OS camera-permission dialog — this
   * does, before the first bind. Answers true once granted.
   */
  private fun ensureCameraPermission(onResult: (Boolean) -> Unit) {
    val ctx = context ?: return onResult(false)
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return onResult(true)
    if (ctx.checkSelfPermission(Manifest.permission.CAMERA) ==
      PackageManager.PERMISSION_GRANTED
    ) {
      return onResult(true)
    }
    val activity = activityBinding?.activity ?: return onResult(false)
    if (pendingPermission != null) return onResult(false) // one dialog at a time
    pendingPermission = onResult
    activity.requestPermissions(arrayOf(Manifest.permission.CAMERA), PERMISSION_CODE)
  }

  override fun onRequestPermissionsResult(
    requestCode: Int,
    permissions: Array<out String>,
    grantResults: IntArray,
  ): Boolean {
    if (requestCode != PERMISSION_CODE) return false
    val granted = grantResults.isNotEmpty() &&
      grantResults[0] == PackageManager.PERMISSION_GRANTED
    pendingPermission?.invoke(granted)
    pendingPermission = null
    return true
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activityBinding = binding
    binding.addRequestPermissionsResultListener(this)
  }

  override fun onDetachedFromActivity() {
    activityBinding?.removeRequestPermissionsResultListener(this)
    activityBinding = null
    // The dialog can't answer once the activity is gone; don't strand Dart.
    pendingPermission?.invoke(false)
    pendingPermission = null
  }

  override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
    onAttachedToActivity(binding)

  private companion object {
    const val CHANNEL = "adaptive_dual_camera/support"
    const val PERMISSION_CODE = 54_71
  }
}
