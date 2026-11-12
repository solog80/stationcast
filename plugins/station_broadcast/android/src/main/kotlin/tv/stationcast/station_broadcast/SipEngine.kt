package tv.stationcast.station_broadcast

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import org.pjsip.pjsua2.Account
import org.pjsip.pjsua2.AccountConfig
import org.pjsip.pjsua2.AudDevManager
import org.pjsip.pjsua2.AudioMedia
import org.pjsip.pjsua2.AudioMediaPort
import org.pjsip.pjsua2.AuthCredInfo
import org.pjsip.pjsua2.Call
import org.pjsip.pjsua2.CallOpParam
import org.pjsip.pjsua2.Endpoint
import org.pjsip.pjsua2.EpConfig
import org.pjsip.pjsua2.LogEntry
import org.pjsip.pjsua2.LogWriter
import org.pjsip.pjsua2.MediaFormatAudio
import org.pjsip.pjsua2.MediaFrame
import org.pjsip.pjsua2.OnCallMediaStateParam
import org.pjsip.pjsua2.OnCallStateParam
import org.pjsip.pjsua2.OnIncomingCallParam
import org.pjsip.pjsua2.OnRegStateParam
import org.pjsip.pjsua2.TransportConfig
import org.pjsip.pjsua2.pj_qos_type
import org.pjsip.pjsua2.pjmedia_type
import org.pjsip.pjsua2.pjsip_inv_state
import org.pjsip.pjsua2.pjsip_role_e
import org.pjsip.pjsua2.pjsip_status_code
import org.pjsip.pjsua2.pjsip_transport_type_e
import org.pjsip.pjsua2.pjsua_call_media_status
import java.util.concurrent.ArrayBlockingQueue

/**
 * EBU 3326 / SIP radio engine for StationCast (pjsua2 / PJSIP 2.15.1).
 *
 * Registers a single account to the studio Asterisk registrar and handles the
 * studio console calling IN. Audio-only, no video. The Dart side drives it via
 * the `tv.stationcast/sip` method channel and receives call-state + stats on the
 * `/sip/events` and `/sip/stats` event channels.
 *
 * Threading model (matches pjsua2 requirements): a dedicated worker thread owns
 * the Endpoint. All API calls marshal through [exec]; callbacks from pjsip
 * arrive on library threads and only touch thread-safe state or post to the
 * main handler. Without this, pjsua2 corrupts internal state and crashes.
 */
class SipEngine(private val appContext: Context) {

  private data class Five<A, B, C, D, E>(val a: A, val b: B, val c: C, val d: D, val e: E)

  interface Listener {
    fun onEvent(state: String, peer: String?, message: String?)
    fun onStats(stats: Map<String, Any?>)
  }

  @Volatile var listener: Listener? = null
  @Volatile var isInitialized: Boolean = false
    private set

  private val worker = HandlerThread("SipEngineWorker").apply { start() }
  private val workerHandler = Handler(worker.looper)
  private val mainHandler = Handler(Looper.getMainLooper())

  private var ep: Endpoint? = null
  private var logWriter: LogWriter? = null
  private var account: RadioAccount? = null
  private var call: RadioCall? = null
  private var currentCodec: String = "OPUS"
  @Volatile private var preferredAudioDeviceId: String? = null
  private var callAudioMedia: AudioMedia? = null
  private var duckLevel = 1.0f
  private var lastAppliedDuckLevel = -1.0f
  private var lastMicActiveAt = 0L
  private var statsRunnable: Runnable? = null
  private var levelRunnable: Runnable? = null
  private val errorCodeOk = 0

  private external fun nativeInitOpus(
    sampleRate: Int,
    bitRate: Int,
    complexity: Int,
    cbr: Boolean
  ): Int

  /** Runs [block] synchronously on the worker thread that owns the Endpoint. */
  private fun <T> exec(block: () -> T): T {
    if (Thread.currentThread() == worker) return block()
    val queue = ArrayBlockingQueue<Any>(1)
    workerHandler.post {
      val res: Any = try { block() as Any } catch (t: Throwable) { t }
      queue.put(res)
    }
    val res = queue.take()
    if (res is Throwable) throw res
    @Suppress("UNCHECKED_CAST")
    return res as T
  }

