package tv.stationcast.station_broadcast

import android.Manifest
import android.content.Context
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.TotalCaptureResult
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.HandlerThread
import android.view.Surface
import androidx.annotation.RequiresPermission
import io.github.thibaultbee.srtdroid.core.enums.Boundary
import io.github.thibaultbee.srtdroid.core.enums.SockOpt
import io.github.thibaultbee.srtdroid.core.enums.Transtype
import io.github.thibaultbee.srtdroid.core.models.MsgCtrl
import io.github.thibaultbee.srtdroid.ktx.CoroutineSrtSocket
import io.github.thibaultbee.srtdroid.ktx.connect
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.nio.ByteBuffer

class BroadcastEngineNew(private val context: Context) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    var onEvent: ((String, String?) -> Unit)? = null
    var onStats: ((Map<String, Any?>) -> Unit)? = null

    private var cameraDevice: CameraDevice? = null
    private var cameraSession: CameraCaptureSession? = null
    private var mediaCodec: MediaCodec? = null
    private var encoderSurface: Surface? = null
    private var previewSurface: Surface? = null
    private var tsMuxer: TsMuxer? = null
    private var srtSocket: CoroutineSrtSocket? = null
    private var cameraThread: HandlerThread? = null
    private var statsJob: Job? = null
    private var isStreaming = false
    private var bytesSent = 0L

    private val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    private var currentLensFacing = CameraCharacteristics.LENS_FACING_BACK

    @RequiresPermission(Manifest.permission.CAMERA)
    suspend fun initialize(args: Map<*, *>) {
        val width = (args["width"] as Number? ?: 1280).toInt()
        val height = (args["height"] as Number? ?: 720).toInt()
        val fps = (args["fps"] as Number? ?: 25).toInt()
        val bitrate = (args["videoBitrateBps"] as Number? ?: 3_000_000).toInt()
        val codecType = when (args["codec"] as String?) {
            "hevc" -> MediaFormat.MIMETYPE_VIDEO_HEVC
            else -> MediaFormat.MIMETYPE_VIDEO_AVC
        }

        // Create encoder with surface input
        val format = MediaFormat.createVideoFormat(codecType, width, height).apply {
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
            try { setInteger("max-bitrate", bitrate) } catch (_: Exception) {}
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
        }
        mediaCodec = MediaCodec.createEncoderByType(codecType).apply {
            configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            encoderSurface = createInputSurface()
            start()
        }

        // Start encoder output loop
        startEncoderThread()

        emit("initialized", null)
    }

    fun setPreviewSurface(surface: Surface?) {
        previewSurface = surface
    }

    @RequiresPermission(Manifest.permission.CAMERA)
    suspend fun startStream(args: Map<*, *>) {
        isStreaming = true
        val host = args["host"] as? String ?: return
        val port = (args["port"] as Number? ?: 9000).toInt()
        connectSrt(host, port, args)

        // Open camera and start session
        cameraThread = HandlerThread("camera").apply { start() }
        openCamera()
        emit("live", null)
    }

    @RequiresPermission(Manifest.permission.CAMERA)
    private suspend fun openCamera() = withContext(Dispatchers.IO) {
        val cameraId = findCameraId(currentLensFacing)
        val handler = cameraThread?.let { android.os.Handler(it.looper) }
        cameraManager.openCamera(cameraId, object : CameraDevice.StateCallback() {
            override fun onOpened(camera: CameraDevice) {
                cameraDevice = camera
                createCaptureSession(camera)
            }
            override fun onDisconnected(camera: CameraDevice) { camera.close() }
            override fun onError(camera: CameraDevice, error: Int) { camera.close() }
        }, handler)
    }

    private fun createCaptureSession(camera: CameraDevice) {
        val surfaces = mutableListOf<Surface>()
        encoderSurface?.let { surfaces.add(it) }
        previewSurface?.let { surfaces.add(it) }
        if (surfaces.isEmpty()) return

        val handler = cameraThread?.let { android.os.Handler(it.looper) }
        camera.createCaptureSession(surfaces, object : CameraCaptureSession.StateCallback() {
            override fun onConfigured(session: CameraCaptureSession) {
                cameraSession = session
                val request = session.device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                    encoderSurface?.let { addTarget(it) }
                    previewSurface?.let { addTarget(it) }
                    set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                    set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, android.util.Range(15, 30))
                }
                session.setRepeatingRequest(request.build(), null, handler)
            }
            override fun onConfigureFailed(session: CameraCaptureSession) {}
        }, handler)
    }

    private fun findCameraId(lensFacing: Int): String {
        for (id in cameraManager.cameraIdList) {
            val chars = cameraManager.getCameraCharacteristics(id)
            if (chars.get(CameraCharacteristics.LENS_FACING) == lensFacing) return id
        }
        return cameraManager.cameraIdList[0]
    }

    private fun startEncoderThread() {
        val codec = mediaCodec ?: return
        Thread {
            val info = MediaCodec.BufferInfo()
            while (true) {
                try {
                    val id = codec.dequeueOutputBuffer(info, 10000)
                    when (id) {
                        MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            tsMuxer?.stop()
                            tsMuxer = TsMuxer { ts -> sendTs(ts) }.apply { start(codec.outputFormat) }
                        }
                        MediaCodec.INFO_TRY_AGAIN_LATER -> {}
                        else -> if (id >= 0) {
                            val data = ByteArray(info.size)
                            codec.getOutputBuffer(id)?.get(data)
                            codec.releaseOutputBuffer(id, false)
                            if (tsMuxer != null) {
                                val isKey = (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
                                tsMuxer?.write(data, info.presentationTimeUs, isKey)
                            }
                        }
                    }
                } catch (_: Exception) { break }
            }
        }.apply { isDaemon = true }.start()
    }

    private suspend fun connectSrt(host: String, port: Int, args: Map<*, *>) = withContext(Dispatchers.IO) {
        try {
            val srtUrl = (args["srtUrl"] as String?) ?: ""
            val fullUrl = if (srtUrl.startsWith("srt://")) srtUrl
            else {
                val sid = args["streamId"] as String? ?: ""
                val pass = args["passphrase"] as String? ?: ""
                val lat = (args["latencyMs"] as Number?)?.toInt() ?: 200
                val p = mutableListOf("latency=${lat * 1000}")
                if (sid.isNotEmpty()) p.add("streamid=$sid")
                if (pass.isNotEmpty()) p.add("passphrase=$pass")
                "srt://$host:$port?${p.joinToString("&")}"
            }
            CoroutineSrtSocket().apply {
                setSockFlag(SockOpt.PAYLOADSIZE, 1316)
                setSockFlag(SockOpt.TRANSTYPE, Transtype.LIVE)
                connect(fullUrl)
                setSockFlag(SockOpt.MAXBW, 0L)
                setSockFlag(SockOpt.INPUTBW, (args["videoBitrateBps"] as Number? ?: 3_000_000).toLong())
                srtSocket = this
            }
        } catch (e: Exception) {
            throw e
        }
    }

    private fun sendTs(data: ByteArray) {
        if (!isStreaming) return
        scope.launch {
            try {
                srtSocket?.send(data, 0, data.size, MsgCtrl(0, 0, false, Boundary.SOLO, 0, -1, -1))
                bytesSent += data.size
            } catch (_: Exception) {}
        }
    }

    suspend fun switchCamera() {
        cameraDevice?.close()
        currentLensFacing = if (currentLensFacing == CameraCharacteristics.LENS_FACING_BACK)
            CameraCharacteristics.LENS_FACING_FRONT else CameraCharacteristics.LENS_FACING_BACK
        openCamera()
    }
    suspend fun setTorch(enabled: Boolean) = Unit
    suspend fun setZoom(ratio: Float) = Unit
    fun getMaxZoom(): Float = 1f
    fun setMuted(muted: Boolean) = Unit
    suspend fun setVideoBitrate(bps: Int) = Unit
    suspend fun dispose() {
        isStreaming = false
        try { cameraSession?.close() } catch (_: Exception) {}
        try { cameraDevice?.close() } catch (_: Exception) {}
        try { mediaCodec?.stop() } catch (_: Exception) {}
        try { mediaCodec?.release() } catch (_: Exception) {}
        try { srtSocket?.close() } catch (_: Exception) {}
        try { cameraThread?.quitSafely() } catch (_: Exception) {}
    }

    // Camera2 compat methods
    suspend fun camera2SetZoom(ratio: Float) = Unit
    suspend fun camera2SetFocusMode(mode: String) = Unit
    suspend fun camera2SetExposureCompensation(ev: Int) = Unit
    suspend fun camera2SetWhiteBalance(mode: String) = Unit
    suspend fun camera2SetIsoSensitivity(iso: Int) = Unit
    suspend fun camera2SetVideoStabilization(enabled: Boolean) = Unit
    suspend fun camera2SetFlashMode(mode: String) = Unit
    fun camera2GetCapabilities(): Map<String, Any?> = emptyMap()
    suspend fun camera2InitializeManager() = Unit
    suspend fun pausePreview() = Unit
    suspend fun resumePreview() = Unit
    suspend fun takeSnapshot(): ByteArray? = null
    suspend fun setMirrorFrontCamera(enabled: Boolean) = Unit
    suspend fun camera2SetFocusDistance(distance: Float) = Unit
    suspend fun stopStream() { isStreaming = false; tsMuxer?.stop(); try { srtSocket?.close() } catch (_: Exception) {}; srtSocket = null; emit("stopped", null) }
    private fun emit(state: String, message: String?) { onEvent?.invoke(state, message) }
}
