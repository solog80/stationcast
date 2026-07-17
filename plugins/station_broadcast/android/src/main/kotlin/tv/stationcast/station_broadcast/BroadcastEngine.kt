package tv.stationcast.station_broadcast

import android.Manifest
import android.content.Context
import android.content.Intent
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaFormat
import android.media.MediaRecorder
import android.os.Build
import android.util.Size
import androidx.annotation.RequiresPermission
import io.github.thibaultbee.srtdroid.core.models.Stats
import io.github.thibaultbee.streampack.core.elements.sources.video.camera.ICameraSource
import io.github.thibaultbee.streampack.core.interfaces.setCameraId
import io.github.thibaultbee.streampack.core.interfaces.startStream
import io.github.thibaultbee.streampack.core.streamers.single.AudioConfig
import io.github.thibaultbee.streampack.core.streamers.single.SingleStreamer
import io.github.thibaultbee.streampack.core.streamers.single.VideoConfig
import io.github.thibaultbee.streampack.core.streamers.single.cameraSingleStreamer
import io.github.thibaultbee.streampack.ext.srt.configuration.mediadescriptor.SrtMediaDescriptor
import java.io.File
import java.text.SimpleDateFormat
import java.util.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/** StreamPack-based broadcast engine: camera+mic capture, SRT publish. */
class BroadcastEngine(private val context: Context) {

    var streamer: SingleStreamer? = null
        private set

    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    var onEvent: ((String, String?) -> Unit)? = null
    var onStats: ((Map<String, Any?>) -> Unit)? = null
    var onHistogram: ((List<Int>) -> Unit)? = null

    private var statsJob: Job? = null
    private var watchJob: Job? = null
    private var histogramJob: Job? = null
    private var isStreamingRequested = false
    private var lastStats: Stats? = null
    private var audioProbe: AudioRecord? = null
    private var previewSurface: android.view.Surface? = null
    var previewSurfaceView: android.view.SurfaceView? = null
    private var orientationListener: android.view.OrientationEventListener? = null

    fun startHistogram() {
        if (histogramJob?.isActive == true) return
        histogramJob = scope.launch(Dispatchers.Main) {
            val buf = IntArray(256)
            while (isActive) {
                val sv = previewSurfaceView ?: run { delay(500); continue }
                val bitmap = try {
                    val b = android.graphics.Bitmap.createBitmap(128, 72, android.graphics.Bitmap.Config.ARGB_8888)
                    val lock = kotlinx.coroutines.CompletableDeferred<Boolean>()
                    android.view.PixelCopy.request(sv, b, { lock.complete(it == android.view.PixelCopy.SUCCESS) }, android.os.Handler(android.os.Looper.getMainLooper()))
                    if (lock.await()) b else null
                } catch (_: Exception) { null }
                if (bitmap != null) {
                    val w = bitmap.width; val h = bitmap.height
                    val pixels = IntArray(w * h)
                    bitmap.getPixels(pixels, 0, w, 0, 0, w, h)
                    buf.fill(0)
                    for (p in pixels) {
                        val r = (p shr 16) and 0xFF
                        val g = (p shr 8) and 0xFF
                        val b = p and 0xFF
                        val luma = (0.299 * r + 0.587 * g + 0.114 * b).toInt().coerceIn(0, 255)
                        buf[luma]++
                    }
                    val max = buf.maxOrNull() ?: 1
                    val normalized = buf.map { (it * 100 / max.coerceAtLeast(1)) }
                    onHistogram?.invoke(normalized)
                    bitmap.recycle()
                }
                delay(66)
            }
        }
    }

    fun stopHistogram() {
        histogramJob?.cancel()
        histogramJob = null
    }

