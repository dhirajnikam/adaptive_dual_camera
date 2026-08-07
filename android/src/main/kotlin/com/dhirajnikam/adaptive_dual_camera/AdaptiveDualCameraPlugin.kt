package com.dhirajnikam.adaptive_dual_camera

import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

/**
 * The package's only native code, and it covers only the simultaneous path:
 * report whether this device can hold both cameras open, and if so run that
 * concurrent session. The sequential path is pure Dart on top of the
 * official `camera` plugin and never reaches this class.
 */
class AdaptiveDualCameraPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private var channel: MethodChannel? = null
  private var context: Context? = null
  private var textures: TextureRegistry? = null
  private var session: ConcurrentCaptureSession? = null

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
   * True only when the platform lists a concurrent combination that actually
   * contains a front *and* a back camera — a device may support concurrency
   * for two back lenses while refusing front+back, which is useless here.
   *
   * Below API 30 there is no query, only the coarse system feature flag.
   */
  private fun supportsConcurrentCameras(): Boolean {
    val ctx = context ?: return false
    return try {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        val manager = ctx.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
          ?: return false
        manager.concurrentCameraIds.any { combo -> hasFrontAndBack(manager, combo) }
      } else {
        ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_CONCURRENT)
      }
    } catch (_: Throwable) {
      // A vendor CameraManager that throws is a device that can't do this.
      false
    }
  }

  private fun hasFrontAndBack(manager: CameraManager, combo: Set<String>): Boolean {
    var front = false
    var back = false
    for (id in combo) {
      when (manager.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING)) {
        CameraCharacteristics.LENS_FACING_FRONT -> front = true
        CameraCharacteristics.LENS_FACING_BACK -> back = true
      }
    }
    return front && back
  }

  private companion object {
    const val CHANNEL = "adaptive_dual_camera/support"
  }
}
