package tv.stationcast.station_broadcast

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.SurfaceTexture
import android.hardware.camera2.*
import android.os.Handler
import android.os.HandlerThread
import android.util.Size
import android.view.Surface
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Direct Camera2 management for full control over camera capabilities.
 * Replaces StreamPack's built-in camera to expose zoom, focus, exposure, white balance, etc.
 * Provides both preview (SurfaceTexture) and encoding (Surface) outputs.
 */
@SuppressLint("MissingPermission")
class Camera2Manager(private val context: Context) {
    private val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var previewSurface: Surface? = null
    private var encodingSurface: Surface? = null
    private var currentCameraId: String? = null
    private var currentPosition = CameraCharacteristics.LENS_FACING_BACK

    private val cameraThread = HandlerThread("Camera2").apply { start() }
    private val cameraHandler = Handler(cameraThread.looper)

    var onCameraOpened: (() -> Unit)? = null
    var onCameraError: ((String) -> Unit)? = null

    /**
     * Initialize Camera2Manager with surfaces for preview and encoding.
     * @param previewSurface Surface for preview display (SurfaceTexture)
     * @param encodingSurface Surface for video encoding (from MediaCodec)
     */
    suspend fun initialize(
        previewSurface: Surface? = null,
        encodingSurface: Surface,
        position: Int = CameraCharacteristics.LENS_FACING_BACK
    ) {
        this.previewSurface = previewSurface
        this.encodingSurface = encodingSurface
        currentPosition = position
        openCamera()
    }

    private suspend fun openCamera() = suspendCancellableCoroutine { continuation ->
        val cameraId = findCameraWithPosition(currentPosition) ?: run {
            continuation.resumeWithException(Exception("No camera found for position $currentPosition"))
            return@suspendCancellableCoroutine
        }
        currentCameraId = cameraId

        cameraManager.openCamera(cameraId, object : CameraDevice.StateCallback() {
            override fun onOpened(device: CameraDevice) {
                cameraDevice = device
                createCaptureSession()
                continuation.resume(Unit)
                onCameraOpened?.invoke()
            }

            override fun onDisconnected(device: CameraDevice) {
                device.close()
                cameraDevice = null
            }

            override fun onError(device: CameraDevice, error: Int) {
                device.close()
                cameraDevice = null
                val msg = "Camera error: $error"
                continuation.resumeWithException(Exception(msg))
                onCameraError?.invoke(msg)
            }
        }, cameraHandler)
    }

