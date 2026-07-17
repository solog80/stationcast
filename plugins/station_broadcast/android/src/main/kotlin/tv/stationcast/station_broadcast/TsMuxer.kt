package tv.stationcast.station_broadcast

import android.media.MediaFormat
import java.nio.ByteBuffer

class TsMuxer(
    private val onTsPacket: (ByteArray) -> Unit
) {
    companion object {
        private const val TS_PACKET_SIZE = 188
        private const val TS_PAYLOAD = 184
        private const val PAT_PID = 0x0000
        private const val PMT_PID = 0x1000
        private const val VIDEO_PID = 0x0100
        private const val STREAM_H264 = 0x1B
        private const val PAT_INTERVAL = 50
        private const val PMT_INTERVAL = 25
    }

    private var cc = 0
    private var pktCount = 0
    private var extraData: ByteArray? = null
    private var streamType = STREAM_H264

    // Pre-built PAT/PMT tables
    private var patData: ByteArray = byteArrayOf()
    private var pmtData: ByteArray = byteArrayOf()

    fun start(format: MediaFormat) {
        val mime = format.getString(MediaFormat.KEY_MIME) ?: MediaFormat.MIMETYPE_VIDEO_AVC
        streamType = if (mime == MediaFormat.MIMETYPE_VIDEO_HEVC) 0x24 else STREAM_H264

        val csd0 = format.getByteBuffer("csd-0")
        val csd1 = format.getByteBuffer("csd-1")
        if (csd0 != null && csd1 != null) {
            val sps = ByteArray(csd0.remaining()).also { csd0.get(it) }
            val pps = ByteArray(csd1.remaining()).also { csd1.get(it) }
            extraData = ByteArray(8 + sps.size + pps.size).apply {
                val b = ByteBuffer.wrap(this)
                b.putInt(0x00000001); b.put(sps)
                b.putInt(0x00000001); b.put(pps)
            }
        }
        buildTables()
    }

    private fun buildTables() {
        // PAT: table_id(1) + section_length(2) + ts_id(2) + version(1) + section(1)
        //      + last_section(1) + program(2) + pid(2) + CRC(4) = 16 bytes
        patData = ByteArray(16).apply {
            val b = ByteBuffer.wrap(this)
            b.put(0x00.toByte())                              // table_id
            b.putShort((0xB000 + 9 + 4).toShort())            // section_length
            b.putShort(0x0001.toShort())                        // transport_stream_id
            b.put(0xC1.toByte())                               // version
            b.put(0x00.toByte())                               // section_number
            b.put(0x01.toByte())                               // last_section_number
            b.putShort(0x0001.toShort())                        // program_number
            b.putShort((0xE000 or PMT_PID).toShort())          // program_map_PID
            b.putInt(0x00000000)                               // CRC
        }
        // PMT: table_id(1) + section_length(2) + program(2) + version(1)
        //      + section(1) + last_section(1) + pcr_pid(2) + prog_info_len(2)
        //      + stream_type(1) + elem_pid(2) + es_info_len(2) + CRC(4) = 21 bytes
        pmtData = ByteArray(21).apply {
            val b = ByteBuffer.wrap(this)
            b.put(0x02.toByte())                               // table_id
            b.putShort((0xB000 + 18).toShort())                // section_length
            b.putShort(0x0001.toShort())
            b.put(0xC1.toByte())                               // version
            b.put(0x00.toByte())                               // section_number
            b.put(0x01.toByte())                               // last_section_number
            b.putShort((0xE000 or PMT_PID).toShort())          // PCR_PID
            b.putShort((0xF000).toShort())                     // program_info_length = 0
            b.put(streamType.toByte())                         // stream_type
            b.putShort((0xE000 or VIDEO_PID).toShort())        // elementary_PID
            b.putShort((0xF000).toShort())                     // ES_info_length = 0
            b.putInt(0x00000000)                               // CRC
        }
    }

    fun write(data: ByteArray, pts: Long, isKeyFrame: Boolean) {
        val frame = if (isKeyFrame && extraData != null) {
            ByteArray(extraData!!.size + data.size).apply {
                System.arraycopy(extraData, 0, this, 0, extraData!!.size)
                System.arraycopy(data, 0, this, extraData!!.size, data.size)
            }
        } else data

        val pes = buildPes(frame, pts)
        var off = 0
        while (off < pes.size) {
            if (pktCount % PAT_INTERVAL == 0 && off == 0) sendPsii(patData, PAT_PID)
            if (pktCount % PMT_INTERVAL == 0 && off == 0) sendPsii(pmtData, PMT_PID)
            pktCount++

            val isFirst = off == 0
            val size = minOf(TS_PAYLOAD, pes.size - off)
            val pus = if (isFirst) 0x40 else 0

            val ts = ByteArray(TS_PACKET_SIZE)
            val buf = ByteBuffer.wrap(ts)
            buf.put(0x47.toByte())
            buf.putShort(VIDEO_PID.toShort())
            buf.put((pus or (cc++ and 0x0F)).toByte())
            buf.put(pes, off, size)
            onTsPacket(ts)
            off += TS_PAYLOAD
        }
    }

    private fun buildPes(data: ByteArray, pts: Long): ByteArray {
        val ptsTicks = pts * 9 / 100  // µs → 90kHz
        val pkt = ByteArray(14 + data.size)
        val b = ByteBuffer.wrap(pkt)
        b.putInt(0x000001E0)          // start code + stream_id video
        val pesLen = if (data.size + 8 > 0xFFFF) 0 else data.size + 8
        b.putShort(pesLen.toShort())
        b.put(0x80.toByte())           // PTS only
        b.put(0x80.toByte())           // PTS length
        b.put(((0x20 or ((ptsTicks ushr 30).toInt() and 0x07) or 0x01)).toByte())
        b.putShort(((ptsTicks ushr 15).toInt() and 0xFFFE or 0x0001).toShort())
        b.putShort(((ptsTicks and 0x7FFF) or 0x0001).toShort())
        b.put(data)
        return pkt
    }

    private fun sendPsii(data: ByteArray, pid: Int) {
        var off = 0
        while (off < data.size) {
            val size = minOf(TS_PAYLOAD, data.size - off)
            val pus = if (off == 0) 0x40 else 0
            val ts = ByteArray(TS_PACKET_SIZE)
            val buf = ByteBuffer.wrap(ts)
            buf.put(0x47.toByte())
            buf.putShort(pid.toShort())
            buf.put((pus or (cc++ and 0x0F)).toByte())
            buf.put(data, off, size)
            onTsPacket(ts)
            off += TS_PAYLOAD
        }
    }

    fun stop() {}
}
