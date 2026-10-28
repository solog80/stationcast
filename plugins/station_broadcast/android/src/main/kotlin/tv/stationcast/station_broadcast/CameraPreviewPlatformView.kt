package tv.stationcast.station_broadcast

import android.content.Context
import android.os.Build
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

class CameraPreviewPlatformView(
    context: Context,
    private val engine: BroadcastEngine
) : PlatformView {
    private val streampackSurfaceView = SurfaceView(context)

    init {
        // Prevent API 34+ SurfaceView destruction when UI overlays appear
        if (Build.VERSION.SDK_INT >= 34) {
            streampackSurfaceView.setSurfaceLifecycle(SurfaceView.SURFACE_LIFECYCLE_FOLLOWS_ATTACHMENT)
        }


        streampackSurfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                streampackSurfaceView.unsplitMotionEvents()
                engine.setPreviewSurface(holder.surface)
                engine.updateSurfaceFixedSize()
            }

            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                streampackSurfaceView.unsplitMotionEvents()
                engine.setPreviewSurface(holder.surface)
                engine.updateSurfaceFixedSize()
            }

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                engine.setPreviewSurface(null)
            }
        })
        engine.previewSurfaceView = streampackSurfaceView
        engine.updateSurfaceFixedSize()

        val currentSurface = streampackSurfaceView.holder.surface
        if (currentSurface != null && currentSurface.isValid) {
            engine.setPreviewSurface(currentSurface)
        }
    }

    private fun View.unsplitMotionEvents() {
        var walk: View? = this
        while (walk != null) {
            (walk as? android.view.ViewGroup)?.isMotionEventSplittingEnabled = false
            walk = walk.parent as? View
        }
    }

    override fun getView(): View = streampackSurfaceView

    override fun dispose() {
        engine.setPreviewSurface(null)
        engine.previewSurfaceView = null
    }
}

class CameraPreviewFactory(
    private val engine: BroadcastEngine
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        CameraPreviewPlatformView(context, engine)
}
