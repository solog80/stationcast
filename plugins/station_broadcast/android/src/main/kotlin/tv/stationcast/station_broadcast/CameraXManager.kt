package tv.stationcast.station_broadcast

import android.annotation.SuppressLint
import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.util.Size
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.SurfaceRequest
import androidx.camera.core.impl.utils.executor.CameraXExecutors
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.core.ZoomState
import java.util.concurrent.Executors
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * CameraX-based camera management with full Camera2 feature access.
 * Cleaner than Camera2 API, handles preview and video capture.
 */
@SuppressLint("MissingPermission")
class CameraXManager(private val context: Context) {
    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: androidx.camera.core.Camera? = null
    private var previewSurfaceRequest: SurfaceRequest? = null
    private var previewSurface: android.view.Surface? = null
    private var encoderSurface: android.view.Surface? = null
    private var currentCameraLensFacing = CameraSelector.LENS_FACING_BACK
    private val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    // Simple lifecycle owner for CameraX (required)
    private val lifecycleOwner = object : LifecycleOwner {
        private val lifecycleRegistry = LifecycleRegistry(this).apply {
            handleLifecycleEvent(Lifecycle.Event.ON_CREATE)
            handleLifecycleEvent(Lifecycle.Event.ON_START)
            handleLifecycleEvent(Lifecycle.Event.ON_RESUME)
        }
        override val lifecycle: Lifecycle = lifecycleRegistry
    }

    var onCameraReady: (() -> Unit)? = null
    var onCameraError: ((String) -> Unit)? = null
    var onFrameAvailable: ((ImageProxy) -> Unit)? = null

    suspend fun initialize() {
        try {
            val cameraProviderFuture = ProcessCameraProvider.getInstance(context)
            cameraProvider = suspendCancellableCoroutine { continuation ->
                cameraProviderFuture.addListener(
                    {
                        try {
                            continuation.resume(cameraProviderFuture.get())
                        } catch (e: Exception) {
                            continuation.resumeWithException(e)
                        }
                    },
                    CameraXExecutors.mainThreadExecutor()
                )
            }
            bindCamera()
        } catch (e: Exception) {
            onCameraError?.invoke("Failed to initialize CameraX: ${e.message}")
            throw e
        }
    }

    fun setEncoderSurface(surface: android.view.Surface) {
        encoderSurface = surface
        bindCamera()
    }

    private fun bindCamera() {
        val provider = cameraProvider ?: return
        provider.unbindAll()

        val cameraSelector = CameraSelector.Builder()
            .requireLensFacing(currentCameraLensFacing)
            .build()

        // Preview UseCase — writes to encoder surface (or display surface if no encoder)
        val preview = Preview.Builder()
            .setTargetResolution(android.util.Size(1280, 720))
            .build()

        preview.setSurfaceProvider { surfaceRequest ->
            try {
                val surface = encoderSurface ?: previewSurface
                if (surface != null) {
                    surfaceRequest.provideSurface(
                        surface,
                        CameraXExecutors.mainThreadExecutor()
                    ) { }
                } else {
                    previewSurfaceRequest = surfaceRequest
                }
            } catch (e: Exception) {
                android.util.Log.e("CameraXManager", "Error providing surface: ${e.message}")
            }
        }

        try {
            camera = provider.bindToLifecycle(
                lifecycleOwner,
                cameraSelector,
                preview
            )
            android.util.Log.i("CameraXManager", "Camera bound with Preview (encoder surface)")
            onCameraReady?.invoke()
        } catch (e: Exception) {
            onCameraError?.invoke("Failed to bind camera: ${e.message}")
        }
    }

    suspend fun setZoom(ratio: Float) {
        val cam = camera ?: return
        try {
            cam.cameraControl.setZoomRatio(ratio.coerceAtLeast(1f))
        } catch (e: Exception) {
            onCameraError?.invoke("Failed to set zoom: ${e.message}")
        }
    }

    suspend fun setFocusMode(mode: String) {
        val cam = camera ?: return
        try {
            // CameraX auto-handles focus, manual control requires more setup
            // For now, we default to auto focus
        } catch (e: Exception) {
            onCameraError?.invoke("Failed to set focus mode: ${e.message}")
        }
    }

