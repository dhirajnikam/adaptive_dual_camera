package com.dhirajnikam.adaptive_dual_camera

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.media.ImageReader
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Size
import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import io.flutter.view.TextureRegistry
import java.io.File
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** A failure worth reporting to Dart with a specific error code. */
private class CameraError(
    val code: String,
    message: String
) : Exception(message)

/**
 * Front + back capture on Camera2.
 *
 * Holds both cameras open when [CameraManager.getConcurrentCameraIds] reports a
 * usable back/front pair (API 30+); otherwise runs one camera at a time and
 * switches between them. Each live camera streams into a Flutter texture so
 * Dart can draw a viewfinder.
 */
class AdaptiveDualCameraPlugin :
    FlutterPlugin,
    MethodCallHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {
    private companion object {
        const val PERMISSION_REQUEST = 0x0DCA

        const val BACK = "back"
        const val FRONT = "front"

        // Guaranteed concurrent-camera stream combination is two streams per
        // camera: one YUV/PRIV at s720p plus one JPEG at s1440p. Everything
        // here stays inside that budget so the concurrent path configures on
        // as many devices as possible.
        val PREVIEW_MAX = Size(1280, 720)
        val CONCURRENT_JPEG_MAX = Size(1920, 1440)
        val VIDEO_MAX = Size(1280, 720)

        // ponytail: fixed 12MP ceiling on the sequential path instead of the
        // sensor maximum — keeps the fallback fast. Raise if quality matters more.
        val SEQUENTIAL_JPEG_MAX = Size(4000, 3000)

        // ponytail: 8MP still ceiling on low-RAM (Android Go) devices — a full
        // 12MP pipeline costs the HAL tens of MB per buffer. Raise if Go-device
        // photo quality ever matters more than headroom.
        val LOW_RAM_JPEG_MAX = Size(3264, 2448)

        const val VIDEO_BITRATE = 6_000_000
        const val VIDEO_FPS = 30

        // ponytail: fixed frame count instead of polling CONTROL_AE_STATE for
        // CONVERGED. Enough for auto-exposure to settle on every device tested;
        // switch to AE-state polling if a slow sensor still shows dark frames.
        const val WARMUP_FRAMES = 12
        const val WARMUP_TIMEOUT_MS = 2000L
        const val OPEN_TIMEOUT_MS = 5000L
        const val CAPTURE_TIMEOUT_MS = 8000L
    }

    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private lateinit var cameraManager: CameraManager
    private lateinit var textureRegistry: TextureRegistry

    private var activity: Activity? = null
    private var pendingPermission: Result? = null
    private var session: Session? = null

    // Lazy so constructing the plugin doesn't need a live Looper (JVM unit tests).
    private val main by lazy { Handler(Looper.getMainLooper()) }
    private var worker: ExecutorService = Executors.newSingleThreadExecutor()
    private var cameraThread: HandlerThread? = null
    private var cameraHandler: Handler? = null

    /** Runs camera callbacks off the worker thread so blocking helpers can't deadlock. */
    private val callbackExecutor = Executor { cameraHandler?.post(it) }

    /** Android Go and friends: never hold two camera pipelines, cap stills lower. */
    private val lowRam by lazy {
        (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).isLowRamDevice
    }

    // --- plugin lifecycle ---------------------------------------------------

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        textureRegistry = binding.textureRegistry
        cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        channel = MethodChannel(binding.binaryMessenger, "adaptive_dual_camera")
        channel.setMethodCallHandler(this)
        if (worker.isShutdown) worker = Executors.newSingleThreadExecutor()
        cameraThread = HandlerThread("adaptive_dual_camera").also {
            it.start()
            cameraHandler = Handler(it.looper)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        runCatching { session?.release() }
        session = null
        worker.shutdown()
        cameraThread?.quitSafely()
        cameraThread = null
        cameraHandler = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onDetachedFromActivity() {
        activity = null
    }

    // --- method dispatch ----------------------------------------------------

    override fun onMethodCall(
        call: MethodCall,
        result: Result
    ) {
        when (call.method) {
            "isSimultaneousSupported" -> result.success(concurrentPair() != null)

            "requestPermission" ->
                requestPermission(call.argument<Boolean>("microphone") == true, result)

            "initialize" ->
                background(result) {
                    requireCameraPermission()
                    session?.release()
                    val forced = call.argument<Boolean>("forceSequential") == true
                    Session(forced).also { session = it }.open()
                }

            "activate" ->
                background(result) {
                    requireSession().activate(call.argument<String>("camera") ?: BACK)
                }

            "capturePhoto" ->
                background(result) {
                    requireSession().capturePhoto(
                        call.argument<List<String>>("cameras") ?: listOf(BACK, FRONT),
                    )
                }

            "startRecording" ->
                background(result) {
                    val cameras = call.argument<List<String>>("cameras") ?: listOf(BACK)
                    val audio = call.argument<Boolean>("audio") != false
                    requireSession().startRecording(cameras, audio)
                }

            "stopRecording" -> background(result) { requireSession().stopRecording() }

            "release" ->
                background(result) {
                    session?.release()
                    session = null
                    null
                }

            else -> result.notImplemented()
        }
    }

    /** Runs [body] off the platform thread and answers [result] on it. */
    private fun background(
        result: Result,
        body: () -> Any?
    ) {
        if (worker.isShutdown) {
            result.error("released", "The plugin has been detached from the engine.", null)
            return
        }
        worker.execute {
            try {
                val value = body()
                main.post { result.success(value) }
            } catch (e: CameraError) {
                main.post { result.error(e.code, e.message, null) }
            } catch (e: Exception) {
                main.post { result.error("capture_failed", e.message ?: e.toString(), null) }
            }
        }
    }

    private fun requireSession(): Session =
        session ?: throw CameraError("not_initialized", "initialize() has not been called.")

    /**
     * Runs [block] on the platform main thread and blocks for the result.
     *
     * The texture registry insists on it: Flutter's surface-texture entry
     * builds a `Handler()` for the current thread and its frame callback must
     * land on the UI thread, so creating or releasing one anywhere else throws.
     */
    private fun <T : Any> onMain(block: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) return block()
        val slot = ArrayBlockingQueue<Any>(1)
        main.post { slot.offer(runCatching(block).fold({ it }, { it })) }
        @Suppress("UNCHECKED_CAST")
        return await(slot, OPEN_TIMEOUT_MS, "waiting for the platform thread") as T
    }

    // --- permission ---------------------------------------------------------

    private fun granted(permission: String) =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun requireCameraPermission() {
        if (!granted(Manifest.permission.CAMERA)) {
            throw CameraError("permission_denied", "Camera permission has not been granted.")
        }
    }

    private fun requestPermission(
        microphone: Boolean,
        result: Result
    ) {
        val wanted =
            buildList {
                if (!granted(Manifest.permission.CAMERA)) add(Manifest.permission.CAMERA)
                if (microphone && !granted(Manifest.permission.RECORD_AUDIO)) {
                    add(Manifest.permission.RECORD_AUDIO)
                }
            }
        if (wanted.isEmpty()) {
            result.success(true)
            return
        }
        val activity = this.activity
        if (activity == null) {
            result.error("no_activity", "Cannot request permission without an Activity.", null)
            return
        }
        if (pendingPermission != null) {
            result.error("already_pending", "A permission request is already in flight.", null)
            return
        }
        pendingPermission = result
        activity.requestPermissions(wanted.toTypedArray(), PERMISSION_REQUEST)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        val allGranted =
            grantResults.isNotEmpty() &&
                grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        pendingPermission?.success(allGranted)
        pendingPermission = null
        return true
    }

    // --- camera discovery ---------------------------------------------------

    private fun facing(id: String): Int? =
        cameraManager.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING)

    private fun firstFacing(lens: Int): String? =
        cameraManager.cameraIdList.firstOrNull { facing(it) == lens }

    /** A back/front camera id pair the device can hold open at once, or null. */
    private fun concurrentPair(): Pair<String, String>? {
        // A second open camera costs tens of MB of HAL buffers — on a low-RAM
        // device the sequential path is the safe one even when a pair exists.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R || lowRam) return null
        return try {
            cameraManager.concurrentCameraIds.firstNotNullOfOrNull { ids ->
                val back = ids.firstOrNull { facing(it) == CameraCharacteristics.LENS_FACING_BACK }
                val front = ids.firstOrNull { facing(it) == CameraCharacteristics.LENS_FACING_FRONT }
                if (back != null && front != null) back to front else null
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun pickSize(
        id: String,
        klass: Class<*>,
        max: Size
    ): Size = choose(streamMap(id).getOutputSizes(klass), max)

    private fun pickSize(
        id: String,
        format: Int,
        max: Size
    ): Size = choose(streamMap(id).getOutputSizes(format), max)

    private fun streamMap(id: String) =
        cameraManager
            .getCameraCharacteristics(id)
            .get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?: throw CameraError("capture_failed", "Camera $id reports no stream configurations.")

    private fun choose(
        sizes: Array<Size>?,
        max: Size
    ): Size {
        val all = sizes ?: throw CameraError("capture_failed", "Camera offers no usable sizes.")
        return all.filter { it.width <= max.width && it.height <= max.height }
            .maxByOrNull { it.width.toLong() * it.height }
            ?: all.minByOrNull { it.width.toLong() * it.height }
            ?: throw CameraError("capture_failed", "Camera offers no usable sizes.")
    }

    /** Degrees to rotate output so it comes out upright for the current device rotation. */
    private fun uprightRotation(id: String): Int {
        val sensor =
            cameraManager
                .getCameraCharacteristics(id)
                .get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
        val display =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                activity?.display?.rotation
            } else {
                @Suppress("DEPRECATION")
                activity?.windowManager?.defaultDisplay?.rotation
            }
        val rotation =
            when (display) {
                Surface.ROTATION_90 -> 90
                Surface.ROTATION_180 -> 180
                Surface.ROTATION_270 -> 270
                else -> 0
            }
        return if (facing(id) == CameraCharacteristics.LENS_FACING_FRONT) {
            (sensor + rotation) % 360
        } else {
            (sensor - rotation + 360) % 360
        }
    }

    private fun cacheFile(
        label: String,
        extension: String
    ) = File(context.cacheDir, "adc_${label}_${System.nanoTime()}.$extension")

    // --- session ------------------------------------------------------------

    /**
     * The open cameras and their Flutter textures.
     *
     * Simultaneous sessions keep a [Rig] per camera for their whole life.
     * Sequential sessions keep exactly one and swap it on [activate], but the
     * texture entries persist either way so Dart's texture ids stay stable.
     */
    private inner class Session(forceSequential: Boolean) {
        private val pair = if (forceSequential) null else concurrentPair()

        /** Cleared if the pair turns out not to handle what's being asked of it. */
        var simultaneous = pair != null
            private set

        private val backId =
            pair?.first
                ?: firstFacing(CameraCharacteristics.LENS_FACING_BACK)
                ?: throw CameraError("no_camera", "This device has no back camera.")
        private val frontId =
            pair?.second
                ?: firstFacing(CameraCharacteristics.LENS_FACING_FRONT)
                ?: throw CameraError("no_camera", "This device has no front camera.")

        private val entries = mutableMapOf<String, TextureRegistry.SurfaceTextureEntry>()
        private val rigs = mutableMapOf<String, Rig>()
        private var recording = emptyList<String>()

        var active = BACK
            private set

        fun idOf(camera: String) = if (camera == BACK) backId else frontId

        fun open(): Map<String, Any> {
            if (simultaneous) {
                start(BACK)
                start(FRONT)
                // Both stream at once so the two exposures settle in the same window.
                rigs.values.forEach { it.awaitExposure() }
            } else {
                start(BACK)
                rigs.getValue(BACK).awaitExposure()
            }
            return describe()
        }

        /** Points the single live camera at [camera]. No-op when both are live. */
        fun activate(camera: String): Map<String, Any> {
            if (simultaneous || camera == active) return describe()
            if (recording.isNotEmpty()) {
                throw CameraError("busy", "Cannot switch cameras while recording.")
            }
            rigs.remove(active)?.close()
            start(camera)
            rigs.getValue(camera).awaitExposure()
            active = camera
            return describe()
        }

        /**
         * Shoots [cameras]. Only a simultaneous session honours more than one
         * per call — sequential callers ask for one at a time so Dart can say
         * which photo is being taken.
         */
        fun capturePhoto(cameras: List<String>): Map<String, Any> {
            if (recording.isNotEmpty()) {
                throw CameraError("busy", "Cannot take a photo while recording.")
            }

            val wanted = if (simultaneous) cameras else listOf(cameras.firstOrNull() ?: active)
            val shots = mutableMapOf<String, Any>()

            // Fire every shutter before collecting, so a simultaneous pair goes
            // off together instead of one JPEG encode apart.
            val firing =
                wanted.map { camera ->
                    if (!simultaneous) activate(camera)
                    camera to rigs.getValue(camera).also { it.fireStill() }
                }
            for ((camera, rig) in firing) {
                shots[camera] = write(rig.awaitJpeg(), camera, "jpg")
            }
            shots["mode"] = if (simultaneous) "simultaneous" else "sequential"
            return shots
        }

        /**
         * Starts recording on [cameras].
         *
         * A device can advertise a concurrent pair for stills yet fail to
         * configure two video streams. When that happens the session drops to
         * sequential and records the back camera only — the returned mode says
         * so, and Dart runs its second pass off that.
         */
        fun startRecording(
            cameras: List<String>,
            audio: Boolean
        ): Map<String, Any> {
            if (recording.isNotEmpty()) {
                throw CameraError("busy", "Already recording.")
            }
            if (audio && !granted(Manifest.permission.RECORD_AUDIO)) {
                throw CameraError(
                    "permission_denied",
                    "Microphone permission has not been granted.",
                )
            }

            if (simultaneous && cameras.size > 1) {
                val started =
                    runCatching {
                        cameras.forEach { rigs.getValue(it).beginVideo(audio && it == BACK) }
                        cameras.forEach { rigs.getValue(it).startRecorder() }
                    }
                if (started.isSuccess) {
                    recording = cameras
                    return describe()
                }
                // Undo the half-built video config and fall through to one camera.
                cameras.forEach { runCatching { rigs[it]?.abandonVideo() } }
                degradeToSequential()
            }

            val camera = cameras.firstOrNull() ?: BACK
            activate(camera)
            val rig = rigs.getValue(camera)
            rig.beginVideo(audio && camera == BACK)
            rig.startRecorder()
            recording = listOf(camera)
            return describe()
        }

        fun stopRecording(): Map<String, Any> {
            if (recording.isEmpty()) throw CameraError("not_recording", "Not recording.")
            val results = mutableMapOf<String, Any>()
            for (camera in recording) {
                val path = rigs.getValue(camera).stopRecorder()
                if (path != null) results[camera] = path
            }
            recording = emptyList()
            return results
        }

        fun release() {
            runCatching { if (recording.isNotEmpty()) stopRecording() }
            rigs.values.forEach { it.close() }
            rigs.clear()
            entries.values.forEach { entry -> onMain { entry.release() } }
            entries.clear()
        }

        // --- internals ------------------------------------------------------

        /**
         * Both cameras were advertised as concurrent but won't record together.
         * Close the front camera and carry on one at a time.
         */
        private fun degradeToSequential() {
            simultaneous = false
            rigs.keys.toList().filter { it != BACK }.forEach { rigs.remove(it)?.close() }
            active = BACK
        }

        private fun start(camera: String) {
            val id = idOf(camera)
            val entry = entries.getOrPut(camera) { onMain { textureRegistry.createSurfaceTexture() } }
            rigs[camera] = Rig(camera, id, entry).also { it.open() }
        }

        private fun write(
            bytes: ByteArray,
            label: String,
            extension: String
        ): String = cacheFile(label, extension).apply { writeBytes(bytes) }.absolutePath

        private fun describe(): Map<String, Any> =
            mapOf(
                "mode" to if (simultaneous) "simultaneous" else "sequential",
                "feeds" to rigs.mapValues { (_, rig) -> rig.describe() },
            )
    }

    /**
     * One camera's device, capture session and outputs.
     *
     * Two stream configurations, swapped on demand so each stays inside the
     * two-stream concurrent budget: photo is preview + JPEG, video is preview +
     * recorder.
     */
    private inner class Rig(
        val camera: String,
        val id: String,
        val entry: TextureRegistry.SurfaceTextureEntry
    ) {
        private val previewSize = pickSize(id, android.graphics.SurfaceTexture::class.java, PREVIEW_MAX)
        private val jpegSize =
            pickSize(
                id,
                ImageFormat.JPEG,
                when {
                    lowRam -> LOW_RAM_JPEG_MAX
                    concurrentPair() != null -> CONCURRENT_JPEG_MAX
                    else -> SEQUENTIAL_JPEG_MAX
                },
            )
        private val videoSize = pickSize(id, MediaRecorder::class.java, VIDEO_MAX)

        private val frames = AtomicInteger()
        private val jpegs = ArrayBlockingQueue<ByteArray>(1)

        private val previewSurface: Surface =
            Surface(
                entry.surfaceTexture().apply {
                    setDefaultBufferSize(previewSize.width, previewSize.height)
                },
            )

        private val jpegReader =
            ImageReader.newInstance(jpegSize.width, jpegSize.height, ImageFormat.JPEG, 2).apply {
                setOnImageAvailableListener({ reader ->
                    val image = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
                    try {
                        val buffer = image.planes[0].buffer
                        val bytes = ByteArray(buffer.remaining())
                        buffer.get(bytes)
                        jpegs.offer(bytes)
                    } finally {
                        image.close()
                    }
                }, cameraHandler)
            }

        private var device: CameraDevice? = null
        private var session: CameraCaptureSession? = null
        private var recorder: MediaRecorder? = null
        private var recorderFile: File? = null
        private var recorderRunning = false

        fun describe(): Map<String, Any> =
            mapOf(
                "textureId" to entry.id(),
                "width" to previewSize.width,
                "height" to previewSize.height,
                "sensorOrientation" to uprightRotation(id),
                "mirrored" to (facing(id) == CameraCharacteristics.LENS_FACING_FRONT),
            )

        @SuppressLint("MissingPermission")
        fun open() {
            val slot = ArrayBlockingQueue<Any>(1)
            cameraManager.openCamera(
                id,
                object : CameraDevice.StateCallback() {
                    override fun onOpened(opened: CameraDevice) {
                        slot.offer(opened)
                    }

                    override fun onDisconnected(opened: CameraDevice) {
                        opened.close()
                        slot.offer(CameraError("camera_lost", "Camera $id disconnected"))
                    }

                    override fun onError(
                        opened: CameraDevice,
                        error: Int
                    ) {
                        opened.close()
                        slot.offer(
                            CameraError("camera_lost", "Camera $id failed to open (error $error)"),
                        )
                    }
                },
                cameraHandler,
            )
            device = await(slot, OPEN_TIMEOUT_MS, "opening camera $id") as CameraDevice
            configure(listOf(previewSurface, jpegReader.surface), CameraDevice.TEMPLATE_PREVIEW)
        }

        /** Rebuilds the capture session around [surfaces] and starts streaming. */
        private fun configure(
            surfaces: List<Surface>,
            template: Int
        ) {
            val camera = device ?: throw CameraError("capture_failed", "Camera $id is not open.")
            runCatching { session?.stopRepeating() }
            runCatching { session?.close() }

            val slot = ArrayBlockingQueue<Any>(1)
            val callback =
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(configured: CameraCaptureSession) {
                        slot.offer(configured)
                    }

                    override fun onConfigureFailed(failed: CameraCaptureSession) {
                        slot.offer(
                            CameraError(
                                "capture_failed",
                                "Camera $id cannot run this stream combination.",
                            ),
                        )
                    }
                }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                camera.createCaptureSession(
                    SessionConfiguration(
                        SessionConfiguration.SESSION_REGULAR,
                        surfaces.map { OutputConfiguration(it) },
                        callbackExecutor,
                        callback,
                    ),
                )
            } else {
                @Suppress("DEPRECATION")
                camera.createCaptureSession(surfaces, callback, cameraHandler)
            }
            session = await(slot, OPEN_TIMEOUT_MS, "configuring camera $id") as CameraCaptureSession

            val request =
                camera.createCaptureRequest(template).apply {
                    // Everything but the still reader streams continuously.
                    surfaces.filter { it != jpegReader.surface }.forEach { addTarget(it) }
                    set(CaptureRequest.CONTROL_AE_MODE, CameraMetadata.CONTROL_AE_MODE_ON)
                    set(
                        CaptureRequest.CONTROL_AF_MODE,
                        CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_PICTURE,
                    )
                }
            session!!.setRepeatingRequest(request.build(), null, cameraHandler)
        }

        /** Blocks until enough preview frames have gone by for exposure to settle. */
        fun awaitExposure() {
            val deadline = System.currentTimeMillis() + WARMUP_TIMEOUT_MS
            // The texture consumer drives frames; count capture callbacks instead.
            val request =
                device!!.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                    addTarget(previewSurface)
                    set(CaptureRequest.CONTROL_AE_MODE, CameraMetadata.CONTROL_AE_MODE_ON)
                }
            frames.set(0)
            session!!.setRepeatingRequest(
                request.build(),
                object : CameraCaptureSession.CaptureCallback() {
                    override fun onCaptureCompleted(
                        session: CameraCaptureSession,
                        request: CaptureRequest,
                        result: android.hardware.camera2.TotalCaptureResult
                    ) {
                        frames.incrementAndGet()
                    }
                },
                cameraHandler,
            )
            while (frames.get() < WARMUP_FRAMES && System.currentTimeMillis() < deadline) {
                Thread.sleep(10)
            }
        }

        fun fireStill() {
            val camera = device ?: throw CameraError("capture_failed", "Camera $id is not open.")
            jpegs.clear()
            val request =
                camera.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE).apply {
                    addTarget(jpegReader.surface)
                    set(CaptureRequest.CONTROL_AE_MODE, CameraMetadata.CONTROL_AE_MODE_ON)
                    set(CaptureRequest.JPEG_ORIENTATION, uprightRotation(id))
                }
            session!!.capture(request.build(), null, cameraHandler)
        }

        fun awaitJpeg(): ByteArray =
            jpegs.poll(CAPTURE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                ?: throw CameraError("capture_failed", "Timed out waiting for a photo from $camera.")

        /** Swaps the session over to preview + recorder. Throws if the device won't. */
        fun beginVideo(audio: Boolean) {
            val file = cacheFile(camera, "mp4")
            val prepared =
                newRecorder().apply {
                    if (audio) setAudioSource(MediaRecorder.AudioSource.CAMCORDER)
                    setVideoSource(MediaRecorder.VideoSource.SURFACE)
                    setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                    setOutputFile(file.absolutePath)
                    setVideoEncodingBitRate(VIDEO_BITRATE)
                    setVideoFrameRate(VIDEO_FPS)
                    setVideoSize(videoSize.width, videoSize.height)
                    setVideoEncoder(MediaRecorder.VideoEncoder.H264)
                    if (audio) setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                    setOrientationHint(uprightRotation(id))
                    prepare()
                }
            recorder = prepared
            recorderFile = file
            configure(listOf(previewSurface, prepared.surface), CameraDevice.TEMPLATE_RECORD)
        }

        fun startRecorder() {
            recorder?.start()
            recorderRunning = true
        }

        /** Stops and returns the clip path, then puts the session back in photo mode. */
        fun stopRecorder(): String? {
            val active = recorder ?: return null
            val file = recorderFile
            val stopped = runCatching { if (recorderRunning) active.stop() }
            recorderRunning = false
            runCatching { active.reset() }
            runCatching { active.release() }
            recorder = null
            recorderFile = null
            runCatching {
                configure(listOf(previewSurface, jpegReader.surface), CameraDevice.TEMPLATE_PREVIEW)
            }
            if (stopped.isFailure) {
                // MediaRecorder.stop() throws when no frames reached the encoder;
                // the file it left behind is unplayable, so don't hand it back.
                file?.delete()
                throw CameraError(
                    "capture_failed",
                    "Recording on $camera was too short to produce a clip.",
                )
            }
            return file?.absolutePath
        }

        /** Tears down a half-built video configuration without touching the clip. */
        fun abandonVideo() {
            recorderRunning = false
            runCatching { recorder?.reset() }
            runCatching { recorder?.release() }
            recorderFile?.delete()
            recorder = null
            recorderFile = null
            runCatching {
                configure(listOf(previewSurface, jpegReader.surface), CameraDevice.TEMPLATE_PREVIEW)
            }
        }

        fun close() {
            abandonVideo()
            runCatching { session?.stopRepeating() }
            runCatching { session?.close() }
            runCatching { device?.close() }
            runCatching { jpegReader.close() }
            runCatching { previewSurface.release() }
            session = null
            device = null
        }

        @Suppress("DEPRECATION")
        private fun newRecorder() =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(context)
            } else {
                MediaRecorder()
            }
    }

    private fun await(
        slot: ArrayBlockingQueue<Any>,
        timeoutMs: Long,
        what: String
    ): Any =
        when (val value = slot.poll(timeoutMs, TimeUnit.MILLISECONDS)) {
            null -> throw CameraError("capture_failed", "Timed out $what")
            is Throwable -> throw value
            else -> value
        }
}