  /** Runs [block] on the worker; turns a Throwable into an error event. */
  private fun onWorker(label: String, block: () -> Unit) {
    workerHandler.post {
      try { block() }
      catch (t: Throwable) {
        Log.e(TAG, "$label: ${t.message}")
        mainHandler.post { listener?.onEvent("failed", null, t.message) }
      }
    }
  }

  private fun onMain(state: String, peer: String? = null, message: String? = null) {
    mainHandler.post { listener?.onEvent(state, peer, message) }
  }

  // ------------------------------------------------------------- lifecycle --

  /** Create + start the endpoint. Safe to call once; no registration yet. */
  fun initialize() {
    onWorker("initialize") { initializeLocked() }
  }

  /** Tear down the endpoint and its worker. */
  fun dispose() {
    exec {
      if (!isInitialized) return@exec
      stopStats()
      try {
        account?.setRegistration(false)
      } catch (_: Throwable) {}
      try {
        account?.delete()
      } catch (_: Throwable) {}
      account = null
      call = null
      ep?.libDestroy()
      ep?.delete()
      ep = null
      isInitialized = false
    }
    workerHandler.post { worker.quitSafely() }
  }

  // ------------------------------------------------------------- register --

  /**
   * Register as the given extension to the studio registrar.
   * args: registrarHost, registrarPort, username, password, extension, codec, autoAnswer
   *
   * Idempotent: any existing account is unregistered + deleted first and the
   * whole operation runs inside one worker task, so repeated calls from the UI
   * (reconnect/retry) can never stack up multiple live pjsua2 accounts (which
   * abort the library with SIGABRT in Account.create).
   */
  fun register(args: Map<*, *>) {
    val host = args["registrarHost"] as? String ?: ""
    val port = (args["registrarPort"] as? Number)?.toInt() ?: 5060
    val user = args["username"] as? String ?: ""
    val pass = args["password"] as? String ?: ""
    val ext = (args["extension"] as? String)?.takeIf { it.isNotEmpty() } ?: user
    currentCodec = codecLabel(args["codec"] as? String)
    onMain("registering")

    onWorker("register") {
      initializeLocked()
      stopStats()
      call = null
      // Tear down any previous account first.
      try { account?.setRegistration(false) } catch (_: Throwable) {}
      try { account?.delete() } catch (_: Throwable) {}
      account = null

      val endpoint = ep ?: return@onWorker
      val cfg = AccountConfig()
      val hostPort = "$host:$port"
      val sipHostPort = if (host.contains(":")) host else hostPort
      cfg.idUri = "\"StationCast Field\" <sip:$ext@$sipHostPort>"
      cfg.regConfig.registrarUri = "sip:$hostPort"
      cfg.regConfig.timeoutSec = 3600
      cfg.regConfig.retryIntervalSec = 30
      cfg.sipConfig.authCreds.add(AuthCredInfo("digest", "*", ext, 0, pass))
      cfg.sipConfig.proxies.add("sip:$hostPort;lr")
      applyCodecPriorities()
      val acc = RadioAccount()
      acc.create(cfg)
      account = acc
      Log.i(TAG, "registered request sent: $ext@$hostPort")
    }
  }

