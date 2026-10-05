package tv.stationcast.station_broadcast

import android.content.Context
import android.os.Build
import android.view.SurfaceHolder
import android.view.View
import android.widget.FrameLayout
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import org.webrtc.RendererCommon
import org.webrtc.SurfaceViewRenderer

class CameraPreviewPlatformView(
    context: Context,
    private val engine: BroadcastEngine,
    private val whipEngine: WhipEngine? = null
) : PlatformView {
    private val container = FrameLayout(context)
    private val webrtcRenderer = SurfaceViewRenderer(context)
    private val streampackSurfaceView = android.view.SurfaceView(context)

    init {
        // Lock display panel composition to 24.0 Hz (matching Blackmagic Camera display lock)
        applySurfaceFrameRateLock()

        // Setup WebRTC renderer for idle preview & WHIP mode
        whipEngine?.rootEglBase?.eglBaseContext?.let { eglContext ->
            webrtcRenderer.init(eglContext, null)
            webrtcRenderer.setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FILL)
            webrtcRenderer.setEnableHardwareScaler(true)
        }
        whipEngine?.addPreviewSink(webrtcRenderer)
        whipEngine?.ensureCameraPreview()

        // Setup clean SurfaceView for StreamPack SRT/RTMP mode
        streampackSurfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                applySurfaceFrameRate(holder.surface)
                engine.setPreviewSurface(holder.surface)
            }

            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                applySurfaceFrameRate(holder.surface)
                engine.setPreviewSurface(holder.surface)
            }

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                engine.setPreviewSurface(null)
            }
        })
        engine.previewSurfaceView = streampackSurfaceView

        val currentSurface = streampackSurfaceView.holder.surface
        if (currentSurface != null && currentSurface.isValid) {
            applySurfaceFrameRate(currentSurface)
            engine.setPreviewSurface(currentSurface)
        }

        container.addView(
            streampackSurfaceView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        )
        container.addView(
            webrtcRenderer,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        )

        // WebRTC preview active by default, StreamPack surface hidden until SRT streaming starts
        webrtcRenderer.visibility = View.VISIBLE
        streampackSurfaceView.visibility = View.GONE

        engine.onPreviewModeChanged = { mode ->
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                if (mode == "streampack") {
                    webrtcRenderer.visibility = View.GONE
                    streampackSurfaceView.visibility = View.VISIBLE
                } else {
                    streampackSurfaceView.visibility = View.GONE
                    webrtcRenderer.visibility = View.VISIBLE
                }
            }
        }
    }

    private fun applySurfaceFrameRate(surface: android.view.Surface?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && surface != null && surface.isValid) {
            try {
                // Lock display refresh rate hint to 24.0 Hz (Blackmagic Camera style display thermal optimization)
                surface.setFrameRate(
                    24.0f,
                    android.view.Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE
                )
                android.util.Log.d("[CameraPreviewView]", "Surface refresh rate locked to 24.0 Hz")
            } catch (e: Exception) {
                android.util.Log.w("[CameraPreviewView]", "Failed to set surface frame rate: ${e.message}")
            }
        }
    }

    private fun applySurfaceFrameRateLock() {
        streampackSurfaceView.holder.surface?.let { applySurfaceFrameRate(it) }
        webrtcRenderer.holder.surface?.let { applySurfaceFrameRate(it) }
    }

    override fun getView(): View = container

    override fun dispose() {
        engine.onPreviewModeChanged = null
        engine.setPreviewSurface(null)
        engine.previewSurfaceView = null
        whipEngine?.removePreviewSink(webrtcRenderer)
        try {
            webrtcRenderer.release()
        } catch (e: Exception) {
            android.util.Log.w("[CameraPreviewView]", "Error releasing WebRTC renderer: ${e.message}")
        }
    }
}

class CameraPreviewFactory(
    private val engine: BroadcastEngine,
    private val whipEngine: WhipEngine? = null
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        CameraPreviewPlatformView(context, engine, whipEngine)
}