    @RequiresPermission(allOf = [Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO])
    suspend fun initialize(args: Map<*, *>) {
        val current = streamer ?: cameraSingleStreamer(context).also { streamer = it }
        val width = (args["width"] as Number? ?: 1280).toInt()
        val height = (args["height"] as Number? ?: 720).toInt()
        val fps = (args["fps"] as Number? ?: 30).toInt()
        val videoBitrate = (args["videoBitrateBps"] as Number? ?: 3_000_000).toInt()
        val audioBitrate = (args["audioBitrateBps"] as Number? ?: 128_000).toInt()
        val mimeType = when (args["codec"] as String?) {
            "hevc" -> MediaFormat.MIMETYPE_VIDEO_HEVC
            else -> MediaFormat.MIMETYPE_VIDEO_AVC
        }

        val deviceOrientation = context.resources.configuration.orientation
        val orientationLabel = if (deviceOrientation == android.content.res.Configuration.ORIENTATION_PORTRAIT) "PORTRAIT" else "LANDSCAPE"
        android.util.Log.d("[BroadcastEngine]", "initialize: device orientation=$orientationLabel")
        android.util.Log.d("[BroadcastEngine]", "initialize: raw args width=${args["width"]}, height=${args["height"]}")
        android.util.Log.d("[BroadcastEngine]", "initialize: parsed width=$width, height=$height")

        // Store base parameters for orientation changes
        // (Orientation listener infrastructure retained for future use)
        // baseWidth = width
        // baseHeight = height
        // baseFps = fps
        // baseVideoBitrate = videoBitrate
        // baseAudioBitrate = audioBitrate
        // baseMimeType = mimeType

        // Always use landscape resolution for stream (16:9)
        // Always pass landscape dimensions regardless of device orientation
        val streamWidth = kotlin.math.max(width, height)
        val streamHeight = kotlin.math.min(width, height)

        android.util.Log.d("[BroadcastEngine]", "initialize: input=${width}x${height}, always using landscape=${streamWidth}x${streamHeight}")
        android.util.Log.d("[BroadcastEngine]", "setConfig: device=$orientationLabel, sending resolution=${streamWidth}x${streamHeight}")

        // Store base parameters for orientation changes
        baseWidth = streamWidth
        baseHeight = streamHeight
        baseBitrate = videoBitrate
        baseFps = fps
        baseMimeType = mimeType

        current.setConfig(
            AudioConfig(startBitrate = audioBitrate),
            VideoConfig(mimeType = mimeType, startBitrate = videoBitrate, resolution = Size(streamWidth, streamHeight), fps = fps)
        )

        val actualVideoConfig = current.videoConfigFlow.value
        android.util.Log.d("[BroadcastEngine]", "Streamer config SET to ${streamWidth}x${streamHeight}, ACTUAL=${actualVideoConfig?.resolution}")

        // Set rotation based on device orientation at init time
        // NOTE: Can't change resolution while streaming, so this rotation is locked for the stream duration
        val initialRotation = if (deviceOrientation == android.content.res.Configuration.ORIENTATION_PORTRAIT) {
            android.view.Surface.ROTATION_90  // Portrait device → ROTATION_90 for upright portrait stream
        } else {
            android.view.Surface.ROTATION_0   // Landscape device → no rotation, landscape stream
        }
        current.setTargetRotation(initialRotation)
        android.util.Log.d("[BroadcastEngine]", "Initial target rotation=$initialRotation (based on device ORIENTATION_${if (deviceOrientation == android.content.res.Configuration.ORIENTATION_PORTRAIT) "PORTRAIT" else "LANDSCAPE"}, locked for stream duration)")
    }

    private var baseWidth = 0
    private var baseHeight = 0
    private var baseBitrate = 0
    private var baseFps = 0
    private var baseMimeType = ""

