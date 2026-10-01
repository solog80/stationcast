package tv.stationcast.station_broadcast

import android.content.Context
import android.util.Log
import kotlinx.coroutines.*
import org.webrtc.*
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.coroutines.suspendCoroutine

/**
 * Native WHIP (WebRTC-HTTP Ingestion Protocol) engine for Android.
 * Handles WebRTC PeerConnection setup, camera/mic capture, SDP offer creation,
 * HTTP POST exchange with WHIP server (e.g. OvenMediaEngine), and session teardown.
 */
class WhipEngine(private val context: Context) {

    private val tag = "[WhipEngine]"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    var onEvent: ((String, String?) -> Unit)? = null
    var onStats: ((Map<String, Any?>) -> Unit)? = null

    private var rootEglBase: EglBase? = null
    private var peerConnectionFactory: PeerConnectionFactory? = null
    private var peerConnection: PeerConnection? = null

    private var videoCapturer: VideoCapturer? = null
    private var surfaceTextureHelper: SurfaceTextureHelper? = null
    private var videoSource: VideoSource? = null
    private var videoTrack: VideoTrack? = null

    private var audioSource: AudioSource? = null
    private var audioTrack: AudioTrack? = null

    private var resourceUrl: String? = null
    private var isStreaming = false
    private var statsJob: Job? = null

    var activePreviewSurface: android.view.Surface? = null

    fun setPreviewSurface(surface: android.view.Surface?) {
        activePreviewSurface = surface
    }

    init {
        initWebRtcFactory()
    }

    private fun initWebRtcFactory() {
        try {
            rootEglBase = EglBase.create()
            val initOptions = PeerConnectionFactory.InitializationOptions.builder(context)
                .setEnableInternalTracer(true)
                .createInitializationOptions()
            PeerConnectionFactory.initialize(initOptions)

            val encoderFactory = DefaultVideoEncoderFactory(
                rootEglBase?.eglBaseContext,
                /* enableIntelVp8Encoder */ true,
                /* enableH264HighProfile */ true
            )
            val decoderFactory = DefaultVideoDecoderFactory(rootEglBase?.eglBaseContext)

            peerConnectionFactory = PeerConnectionFactory.builder()
                .setVideoEncoderFactory(encoderFactory)
                .setVideoDecoderFactory(decoderFactory)
                .setOptions(PeerConnectionFactory.Options())
                .createPeerConnectionFactory()

            Log.d(tag, "WebRTC PeerConnectionFactory initialized successfully")
        } catch (e: Exception) {
            Log.e(tag, "Failed to initialize WebRTC PeerConnectionFactory: ${e.message}", e)
        }
    }