  /** Ensure the endpoint exists; safe to call while already on the worker. */
  private fun initializeLocked() {
    if (isInitialized) return
    val endpoint = Endpoint()
    endpoint.libCreate()
    val cfg = EpConfig()
    cfg.logConfig.level = 4
    cfg.logConfig.consoleLevel = 0
    logWriter = object : LogWriter() {
      override fun write(entry: LogEntry) {
        Log.i(TAG, entry.msg.trimEnd())
      }
    }
    cfg.logConfig.writer = logWriter
    cfg.uaConfig.userAgent = "StationCast-Radio"
    cfg.uaConfig.maxCalls = 2L
    cfg.medConfig.clockRate = 48000L
    cfg.medConfig.sndClockRate = 48000L
    cfg.medConfig.quality = 10L
    // Disable PJSIP software echo canceller/noise suppressor and VAD so vocal
    // harmonics are not colored by telephony voice processing.
    cfg.medConfig.ecTailLen = 0L
    cfg.medConfig.noVad = true
    // Mobile links are bursty; a larger adaptive jitter buffer avoids
    // robotic/PLC artifacts at the cost of a little latency.
    cfg.medConfig.jbInit = 200
    cfg.medConfig.jbMinPre = 100
    cfg.medConfig.jbMaxPre = 400
    cfg.medConfig.jbMax = 500
    endpoint.libInit(cfg)
    try {
      val rc = nativeInitOpus(48000, 128000, 10, true)
      Log.i(TAG, "Opus 48kHz 128kbps Fullband CELT broadcast codec registered (rc=$rc)")
    } catch (t: Throwable) {
      Log.e(TAG, "nativeInitOpus failed: ${t.message}")
    }
    val udp = TransportConfig()
    udp.qosType = pj_qos_type.PJ_QOS_TYPE_VOICE
    endpoint.transportCreate(pjsip_transport_type_e.PJSIP_TRANSPORT_UDP, udp)
    endpoint.libStart()
    try { endpoint.libRegisterThread("SipEngineWorker") } catch (_: Throwable) {}
    ep = endpoint
    isInitialized = true
    Log.i(TAG, "PJSIP endpoint initialized (${endpoint.libVersion().full})")
  }

  /** Unregister and release the account (keeps endpoint alive). */
  fun unregister() {
    onWorker("unregister") {
      stopStats()
      call = null
      try {
        account?.setRegistration(false)
      } catch (_: Throwable) {}
      try {
        account?.delete()
      } catch (_: Throwable) {}
      account = null
      onMain("idle")
    }
  }

  private fun codecLabel(codec: String?): String = when (codec?.lowercase()) {
    "g722" -> "G.722"
    "pcmu" -> "G.711"
    "pcma" -> "G.711"
    else -> "OPUS" // 48kHz Fullband Opus broadcast default
  }

  /** Endpoint-wide codec priorities; preferred codec first, Opus & G.722 available. */
  private fun applyCodecPriorities() {
    val endpoint = ep ?: return
    try {
      val available = mutableListOf<String>()
      for (ci in endpoint.codecEnum2()) {
        available.add(ci.codecId)
        endpoint.codecSetPriority(ci.codecId, 0)
      }
      Log.i(TAG, "Available PJSIP codecs: $available (preferred=$currentCodec)")
      var prio: Short = 254
      val wanted = when (currentCodec) {
        "OPUS" -> listOf("opus/48000/2", "opus/48000", "G722/16000/1", "G722/16000", "PCMA/8000/1", "PCMU/8000/1")
        "G.711" -> listOf("PCMU/8000/1", "PCMU/8000", "PCMA/8000/1", "PCMA/8000", "opus/48000/2", "G722/16000/1")
        else -> listOf("G722/16000/1", "G722/16000", "opus/48000/2", "opus/48000", "PCMA/8000/1", "PCMU/8000/1")
      }
      for (id in wanted) {
        try { endpoint.codecSetPriority(id, prio); prio = (prio - 1).toShort() } catch (_: Throwable) {}
      }
      try { endpoint.codecSetPriority("telephone-event/8000", 200.toShort()) } catch (_: Throwable) {}
    } catch (t: Throwable) { Log.w(TAG, "codec priorities: ${t.message}") }
  }

  // ----------------------------------------------------------------- calls --

  /** Answer the ringing call with 200 OK and connect audio. */
  fun accept() {
    onWorker("accept") {
      val c = call ?: return@onWorker
      val prm = CallOpParam()
      prm.statusCode = pjsip_status_code.PJSIP_SC_OK
      prm.opt.audioCount = 1
      c.answer(prm)
      onMain("connecting")
    }
  }

  /** Decline the ringing call. */
  fun decline() {
    onWorker("decline") {
      val c = call ?: return@onWorker
      val prm = CallOpParam()
      prm.statusCode = pjsip_status_code.PJSIP_SC_DECLINE
      try { c.hangup(prm) } catch (_: Throwable) {}
      call = null
      onMain("registered")
    }
  }

  /** Hang up the active call. */
  fun hangup() {
    onWorker("hangup") {
      val c = call ?: return@onWorker
      try { c.hangup(CallOpParam()) } catch (_: Throwable) {}
      call = null
      stopStats()
      teardownVuTaps()
      onMain("ended")
      onMain("registered")
    }
  }

