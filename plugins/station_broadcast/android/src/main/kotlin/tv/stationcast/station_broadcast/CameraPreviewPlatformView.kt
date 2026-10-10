package tv.stationcast.station_broadcast

import android.content.Context
import android.graphics.SurfaceTexture
import android.view.Surface
import android.view.TextureView
import android.view.View
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

class CameraPreviewPlatformView(
    context: Context,
    private val engine: BroadcastEngine
) : PlatformView, TextureView.SurfaceTextureListener {
    private val textureView = TextureView(context)
    private var activeSurface: Surface? = null

    init {
        textureView.surfaceTextureListener = this
        if (textureView.isAvailable) {
            val st = textureView.surfaceTexture
            if (st != null) {
                activeSurface = Surface(st)
                engine.setPreviewSurface(activeSurface)
            }
        }
    }

    override fun onSurfaceTextureAvailable(surfaceTexture: SurfaceTexture, width: Int, height: Int) {
        textureView.unsplitMotionEvents()
        if (activeSurface == null || !activeSurface!!.isValid) {
            activeSurface = Surface(surfaceTexture)
        }
        engine.setPreviewSurface(activeSurface)
    }

    override fun onSurfaceTextureSizeChanged(surfaceTexture: SurfaceTexture, width: Int, height: Int) {
        textureView.unsplitMotionEvents()
        if (activeSurface == null || !activeSurface!!.isValid) {
            activeSurface = Surface(surfaceTexture)
        }
        engine.setPreviewSurface(activeSurface)
    }

    override fun onSurfaceTextureDestroyed(surfaceTexture: SurfaceTexture): Boolean {
        // Return false so Android keeps the SurfaceTexture target alive in GPU memory!
        // This preserves the Camera2 capture pipeline when backgrounded or switching apps.
        return false
    }

    override fun onSurfaceTextureUpdated(surfaceTexture: SurfaceTexture) {}

    private fun View.unsplitMotionEvents() {
        var walk: View? = this
        while (walk != null) {
            (walk as? android.view.ViewGroup)?.isMotionEventSplittingEnabled = false
            walk = walk.parent as? View
        }
    }

    override fun getView(): View = textureView

    override fun dispose() {
        textureView.surfaceTextureListener = null
        activeSurface?.release()
        activeSurface = null
        engine.setPreviewSurface(null)
    }
}

class CameraPreviewFactory(
    private val engine: BroadcastEngine
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        CameraPreviewPlatformView(context, engine)
}