    /**
     * Start WebRTC WHIP streaming to the specified WHIP URL endpoint.
     */
    fun startWhipStream(
        whipUrl: String,
        width: Int = 1280,
        height: Int = 720,
        fps: Int = 30,
        bitrateBps: Int = 3_000_000
    ) {
        scope.launch {
            try {
                if (isStreaming) {
                    stopWhipStream()
                }

                emitEvent("connecting", "Initializing WHIP session")
                val factory = peerConnectionFactory ?: throw IllegalStateException("PeerConnectionFactory not initialized")

                // 1. Audio Track Setup
                val audioConstraints = MediaConstraints().apply {
                    mandatory.add(MediaConstraints.KeyValuePair("googEchoCancellation", "true"))
                    mandatory.add(MediaConstraints.KeyValuePair("googAutoGainControl", "true"))
                    mandatory.add(MediaConstraints.KeyValuePair("googHighpassFilter", "true"))
                    mandatory.add(MediaConstraints.KeyValuePair("googNoiseSuppression", "true"))
                }
                audioSource = factory.createAudioSource(audioConstraints)
                audioTrack = factory.createAudioTrack("audio_track_0", audioSource)

                // 2. Video Track Setup
                videoCapturer = createCameraCapturer()
                if (videoCapturer != null) {
                    surfaceTextureHelper = SurfaceTextureHelper.create("WebRtcThread", rootEglBase?.eglBaseContext)
                    videoSource = factory.createVideoSource(videoCapturer!!.isScreencast)
                    videoCapturer!!.initialize(surfaceTextureHelper, context, videoSource!!.capturerObserver)
                    videoCapturer!!.startCapture(width, height, fps)

                    videoTrack = factory.createVideoTrack("video_track_0", videoSource)
                } else {
                    Log.w(tag, "No camera capturer available, streaming audio only")
                }

                // 3. Create PeerConnection
                val iceServers = listOf(
                    PeerConnection.IceServer.builder("stun:stun.l.google.com:19302").createIceServer()
                )
                val rtcConfig = PeerConnection.RTCConfiguration(iceServers).apply {
                    sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
                    continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
                }

                val pcObserver = object : PeerConnection.Observer {
                    override fun onSignalingChange(state: PeerConnection.SignalingState?) {}
                    override fun onIceConnectionChange(state: PeerConnection.IceConnectionState?) {
                        Log.d(tag, "ICE Connection State: $state")
                        if (state == PeerConnection.IceConnectionState.CONNECTED) {
                            isStreaming = true
                            emitEvent("live", "WebRTC Connected")
                            startStatsLoop()
                        } else if (state == PeerConnection.IceConnectionState.DISCONNECTED ||
                            state == PeerConnection.IceConnectionState.FAILED) {
                            emitEvent("failed", "ICE connection failed ($state)")
                        }
                    }
                    override fun onIceConnectionReceivingChange(receiving: Boolean) {}
                    override fun onIceGatheringChange(state: PeerConnection.IceGatheringState?) {}
                    override fun onIceCandidate(candidate: IceCandidate?) {}
                    override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>?) {}
                    override fun onAddStream(stream: MediaStream?) {}
                    override fun onRemoveStream(stream: MediaStream?) {}
                    override fun onDataChannel(channel: DataChannel?) {}
                    override fun onRenegotiationNeeded() {}
                }

                peerConnection = factory.createPeerConnection(rtcConfig, pcObserver)
                    ?: throw IllegalStateException("Failed to create PeerConnection")

                // Add Tracks
                audioTrack?.let { peerConnection?.addTrack(it, listOf("media_stream_0")) }
                videoTrack?.let { videoTrack ->
                    val sender = peerConnection?.addTrack(videoTrack, listOf("media_stream_0"))
                    sender?.let { s ->
                        val params = s.parameters
                        if (params.encodings.isNotEmpty()) {
                            params.encodings[0].maxBitrateBps = bitrateBps
                            s.parameters = params
                        }
                    }
                }

                // 4. Create SDP Offer
                val mediaConstraints = MediaConstraints().apply {
                    mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveAudio", "false"))
                    mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveVideo", "false"))
                }

                val offerSdp = suspendCoroutine<SessionDescription> { continuation ->
                    peerConnection?.createOffer(object : SimpleSdpObserver() {
                        override fun onCreateSuccess(sdp: SessionDescription?) {
                            if (sdp != null) {
                                continuation.resume(sdp)
                            } else {
                                continuation.resumeWithException(RuntimeException("Created SDP offer is null"))
                            }
                        }

                        override fun onCreateFailure(error: String?) {
                            continuation.resumeWithException(RuntimeException("Failed to create SDP offer: $error"))
                        }
                    }, mediaConstraints)
                }

                // Set Local Description
                suspendCoroutine<Unit> { continuation ->
                    peerConnection?.setLocalDescription(object : SimpleSdpObserver() {
                        override fun onSetSuccess() {
                            continuation.resume(Unit)
                        }

                        override fun onSetFailure(error: String?) {
                            continuation.resumeWithException(RuntimeException("Failed to set local SDP: $error"))
                        }
                    }, offerSdp)
                }

                // Wait for ICE gathering to complete or have initial candidates in SDP
                delay(300) // brief delay to allow candidate gathering into localDescription

                val currentLocalSdp = peerConnection?.localDescription?.description ?: offerSdp.description
                Log.d(tag, "Sending WHIP Offer SDP to $whipUrl:\n$currentLocalSdp")

                // 5. HTTP POST to WHIP Endpoint
                val whipResult = performWhipPost(whipUrl, currentLocalSdp)
                resourceUrl = whipResult.locationHeader

                Log.d(tag, "Received WHIP Answer SDP:\n${whipResult.answerSdp}")

                // 6. Set Remote Description
                val answerSdp = SessionDescription(SessionDescription.Type.ANSWER, whipResult.answerSdp)
                suspendCoroutine<Unit> { continuation ->
                    peerConnection?.setRemoteDescription(object : SimpleSdpObserver() {
                        override fun onSetSuccess() {
                            continuation.resume(Unit)
                        }

                        override fun onSetFailure(error: String?) {
                            continuation.resumeWithException(RuntimeException("Failed to set remote SDP: $error"))
                        }
                    }, answerSdp)
                }

                Log.d(tag, "WHIP handshake completed successfully!")

            } catch (t: Throwable) {
                Log.e(tag, "WHIP streaming failed: ${t.message}", t)
                emitEvent("failed", t.message ?: "WHIP initialization error")
                stopWhipStream()
            }
        }
    }

    private data class WhipPostResult(val answerSdp: String, val locationHeader: String?)

    private fun performWhipPost(whipUrl: String, offerSdp: String): WhipPostResult {
        val url = URL(whipUrl)
        val conn = url.openConnection() as HttpURLConnection
        try {
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.doInput = true
            conn.connectTimeout = 10000
            conn.readTimeout = 10000
            conn.setRequestProperty("Content-Type", "application/sdp")

            OutputStreamWriter(conn.outputStream, Charsets.UTF_8).use { writer ->
                writer.write(offerSdp)
                writer.flush()
            }

            val responseCode = conn.responseCode
            Log.d(tag, "WHIP HTTP Response Code: $responseCode")

            if (responseCode !in 200..299) {
                val errorMsg = try {
                    BufferedReader(InputStreamReader(conn.errorStream, Charsets.UTF_8)).readText()
                } catch (_: Exception) { "" }
                throw RuntimeException("WHIP server returned HTTP $responseCode: $errorMsg")
            }

            val location = conn.getHeaderField("Location")
            val answerSdp = BufferedReader(InputStreamReader(conn.inputStream, Charsets.UTF_8)).readText()

            val absoluteLocation = if (!location.isNullOrEmpty()) {
                if (location.startsWith("http://") || location.startsWith("https://")) {
                    location
                } else {
                    URL(url, location).toString()
                }
            } else null

            return WhipPostResult(answerSdp, absoluteLocation)
        } finally {
            conn.disconnect()
        }
    }

    /**
     * Stop WHIP stream, send HTTP DELETE to teardown session on server, and release resources.
     */
    fun stopWhipStream() {
        scope.launch {
            try {
                isStreaming = false
                statsJob?.cancel()
                statsJob = null

                // Perform WHIP HTTP DELETE teardown if Location header was provided
                resourceUrl?.let { resUrl ->
                    try {
                        Log.d(tag, "Sending WHIP DELETE to $resUrl")
                        val url = URL(resUrl)
                        val conn = url.openConnection() as HttpURLConnection
                        conn.requestMethod = "DELETE"
                        conn.connectTimeout = 5000
                        conn.readTimeout = 5000
                        val code = conn.responseCode
                        Log.d(tag, "WHIP DELETE response: $code")
                        conn.disconnect()
                    } catch (e: Exception) {
                        Log.w(tag, "WHIP DELETE teardown error: ${e.message}")
                    }
                }
                resourceUrl = null

                // Close PeerConnection & Video Capturer
                peerConnection?.close()
                peerConnection = null

                videoCapturer?.stopCapture()
                videoCapturer?.dispose()
                videoCapturer = null

                surfaceTextureHelper?.dispose()
                surfaceTextureHelper = null

                videoTrack?.dispose()
                videoTrack = null

                videoSource?.dispose()
                videoSource = null

                audioTrack?.dispose()
                audioTrack = null

                audioSource?.dispose()
                audioSource = null

                Log.d(tag, "WHIP Stream stopped and resources released")
                emitEvent("stopped", null)
            } catch (t: Throwable) {
                Log.e(tag, "Error stopping WHIP stream: ${t.message}", t)
            }
        }
    }

    private fun createCameraCapturer(): VideoCapturer? {
        val enumerator = Camera2Enumerator(context)
        val deviceNames = enumerator.deviceNames

        // Try front camera first, then back camera
        for (deviceName in deviceNames) {
            if (enumerator.isBackFacing(deviceName)) {
                return enumerator.createCapturer(deviceName, null)
            }
        }
        for (deviceName in deviceNames) {
            if (enumerator.isFrontFacing(deviceName)) {
                return enumerator.createCapturer(deviceName, null)
            }
        }
        return null
    }

    private fun startStatsLoop() {
        statsJob?.cancel()
        statsJob = scope.launch {
            while (isStreaming) {
                peerConnection?.getStats { report ->
                    var bps = 0L
                    var rtt = 0
                    var pktsSent = 0L
                    var pktsLost = 0L

                    for (stats in report.statsMap.values) {
                        if (stats.type == "outbound-rtp") {
                            val bytes = (stats.members["bytesSent"] as? Number)?.toLong() ?: 0L
                            pktsSent += (stats.members["packetsSent"] as? Number)?.toLong() ?: 0L
                            pktsLost += (stats.members["packetsLost"] as? Number)?.toLong() ?: 0L
                        } else if (stats.type == "remote-inbound-rtp") {
                            rtt = ((stats.members["roundTripTime"] as? Number)?.toDouble()?.times(1000))?.toInt() ?: 0
                        }
                    }

                    scope.launch(Dispatchers.Main) {
                        onStats?.invoke(mapOf(
                            "bitrateBps" to bps,
                            "rttMs" to rtt,
                            "packetsSent" to pktsSent,
                            "packetsDropped" to pktsLost,
                            "protocol" to "webrtc"
                        ))
                    }
                }
                delay(1000)
            }
        }
    }

    private fun emitEvent(state: String, message: String?) {
        scope.launch(Dispatchers.Main) {
            onEvent?.invoke(state, message)
        }
    }

    open class SimpleSdpObserver : SdpObserver {
        override fun onCreateSuccess(sdp: SessionDescription?) {}
        override fun onSetSuccess() {}
        override fun onCreateFailure(error: String?) {}
        override fun onSetFailure(error: String?) {}
    }
}
