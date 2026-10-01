package tv.stationcast.station_broadcast

import android.content.Context
import android.view.SurfaceHolder
import android.view.SurfaceView
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

class CameraPreviewPlatformView(
    context: Context,
    private val engine: BroadcastEngine,
    private val whipEngine: WhipEngine? = null
) : PlatformView {
    private val surfaceView = SurfaceView(context)
    init {
        engine.previewSurfaceView = surfaceView
        surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                engine.setPreviewSurface(holder.surface)
                whipEngine?.setPreviewSurface(holder.surface)
                val res = engine.getCameraResolution()
                if (res.isNotEmpty()) {
                    val w = res["width"]?.toInt() ?: return
                    val h = res["height"]?.toInt() ?: return
                    holder.setFixedSize(w, h)
                }
            }
            override fun surfaceChanged(holder: SurfaceHolder, fmt: Int, w: Int, h: Int) {}
            override fun surfaceDestroyed(holder: SurfaceHolder) {
                engine.setPreviewSurface(null)
                whipEngine?.setPreviewSurface(null)
            }
        })
    }
    override fun getView(): android.view.View = surfaceView
    override fun dispose() {}
}

class CameraPreviewFactory(
    private val engine: BroadcastEngine,
    private val whipEngine: WhipEngine? = null
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        CameraPreviewPlatformView(context, engine, whipEngine)
}