  /**
   * Place an outbound call (field phone -> studio Comrex). [target] is the SIP
   * URI to dial, e.g. "100" (routed via the registered account/proxy) or a full
   * "sip:100@host". Emits "connecting" immediately; "live" once CONFIRMED.
   */
  fun dial(target: String) {
    onWorker("dial") {
      val acc = account ?: return@onWorker
      val t = target.trim()
      if (t.isEmpty()) return@onWorker
      val uri = if (t.startsWith("sip:", ignoreCase = true)) t else "sip:$t"
      val newCall = RadioCall(acc, -1)
      val prm = CallOpParam(true) // call.opt = true -> use default settings
      prm.opt.audioCount = 1
      prm.opt.videoCount = 0L
      newCall.makeCall(uri, prm)
      val id = try { newCall.info.id } catch (_: Throwable) { 0 }
      newCall.wireId = id
      call = newCall
      Log.i(TAG, "outbound call to $uri")
      onMain("connecting")
    }
  }

  // ----------------------------------------------------------- stats loop --

  /** Full stats ~1 Hz while a call is live (codec + RTCP + levels). */
  private fun startStats() {
    stopStats()
    val full = object : Runnable {
      override fun run() {
        if (call == null || !isInitialized) return
        // pjsua2 calls MUST run on this registered worker thread.
        val stats = buildStats()
        mainHandler.post { listener?.onStats(stats) }
        workerHandler.postDelayed(this, 1000)
      }
    }
    // Real-time audio levels at ~15 Hz so meters look live, not staged.
    val level = object : Runnable {
      override fun run() {
        if (call == null || !isInitialized) return
        applyDucking()
        val partial = levelPartial()
        mainHandler.post { listener?.onStats(partial) }
        workerHandler.postDelayed(this, 66)
      }
    }
    statsRunnable = full
    levelRunnable = level
    workerHandler.postDelayed(full, 300)
    workerHandler.postDelayed(level, 50)
  }

  private fun stopStats() {
    statsRunnable?.let { workerHandler.removeCallbacks(it) }
    statsRunnable = null
    levelRunnable?.let { workerHandler.removeCallbacks(it) }
    levelRunnable = null
  }

  private fun activeStreamCodec(): String {
    val c = call ?: return currentCodec
    return try {
      val name = c.getStreamInfo(0L).codecName.uppercase()
      when {
        name.contains("OPUS") -> "OPUS"
        name.contains("G722") -> "G.722"
        name.contains("PCMU") || name.contains("PCMA") -> "G.711"
        name.isNotEmpty() -> name
        else -> currentCodec
      }
    } catch (_: Throwable) {
      currentCodec
    }
  }

  private fun buildStats(): Map<String, Any?> {
    val (txDb, rxDb) = currentLevels()
    val (txBytes, rxBytes, rtt, jitter, lost) = getCallRtcpFull()
    return mapOf(
      "jitterMs" to jitter,
      "rttMs" to rtt,
      "packetsLost" to lost,
      "txPayloadBytes" to txBytes,
      "rxPayloadBytes" to rxBytes,
      "codec" to activeStreamCodec(),
      "audioLevelDb" to listOf(txDb, txDb),
      "rxAudioLevelDb" to listOf(rxDb, rxDb),
    )
  }

  // Real-time audio levels at ~15 Hz read from decoded PCM taps.
  private fun levelPartial(): Map<String, Any?> {
    val (txDb, rxDb) = currentLevels()
    return mapOf(
      "jitterMs" to 0.0,
      "rttMs" to 0.0,
      "packetsLost" to 0,
      "txPayloadBytes" to 0,
      "rxPayloadBytes" to 0,
      "codec" to "",
      "audioLevelDb" to listOf(txDb, txDb),
      "rxAudioLevelDb" to listOf(rxDb, rxDb),
    )
  }

  // ---- Decoded PCM VU taps ---------------------------------------------
  private var vuTx: VuTap? = null
  private var vuRx: VuTap? = null