    private fun startOrientationListener() {
        orientationListener?.disable()
        orientationListener = object : android.view.OrientationEventListener(context) {
            override fun onOrientationChanged(orientation: Int) {
                val current = streamer ?: return
                if (baseWidth == 0 || baseHeight == 0) return

                val isPortrait = orientation < 45 || orientation >= 315
                val (outputWidth, outputHeight) = if (isPortrait) {
                    // Portrait: swap to portrait resolution
                    Pair(baseHeight, baseWidth)
                } else {
                    // Landscape: keep original (landscape) resolution
                    Pair(baseWidth, baseHeight)
                }

                scope.launch {
                    try {
                        val beforeConfig = current.videoConfigFlow.value
                        android.util.Log.d("[BroadcastEngine]", "Before orientation update: ${beforeConfig?.resolution}")

                        val newConfig = VideoConfig(
                            mimeType = baseMimeType,
                            startBitrate = baseBitrate,
                            resolution = android.util.Size(outputWidth, outputHeight),
                            fps = baseFps
                        )
                        android.util.Log.d("[BroadcastEngine]", "Calling setVideoConfig(${outputWidth}x${outputHeight})")
                        current.setVideoConfig(newConfig)

                        val afterConfig = current.videoConfigFlow.value
                        android.util.Log.d("[BroadcastEngine]", "After setVideoConfig: ${afterConfig?.resolution}")
                        android.util.Log.d("[BroadcastEngine]", "Orientation $orientation° -> requested ${outputWidth}x${outputHeight}, encoder now at ${afterConfig?.resolution}")
                    } catch (e: Exception) {
                        android.util.Log.e("[BroadcastEngine]", "ERROR updating config: ${e.javaClass.simpleName}: ${e.message}")
                        e.printStackTrace()
                    }
                }
            }
        }.apply { enable() }
    }

    private fun updateVideoConfig() {
        // Stream always uses landscape (streamWidth x streamHeight)
    }

    suspend fun startStream(args: Map<*, *>) {
        val current = requireNotNull(streamer) { "Engine not initialized" }
        emit("connecting", null)

        isStreamingRequested = true
        try {
            when (args["protocol"] as String?) {
                "rtmp" -> {
                    val url = requireNotNull(args["rtmpUrl"] as String?) { "rtmpUrl required" }
                    val key = args["streamKey"] as String? ?: ""
                    current.startStream(if (key.isEmpty()) url else "$url/$key")
                }
                else -> {
                    val descriptor = SrtMediaDescriptor(
                        host = requireNotNull(args["host"] as String?) { "host required" },
                        port = (args["port"] as Number? ?: 9000).toInt(),
                        streamId = (args["streamId"] as String?)?.ifEmpty { null },
                        passPhrase = (args["passphrase"] as String?)?.ifEmpty { null },
                        latency = (args["latencyMs"] as Number?)?.toInt()
                    )
                    current.startStream(descriptor)
                }
            }
            startForegroundService()
            startStatsPolling(current)
            startConnectionWatch(current)
            emit("live", null)
        } catch (t: Throwable) {
            isStreamingRequested = false
            emit("failed", t.message ?: t.toString())
            throw t
        }
    }

    suspend fun stopStream() {
        isStreamingRequested = false
        statsJob?.cancel()
        watchJob?.cancel()
        orientationListener?.disable()
        stopForegroundService()
        streamer?.let {
            runCatching { it.stopStream() }
            runCatching { it.close() }
        }
        emit("stopped", null)
    }

