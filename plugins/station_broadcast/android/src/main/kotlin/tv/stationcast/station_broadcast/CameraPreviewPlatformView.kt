package tv.stationcast.station_broadcast

import android.content.Context
import android.view.View
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
    private val webrtcRenderer = SurfaceViewRenderer(context)

    init {
        whipEngine?.rootEglBase?.eglBaseContext?.let { eglContext ->
            webrtcRenderer.init(eglContext, null)
            webrtcRenderer.setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FILL)
            webrtcRenderer.setEnableHardwareScaler(true)
        }

        whipEngine?.addPreviewSink(webrtcRenderer)
        whipEngine?.ensureCameraPreview()
    }

    override fun getView(): View = webrtcRenderer

    override fun dispose() {
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