  /** Receives 16-bit PCM (bytes) and keeps a smoothed RMS level in dBFS. */
  private inner class VuTap(name: String) : AudioMediaPort() {
    @Volatile var levelDb: Double = -60.0
      private set
    private val tag = name

    override fun onFrameReceived(frame: MediaFrame) {
      try {
        val buf = frame.buf ?: return
        val size = buf.size
        if (size < 2) return
        var sum = 0.0
        var n = 0
        var i = 0
        // MediaFrame.buf is bytes; each PCM16 sample = 2 little-endian bytes.
        while (i + 1 < size) {
          val lo = buf.get(i).toInt() and 0xFF
          val hi = buf.get(i + 1).toInt() and 0xFF
          val s = (lo or (hi shl 8)).toShort().toInt()
          sum += (s * s).toDouble()
          n++
          i += 32 // sample every 16th PCM16 sample (60 samples/frame) to minimize JNI overhead
        }
        if (n == 0) return
        val rms = kotlin.math.sqrt(sum / n)
        val norm = (rms / 32768.0).coerceIn(0.0, 1.0)
        val dbfs = if (norm > 0.001) {
          (20.0 * kotlin.math.log10(norm)).coerceIn(-60.0, 0.0)
        } else {
          -60.0
        }
        // Instant attack + 26 dB/s decay (0.52 dB per 20ms frame), matching AudioMeterBallistics
        val decayed = (levelDb - 0.52).coerceAtLeast(-60.0)
        levelDb = if (dbfs >= decayed) dbfs else decayed
      } catch (_: Throwable) {}
    }
  }

  /** Create a tap and register it in the conference so it receives real audio. */
  private fun createVuTap(name: String): VuTap {
    val t = VuTap(name)
    try {
      val fmt = MediaFormatAudio()
      fmt.type = pjmedia_type.PJMEDIA_TYPE_AUDIO.toInt()
      fmt.clockRate = 48000
      fmt.channelCount = 1
      fmt.bitsPerSample = 16
      fmt.frameTimeUsec = 20000
      t.createPort(name, fmt)
    } catch (e: Throwable) { Log.w(TAG, "$name createPort: ${e.message}") }
    try { ep?.mediaAdd(t) } catch (e: Throwable) { Log.w(TAG, "$name mediaAdd: ${e.message}") }
    return t
  }

  /** Wire taps to the call: TX from mic(capture), RX from call decoded audio. */
  private fun wireVuTaps(adm: AudDevManager, callAudio: AudioMedia) {
    if (vuTx == null) {
      val t = createVuTap("vuTx")
      vuTx = t
      try { adm.captureDevMedia.startTransmit(t) } catch (e: Throwable) { Log.w(TAG, "vuTx startTransmit: ${e.message}") }
    }
    if (vuRx == null) {
      val t = createVuTap("vuRx")
      vuRx = t
      try { callAudio.startTransmit(t) } catch (e: Throwable) { Log.w(TAG, "vuRx startTransmit: ${e.message}") }
    }
  }

  private fun teardownVuTaps() {
    resetDucking()
    configureAudioOutput(false)
    try {
      val adm = ep?.audDevManager() ?: return
      vuTx?.let {
        try { adm.captureDevMedia.stopTransmit(it) } catch (_: Throwable) {}
        try { ep?.mediaRemove(it) } catch (_: Throwable) {}
        it.delete()
      }
      vuRx?.let {
        try { ep?.mediaRemove(it) } catch (_: Throwable) {}
        it.delete()
      }
    } catch (_: Throwable) {}
    vuTx = null
    vuRx = null
  }

  /** Current smoothed TX/RX levels (-60..0). Called on the worker thread. */
  private fun currentLevels(): Pair<Double, Double> {
    val tx = vuTx?.levelDb ?: -60.0
    val rx = vuRx?.levelDb ?: -60.0
    return Pair(tx, rx)
  }

  /**
   * Lower the call's RX level (what we hear) while the local mic is active.
   * The call's TX path is untouched, so the studio still receives the full mic.
   */
  private fun applyDucking() {
    val audio = callAudioMedia ?: return
    val micDb = vuTx?.levelDb ?: -60.0
    val now = SystemClock.elapsedRealtime()

    if (micDb >= DUCK_START_DB) {
      lastMicActiveAt = now
    }
    val holding = now - lastMicActiveAt <= DUCK_HOLD_MS
    val talking = micDb >= DUCK_STOP_DB && (micDb >= DUCK_START_DB || holding)
    val target = if (talking) DUCK_LEVEL else 1.0f

    val next = if (target < duckLevel) {
      (duckLevel - DUCK_ATTACK_STEP).coerceAtLeast(target)
    } else {
      (duckLevel + DUCK_RELEASE_STEP).coerceAtMost(target)
    }
    duckLevel = next

    val delta = next - lastAppliedDuckLevel
    if (delta >= 0.005f || delta <= -0.005f) {
      try {
        audio.adjustRxLevel(next)
        lastAppliedDuckLevel = next
      } catch (t: Throwable) {
        Log.w(TAG, "duck adjustRxLevel: ${t.message}")
      }
    }
  }

