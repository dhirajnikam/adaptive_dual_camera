package com.dhirajnikam.adaptive_dual_camera

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.camera.core.CameraSelector
import androidx.camera.core.ConcurrentCamera
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.core.UseCaseGroup
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import io.flutter.view.TextureRegistry
import java.io.File
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicInteger

/**
 * Holds the front and back cameras open at the same time and takes one still
 * from each, together.
 *
 * Deliberately *not* a compositor: each preview is handed straight to a
 * Flutter texture and each still is written as its own JPEG. Composing the
 * two into the final layout is the Dart side's job, which keeps this class
 * small and keeps the saved image identical to the sequential path's.
 *
 * Only used for [DualCaptureMode.auto] on hardware that reports concurrent
 * support; the sequential path never comes through here.
 */
class ConcurrentCaptureSession(
  private val context: Context,
  private val textures: TextureRegistry,
) {
  private val mainHandler = Handler(Looper.getMainLooper())
  private val mainExecutor = Executor { mainHandler.post(it) }
  private val lifecycle = SimpleLifecycleOwner()

  private var provider: ProcessCameraProvider? = null
  private var backTexture: TextureRegistry.SurfaceProducer? = null
  private var frontTexture: TextureRegistry.SurfaceProducer? = null
  private var backCapture: ImageCapture? = null
  private var frontCapture: ImageCapture? = null

  /** True once both cameras are bound and streaming. */
  var isRunning = false
    private set

  /** Set by [stop]; a bind still in flight must abandon itself. */
  @Volatile private var stopped = false

  /**
   * Bind both cameras. [onReady] receives the texture ids and each preview's
   * dimensions and sensor rotation, which Dart needs to orient the previews.
   */
  fun start(
    onReady: (Map<String, Any>) -> Unit,
    onError: (Throwable) -> Unit,
  ) {
    if (isRunning) {
      onError(IllegalStateException("Session already running"))
      return
    }
    val future = ProcessCameraProvider.getInstance(context)
    future.addListener({
      try {
        // The Dart side gave up (timeout) and already called stop(); binding
        // now would hold both cameras with nobody listening.
        if (stopped) return@addListener

        val cameraProvider = future.get()
        provider = cameraProvider
        cameraProvider.unbindAll()

        // Deliberately no availableConcurrentCameraInfos gate here: it is
        // fed by getConcurrentCameraIds(), which is empty on plenty of
        // hardware that binds front+back just fine. bindToLifecycle below
        // is the real arbiter and throws on devices that truly can't.

        val back = textures.createSurfaceProducer()
        val front = textures.createSurfaceProducer()
        backTexture = back
        frontTexture = front

        // Let each camera run its native resolution; Dart's BoxFit.cover
        // crops. Forcing an aspect makes the HAL pre-stretch the sensor.
        val backPreview = Preview.Builder().build().also { preview ->
          preview.setSurfaceProvider(mainExecutor) { request ->
            back.setSize(request.resolution.width, request.resolution.height)
            request.provideSurface(back.surface, mainExecutor) {}
          }
        }
        val frontPreview = Preview.Builder().build().also { preview ->
          preview.setSurfaceProvider(mainExecutor) { request ->
            front.setSize(request.resolution.width, request.resolution.height)
            request.provideSurface(front.surface, mainExecutor) {}
          }
        }

        // MINIMIZE_LATENCY: the two shutters should fire as close together as
        // possible — that closeness is the entire point of this path.
        val backStill = ImageCapture.Builder()
          .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
          .build()
        val frontStill = ImageCapture.Builder()
          .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
          .build()
        backCapture = backStill
        frontCapture = frontStill

        val configs = listOf(
          ConcurrentCamera.SingleCameraConfig(
            CameraSelector.DEFAULT_BACK_CAMERA,
            UseCaseGroup.Builder().addUseCase(backPreview).addUseCase(backStill).build(),
            lifecycle,
          ),
          ConcurrentCamera.SingleCameraConfig(
            CameraSelector.DEFAULT_FRONT_CAMERA,
            UseCaseGroup.Builder().addUseCase(frontPreview).addUseCase(frontStill).build(),
            lifecycle,
          ),
        )

        lifecycle.start()
        val bound = cameraProvider.bindToLifecycle(configs)
        if (bound.cameras.size < 2) {
          throw IllegalStateException("Only ${bound.cameras.size} camera bound")
        }

        // Read sizes from resolutionInfo after binding rather than inside
        // the surface-provider callback — that callback can land after
        // onReady, which would hand Dart a map with no dimensions in it.
        val dims = HashMap<String, Any>()
        backPreview.resolutionInfo?.resolution?.let {
          dims["backWidth"] = it.width
          dims["backHeight"] = it.height
        }
        frontPreview.resolutionInfo?.resolution?.let {
          dims["frontWidth"] = it.width
          dims["frontHeight"] = it.height
        }
        for (camera in bound.cameras) {
          val info = camera.cameraInfo
          val isFront = info.lensFacing == CameraSelector.LENS_FACING_FRONT
          dims[if (isFront) "frontRotation" else "backRotation"] =
            info.sensorRotationDegrees
        }

        isRunning = true
        onReady(
          hashMapOf<String, Any>(
            "backTextureId" to back.id(),
            "frontTextureId" to front.id(),
          ).apply { putAll(dims) },
        )
      } catch (t: Throwable) {
        // Any failure here means "this device can't really do it" — release
        // everything so the Dart side can fall back to the sequential flow
        // with both cameras free.
        stop()
        onError(t)
      }
    }, mainExecutor)
  }

  /**
   * Fire both shutters and reply once both JPEGs are on disk. Either failing
   * fails the whole capture — a half-simultaneous result is worse than
   * falling back.
   */
  fun captureBoth(
    onResult: (Map<String, String>) -> Unit,
    onError: (Throwable) -> Unit,
  ) {
    val back = backCapture
    val front = frontCapture
    if (!isRunning || back == null || front == null) {
      onError(IllegalStateException("Session is not running"))
      return
    }

    val stamp = System.currentTimeMillis()
    val backFile = File(context.cacheDir, "ADC_back_$stamp.jpg")
    val frontFile = File(context.cacheDir, "ADC_front_$stamp.jpg")

    val remaining = AtomicInteger(2)
    val failure = arrayOfNulls<Throwable>(1)

    fun settle() {
      if (remaining.decrementAndGet() != 0) return
      val error = failure[0]
      if (error != null) {
        backFile.delete()
        frontFile.delete()
        onError(error)
      } else {
        onResult(
          mapOf(
            "backPath" to backFile.absolutePath,
            "frontPath" to frontFile.absolutePath,
          ),
        )
      }
    }

    fun shoot(capture: ImageCapture, file: File, mirror: Boolean) {
      val metadata = ImageCapture.Metadata().apply { isReversedHorizontal = mirror }
      val options = ImageCapture.OutputFileOptions.Builder(file)
        .setMetadata(metadata)
        .build()
      capture.takePicture(
        options,
        mainExecutor,
        object : ImageCapture.OnImageSavedCallback {
          override fun onImageSaved(output: ImageCapture.OutputFileResults) = settle()

          override fun onError(exception: ImageCaptureException) {
            failure[0] = exception
            settle()
          }
        },
      )
    }

    // Both calls go out before either callback can land — as close to one
    // moment as the framework allows.
    shoot(back, backFile, mirror = false)
    shoot(front, frontFile, mirror = true)
  }

  fun stop() {
    stopped = true
    isRunning = false
    try {
      provider?.unbindAll()
    } catch (_: Throwable) {
    }
    lifecycle.stop()
    provider = null
    backCapture = null
    frontCapture = null
    backTexture?.release()
    frontTexture?.release()
    backTexture = null
    frontTexture = null
  }

  /** Minimal always-resumed LifecycleOwner for a headless camera session. */
  private class SimpleLifecycleOwner : LifecycleOwner {
    private val registry = LifecycleRegistry(this)
    override val lifecycle: Lifecycle get() = registry

    fun start() {
      registry.currentState = Lifecycle.State.RESUMED
    }

    fun stop() {
      if (registry.currentState != Lifecycle.State.DESTROYED) {
        registry.currentState = Lifecycle.State.DESTROYED
      }
    }
  }
}
