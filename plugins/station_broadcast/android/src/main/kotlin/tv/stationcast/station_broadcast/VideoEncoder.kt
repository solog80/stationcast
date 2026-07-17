package tv.stationcast.station_broadcast

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import androidx.camera.core.ImageProxy
import java.util.concurrent.LinkedBlockingQueue

/**
 * Wraps Android MediaCodec for H.264/HEVC video encoding.
 * Accepts raw YUV frames from ImageAnalysis and encodes to H.264 bitstream.
 */
class VideoEncoder(
    private val width: Int,
    private val height: Int,
    private val fps: Int = 30,
    private val bitrateBps: Int = 3_000_000,
    private val codecName: String = MediaFormat.MIMETYPE_VIDEO_AVC // H.264
) {
    init {
        android.util.Log.i("VideoEncoder", "VideoEncoder created: ${width}x${height} $codecName")
    }

    private var mediaCodec: MediaCodec? = null
    private val outputBuffers = LinkedBlockingQueue<ByteArray?>()
    private var frameCount = 0L
    private var inputBufferIndex = 0

    var onEncodedFrame: ((data: ByteArray, presentationTimeUs: Long, flags: Int) -> Unit)? = null
    var onEncoderError: ((String) -> Unit)? = null
    var onFormatChanged: ((MediaFormat) -> Unit)? = null

    fun start() {
        try {
            android.util.Log.i("VideoEncoder", "Starting encoder: ${width}x${height} ${codecName} ${bitrateBps}bps ${fps}fps")

            val format = MediaFormat().apply {
                setString(MediaFormat.KEY_MIME, codecName)
                setInteger(MediaFormat.KEY_WIDTH, width)
                setInteger(MediaFormat.KEY_HEIGHT, height)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrateBps)
                setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                // Force Constant Bitrate — strict bitrate enforcement for streaming
                setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
                // Set max bitrate equal to target for tighter control
                try { setInteger("max-bitrate", bitrateBps) } catch (_: Exception) {}
                // Reduce encoding complexity for lower bitrate
                setInteger(MediaFormat.KEY_COMPLEXITY, 0)
                // Use YUV420 Semi-Planar format (NV21) - most common from camera
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
            }

            mediaCodec = MediaCodec.createEncoderByType(codecName).apply {
                android.util.Log.i("VideoEncoder", "Encoder created: $codecName")
                configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                android.util.Log.i("VideoEncoder", "Encoder configured for YUV420 SemiPlanar input (buffer mode)")
                start()
                android.util.Log.i("VideoEncoder", "Encoder started - input buffer capacity for ${width}x${height}: ${getInputBuffers()[0].capacity()} bytes")
            }

            // Start polling for encoded frames
            startEncodingThread()
        } catch (e: Exception) {
            android.util.Log.e("VideoEncoder", "Failed to start encoder: ${e.message}", e)
            onEncoderError?.invoke("Failed to start encoder: ${e.message}")
        }
    }
    fun encodeFrame(imageProxy: ImageProxy, presentationTimeUs: Long) {
        val codec = mediaCodec ?: return
        try {
            val inputIndex = codec.dequeueInputBuffer(0L)
            if (inputIndex < 0) {
                return
            }

            val inputBuffer = codec.getInputBuffer(inputIndex) ?: return
            inputBuffer.clear()

            val planes = imageProxy.planes
            val yPlane = planes[0]
            val yBuffer = yPlane.buffer
            yBuffer.rewind()
            val yRowStride = yPlane.rowStride

            // Copy Y plane: exactly width * height bytes, handling row stride padding
            val ySize = width * height
            if (yRowStride == width) {
                val data = ByteArray(ySize)
                yBuffer.get(data)
                inputBuffer.put(data)
            } else {
                var yOffset = 0
                val row = ByteArray(width)
                for (rowIdx in 0 until height) {
                    yBuffer.position(yRowStride * rowIdx)
                    yBuffer.get(row, 0, width)
                    inputBuffer.put(row)
                    yOffset += width
                }
            }

            // UV planes: handle semi-planar format (NV12/NV21)
            val uPlane = planes[1]
            val vPlane = planes[2]
            val uvPixelStride = uPlane.pixelStride
            val uvRowStride = uPlane.rowStride
            val uvHeight = height / 2

            if (uvPixelStride == 2) {
                // Semi-planar: U and V interleaved (NV12/NV21)
                val uvBuffer = uPlane.buffer
                uvBuffer.rewind()
                val uvSize = width * uvHeight
                if (uvRowStride == width) {
                    val data = ByteArray(uvSize)
                    uvBuffer.get(data)
                    inputBuffer.put(data)
                } else {
                    val uvRow = ByteArray(width)
                    for (rowIdx in 0 until uvHeight) {
                        uvBuffer.position(uvRowStride * rowIdx)
                        uvBuffer.get(uvRow, 0, width)
                        inputBuffer.put(uvRow)
                    }
                }
            } else if (uvPixelStride == 1) {
                // Planar: separate U and V planes
                val uBuffer = uPlane.buffer
                val vBuffer = vPlane.buffer
                uBuffer.rewind()
                vBuffer.rewind()
                val uvSize = width / 2 * uvHeight
                if (uvRowStride == width / 2) {
                    val uData = ByteArray(uvSize)
                    uBuffer.get(uData)
                    inputBuffer.put(uData)
                } else {
                    val uRow = ByteArray(width / 2)
                    for (rowIdx in 0 until uvHeight) {
                        uBuffer.position(uvRowStride * rowIdx)
                        uBuffer.get(uRow, 0, width / 2)
                        inputBuffer.put(uRow)
                    }
                }
                val vRowStride = vPlane.rowStride
                if (vRowStride == width / 2) {
                    val vData = ByteArray(uvSize)
                    vBuffer.get(vData)
                    inputBuffer.put(vData)
                } else {
                    val vRow = ByteArray(width / 2)
                    for (rowIdx in 0 until uvHeight) {
                        vBuffer.position(vRowStride * rowIdx)
                        vBuffer.get(vRow, 0, width / 2)
                        inputBuffer.put(vRow)
                    }
                }
            }

            val totalSize = inputBuffer.position()
            codec.queueInputBuffer(inputIndex, 0, totalSize, presentationTimeUs, 0)

            if (frameCount % 30 == 0L) {
                android.util.Log.d("VideoEncoder", "Frame #$frameCount queued: $totalSize bytes (${width}x${height})")
            }
            frameCount++
        } catch (e: Exception) {
            android.util.Log.e("VideoEncoder", "Failed to encode frame: ${e.message}", e)
            onEncoderError?.invoke("Frame encoding error: ${e.message}")
        }
    }

    private fun startEncodingThread() {
        Thread {
            val codec = mediaCodec ?: return@Thread
            val bufferInfo = MediaCodec.BufferInfo()
            var frameCount = 0

            android.util.Log.i("VideoEncoder", "Encoding thread started, waiting for frames...")

            while (codec != null) {
                try {
                    val outputBufferId = codec.dequeueOutputBuffer(bufferInfo, 100)
                    if (outputBufferId >= 0 || outputBufferId == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        android.util.Log.d("VideoEncoder", "Got output: $outputBufferId")
                    }

                    when {
                        outputBufferId >= 0 -> {
                            frameCount++
                            val encodedData = ByteArray(bufferInfo.size)
                            codec.getOutputBuffer(outputBufferId)?.get(encodedData)
                            codec.releaseOutputBuffer(outputBufferId, false)

                            if (frameCount % 30 == 0) {
                                android.util.Log.d("VideoEncoder", "Frame #$frameCount: ${bufferInfo.size} bytes")
                            }

                            onEncodedFrame?.invoke(encodedData, bufferInfo.presentationTimeUs, bufferInfo.flags)
                        }
                        outputBufferId == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            android.util.Log.i("VideoEncoder", "Output format changed")
                            val newFormat = codec.outputFormat
                            onFormatChanged?.invoke(newFormat)
                        }
                        outputBufferId == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                            // Timeout waiting for output
                        }
                    }
                } catch (e: Exception) {
                    android.util.Log.e("VideoEncoder", "Encoding error: ${e.message}", e)
                    onEncoderError?.invoke("Encoding error: ${e.message}")
                    break
                }
            }
            android.util.Log.i("VideoEncoder", "Encoding thread stopped after $frameCount frames")
        }.apply { isDaemon = true }.start()
    }

    fun stop() {
        try {
            mediaCodec?.let {
                it.signalEndOfInputStream()
                it.stop()
                it.release()
            }
            mediaCodec = null
        } catch (e: Exception) {
            onEncoderError?.invoke("Failed to stop encoder: ${e.message}")
        }
    }

    fun setBitrate(newBitrateBps: Int) {
        // Bitrate update via setParameters is only available on API 33+
        // For now, this is a placeholder
        android.util.Log.i("VideoEncoder", "Bitrate update requested: $newBitrateBps bps")
    }
}