  private fun resetDucking() {
    val audio = callAudioMedia
    callAudioMedia = null
    duckLevel = 1.0f
    lastAppliedDuckLevel = -1.0f
    lastMicActiveAt = 0L
    try { audio?.adjustRxLevel(1.0f) } catch (_: Throwable) {}
  }

  private fun getCallRtcpFull(): Five<Long, Long, Double, Double, Int> {
    return try {
      val c = call ?: return Five(0, 0, 0.0, 0.0, 0)
      val stat = c.getStreamStat(0L)
      val rtcp = stat.rtcp
      val txBytes = rtcp.txStat.bytes
      val rxBytes = rtcp.rxStat.bytes
      val rtt = rtcp.rttUsec.mean / 1000.0 // us -> ms
      val jitter = rtcp.rxRawJitterUsec.mean / 1000.0
      val lost = rtcp.rxStat.loss.toInt()
      Five(
        txBytes,
        rxBytes,
        if (rtt.isNaN()) 0.0 else rtt,
        if (jitter.isNaN()) 0.0 else jitter,
        lost
      )
    } catch (_: Throwable) { Five(0, 0, 0.0, 0.0, 0) }
  }

  // ------------------------------------------------------------- pjsua2 subclasses --

  /** Account that surfaces registration state and hands calls to [RadioCall]. */
  private inner class RadioAccount : Account() {
    override fun onRegState(prm: OnRegStateParam) {
      val code = prm.code
      val ok = code / 100 == 2
      Log.i(TAG, "onRegState code=$code ${prm.reason}")
      if (ok) onMain("registered")
      else onMain("failed", null, "Registration failed ($code ${prm.reason})")
    }

    override fun onIncomingCall(prm: OnIncomingCallParam) {
      // Construct the call and marshal pjsua2 work to the worker thread.
      workerHandler.post {
        val newCall = RadioCall(this, prm.callId)
        newCall.wireId = prm.callId
        call = newCall
        // Extract the caller display/URI ("STUDIO LIVE").
        val peer = try {
          val ci = newCall.info
          ci.remoteUri
        } catch (_: Throwable) { "" }
        // Send 180 Ringing so the studio hears ringback while we alert the user.
        try {
          val opPrm = CallOpParam()
          opPrm.statusCode = pjsip_status_code.PJSIP_SC_RINGING
          newCall.answer(opPrm)
        } catch (_: Throwable) {}
        Log.i(TAG, "incoming call from $peer")
        onMain("ringing", peer)
      }
    }
  }

