package tv.stationcast.station_broadcast

import android.content.Context
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
                engine.setPreviewSurface(holder.surface)
            }

            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                engine.setPreviewSurface(holder.surface)
            }

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                engine.setPreviewSurface(null)
            }
        })
        engine.previewSurfaceView = streampackSurfaceView

        val currentSurface = streampackSurfaceView.holder.surface
        if (currentSurface != null && currentSurface.isValid) {
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
