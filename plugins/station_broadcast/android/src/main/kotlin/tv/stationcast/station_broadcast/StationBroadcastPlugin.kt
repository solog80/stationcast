package tv.stationcast.station_broadcast

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.thibaultbee.streampack.ui.views.PreviewView
import kotlinx.coroutines.launch

/**
 * Flutter entry point: routes channel calls to [BroadcastEngine] (StreamPack).
 * The CameraX + VideoEncoder engine is preserved in BroadcastEngineNew.kt as reference.
 */
class StationBroadcastPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventsChannel: EventChannel
    private lateinit var statsChannel: EventChannel
    private lateinit var histogramChannel: EventChannel
    // Use BroadcastEngine (StreamPack) — working Camera2 + TS + SRT
    private lateinit var engine: BroadcastEngine
    private lateinit var applicationContext: Context
    private var talkbackPlayer: TalkbackAudioPlayer? = null

    private var eventSink: EventChannel.EventSink? = null
    private var statsSink: EventChannel.EventSink? = null
    private var histogramSink: EventChannel.EventSink? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        engine = BroadcastEngine(applicationContext)
        engine.onEvent = { state, message ->
            eventSink?.success(mapOf("state" to state, "message" to message))
        }
        engine.onStats = { stats -> statsSink?.success(stats) }

        methodChannel = MethodChannel(binding.binaryMessenger, "tv.stationcast/broadcast")
        methodChannel.setMethodCallHandler(this)

        eventsChannel = EventChannel(binding.binaryMessenger, "tv.stationcast/broadcast/events")
        eventsChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })

        statsChannel = EventChannel(binding.binaryMessenger, "tv.stationcast/broadcast/stats")
        statsChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                statsSink = events
            }

            override fun onCancel(arguments: Any?) {
                statsSink = null
            }
        })

        histogramChannel = EventChannel(binding.binaryMessenger, "tv.stationcast/broadcast/histogram")
        histogramChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                histogramSink = events
                engine.startHistogram()
            }

            override fun onCancel(arguments: Any?) {
                histogramSink = null
                engine.stopHistogram()
            }
        })
        engine.onHistogram = { bins -> histogramSink?.success(bins) }

        binding.platformViewRegistry.registerViewFactory(
            "tv.stationcast/camera_preview",
            CameraPreviewFactory(engine)
        )
        binding.platformViewRegistry.registerViewFactory(
            "tv.stationcast/srt_player",
            SrtPlayerViewFactory(binding.binaryMessenger)
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        engine.scope.launch { engine.dispose() }
    }

    @SuppressLint("MissingPermission") // permissions are gated on the Dart side
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> launchCatching(result) {
                engine.initialize(call.arguments as Map<*, *>)
                result.success(null)
            }
            "startStream" -> launchCatching(result) {
                engine.startStream(call.arguments as Map<*, *>)
                result.success(null)
            }
            "stopStream" -> launchCatching(result) {
                engine.stopStream()
                result.success(null)
            }
            "switchCamera" -> launchCatching(result) {
                engine.switchCamera()
                result.success(null)
            }
            "setTorch" -> launchCatching(result) {
                engine.setTorch(call.argument<Boolean>("enabled") ?: false)
                result.success(null)
            }
            "setZoom" -> launchCatching(result) {
                engine.setZoom((call.argument<Number>("ratio") ?: 1.0).toFloat())
                result.success(null)
            }
            "setMuted" -> {
                engine.setMuted(call.argument<Boolean>("muted") ?: false)
                result.success(null)
            }
            "setVideoBitrate" -> {
                val bps = call.argument<Number>("bps")?.toInt()
                if (bps == null) {
                    result.success(null)
                } else {
                    launchCatching(result) {
                        engine.setVideoBitrate(bps)
                        result.success(null)
                    }
                }
            }
            "getMaxZoom" -> result.success(engine.getMaxZoom().toDouble())
            "getCameraResolution" -> result.success(engine.getCameraResolution())
            "getAudioDevices" -> result.success(listAudioDevices())
            "selectAudioDevice" -> {
                selectAudioDevice(call.argument<String>("id"))
                result.success(null)
            }
            "dispose" -> launchCatching(result) {
                engine.dispose()
                result.success(null)
            }
            "talkbackStart" -> launchCatching(result) {
                val url = call.argument<String>("url") ?: ""
                talkbackPlayer?.stop()
                talkbackPlayer = TalkbackAudioPlayer(applicationContext)
                talkbackPlayer!!.start(url)
                result.success(null)
            }
            "talkbackStop" -> {
                talkbackPlayer?.stop()
                talkbackPlayer = null
                result.success(null)
            }
            "pausePreview" -> launchCatching(result) {
                engine.pausePreview()
                result.success(null)
            }
            "resumePreview" -> launchCatching(result) {
                engine.resumePreview()
                result.success(null)
            }
            "takeSnapshot" -> launchCatching(result) {
                val bytes = engine.takeSnapshot()
                result.success(bytes)
            }
            "setMirrorFrontCamera" -> launchCatching(result) {
                engine.setMirrorFrontCamera(call.argument<Boolean>("enabled") ?: false)
                result.success(null)
            }
            "camera2InitializeManager" -> launchCatching(result) {
                engine.camera2InitializeManager()
                result.success(null)
            }
            "camera2SetZoom" -> launchCatching(result) {
                engine.camera2SetZoom((call.argument<Number>("ratio") ?: 1.0).toFloat())
                result.success(null)
            }
            "camera2SetFocusMode" -> launchCatching(result) {
                engine.camera2SetFocusMode(call.argument<String>("mode") ?: "auto")
                result.success(null)
            }
            "camera2SetExposureCompensation" -> launchCatching(result) {
                engine.camera2SetExposureCompensation(call.argument<Number>("ev")?.toInt() ?: 0)
                result.success(null)
            }
            "camera2SetWhiteBalance" -> launchCatching(result) {
                engine.camera2SetWhiteBalance(call.argument<String>("mode") ?: "auto")
                result.success(null)
            }
            "camera2SetIsoSensitivity" -> launchCatching(result) {
                engine.camera2SetIsoSensitivity(call.argument<Number>("iso")?.toInt() ?: 100)
                result.success(null)
            }
            "camera2SetVideoStabilization" -> launchCatching(result) {
                engine.camera2SetVideoStabilization(call.argument<Boolean>("enabled") ?: true)
                result.success(null)
            }
            "camera2SetFlashMode" -> launchCatching(result) {
                engine.camera2SetFlashMode(call.argument<String>("mode") ?: "off")
                result.success(null)
            }
            "camera2GetCapabilities" -> result.success(engine.camera2GetCapabilities())
            "camera2SetFocusPoint" -> launchCatching(result) {
                val x = call.argument<Double>("x")?.toFloat() ?: 0.5f
                val y = call.argument<Double>("y")?.toFloat() ?: 0.5f
                engine.camera2SetFocusPoint(x, y)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun launchCatching(result: MethodChannel.Result, block: suspend () -> Unit) {
        engine.scope.launch {
            try {
                block()
            } catch (t: Throwable) {
                result.error("broadcast_error", t.message ?: t.toString(), null)
            }
        }
    }

    private fun listAudioDevices(): List<Map<String, String>> {
        val audioManager =
            applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        return audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS)
            .distinctBy { it.id }
            .map { device ->
            mapOf(
                "id" to device.id.toString(),
                "name" to device.productName.toString(),
                "type" to when (device.type) {
                    AudioDeviceInfo.TYPE_BUILTIN_MIC -> "builtin"
                    AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wired"
                    AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET -> "usb"
                    AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "bluetooth"
                    else -> "unknown"
                }
            )
        }
    }

    /**
     * Routes capture to the given input device. StreamPack's microphone source
     * follows the platform communication device on API 31+.
     */
    private fun selectAudioDevice(id: String?) {
        if (id == null) return
        val audioManager =
            applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val device = audioManager.availableCommunicationDevices
                .firstOrNull { it.id.toString() == id }
            if (device != null) {
                audioManager.setCommunicationDevice(device)
            }
        }
    }
}
