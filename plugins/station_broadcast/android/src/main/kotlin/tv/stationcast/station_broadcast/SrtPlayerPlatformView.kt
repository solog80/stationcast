package tv.stationcast.station_broadcast

import android.content.Context
import android.net.Uri
import android.util.Log
import android.view.View
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.extractor.Extractor
import androidx.media3.extractor.ExtractorsFactory
import androidx.media3.extractor.ts.TsExtractor
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.github.thibaultbee.srtdroid.core.enums.SockOpt
import io.github.thibaultbee.srtdroid.core.extensions.connect
import io.github.thibaultbee.srtdroid.core.models.SrtSocket
import io.github.thibaultbee.srtdroid.core.models.SrtUrl
import java.io.IOException
import java.util.LinkedList
import java.util.Queue

@UnstableApi
class SrtPlayerPlatformView(
    context: Context,
    id: Int,
    url: String,
    messenger: BinaryMessenger,
) : PlatformView, Player.Listener, MethodChannel.MethodCallHandler {

    private val playerView: PlayerView
    private val player: ExoPlayer

    init {
        Log.i("SrtPlatform", "PlatformView init, url: $url")
        try {
            player = ExoPlayer.Builder(context).build()
            player.addListener(this)
            Log.i("SrtPlatform", "ExoPlayer created")
        } catch (e: Exception) {
            Log.e("SrtPlatform", "ExoPlayer creation failed: $e")
            throw e
        }
        try {
            val dataSourceFactory = DataSource.Factory { SrtDataSource() }
            val extractorsFactory = ExtractorsFactory { arrayOf(TsExtractor()) }
            val mediaItem = MediaItem.fromUri(Uri.parse(url))
            val mediaSource: MediaSource =
                ProgressiveMediaSource.Factory(dataSourceFactory, extractorsFactory)
                    .createMediaSource(mediaItem)
            Log.i("SrtPlatform", "MediaSource created")
            player.setMediaSource(mediaSource)
            Log.i("SrtPlatform", "MediaSource set, calling prepare()")
            player.prepare()
            player.playWhenReady = true
            Log.i("SrtPlatform", "prepare() completed, playWhenReady=true")
        } catch (e: Exception) {
            Log.e("SrtPlatform", "Player setup failed: $e")
            throw e
        }

        playerView = PlayerView(context).apply {
            player = this@SrtPlayerPlatformView.player
            useController = false
            resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
        }

        MethodChannel(messenger, "tv.stationcast/srt_player_$id")
            .also { it.setMethodCallHandler(this) }
    }

    override fun getView(): View = playerView

    // Player.Listener callbacks
    override fun onPlaybackStateChanged(playbackState: Int) {
        val name = when (playbackState) {
            Player.STATE_IDLE -> "IDLE"
            Player.STATE_BUFFERING -> "BUFFERING"
            Player.STATE_READY -> "READY"
            Player.STATE_ENDED -> "ENDED"
            else -> "$playbackState"
        }
        Log.i("SrtPlatform", "ExoPlayer state: $name")
    }

    override fun onIsPlayingChanged(isPlaying: Boolean) {
        Log.i("SrtPlatform", "ExoPlayer isPlaying: $isPlaying")
    }

    override fun onPlayerError(error: PlaybackException) {
        Log.e("SrtPlatform", "ExoPlayer error: ${error.localizedMessage} errorCode=${error.errorCode}")
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setVolume" -> {
                player.volume = (call.argument<Number>("volume")?.toFloat() ?: 0f)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun dispose() {
        player.removeListener(this)
        player.stop()
        player.release()
    }
}

class SrtPlayerViewFactory(
    private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val params = args as? Map<String, Any?>
        val url = params?.get("url") as? String ?: ""
        return SrtPlayerPlatformView(context, viewId, url, messenger)
    }
}

@UnstableApi
class SrtDataSource : BaseDataSource(true) {

    companion object {
        private const val TS_PACKET_SIZE = 188
        private const val PAYLOAD_SIZE = 1316
    }

    private val byteQueue: Queue<ByteArray> = LinkedList()
    private var socket: SrtSocket? = null

    override fun open(dataSpec: DataSpec): Long {
        Log.i("SrtPlatform", "open() called, uri: ${dataSpec.uri}")
        socket = SrtSocket().apply {
            connect(SrtUrl(dataSpec.uri))
            setSockFlag(SockOpt.RCVTIMEO, 3000)
        }
        Log.i("SrtPlatform", "socket connected")
        return C.LENGTH_UNSET.toLong()
    }

    private var totalReadCalls = 0
    private var totalBytesRead = 0L

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        val sock = socket ?: throw IOException("Socket not connected")

        totalReadCalls++

        // Drain queued data first
        var total = 0
        var chunk = byteQueue.poll()
        while (chunk != null && total < length) {
            val copyLen = minOf(chunk.size, length - total)
            System.arraycopy(chunk, 0, buffer, offset + total, copyLen)
            total += copyLen
            chunk = byteQueue.poll()
        }
        if (total >= length) {
            totalBytesRead += total
            Log.i("SrtPlatform", "read#$totalReadCalls returned $total from queue (totalBytes=$totalBytesRead)")
            return total
        }

        // Receive more from SRT
        var recvOk = false
        try {
            val t0 = System.currentTimeMillis()
            val rcvBuffer = sock.recv(PAYLOAD_SIZE)
            val dt = System.currentTimeMillis() - t0
            Log.i("SrtPlatform", "read#$totalReadCalls recv() got ${rcvBuffer.size} bytes in ${dt}ms")
            recvOk = true
            val count = rcvBuffer.size / TS_PACKET_SIZE
            for (i in 0 until count) {
                val pkt = rcvBuffer.copyOfRange(i * TS_PACKET_SIZE, (i + 1) * TS_PACKET_SIZE)
                if (total + TS_PACKET_SIZE <= length) {
                    System.arraycopy(pkt, 0, buffer, offset + total, TS_PACKET_SIZE)
                    total += TS_PACKET_SIZE
                } else {
                    byteQueue.add(pkt)
                }
            }
            Log.i("SrtPlatform", "read#$totalReadCalls copied $total bytes from recv, queued ${count - total / TS_PACKET_SIZE} packets")
        } catch (e: Exception) {
            Log.w("SrtPlatform", "read#$totalReadCalls recv() failed: $e")
        }

        totalBytesRead += total
        Log.i("SrtPlatform", "read#$totalReadCalls returning $total (totalBytes=$totalBytesRead recvOk=$recvOk)")
        return if (total > 0) total else 0
    }

    override fun getUri(): Uri = Uri.EMPTY

    override fun close() {
        byteQueue.clear()
        socket?.close()
        socket = null
    }
}