    private fun createCaptureSession() {
        val device = cameraDevice ?: return
        val encoding = encodingSurface ?: return

        try {
            // Build list of surfaces: encoding is required, preview is optional
            val surfaces = mutableListOf(encoding)
            if (previewSurface != null) {
                surfaces.add(previewSurface!!)
            }

            device.createCaptureSession(
                surfaces,
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        captureSession = session
                        startCapture()
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        onCameraError?.invoke("Failed to configure capture session")
                    }
                },
                cameraHandler
            )
        } catch (e: CameraAccessException) {
            onCameraError?.invoke("Camera access exception: ${e.message}")
        }
    }

    private fun startCapture() {
        val device = cameraDevice ?: return
        val session = captureSession ?: return
        val encoding = encodingSurface ?: return

        try {
            val captureRequestBuilder = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
            captureRequestBuilder.addTarget(encoding)
            if (previewSurface != null) {
                captureRequestBuilder.addTarget(previewSurface!!)
            }
            captureRequestBuilder.set(
                CaptureRequest.CONTROL_AF_MODE,
                CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_VIDEO
            )
            session.setRepeatingRequest(captureRequestBuilder.build(), null, cameraHandler)
        } catch (e: CameraAccessException) {
            onCameraError?.invoke("Failed to start capture: ${e.message}")
        }
    }

    private fun buildCaptureRequest(device: CameraDevice): CaptureRequest.Builder {
        val builder = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
        builder.addTarget(encodingSurface!!)
        if (previewSurface != null) {
            builder.addTarget(previewSurface!!)
        }
        return builder
    }

    suspend fun setZoom(ratio: Float) {
        val device = cameraDevice ?: return
        val session = captureSession ?: return
        val characteristics = cameraManager.getCameraCharacteristics(currentCameraId ?: return)
        val maxZoom = characteristics.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1f
        val clamped = ratio.coerceIn(1f, maxZoom)

        try {
            val cropRegion = characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE) ?: return
            val zoomRatio = 1f / clamped
            val centerX = cropRegion.centerX()
            val centerY = cropRegion.centerY()
            val halfWidth = (cropRegion.width() * zoomRatio / 2).toInt()
            val halfHeight = (cropRegion.height() * zoomRatio / 2).toInt()

            val newCrop = android.graphics.Rect(
                centerX - halfWidth,
                centerY - halfHeight,
                centerX + halfWidth,
                centerY + halfHeight
            )

            val builder = buildCaptureRequest(device)
            builder.set(CaptureRequest.SCALER_CROP_REGION, newCrop)
            session.setRepeatingRequest(builder.build(), null, cameraHandler)
        } catch (e: Exception) {
            onCameraError?.invoke("Failed to set zoom: ${e.message}")
        }
    }

    suspend fun setFocusMode(mode: String) {
        val device = cameraDevice ?: return
        val session = captureSession ?: return

        try {
            val builder = buildCaptureRequest(device)

            val afMode = when (mode) {
                "auto" -> CameraMetadata.CONTROL_AF_MODE_AUTO
                "continuous" -> CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_VIDEO
                "manual" -> CameraMetadata.CONTROL_AF_MODE_OFF
                "macro" -> CameraMetadata.CONTROL_AF_MODE_MACRO
                else -> CameraMetadata.CONTROL_AF_MODE_AUTO
            }

            builder.set(CaptureRequest.CONTROL_AF_MODE, afMode)
            session.setRepeatingRequest(builder.build(), null, cameraHandler)
        } catch (e: Exception) {
            onCameraError?.invoke("Failed to set focus mode: ${e.message}")
        }
    }

    suspend fun setExposureCompensation(ev: Int) {
        val device = cameraDevice ?: return
        val session = captureSession ?: return
        val characteristics = cameraManager.getCameraCharacteristics(currentCameraId ?: return)

        val range = characteristics.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE) ?: return
        val clamped = ev.coerceIn(range.lower, range.upper)

        try {
            val builder = buildCaptureRequest(device)
            builder.set(CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION, clamped)
            session.setRepeatingRequest(builder.build(), null, cameraHandler)
        } catch (e: Exception) {
            onCameraError?.invoke("Failed to set exposure compensation: ${e.message}")
        }
    }

    suspend fun setWhiteBalance(mode: String) {
        val device = cameraDevice ?: return
        val session = captureSession ?: return

        try {
            val builder = buildCaptureRequest(device)

            val awbMode = when (mode) {
                "auto" -> CameraMetadata.CONTROL_AWB_MODE_AUTO
                "incandescent" -> CameraMetadata.CONTROL_AWB_MODE_INCANDESCENT
                "fluorescent" -> CameraMetadata.CONTROL_AWB_MODE_FLUORESCENT
                "warmFluorescent" -> CameraMetadata.CONTROL_AWB_MODE_WARM_FLUORESCENT
                "daylight" -> CameraMetadata.CONTROL_AWB_MODE_DAYLIGHT
                "cloudyDaylight" -> CameraMetadata.CONTROL_AWB_MODE_CLOUDY_DAYLIGHT
                "twilight" -> CameraMetadata.CONTROL_AWB_MODE_TWILIGHT
                "shade" -> CameraMetadata.CONTROL_AWB_MODE_SHADE
                else -> CameraMetadata.CONTROL_AWB_MODE_AUTO
            }

            builder.set(CaptureRequest.CONTROL_AWB_MODE, awbMode)
            session.setRepeatingRequest(builder.build(), null, cameraHandler)
        } catch (e: Exception) {
            onCameraError?.invoke("Failed to set white balance: ${e.message}")
        }
    }

    suspend fun setIsoSensitivity(iso: Int) {
        val device = cameraDevice ?: return
        val session = captureSession ?: return
        val characteristics = cameraManager.getCameraCharacteristics(currentCameraId ?: return)

        val range = characteristics.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE) ?: return
        val clamped = iso.coerceIn(range.lower, range.upper)

        try {
            val builder = buildCaptureRequest(device)
            builder.set(CaptureRequest.SENSOR_SENSITIVITY, clamped)
            session.setRepeatingRequest(builder.build(), null, cameraHandler)
        } catch (e: Exception) {
            onCameraError?.invoke("Failed to set ISO: ${e.message}")
        }
    }

    suspend fun setVideoStabilization(enabled: Boolean) {
        val device = cameraDevice ?: return
        val session = captureSession ?: return

        try {
            val builder = buildCaptureRequest(device)
            builder.set(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE,
                if (enabled) CameraMetadata.CONTROL_VIDEO_STABILIZATION_MODE_ON
                else CameraMetadata.CONTROL_VIDEO_STABILIZATION_MODE_OFF
            )
            session.setRepeatingRequest(builder.build(), null, cameraHandler)
        } catch (e: Exception) {
            onCameraError?.invoke("Failed to set video stabilization: ${e.message}")
        }
    }

    suspend fun setFlashMode(mode: String) {
        val device = cameraDevice ?: return
        val session = captureSession ?: return

        try {
            val builder = buildCaptureRequest(device)

            when (mode) {
                "torch" -> {
                    builder.set(CaptureRequest.FLASH_MODE, CameraMetadata.FLASH_MODE_OFF)
                    builder.set(CaptureRequest.CONTROL_AE_MODE, CameraMetadata.CONTROL_AE_MODE_ON)
                    builder.set(CaptureRequest.FLASH_MODE, CameraMetadata.FLASH_MODE_TORCH)
                }
                "on" -> {
                    builder.set(CaptureRequest.FLASH_MODE, CameraMetadata.FLASH_MODE_SINGLE)
                }
                "auto" -> {
                    builder.set(CaptureRequest.FLASH_MODE, CameraMetadata.FLASH_MODE_SINGLE)
                }
                else -> {
                    builder.set(CaptureRequest.FLASH_MODE, CameraMetadata.FLASH_MODE_OFF)
                }
            }
            session.setRepeatingRequest(builder.build(), null, cameraHandler)
        } catch (e: Exception) {
            onCameraError?.invoke("Failed to set flash mode: ${e.message}")
        }
    }

    fun getCameraCapabilities(cameraId: String? = currentCameraId): Map<String, Any?> {
        if (cameraId == null) return emptyMap()

        return try {
            val chars = cameraManager.getCameraCharacteristics(cameraId)
            mapOf(
                "maxZoom" to (chars.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1f),
                "supportedFocusModes" to (chars.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES)?.map { it.toString() } ?: emptyList<String>()),
                "exposureCompensationRange" to (chars.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE)?.let {
                    mapOf("min" to it.lower, "max" to it.upper)
                } ?: null),
                "sensitivityRange" to (chars.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)?.let {
                    mapOf("min" to it.lower, "max" to it.upper)
                } ?: null),
                "supportedWhiteBalanceModes" to (chars.get(CameraCharacteristics.CONTROL_AWB_AVAILABLE_MODES)?.map { it.toString() } ?: emptyList<String>()),
                "supportedSceneModes" to (chars.get(CameraCharacteristics.CONTROL_AVAILABLE_SCENE_MODES)?.map { it.toString() } ?: emptyList<String>()),
                "supportedEffects" to (chars.get(CameraCharacteristics.CONTROL_AVAILABLE_EFFECTS)?.map { it.toString() } ?: emptyList<String>()),
                "videoStabilizationAvailable" to (chars.get(CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES) != null),
                "maxFocalLength" to (chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)?.maxOrNull() ?: 0f),
                "minFocalLength" to (chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)?.minOrNull() ?: 0f),
            )
        } catch (e: Exception) {
            onCameraError?.invoke("Failed to get camera capabilities: ${e.message}")
            emptyMap()
        }
    }

    suspend fun switchCamera() {
        currentPosition = if (currentPosition == CameraCharacteristics.LENS_FACING_BACK) {
            CameraCharacteristics.LENS_FACING_FRONT
        } else {
            CameraCharacteristics.LENS_FACING_BACK
        }
        close()
        openCamera()
    }

    fun close() {
        captureSession?.close()
        captureSession = null
        cameraDevice?.close()
        cameraDevice = null
    }

    fun dispose() {
        close()
        cameraThread.quitSafely()
    }

    private fun findCameraWithPosition(position: Int): String? {
        for (cameraId in cameraManager.cameraIdList) {
            val chars = cameraManager.getCameraCharacteristics(cameraId)
            if (chars.get(CameraCharacteristics.LENS_FACING) == position) {
                return cameraId
            }
        }
        return null
    }
}