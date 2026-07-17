package tv.stationcast.station_broadcast

import android.content.Context
import android.net.Uri
import android.util.Log
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
import io.github.thibaultbee.srtdroid.core.enums.SockOpt
import io.github.thibaultbee.srtdroid.core.extensions.connect
import io.github.thibaultbee.srtdroid.core.models.SrtSocket
import io.github.thibaultbee.srtdroid.core.models.SrtUrl
import java.io.IOException
import java.util.LinkedList
import java.util.Queue

@UnstableApi
class TalkbackAudioPlayer(context: Context) : Player.Listener {
    private val player = ExoPlayer.Builder(context).build()
    private var started = false

    init {
        player.addListener(this)
    }

    fun start(url: String) {
        if (started) return
        started = true
        Log.i("Talkback", "start() url=$url")

        val dataSourceFactory = DataSource.Factory { TalkbackSrtDataSource() }
        val extractorsFactory = ExtractorsFactory { arrayOf<TsExtractor>(TsExtractor()) }
        val mediaItem = MediaItem.fromUri(Uri.parse(url))
        val mediaSource: MediaSource =
            ProgressiveMediaSource.Factory(dataSourceFactory, extractorsFactory)
                .createMediaSource(mediaItem)
        player.setMediaSource(mediaSource)
        player.prepare()
        player.playWhenReady = true
        Log.i("Talkback", "ExoPlayer prepared, playWhenReady=true")
    }

    override fun onPlayerError(error: PlaybackException) {
        Log.e("Talkback", "ExoPlayer error: ${error.localizedMessage} errorCode=${error.errorCode}")
    }

    fun stop() {
        if (!started) return
        started = false
        Log.i("Talkback", "stop()")
        player.removeListener(this)
        player.stop()
        player.release()
    }
}

@UnstableApi
class TalkbackSrtDataSource : BaseDataSource(true) {

    companion object {
        private const val TS_PACKET_SIZE = 188
        private const val PAYLOAD_SIZE = 1316
    }

    private val byteQueue: Queue<ByteArray> = LinkedList()
    private var socket: SrtSocket? = null

    override fun open(dataSpec: DataSpec): Long {
        socket = SrtSocket().apply {
            connect(SrtUrl(dataSpec.uri))
            setSockFlag(SockOpt.RCVTIMEO, 3000)
        }
        return androidx.media3.common.C.LENGTH_UNSET.toLong()
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        val sock = socket ?: throw IOException("Socket not connected")

        var total = 0
        var chunk = byteQueue.poll()
        while (chunk != null && total < length) {
            val copyLen = minOf(chunk.size, length - total)
            System.arraycopy(chunk, 0, buffer, offset + total, copyLen)
            total += copyLen
            chunk = byteQueue.poll()
        }
        if (total >= length) return total

        try {
            val rcvBuffer = sock.recv(PAYLOAD_SIZE)
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
        } catch (_: Exception) {
        }

        return if (total > 0) total else 0
    }

    override fun getUri(): android.net.Uri = android.net.Uri.EMPTY

    override fun close() {
        byteQueue.clear()
        socket?.close()
        socket = null
    }
}