  /** Call that reports lifecycle + connects audio once media is active. */
  private inner class RadioCall(acc: RadioAccount, callId: Int) : Call(acc, callId) {
    var wireId: Int = -1
    private var wasConnected = false
    private var wasDisconnected = false

    override fun onCallState(prm: OnCallStateParam) {
      // Marshal onto the registered worker thread: pjsip callback threads are
      // not pj_thread-registered, and calling into pjsua2 (info/startTransmit/
      // delete) from them aborts pjlib.
      workerHandler.post {
        val state = try { info.state } catch (_: Throwable) { return@post }
        when (state) {
          pjsip_inv_state.PJSIP_INV_STATE_CONFIRMED -> {
            if (!wasConnected) {
              wasConnected = true
              val peer = try { info.remoteUri } catch (_: Throwable) { "" }
              Log.i(TAG, "call confirmed (live)")
              startStats()
              onMain("live", peer)
            }
          }
          pjsip_inv_state.PJSIP_INV_STATE_DISCONNECTED -> {
            if (!wasDisconnected) {
              wasDisconnected = true
              Log.i(TAG, "call disconnected")
              stopStats()
              teardownVuTaps()
              onMain("ended")
              onMain("registered")
            }
            // pjsua2 requires explicit deletion once a call finishes.
            workerHandler.post { try { delete() } catch (_: Throwable) {} }
          }
          else -> {}
        }
      }
    }

    override fun onCallMediaState(prm: OnCallMediaStateParam) {
      // IMPORTANT: this callback fires on an unregistered pjsip thread.
      // Calling pjsua2 (getMedia/audDevManager/startTransmit) here aborts with
      // "pj_thread_this(): Calling pjlib from unknown/external thread". Marshal
      // the media wiring onto the worker thread that owns the endpoint.
      workerHandler.post {
        try {
          val ci = info
          for (i in 0 until ci.media.size) {
            val mi = ci.media[i.toInt()]
            Log.i(TAG, "media[$i] type=${mi.type} status=${mi.status}")
            if (mi.type == pjmedia_type.PJMEDIA_TYPE_AUDIO &&
                mi.status == pjsua_call_media_status.PJSUA_CALL_MEDIA_ACTIVE) {
              val aud = AudioMedia.typecastFromMedia(getMedia(i.toLong()))
              if (aud == null) { Log.w(TAG, "media[$i] no AudioMedia"); continue }
              callAudioMedia = aud
              duckLevel = 1.0f
              lastAppliedDuckLevel = -1.0f
              lastMicActiveAt = 0L
              try { aud.adjustRxLevel(1.0f) } catch (_: Throwable) {}
              val adm: AudDevManager = ep!!.audDevManager()
              configureAudioOutput(true)
              try { aud.startTransmit(adm.playbackDevMedia) } catch (t: Throwable) { Log.w(TAG, "tx->playback: ${t.message}") }
              try { adm.captureDevMedia.startTransmit(aud) } catch (t: Throwable) { Log.w(TAG, "capture->tx: ${t.message}") }
              wireVuTaps(adm, aud)
              Log.i(TAG, "audio connected (bidirectional)")
            }
          }
        } catch (t: Throwable) {
          Log.w(TAG, "connectAudio: ${t.message}")
        }
      }
    }
  }

  fun setPreferredAudioDeviceId(id: String?) {
    preferredAudioDeviceId = id
    if (call != null) {
      configureAudioOutput(true)
    }
  }

  /**
   * Configure Android AudioManager for fullband broadcast capture & playback.
   *
   * OpenSL ES now uses SL_ANDROID_STREAM_MEDIA (STREAM_MUSIC) for playback and
   * SL_ANDROID_RECORDING_PRESET_VOICE_RECOGNITION for capture. Keeping the
   * phone in MODE_NORMAL (unless a Bluetooth SCO/BLE hands-free headset is
   * active) prevents Android/Samsung HALs from engaging telephony voice-call
   * guard mode (l_guard_call_mode=3) and switching the microphone from the
   * primary bottom mic (BUILTIN_MIC) to the rear camera pinhole mic (BACK_MIC).
   */
  private fun configureAudioOutput(active: Boolean) {
    try {
      val am = appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
      if (!active) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
          try { am.clearCommunicationDevice() } catch (_: Throwable) {}
        }
        @Suppress("DEPRECATION")
        am.isSpeakerphoneOn = false
        am.mode = AudioManager.MODE_NORMAL
        return
      }

      val maxVol = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
      val curVol = am.getStreamVolume(AudioManager.STREAM_MUSIC)
      val minTarget = (maxVol * 0.65).toInt().coerceAtLeast(1)
      if (curVol < minTarget) {
        am.setStreamVolume(AudioManager.STREAM_MUSIC, minTarget, 0)
      }

      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        val devs = am.availableCommunicationDevices
        val prefId = preferredAudioDeviceId
        val selectedInput = if (prefId != null) {
          am.getDevices(AudioManager.GET_DEVICES_INPUTS).firstOrNull { it.id.toString() == prefId }
        } else null

        // If user explicitly selected built-in mic, keep MODE_NORMAL and clear communication device
        if (selectedInput != null && selectedInput.type == AudioDeviceInfo.TYPE_BUILTIN_MIC) {
          try { am.clearCommunicationDevice() } catch (_: Throwable) {}
          @Suppress("DEPRECATION")
          am.isSpeakerphoneOn = false
          am.mode = AudioManager.MODE_NORMAL
          Log.i(TAG, "AudioManager forced to BUILTIN_MIC (${selectedInput.productName}) in MODE_NORMAL")
          return
        }

