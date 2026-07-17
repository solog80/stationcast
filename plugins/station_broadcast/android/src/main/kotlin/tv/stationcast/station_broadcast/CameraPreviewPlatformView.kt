package tv.stationcast.station_broadcast

import android.content.Context
import android.view.SurfaceHolder
import android.view.SurfaceView
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

class CameraPreviewPlatformView(
    context: Context,
    private val engine: BroadcastEngine
) : PlatformView {
    private val surfaceView = SurfaceView(context)
    init {
        engine.previewSurfaceView = surfaceView
        surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                engine.setPreviewSurface(holder.surface)
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
            }
        })
    }
    override fun getView(): android.view.View = surfaceView
    override fun dispose() {}
}

class CameraPreviewFactory(
    private val engine: BroadcastEngine
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        CameraPreviewPlatformView(context, engine)
}