    suspend fun setExposureCompensation(ev: Int) {
        val cam = camera ?: return
        try {
            val clamped = ev.coerceIn(-16, 16)
            android.util.Log.d("CameraXManager", "setExposureCompensationIndex($clamped) called")

            val future = cam.cameraControl.setExposureCompensationIndex(clamped)
            android.util.Log.d("CameraXManager", "Future returned, adding listener...")

            future.addListener({
                android.util.Log.d("CameraXManager", "Exposure compensation applied: $clamped")
            }, CameraXExecutors.mainThreadExecutor())

        } catch (e: Exception) {
            android.util.Log.e("CameraXManager", "Failed to set exposure: ${e.message}", e)
            onCameraError?.invoke("Failed to set exposure: ${e.message}")
        }
    }

    suspend fun setWhiteBalance(mode: String) {
        // CameraX handles white balance automatically
        // Manual control would require CameraX extensions or Camera2 interop
    }

    suspend fun setIsoSensitivity(iso: Int) {
        // CameraX doesn't expose manual ISO control directly
        android.util.Log.i("CameraXManager", "ISO setting requested: $iso (CameraX limitation: not supported)")
    }

    suspend fun setVideoStabilization(enabled: Boolean) {
        val cam = camera ?: return
        cam.cameraControl.enableTorch(false) // Reset other controls
        // Stabilization is typically handled by the camera hardware
    }

    suspend fun setFlashMode(mode: String) {
        val cam = camera ?: return
        try {
            val enabled = mode == "torch"
            cam.cameraControl.enableTorch(enabled)
        } catch (e: Exception) {
            onCameraError?.invoke("Failed to set flash: ${e.message}")
        }
    }

    suspend fun switchCamera() {
        currentCameraLensFacing = if (currentCameraLensFacing == CameraSelector.LENS_FACING_BACK) {
            CameraSelector.LENS_FACING_FRONT
        } else {
            CameraSelector.LENS_FACING_BACK
        }
        bindCamera()
    }

    fun getPreviewSurfaceRequest(): SurfaceRequest? = previewSurfaceRequest

    fun getCameraCapabilities(): Map<String, Any?> {
        val cam = camera ?: return emptyMap()
        val cameraInfo = cam.cameraInfo

        return try {
            // Query actual exposure compensation range from Camera2 characteristics
            val characteristics = cameraManager.getCameraCharacteristics(
                cameraManager.cameraIdList.find { id ->
                    val facing = cameraManager.getCameraCharacteristics(id)
                        .get(android.hardware.camera2.CameraCharacteristics.LENS_FACING)
                    facing == currentCameraLensFacing
                } ?: cameraManager.cameraIdList[0]
            )

            val exposureCompensationRange = characteristics.get(
                android.hardware.camera2.CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE
            )

            val minExp = exposureCompensationRange?.lower ?: -4
            val maxExp = exposureCompensationRange?.upper ?: 4

            // Query actual zoom range from Camera2 characteristics
            val maxDigitalZoom = characteristics.get(
                android.hardware.camera2.CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM
            ) ?: 4f

            android.util.Log.i("CameraXManager", "Exposure compensation range: $minExp to $maxExp")
            android.util.Log.i("CameraXManager", "Max digital zoom: $maxDigitalZoom")

            mapOf(
                "maxZoom" to maxDigitalZoom,
                "minZoom" to 1f,
                "exposureCompensationRange" to mapOf(
                    "min" to minExp,
                    "max" to maxExp
                ),
                "hasFlash" to cameraInfo.hasFlashUnit(),
                "supportedExtensions" to listOf("auto", "exposure", "zoom"),
            )
        } catch (e: Exception) {
            android.util.Log.e("CameraXManager", "Error getting capabilities: ${e.message}")
            mapOf(
                "exposureCompensationRange" to mapOf("min" to -4, "max" to 4),
                "maxZoom" to 4f
            )
        }
    }

    fun setPreviewSurface(surface: android.view.Surface) {
        previewSurface = surface
        previewSurfaceRequest?.let { request ->
            try {
                android.util.Log.d("CameraXManager", "Providing surface to preview: ${surface}")
                request.provideSurface(
                    surface,
                    CameraXExecutors.mainThreadExecutor()
                ) { }
                previewSurfaceRequest = null
            } catch (e: Exception) {
                android.util.Log.e("CameraXManager", "Error providing pending surface: ${e.message}")
            }
        }
        if (previewSurfaceRequest == null && camera != null) {
            android.util.Log.i("CameraXManager", "Surface already connected, camera data should flow now")
        }
    }

    fun dispose() {
        cameraProvider?.unbindAll()
        cameraProvider = null
        camera = null
        previewSurface = null
    }
}