    @RequiresPermission(Manifest.permission.CAMERA)
    suspend fun switchCamera() {
        val current = requireNotNull(streamer) { "Engine not initialized" }
        val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val activeId = (current.videoInput?.sourceFlow?.value as? ICameraSource)?.cameraId
        val activeFacing = activeId?.let {
            cameraManager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING)
        } ?: CameraCharacteristics.LENS_FACING_BACK
        val targetFacing = if (activeFacing == CameraCharacteristics.LENS_FACING_BACK) {
            CameraCharacteristics.LENS_FACING_FRONT
        } else {
            CameraCharacteristics.LENS_FACING_BACK
        }
        val targetId = cameraManager.cameraIdList.firstOrNull {
            cameraManager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == targetFacing
        } ?: return
        current.setCameraId(targetId)
        // Re-apply preview surface to the new camera source
        previewSurface?.let { surface ->
                delay(100) // brief pause for camera switch to settle
            val src = cameraSource()
            if (src != null) {
                src.setPreview(surface)
                src.startPreview()
            }
        }
    }

    suspend fun setTorch(enabled: Boolean) {
        cameraSource()?.settings?.flash?.setIsEnable(enabled)
    }

    suspend fun setZoom(ratio: Float) {
        cameraSource()?.settings?.zoom?.setZoomRatio(ratio)
    }

    fun getMaxZoom(): Float {
        return try {
            val id = cameraSource()?.cameraId ?: return 1f
            val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            val characteristics = cameraManager.getCameraCharacteristics(id)
            characteristics.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1f
        } catch (_: Throwable) { 1f }
    }

    fun setMuted(muted: Boolean) {
        streamer?.audioInput?.isMuted = muted
    }

    suspend fun setVideoBitrate(bps: Int) {
        val current = streamer ?: return
        val videoConfig = current.videoConfigFlow.value ?: return
        current.setVideoConfig(videoConfig.copy(startBitrate = bps))
    }

    /** Full Camera2 API via StreamPack's ICameraSource.settings */
    suspend fun pausePreview() {}
    suspend fun resumePreview() {}
    suspend fun takeSnapshot(): ByteArray? = null
    suspend fun camera2SetZoom(ratio: Float) = setZoom(ratio)
    suspend fun camera2SetFocusMode(mode: String) {
        val cam = cameraSource()?.settings?.focus ?: return
        val value = when (mode) {
            "auto" -> android.hardware.camera2.CaptureRequest.CONTROL_AF_MODE_AUTO
            "continuous" -> android.hardware.camera2.CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO
            "continuous_video" -> android.hardware.camera2.CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO
            "continuous_picture" -> android.hardware.camera2.CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE
            "macro" -> android.hardware.camera2.CaptureRequest.CONTROL_AF_MODE_MACRO
            "edof" -> android.hardware.camera2.CaptureRequest.CONTROL_AF_MODE_EDOF
            else -> android.hardware.camera2.CaptureRequest.CONTROL_AF_MODE_OFF // manual, infinity
        }
        if (value in cam.availableAutoModes) cam.setAutoMode(value)
    }
    suspend fun camera2SetExposureCompensation(ev: Int) {
        val cam = cameraSource()?.settings?.exposure ?: return
        cam.setCompensation(ev)
    }
    suspend fun camera2SetWhiteBalance(mode: String) {
        val cam = cameraSource()?.settings?.whiteBalance ?: return
        val value = when (mode) {
            "auto" -> android.hardware.camera2.CaptureRequest.CONTROL_AWB_MODE_AUTO
            "incandescent" -> android.hardware.camera2.CaptureRequest.CONTROL_AWB_MODE_INCANDESCENT
            "fluorescent" -> android.hardware.camera2.CaptureRequest.CONTROL_AWB_MODE_FLUORESCENT
            "daylight" -> android.hardware.camera2.CaptureRequest.CONTROL_AWB_MODE_DAYLIGHT
            "cloudy" -> android.hardware.camera2.CaptureRequest.CONTROL_AWB_MODE_CLOUDY_DAYLIGHT
            "twilight" -> android.hardware.camera2.CaptureRequest.CONTROL_AWB_MODE_TWILIGHT
            "shade" -> android.hardware.camera2.CaptureRequest.CONTROL_AWB_MODE_SHADE
            else -> android.hardware.camera2.CaptureRequest.CONTROL_AWB_MODE_OFF
        }
        if (value in cam.availableAutoModes) cam.setAutoMode(value)
    }
    suspend fun camera2SetIsoSensitivity(iso: Int) {
        val cam = cameraSource()?.settings?.iso ?: return
        cam.setSensorSensitivity(iso)
    }
    suspend fun camera2SetVideoStabilization(enabled: Boolean) {
        val cam = cameraSource()?.settings?.stabilization ?: return
        cam.setIsEnableVideo(enabled)
    }
    suspend fun camera2SetFlashMode(mode: String) {
        val cam = cameraSource()?.settings?.flash ?: return
        cam.setIsEnable(mode == "torch")
    }
    fun camera2GetCapabilities(): Map<String, Any> {
        val src = cameraSource() ?: return emptyMap()
        val chars = src.settings.characteristics
        val expRange = chars.get(android.hardware.camera2.CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE)
        val maxZoom = chars.get(android.hardware.camera2.CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1f
        return mapOf(
            "maxZoom" to maxZoom,
            "minZoom" to 1f,
            "exposureCompensationRange" to mapOf(
                "min" to (expRange?.lower ?: -4),
                "max" to (expRange?.upper ?: 4)
            ),
            "hasFlash" to src.settings.flash.isAvailable,
        )
    }

    suspend fun camera2InitializeManager() = Unit
    fun setMirrorFrontCamera(enabled: Boolean) = Unit
    fun setPreviewSurface(surface: android.view.Surface?) {
        previewSurface = surface
        if (surface != null) {
            val src = cameraSource()
            if (src != null) {
                scope.launch {
                    src.setPreview(surface)
                    src.startPreview()
                }
            }
        }
    }
    suspend fun camera2SetFocusDistance(distance: Float) {
        val cam = cameraSource()?.settings?.focus ?: return
        cam.setLensDistance(distance)
    }

    /** Tap-to-focus: normalized coords 0..1 */
    suspend fun camera2SetFocusPoint(x: Float, y: Float) {
        val source = cameraSource() ?: return
        val rect = android.hardware.camera2.params.MeteringRectangle(
            (x * 2000 - 1000).toInt(),
            (y * 2000 - 1000).toInt(),
            200, 200, 1
        )
        source.settings.focus.setAutoMode(android.hardware.camera2.CaptureRequest.CONTROL_AF_MODE_AUTO)
        source.settings.focus.setMeteringRegions(listOf(rect))
        source.settings.exposure.setMeteringRegions(listOf(rect))
        source.settings.applyRepeatingSession()
    }

    suspend fun dispose() {
        orientationListener?.disable()
        orientationListener = null
        isStreamingRequested = false
        statsJob?.cancel()
        watchJob?.cancel()
        stopForegroundService()
        streamer?.let {
            runCatching { it.stopStream() }
            runCatching { it.close() }
            runCatching { it.release() }
        }
        streamer = null
    }

    private fun cameraSource(): ICameraSource? =
        streamer?.videoInput?.sourceFlow?.value as? ICameraSource

    fun getCameraResolution(): Map<String, Double> {
        try {
            val cameraManager = context.getSystemService(android.content.Context.CAMERA_SERVICE) as android.hardware.camera2.CameraManager
            val cameraIds = cameraManager.cameraIdList
            if (cameraIds.isEmpty()) {
                android.util.Log.d("[getCameraResolution]", "No cameras found")
                return emptyMap()
            }

            val cameraId = cameraIds[0]
            val characteristics = cameraManager.getCameraCharacteristics(cameraId)
            val streamConfigMap = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) ?: return emptyMap()
            val outputSizes = streamConfigMap.getOutputSizes(android.view.SurfaceView::class.java)
                ?: streamConfigMap.getOutputSizes(android.graphics.SurfaceTexture::class.java)
                ?: return emptyMap()

            if (outputSizes.isEmpty()) return emptyMap()

            // Try to find best 16:9 resolution (target: 1920x1080 for streaming)
            val size16_9 = outputSizes.filter { size ->
                val ar = size.width.toDouble() / size.height.toDouble()
                ar > 1.76 && ar < 1.80 // 16:9 ≈ 1.777
            }.maxByOrNull { it.width * it.height }

            val selectedSize = size16_9 ?: outputSizes.maxByOrNull { it.width * it.height }!!
            val aspectRatio = selectedSize.width.toDouble() / selectedSize.height.toDouble()

            android.util.Log.d("[getCameraResolution]", "Selected: ${selectedSize.width}x${selectedSize.height}, AR: $aspectRatio, is16_9: ${size16_9 != null}")
            return mapOf(
                "width" to selectedSize.width.toDouble(),
                "height" to selectedSize.height.toDouble(),
                "aspectRatio" to aspectRatio
            )
        } catch (e: Exception) {
            android.util.Log.e("[getCameraResolution]", "Exception: ${e.message}", e)
            return emptyMap()
        }
    }

    private fun readAudioLevelDb(): List<Double>? {
        val probe = audioProbe ?: return null
        if (probe.state != AudioRecord.STATE_INITIALIZED) return null
        return try {
            val buf = ShortArray(512)
            val read = probe.read(buf, 0, buf.size)
            if (read > 0) {
                var sum = 0.0
                for (i in 0 until read) { val s = buf[i].toDouble(); sum += s * s }
                val rms = kotlin.math.sqrt(sum / read)
                val norm = (rms / 32768.0).coerceIn(0.0, 1.0)
                if (norm > 0.015) {
                    val dbfs = (20 * kotlin.math.log10(norm)).coerceIn(-60.0, 0.0)
                    listOf(dbfs, dbfs)
                } else null
            } else null
        } catch (_: Exception) { null }
    }

    private fun initAudioProbe() {
        try {
            val sr = 44100
            val bs = AudioRecord.getMinBufferSize(sr, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            if (bs <= 0) return
            @Suppress("DEPRECATION")
            val r = AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, sr,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, bs.coerceAtLeast(4096))
            if (r.state == AudioRecord.STATE_INITIALIZED) { r.startRecording(); audioProbe = r }
        } catch (_: Exception) {}
    }

    private fun startStatsPolling(current: SingleStreamer) {
        initAudioProbe()
        statsJob?.cancel()
        statsJob = scope.launch {
            while (isActive) {
                val stats = runCatching { current.endpoint.metrics as? Stats }.getOrNull()
                if (stats != null) {
                    lastStats = stats
                    onStats?.invoke(mapOf(
                        "bitrateBps" to (stats.mbpsSendRate * 1_000_000).toLong(),
                        "rttMs" to stats.msRTT,
                        "packetsSent" to stats.pktSentTotal,
                        "packetsDropped" to stats.pktSndDropTotal,
                        "packetsRetransmitted" to stats.pktRetransTotal,
                        "bandwidthMbps" to stats.mbpsBandwidth,
                    ))
                }
                delay(1000)
            }
        }
        // Fast audio level loop (~50ms for smooth VU meter)
        scope.launch {
            while (isActive) {
                val audioLevelDb = readAudioLevelDb()
                if (audioLevelDb != null) {
                    onStats?.invoke(mapOf("audioLevelDb" to audioLevelDb))
                }
                delay(50)
            }
        }
    }

    private fun startConnectionWatch(current: SingleStreamer) {
        watchJob?.cancel()
        watchJob = scope.launch {
            current.endpoint.isOpenFlow.collect { open ->
                if (!open && isStreamingRequested) {
                    isStreamingRequested = false
                    statsJob?.cancel()
                    stopForegroundService()
                    emit("failed", "Connection lost")
                }
            }
        }
    }

    private fun startForegroundService() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(Intent(context, StreamingForegroundService::class.java))
        } else {
            context.startService(Intent(context, StreamingForegroundService::class.java))
        }
    }

    private fun stopForegroundService() {
        context.stopService(Intent(context, StreamingForegroundService::class.java))
    }

    private fun emit(state: String, message: String?) {
        onEvent?.invoke(state, message)
    }
}