        // If user explicitly selected an external communication device (BT/USB/Wired)
        val explicitCommDev = if (prefId != null) {
          devs.firstOrNull {
            it.id.toString() == prefId ||
            (selectedInput != null && sameAudioFamily(it.type, selectedInput.type))
          }
        } else null

        val selectedIsBluetooth = selectedInput != null &&
          (selectedInput.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
           selectedInput.type == AudioDeviceInfo.TYPE_BLE_HEADSET)

        // USB/wired mics must not force Android into telephony/HFP mode.
        // Keeping MODE_NORMAL preserves the media/A2DP output (e.g. Bluetooth
        // headphones for RX) while still selecting the USB capture device.
        if (selectedInput != null && !selectedIsBluetooth) {
          @Suppress("DEPRECATION")
          am.isSpeakerphoneOn = false
          am.mode = AudioManager.MODE_NORMAL
          if (explicitCommDev != null) {
            val ok = am.setCommunicationDevice(explicitCommDev)
            Log.i(TAG, "AudioManager USB/wired input -> ${explicitCommDev.productName} (type=${explicitCommDev.type}, ok=$ok, MODE_NORMAL)")
          } else {
            Log.w(TAG, "No communication output for ${selectedInput.productName}; keeping media route")
          }
          return
        }

        // Bluetooth input genuinely needs the communication/SCO path.
        val commDev = explicitCommDev ?: if (selectedInput == null && prefId == null) {
          devs.firstOrNull {
            it.type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
            it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO
          }
        } else null
        if (commDev != null) {
          am.mode = AudioManager.MODE_IN_COMMUNICATION
          val ok = am.setCommunicationDevice(commDev)
          Log.i(TAG, "AudioManager communication device -> ${commDev.productName} (type=${commDev.type}, ok=$ok)")
        } else if (prefId == null) {
          try { am.clearCommunicationDevice() } catch (_: Throwable) {}
          @Suppress("DEPRECATION")
          am.isSpeakerphoneOn = false
          am.mode = AudioManager.MODE_NORMAL
          Log.i(TAG, "AudioManager set to MODE_NORMAL (broadcast media routing, primary BUILTIN_MIC)")
        } else {
          // Keep the current route rather than dropping the headset when the
          // selected input has no matching communication output.
          Log.w(TAG, "No communication device for selected input ${selectedInput?.productName}; keeping current route")
        }
      } else {
        @Suppress("DEPRECATION")
        am.isSpeakerphoneOn = false
        am.mode = AudioManager.MODE_NORMAL
      }
    } catch (t: Throwable) {
      Log.w(TAG, "configureAudioOutput($active): ${t.message}")
    }
  }

  private fun sameAudioFamily(a: Int, b: Int): Boolean {
    if (a == b) return true
    fun family(type: Int): Int = when (type) {
      AudioDeviceInfo.TYPE_USB_DEVICE,
      AudioDeviceInfo.TYPE_USB_HEADSET,
      AudioDeviceInfo.TYPE_USB_ACCESSORY -> 1
      AudioDeviceInfo.TYPE_WIRED_HEADSET,
      AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> 2
      AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
      AudioDeviceInfo.TYPE_BLE_HEADSET -> 3
      else -> type
    }
    return family(a) == family(b)
  }

  companion object {
    private const val TAG = "StationCastSip"
    private const val DUCK_START_DB = -30.0
    private const val DUCK_STOP_DB = -38.0
    private const val DUCK_HOLD_MS = 250L
    private const val DUCK_LEVEL = 0.55f
    private const val DUCK_ATTACK_STEP = 0.15f
    private const val DUCK_RELEASE_STEP = 0.06f

    init {
      try {
        System.loadLibrary("openh264")
      } catch (_: Throwable) {}
      try {
        System.loadLibrary("pjsua2")
        System.loadLibrary("station_opus")
      } catch (t: Throwable) {
        Log.e(TAG, "Failed to load station_opus JNI library: ${t.message}")
      }
    }
  }
}
