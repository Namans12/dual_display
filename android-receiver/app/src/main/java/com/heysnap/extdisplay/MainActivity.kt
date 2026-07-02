package com.heysnap.extdisplay

import android.app.Activity
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.text.Editable
import android.text.InputFilter
import android.text.InputType
import android.text.TextWatcher
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.Toast
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.Window
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.security.SecureRandom
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec
import kotlin.concurrent.thread

private const val TAG = "ExtDisplay"
private const val LISTEN_PORT = 5000
private const val TOUCH_PORT = 5001
private const val DISCOVERY_PORT = 5002
private const val AUDIO_PORT = 5003
private const val AUDIO_MAGIC = 0x45584155 // 'EXAU'
private const val ENC_VIDEO_MAGIC = 0x45585645 // 'EXVE' (encrypted-video stream marker)
private const val TOUCH_MAGIC = 0x48585450 // 'HXTP'
private const val DISCOVERY_QUERY = "EXTDISP?v1"
private const val DISCOVERY_REPLY_PREFIX = "EXTDISP!v1|"
// Placeholder size — MediaCodec adapts to the real resolution carried in the SPS.
private const val INITIAL_WIDTH = 320
private const val INITIAL_HEIGHT = 240
private const val MIME_AVC = "video/avc"
private const val MIME_HEVC = "video/hevc"

/** PBKDF2-HMAC-SHA256 (matches the Windows sender) + AES-256-GCM. */
private object Crypto {
    private const val SALT = "ExtDisplay/v1"
    private const val ITERS = 200000
    fun deriveKey(code: String): ByteArray {
        val spec = PBEKeySpec(code.toCharArray(), SALT.toByteArray(Charsets.US_ASCII), ITERS, 256)
        return SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
    }
    fun hex(b: ByteArray): String = b.joinToString("") { "%02x".format(it) }
}

/**
 * AES-256-GCM sealer/opener. Frame = [12B nonce][ciphertext][16B tag]; the nonce is
 * a 4-byte random per-session prefix + an 8-byte big-endian counter, matching the
 * sender's replay guard.
 */
private class Sealer(key: ByteArray) {
    private val keySpec = SecretKeySpec(key, "AES")
    private val prefix = ByteArray(4).also { SecureRandom().nextBytes(it) }
    private var counter = 0L

    @Synchronized fun seal(plain: ByteArray): ByteArray {
        val nonce = ByteArray(12)
        System.arraycopy(prefix, 0, nonce, 0, 4)
        counter++
        for (i in 0 until 8) nonce[4 + i] = ((counter ushr (8 * (7 - i))) and 0xff).toByte()
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, keySpec, GCMParameterSpec(128, nonce))
        return nonce + c.doFinal(plain)  // doFinal appends the 16-byte tag
    }

    /** Decrypt a [12B nonce][ct][16B tag] frame; null on auth failure. (Stage 3.) */
    fun open(frame: ByteArray, off: Int, len: Int): ByteArray? {
        if (len < 12 + 16) return null
        return try {
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, keySpec, GCMParameterSpec(128, frame, off, 12))
            c.doFinal(frame, off + 12, len - 12)
        } catch (_: Exception) { null }
    }
}

class MainActivity : Activity(), SurfaceHolder.Callback {
    private lateinit var rootLayout: FrameLayout
    private lateinit var surfaceView: SurfaceView
    private lateinit var statusView: TextView
    private lateinit var pairInput: EditText
    private lateinit var pairPanel: LinearLayout
    private var receiver: H264TcpReceiver? = null
    private val touchUplink = TouchUplink()
    private val audioReceiver = AudioReceiver()
    private val discovery = DiscoveryResponder()
    @Volatile private var pairingKey: ByteArray? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestWindowFeature(Window.FEATURE_NO_TITLE)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        surfaceView = SurfaceView(this)
        surfaceView.holder.addCallback(this)
        touchUplink.start()
        audioReceiver.start()
        discovery.start(applicationContext)

        statusView = TextView(this).apply {
            val ip = localWifiIp()
            text = if (ip != null) "Ready  •  Wi-Fi $ip  •  USB ready" else "Waiting on TCP $LISTEN_PORT"
            setTextColor(0xFFFFFFFF.toInt())
            setBackgroundColor(0x99000000.toInt())
            textSize = 14f
            setPadding(18, 10, 18, 10)
        }

        // Pairing panel: if the PC shows a pairing code (encryption on), type it here
        // once. Leave it be for an open/trusted LAN. A boxed, monospaced, letter-
        // spaced field reads like separate blocks and shows every character clearly.
        val pairTitle = TextView(this).apply {
            text = "Pairing code (from PC)"
            setTextColor(0xFFDDDDDD.toInt())
            textSize = 13f
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, 8)
        }
        val boxBg = GradientDrawable().apply {
            setColor(0xEE1A1A1A.toInt())
            cornerRadius = 14f
            setStroke(2, 0xFF3A6EA5.toInt())
        }
        pairInput = EditText(this).apply {
            hint = "--------"
            setTextColor(0xFFFFFFFF.toInt())
            setHintTextColor(0xFF555555.toInt())
            background = boxBg
            setPadding(28, 16, 28, 16)
            textSize = 26f
            typeface = Typeface.MONOSPACE
            letterSpacing = 0.5f
            gravity = Gravity.CENTER
            isSingleLine = true
            filters = arrayOf(InputFilter.LengthFilter(8), InputFilter.AllCaps())
            inputType = InputType.TYPE_CLASS_TEXT or
                InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS or
                InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            imeOptions = EditorInfo.IME_ACTION_DONE
            setOnEditorActionListener { _, actionId, _ ->
                if (actionId == EditorInfo.IME_ACTION_DONE) { applyPairingCode(text.toString().trim()); true }
                else false
            }
            // Codes are exactly 8 chars. Auto-apply once full, but DEFER via post{}
            // so the 8th character actually draws before the panel reacts (the old
            // synchronous hide made the last char "not show" while it still paired).
            addTextChangedListener(object : TextWatcher {
                override fun afterTextChanged(s: Editable?) {
                    if ((s?.length ?: 0) == 8) { val c = s.toString(); post { applyPairingCode(c) } }
                }
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, cc: Int) {}
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, cc: Int) {}
            })
        }
        pairPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            addView(pairTitle)
            addView(pairInput, LinearLayout.LayoutParams(360, LinearLayout.LayoutParams.WRAP_CONTENT))
        }

        rootLayout = FrameLayout(this).apply {
            setBackgroundColor(0xFF000000.toInt())
            addView(surfaceView, FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            ))
            addView(statusView, FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.TOP or Gravity.START
            ).apply {
                leftMargin = 18
                topMargin = 18
            })
            addView(pairPanel, FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.TOP or Gravity.CENTER_HORIZONTAL
            ).apply {
                topMargin = 24
            })
        }

        setContentView(rootLayout)
        // Don't let the pairing field grab focus on launch (that popped the keyboard
        // and blocked the screen). It only takes focus when the user taps it.
        rootLayout.isFocusableInTouchMode = true
        rootLayout.requestFocus()
        hideSystemUi()
        Log.i(TAG, "onCreate done; touch capture via dispatchTouchEvent is active")
    }

    // Derive the shared key from the PC's pairing code and encrypt the uplink.
    // Empty code = open/plaintext (trusted LAN).
    private fun applyPairingCode(code: String) {
        if (code.isEmpty()) {
            pairingKey = null
            touchUplink.setKey(null)
            audioReceiver.setKey(null)
            receiver?.setKey(null)
            return
        }
        if (code.length != 8) return  // wait until the full code is entered
        try {
            val key = Crypto.deriveKey(code)
            pairingKey = key
            touchUplink.setKey(key)     // touch encrypts per-packet (reads key live)
            audioReceiver.setKey(key)   // audio decrypts per-frame (reads key live)
            receiver?.setKey(key)       // video decrypts per-frame (drained until now)
            Log.i(TAG, "Paired: encryption enabled (key ${Crypto.hex(key).take(8)}…)")
            statusView.text = "Paired — link encrypted"
            // Show the completed code (green), then tuck the panel away — deferred so
            // the final character is visible before it disappears.
            pairInput.isEnabled = false
            pairInput.setTextColor(0xFF66DD88.toInt())
            pairPanel.postDelayed({ pairPanel.visibility = View.GONE; hideSystemUi() }, 700)
            Toast.makeText(this, "Paired — link encrypted", Toast.LENGTH_SHORT).show()
        } catch (e: Exception) {
            Log.i(TAG, "Pairing failed: ${e.message}")
            Toast.makeText(this, "Pairing failed: ${e.message}", Toast.LENGTH_SHORT).show()
        }
    }

    // Capture EVERY touch at the window level, before any child view can consume
    // it. This is far more reliable than a per-view OnTouchListener (a SurfaceView
    // in particular does not always deliver touches to a listener). We still call
    // through to super so the normal view hierarchy keeps working.
    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN ->
                sendPointer(event, event.actionIndex, 0)
            MotionEvent.ACTION_POINTER_UP, MotionEvent.ACTION_UP ->
                sendPointer(event, event.actionIndex, 2)
            MotionEvent.ACTION_CANCEL ->
                for (i in 0 until event.pointerCount) sendPointer(event, i, 3)
            MotionEvent.ACTION_MOVE ->
                for (i in 0 until event.pointerCount) sendPointer(event, i, 1)
        }
        return super.dispatchTouchEvent(event)
    }

    // S Pen hover (no contact) arrives on the generic-motion path.
    override fun onGenericMotionEvent(event: MotionEvent): Boolean {
        val type = when (event.actionMasked) {
            MotionEvent.ACTION_HOVER_MOVE -> 4
            MotionEvent.ACTION_HOVER_EXIT -> 5
            else -> -1
        }
        if (type >= 0) sendPointer(event, 0, type)
        return super.onGenericMotionEvent(event)
    }

    private val locBuf = IntArray(2)
    private var loggedFirstTouch = false

    /**
     * Emits one v2 packet for pointer [i] of [event]. Coordinates are window-
     * relative (from dispatchTouchEvent); we normalize them against the video
     * SurfaceView's on-screen rectangle so the host maps them onto the display.
     */
    private fun sendPointer(event: MotionEvent, i: Int, type: Int) {
        val w = surfaceView.width
        val h = surfaceView.height
        if (w <= 0 || h <= 0) return
        surfaceView.getLocationInWindow(locBuf)
        val nx = ((event.getX(i) - locBuf[0]) / w).coerceIn(0f, 1f)
        val ny = ((event.getY(i) - locBuf[1]) / h).coerceIn(0f, 1f)
        if (!loggedFirstTouch) {
            loggedFirstTouch = true
            Log.i(TAG, "first touch: type=$type nx=$nx ny=$ny surface=${w}x$h")
        }
        touchUplink.send(
            type = type,
            tool = toolCode(event, i),
            pointerId = event.getPointerId(i),
            pointerCount = event.pointerCount,
            pressure = event.getPressure(i),
            nx = nx,
            ny = ny,
            timestampUs = event.eventTime * 1000
        )
    }

    private fun localWifiIp(): String? {
        return try {
            java.net.NetworkInterface.getNetworkInterfaces().toList()
                .filter { it.isUp && !it.isLoopback }
                .flatMap { it.inetAddresses.toList() }
                .filterIsInstance<java.net.Inet4Address>()
                .firstOrNull { it.isSiteLocalAddress }
                ?.hostAddress
        } catch (_: Exception) {
            null
        }
    }

    private fun toolCode(event: MotionEvent, i: Int): Int = when (event.getToolType(i)) {
        // A real eraser tip (e.g. Surface Pen flipped) erases. The Samsung S Pen has
        // no eraser tip, and its side button is owned by Samsung Air Command at the
        // system level (a press opens the side panel) — it is not a reliable
        // hold-to-erase modifier, so we do NOT map it (that only caused glitchy
        // mixed pen/eraser strokes). Pressure + hover + drawing all work.
        MotionEvent.TOOL_TYPE_ERASER -> 2
        MotionEvent.TOOL_TYPE_STYLUS -> 1
        else -> 0
    }

    // Letterbox: size the SurfaceView to the video's aspect ratio so 16:9
    // streams aren't stretched onto the 16:10 panel.
    private fun applyVideoSize(videoWidth: Int, videoHeight: Int) {
        // Video is decoding, so no pairing is needed (either the host is open, or we
        // already paired and the encrypted stream is flowing). Tuck the box away so
        // it never lingers/blocks when encryption is off.
        if (::pairPanel.isInitialized && pairPanel.visibility != View.GONE) {
            pairPanel.visibility = View.GONE
            hideSystemUi()
        }
        val screenW = rootLayout.width
        val screenH = rootLayout.height
        if (screenW == 0 || screenH == 0 || videoWidth <= 0 || videoHeight <= 0) return
        val scale = minOf(
            screenW.toFloat() / videoWidth,
            screenH.toFloat() / videoHeight
        )
        val params = FrameLayout.LayoutParams(
            (videoWidth * scale).toInt(),
            (videoHeight * scale).toInt(),
            Gravity.CENTER
        )
        if (surfaceView.layoutParams.width != params.width ||
            surfaceView.layoutParams.height != params.height
        ) {
            surfaceView.layoutParams = params
        }
    }

    override fun onDestroy() {
        receiver?.stop()
        receiver = null
        touchUplink.stop()
        audioReceiver.stop()
        discovery.stop()
        super.onDestroy()
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        receiver?.stop()
        receiver = H264TcpReceiver(
            surface = holder.surface,
            onStatus = { status -> runOnUiThread { statusView.text = status } },
            onVideoSize = { w, h -> runOnUiThread { applyVideoSize(w, h) } }
        ).also { it.setKey(pairingKey); it.start() }
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        receiver?.stop()
        receiver = null
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = Unit

    private fun hideSystemUi() {
        window.decorView.systemUiVisibility =
            View.SYSTEM_UI_FLAG_FULLSCREEN or
            View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
            View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
            View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
            View.SYSTEM_UI_FLAG_LAYOUT_STABLE

        if (android.os.Build.VERSION.SDK_INT >= 30) {
            window.insetsController?.let {
                it.hide(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
                it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        }
    }
}

/**
 * Reassembles UDP-fragmented NAL units. Each datagram carries a 12-byte
 * big-endian header { magic 'EXUD', nalSeq u32, fragIndex u16, fragCount u16 }
 * followed by a payload fragment. Fragments are collected per nalSeq; a NAL is
 * emitted once all its fragments arrive. Moving to a new nalSeq drops any
 * incomplete previous NAL (a lost fragment), so playback recovers on the next
 * keyframe rather than corrupting the stream. Called from a single thread.
 */
private const val MAX_FRAGMENTS = 4096  // >5.7 MB per NAL at 1400B fragments

private class UdpReassembler(private val onNal: (ByteArray) -> Unit) {
    private var curSeq = -1L
    private var fragCount = 0
    private var received = 0
    private var fragments: Array<ByteArray?> = arrayOf()
    private var emitted = false

    fun onPacket(data: ByteArray, len: Int) {
        if (len < 12) return
        val magic = ((data[0].toInt() and 0xFF) shl 24) or ((data[1].toInt() and 0xFF) shl 16) or
            ((data[2].toInt() and 0xFF) shl 8) or (data[3].toInt() and 0xFF)
        if (magic != 0x45585544) return  // 'EXUD'
        val seq = ((data[4].toLong() and 0xFF) shl 24) or ((data[5].toLong() and 0xFF) shl 16) or
            ((data[6].toLong() and 0xFF) shl 8) or (data[7].toLong() and 0xFF)
        val fragIndex = ((data[8].toInt() and 0xFF) shl 8) or (data[9].toInt() and 0xFF)
        val fc = ((data[10].toInt() and 0xFF) shl 8) or (data[11].toInt() and 0xFF)
        // Bound fragCount so a malformed/hostile packet can't allocate huge arrays.
        if (fc <= 0 || fc > MAX_FRAGMENTS || fragIndex >= fc) return
        // Drop late fragments from an already-passed NAL so they can't reset state.
        if (seq < curSeq) return

        if (seq != curSeq) {
            curSeq = seq
            fragCount = fc
            received = 0
            fragments = arrayOfNulls(fc)
            emitted = false
        }
        if (emitted || fragments.size != fc) return
        if (fragments[fragIndex] == null) {
            fragments[fragIndex] = data.copyOfRange(12, len)
            received++
        }
        if (received == fragCount) {
            val total = fragments.sumOf { it?.size ?: 0 }
            val nal = ByteArray(total)
            var off = 0
            for (f in fragments) {
                if (f != null) {
                    System.arraycopy(f, 0, nal, off, f.size)
                    off += f.size
                }
            }
            onNal(nal)
            emitted = true
        }
    }
}

private class H264TcpReceiver(
    private val surface: Surface,
    private val onStatus: (String) -> Unit,
    private val onVideoSize: (Int, Int) -> Unit
) {
    private val running = AtomicBoolean(false)
    private var server: ServerSocket? = null
    private var udpSocket: java.net.DatagramSocket? = null
    private var codec: MediaCodec? = null
    @Volatile private var videoSealer: Sealer? = null

    /** Set the pairing key to decrypt the video, or null for plaintext. Read live
     *  per-frame, so entering the code mid-stream starts decryption without a
     *  reconnect (the encrypted branch drains frames until this is set). */
    fun setKey(key: ByteArray?) { videoSealer = key?.let { Sealer(it) } }

    // Both transports push complete NAL units here; one decode loop consumes
    // them, so the host can use TCP (reliable) or UDP (low latency) and the app
    // handles whichever arrives.
    private val nalQueue = LinkedBlockingQueue<ByteArray>(2048)

    fun start() {
        if (!running.compareAndSet(false, true)) return
        thread(name = "tcp-feeder") { tcpLoop() }
        thread(name = "udp-feeder") { udpLoop() }
        thread(name = "decode-loop") { decodeLoop() }
        onStatus("Listening (TCP/UDP $LISTEN_PORT)")
    }

    fun stop() {
        // Only flip the flag + unblock the I/O threads. The decode thread owns
        // the codec and releases it itself when `running` goes false (avoids a
        // cross-thread release race against in-flight dequeue/queue calls).
        running.set(false)
        closeServer()
        try {
            udpSocket?.close()
        } catch (_: Exception) {
        }
        nalQueue.clear()
    }

    // TCP transport: accept a connection and feed its NALs into the queue.
    private fun tcpLoop() {
        while (running.get()) {
            try {
                server = ServerSocket().apply {
                    reuseAddress = true
                    receiveBufferSize = 1 shl 20
                    bind(InetSocketAddress(LISTEN_PORT))
                }
                server!!.accept().use { socket ->
                    socket.tcpNoDelay = true
                    onStatus("Connected (USB/TCP): ${socket.inetAddress.hostAddress}")
                    // Peek 4 bytes. Encrypted streams begin with the 'EXVE' marker;
                    // plaintext streams begin with an Annex-B start code (push those
                    // back for the splitter).
                    val pin = java.io.PushbackInputStream(
                        java.io.BufferedInputStream(socket.getInputStream()), 4)
                    val magic = ByteArray(4)
                    var got = 0
                    while (got < 4) {
                        val r = pin.read(magic, got, 4 - got)
                        if (r < 0) break
                        got += r
                    }
                    if (got < 4) return@use
                    val m = ((magic[0].toInt() and 0xff) shl 24) or
                            ((magic[1].toInt() and 0xff) shl 16) or
                            ((magic[2].toInt() and 0xff) shl 8) or
                            (magic[3].toInt() and 0xff)
                    if (m == ENC_VIDEO_MAGIC) {
                        // Length-prefixed encrypted frames [4B BE len][nonce+ct+tag].
                        // videoSealer is read PER-FRAME: before pairing it's null so we
                        // DRAIN frames (no garbage decode / no picture-of-noise); once
                        // you enter the code the next frames decrypt and video appears —
                        // all on the same connection, no reconnect.
                        val inp = java.io.DataInputStream(pin)
                        val lenBuf = ByteArray(4)
                        while (running.get()) {
                            inp.readFully(lenBuf)
                            val n = ((lenBuf[0].toInt() and 0xff) shl 24) or
                                    ((lenBuf[1].toInt() and 0xff) shl 16) or
                                    ((lenBuf[2].toInt() and 0xff) shl 8) or
                                    (lenBuf[3].toInt() and 0xff)
                            if (n <= 0 || n > (8 shl 20)) break  // sanity / desync
                            val frame = ByteArray(n)
                            inp.readFully(frame)
                            val s = videoSealer ?: continue          // not keyed yet -> drain
                            val nal = s.open(frame, 0, frame.size) ?: break  // wrong code / tamper
                            nalQueue.put(nal)
                        }
                    } else {
                        pin.unread(magic, 0, got)  // those bytes start the Annex-B stream
                        val splitter = AnnexBNalSplitter(pin)
                        while (running.get()) {
                            val nal = splitter.nextNal() ?: break
                            nalQueue.put(nal)
                        }
                    }
                }
            } catch (ex: Exception) {
                if (running.get()) Thread.sleep(300)
            } finally {
                closeServer()
            }
        }
    }

    // UDP transport: reassemble fragmented NALs (12-byte EXUD header) and feed
    // complete ones into the queue. Incomplete NALs (lost fragments) are dropped.
    private fun udpLoop() {
        while (running.get()) {
            try {
                val sock = java.net.DatagramSocket(null).apply {
                    reuseAddress = true
                    receiveBufferSize = 1 shl 21
                    bind(InetSocketAddress(LISTEN_PORT))
                }
                udpSocket = sock
                val reasm = UdpReassembler { blob ->
                    if (!running.get()) return@UdpReassembler
                    // When paired, each reassembled blob is an AES-GCM frame; decrypt
                    // to the NAL (drop on auth failure = wrong code / tampering).
                    val s = videoSealer
                    val nal = if (s != null) s.open(blob, 0, blob.size) else blob
                    if (nal != null) nalQueue.offer(nal)
                }
                val buf = ByteArray(2048)
                var announced = false
                while (running.get()) {
                    val packet = java.net.DatagramPacket(buf, buf.size)
                    sock.receive(packet)
                    if (!announced) {
                        onStatus("Connected (Wi-Fi/UDP): ${packet.address.hostAddress}")
                        announced = true
                    }
                    reasm.onPacket(packet.data, packet.length)
                }
            } catch (ex: Exception) {
                if (running.get()) Thread.sleep(300)
            } finally {
                try {
                    udpSocket?.close()
                } catch (_: Exception) {
                }
            }
        }
    }

    // Distinguishes H.264 from HEVC by the first NAL's header. HEVC uses a
    // 2-byte header where nal_unit_type = (byte0 >> 1) & 0x3F (VPS=32, SPS=33,
    // PPS=34); H.264 uses nal_unit_type = byte0 & 0x1F (SPS=7, PPS=8). The
    // parameter-set NALs that lead a stream are unambiguous between the two.
    private fun detectCodec(nal: ByteArray): String {
        val sc = if (nal.size >= 4 && nal[2] == 0.toByte()) 4 else 3
        if (nal.size <= sc) return MIME_AVC
        val header = nal[sc].toInt() and 0xFF
        val hevcType = (header shr 1) and 0x3F
        if (header and 0x80 == 0 && hevcType in intArrayOf(32, 33, 34)) {
            return MIME_HEVC
        }
        return MIME_AVC
    }

    // Consumes NALs from the shared queue (fed by TCP or UDP) and decodes them.
    // Resets the codec on error (e.g. surface loss) and resumes.
    private fun decodeLoop() {
        while (running.get()) {
            try {
                decodeSession()  // releases its own codec in a finally
            } catch (ex: Exception) {
                if (running.get()) {
                    onStatus("Decoder reset: ${ex.message ?: ex.javaClass.simpleName}")
                    Thread.sleep(300)
                }
            }
        }
    }

    private fun decodeSession() {
        // Wait for the first NAL to pick H.264 vs HEVC (no codec header needed).
        var firstNal: ByteArray? = null
        while (running.get() && firstNal == null) {
            firstNal = nalQueue.poll(500, TimeUnit.MILLISECONDS)
        }
        val first = firstNal ?: return
        val mime = detectCodec(first)

        val decoder = MediaCodec.createDecoderByType(mime)
        codec = decoder
        // The decode thread is the SOLE owner of the codec — it always releases
        // it here. stop() only flips `running`, so there is no cross-thread
        // stop()/release() race against the dequeue/queue calls below.
        try {
            val format = MediaFormat.createVideoFormat(mime, INITIAL_WIDTH, INITIAL_HEIGHT).apply {
                if (android.os.Build.VERSION.SDK_INT >= 30) {
                    setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                }
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 1 shl 20)
                // Realtime priority + uncapped operating rate ask for the fastest schedule.
                setInteger(MediaFormat.KEY_PRIORITY, 0)
                setInteger(MediaFormat.KEY_OPERATING_RATE, Short.MAX_VALUE.toInt())
            }
            decoder.configure(format, surface, null, 0)
            decoder.start()
            onStatus("Decoding ${if (mime == MIME_HEVC) "HEVC" else "H.264"}")

            val info = MediaCodec.BufferInfo()
            var nal: ByteArray? = first  // feed the peeked NAL first
            while (running.get()) {
                val current = nal ?: nalQueue.poll(500, TimeUnit.MILLISECONDS) ?: continue
                nal = null
                var queued = false
                while (running.get() && !queued) {
                    val inputIndex = decoder.dequeueInputBuffer(1_000)
                    if (inputIndex >= 0) {
                        decoder.getInputBuffer(inputIndex)?.apply { clear(); put(current) }
                        // PTS 0 + render-at-vsync means MediaCodec never delays output.
                        decoder.queueInputBuffer(inputIndex, 0, current.size, 0L, 0)
                        queued = true
                    } else {
                        drainOutput(decoder, info)
                    }
                }
                drainOutput(decoder, info)
            }
        } finally {
            try { decoder.stop() } catch (_: Exception) {}
            try { decoder.release() } catch (_: Exception) {}
            if (codec === decoder) codec = null
        }
    }

    private fun drainOutput(decoder: MediaCodec, info: MediaCodec.BufferInfo) {
        while (true) {
            val outputIndex = decoder.dequeueOutputBuffer(info, 0)
            when {
                outputIndex >= 0 -> decoder.releaseOutputBuffer(outputIndex, true)
                outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val format = decoder.outputFormat
                    // Crop rectangle is the true visible size; KEY_WIDTH/HEIGHT
                    // include codec alignment padding.
                    val width = if (format.containsKey("crop-right")) {
                        format.getInteger("crop-right") - format.getInteger("crop-left") + 1
                    } else {
                        format.getInteger(MediaFormat.KEY_WIDTH)
                    }
                    val height = if (format.containsKey("crop-bottom")) {
                        format.getInteger("crop-bottom") - format.getInteger("crop-top") + 1
                    } else {
                        format.getInteger(MediaFormat.KEY_HEIGHT)
                    }
                    onVideoSize(width, height)
                }
                else -> return
            }
        }
    }

    private fun closeServer() {
        try {
            server?.close()
        } catch (_: Exception) {
        }
        server = null
    }
}

/**
 * Answers LAN discovery so the Windows host finds the tablet without typing an
 * IP. Listens for a UDP "EXTDISP?v1" broadcast on DISCOVERY_PORT and replies
 * "EXTDISP!v1|<model>|<videoPort>" straight back to the sender.
 */
private class DiscoveryResponder {
    private val running = AtomicBoolean(false)
    private var socket: java.net.DatagramSocket? = null
    private var multicastLock: android.net.wifi.WifiManager.MulticastLock? = null

    fun start(context: android.content.Context) {
        if (!running.compareAndSet(false, true)) return
        // Without a multicast lock, Wi-Fi power saving can drop inbound broadcast
        // packets, so discovery would silently fail on some devices.
        try {
            val wifi = context.getSystemService(android.content.Context.WIFI_SERVICE)
                as android.net.wifi.WifiManager
            multicastLock = wifi.createMulticastLock("ExtendedDisplayDiscovery").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Exception) {
        }
        thread(name = "discovery-responder") {
            while (running.get()) {
                try {
                    val sock = java.net.DatagramSocket(null).apply {
                        reuseAddress = true
                        broadcast = true
                        bind(InetSocketAddress(DISCOVERY_PORT))
                    }
                    socket = sock
                    val buf = ByteArray(256)
                    while (running.get()) {
                        val packet = java.net.DatagramPacket(buf, buf.size)
                        sock.receive(packet)
                        val msg = String(packet.data, 0, packet.length).trim()
                        if (msg == DISCOVERY_QUERY) {
                            val name = "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}"
                            val reply = "$DISCOVERY_REPLY_PREFIX$name|$LISTEN_PORT".toByteArray()
                            sock.send(
                                java.net.DatagramPacket(reply, reply.size, packet.address, packet.port)
                            )
                        }
                    }
                } catch (_: Exception) {
                    if (running.get()) Thread.sleep(500)
                } finally {
                    try {
                        socket?.close()
                    } catch (_: Exception) {
                    }
                    socket = null
                }
            }
        }
    }

    fun stop() {
        running.set(false)
        try {
            socket?.close()
        } catch (_: Exception) {
        }
        try {
            multicastLock?.release()
        } catch (_: Exception) {
        }
        multicastLock = null
    }
}

/**
 * Serves touch events to the host as fixed 28-byte big-endian packets
 * (protocol v2), one packet per pointer per event:
 * magic u32 'HXTP', version u16 = 2,
 * type u8 (0=down 1=move 2=up 3=cancel 4=hover-move 5=hover-exit),
 * tool u8 (0=finger 1=stylus 2=eraser), pointerId u8, pointerCount u8,
 * pressure u16 (0..1024; 0 when hovering), normalizedX f32, normalizedY f32,
 * timestampUs u64. Listens on TOUCH_PORT; events are dropped when no host
 * is connected.
 */
private class TouchUplink {
    private val running = AtomicBoolean(false)
    private var server: ServerSocket? = null
    @Volatile private var current: Socket? = null
    @Volatile private var sealer: Sealer? = null
    private val queue = LinkedBlockingQueue<ByteArray>(256)

    /** Set the pairing key to encrypt outgoing touch packets, or null for plaintext. */
    fun setKey(key: ByteArray?) { sealer = key?.let { Sealer(it) } }

    fun start() {
        if (!running.compareAndSet(false, true)) return

        // Accept loop: the NEWEST host connection wins. When the host reconnects
        // (Wi-Fi blip, sender restart) it is accepted immediately and supersedes
        // the stale socket — we never wait for the old, possibly half-open socket
        // to be noticed dead (which previously required a touch to trigger a write
        // failure, so the first reconnect silently lost touch).
        thread(name = "touch-accept") {
            while (running.get()) {
                try {
                    val s = ServerSocket().apply {
                        reuseAddress = true
                        bind(InetSocketAddress(TOUCH_PORT))
                    }
                    server = s
                    Log.i(TAG, "TouchUplink listening on $TOUCH_PORT")
                    while (running.get()) {
                        val sock = s.accept()
                        sock.tcpNoDelay = true
                        try { sock.keepAlive = true } catch (_: Exception) {}
                        Log.i(TAG, "TouchUplink client connected: ${sock.inetAddress}")
                        val old = current
                        current = sock
                        queue.clear()
                        if (old != null) try { old.close() } catch (_: Exception) {}
                    }
                } catch (_: Exception) {
                    if (running.get()) Thread.sleep(300)
                } finally {
                    try { server?.close() } catch (_: Exception) {}
                    server = null
                }
            }
        }

        // Writer loop: drain the queue to whatever the current socket is. A write
        // failure just drops that socket; the accept loop supplies the next one.
        thread(name = "touch-writer") {
            while (running.get()) {
                val packet = queue.poll(500, TimeUnit.MILLISECONDS) ?: continue
                val sock = current ?: continue
                try {
                    val out = sock.getOutputStream()
                    out.write(packet)
                    out.flush()
                } catch (_: Exception) {
                    try { sock.close() } catch (_: Exception) {}
                    if (current === sock) current = null
                }
            }
        }
    }

    fun stop() {
        running.set(false)
        try { server?.close() } catch (_: Exception) {}
        try { current?.close() } catch (_: Exception) {}
    }

    fun send(
        type: Int,
        tool: Int,
        pointerId: Int,
        pointerCount: Int,
        pressure: Float,
        nx: Float,
        ny: Float,
        timestampUs: Long
    ) {
        if (!running.get()) return
        val buf = ByteBuffer.allocate(28)
        buf.putInt(TOUCH_MAGIC)
        buf.putShort(2)
        buf.put(type.toByte())
        buf.put(tool.toByte())
        buf.put(pointerId.toByte())
        buf.put(pointerCount.toByte())
        buf.putShort((pressure * 1024).toInt().coerceIn(0, 1024).toShort())
        buf.putFloat(nx.coerceIn(0f, 1f))
        buf.putFloat(ny.coerceIn(0f, 1f))
        buf.putLong(timestampUs)
        // Encrypt when paired (host derived the same key from the PIN); else plaintext.
        val s = sealer
        queue.offer(if (s != null) s.seal(buf.array()) else buf.array())
    }
}

/**
 * Desktop-audio player. The PC (WASAPI loopback) connects to AUDIO_PORT and sends a
 * 12-byte format header [4B 'EXAU'][4B BE rate][2B BE channels][2B BE bits], then
 * length-prefixed frames [4B BE len][payload] where payload is raw S16LE PCM (open
 * link) or an AES-GCM blob (paired). We play it through an AudioTrack. Newest
 * connection wins (a reconnect supersedes the stale socket), matching TouchUplink.
 */
private class AudioReceiver {
    private val running = AtomicBoolean(false)
    private var server: ServerSocket? = null
    @Volatile private var current: Socket? = null
    @Volatile private var sealer: Sealer? = null

    /** Set the pairing key to decrypt incoming audio, or null for plaintext. */
    fun setKey(key: ByteArray?) { sealer = key?.let { Sealer(it) } }

    fun start() {
        if (!running.compareAndSet(false, true)) return
        thread(name = "audio-accept") {
            while (running.get()) {
                try {
                    val s = ServerSocket().apply {
                        reuseAddress = true
                        bind(InetSocketAddress(AUDIO_PORT))
                    }
                    server = s
                    Log.i(TAG, "AudioReceiver listening on $AUDIO_PORT")
                    while (running.get()) {
                        val sock = s.accept()
                        sock.tcpNoDelay = true
                        Log.i(TAG, "AudioReceiver client connected: ${sock.inetAddress?.hostAddress}")
                        val old = current
                        current = sock
                        if (old != null) try { old.close() } catch (_: Exception) {}
                        thread(name = "audio-play") { serve(sock) }
                    }
                } catch (_: Exception) {
                    if (running.get()) Thread.sleep(300)
                } finally {
                    try { server?.close() } catch (_: Exception) {}
                    server = null
                }
            }
        }
    }

    private fun serve(sock: Socket) {
        var track: AudioTrack? = null
        try {
            val inp = java.io.DataInputStream(java.io.BufferedInputStream(sock.getInputStream()))
            val hdr = ByteArray(16)
            inp.readFully(hdr)
            if (beInt(hdr, 0) != AUDIO_MAGIC) return
            val rate = beInt(hdr, 4)
            val channels = beShort(hdr, 8)
            val encrypted = (hdr[11].toInt() and 1) != 0  // stream is AES-GCM per frame
            val delayMs = ((hdr[12].toInt() and 0xff) shl 8) or (hdr[13].toInt() and 0xff)
            if (rate !in 8000..192000) return
            val mask = if (channels >= 2) AudioFormat.CHANNEL_OUT_STEREO
                       else AudioFormat.CHANNEL_OUT_MONO
            val minBuf = AudioTrack.getMinBufferSize(rate, mask, AudioFormat.ENCODING_PCM_16BIT)
            if (minBuf <= 0) return
            // The AudioTrack buffer sets the audio latency, so it's the A/V-sync knob:
            // bigger = audio plays later (raise it if audio leads the video). The PC's
            // "Audio delay (ms)" field drives it; floor at minBuf so it never underruns.
            // (blocking write() paces us; LOW_LATENCY perf mode threw build() here.)
            val bytesPerMs = rate * 4 / 1000   // stereo 16-bit = 4 bytes/frame
            val bufBytes = maxOf(minBuf, (delayMs * bytesPerMs / 4) * 4)
            track = AudioTrack.Builder()
                .setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                    .build())
                .setAudioFormat(AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(rate)
                    .setChannelMask(mask)
                    .build())
                .setBufferSizeInBytes(bufBytes)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
            track.play()
            // 1-byte ACK: tells the sender a live receiver actually got the header.
            // adb-forward accepts the sender's local socket even before this app has
            // bound 5003 (startup race), so without this the sender would stream into
            // a dead relay forever. The sender waits for this byte and reconnects if
            // it never arrives.
            try { sock.getOutputStream().write(0xAC); sock.getOutputStream().flush() } catch (_: Exception) {}
            Log.i(TAG, "Audio: playing ${rate}Hz ${channels}ch enc=$encrypted")

            val lenBuf = ByteArray(4)
            while (running.get() && current === sock) {
                inp.readFully(lenBuf)
                val n = beInt(lenBuf, 0)
                if (n <= 0 || n > (1 shl 20)) break  // sanity / desync
                val frame = ByteArray(n)
                inp.readFully(frame)
                if (encrypted) {
                    val s = sealer ?: continue        // paired stream, not keyed yet -> stay silent
                    val pcm = s.open(frame, 0, frame.size) ?: break  // wrong key / tamper
                    track.write(pcm, 0, pcm.size)     // blocks = natural pacing/backpressure
                } else {
                    track.write(frame, 0, frame.size)
                }
            }
        } catch (e: Exception) {
            // Socket closed / superseded is normal; log others (e.g. AudioTrack build).
            if (running.get() && current === sock) Log.i(TAG, "audio serve ended: ${e.message}")
        } finally {
            try { track?.stop() } catch (_: Exception) {}
            try { track?.release() } catch (_: Exception) {}
            try { sock.close() } catch (_: Exception) {}
            if (current === sock) current = null
        }
    }

    fun stop() {
        running.set(false)
        try { server?.close() } catch (_: Exception) {}
        try { current?.close() } catch (_: Exception) {}
    }

    private fun beInt(b: ByteArray, o: Int): Int =
        ((b[o].toInt() and 0xff) shl 24) or ((b[o + 1].toInt() and 0xff) shl 16) or
        ((b[o + 2].toInt() and 0xff) shl 8) or (b[o + 3].toInt() and 0xff)
    private fun beShort(b: ByteArray, o: Int): Int =
        ((b[o].toInt() and 0xff) shl 8) or (b[o + 1].toInt() and 0xff)
}

/**
 * Splits an Annex-B byte stream into NAL units (start code included).
 *
 * Reads in chunks and scans with a sliding window — no per-byte allocations.
 * A NAL is emitted when the next start code is found, or when the stream ends.
 */
private class AnnexBNalSplitter(private val input: InputStream) {
    private var buffer = ByteArray(1 shl 16)
    private var size = 0            // valid bytes in buffer
    private var scan = 0            // next index to scan for a start code
    private var nalStart = -1       // index where the current NAL begins (start code included)
    private var eof = false

    fun nextNal(): ByteArray? {
        while (true) {
            if (nalStart < 0) {
                val first = findStartCode(0)
                if (first < 0) {
                    if (!fillMore()) return null
                    continue
                }
                nalStart = first
                scan = first + startCodeLengthAt(first)
            }

            val next = findStartCode(scan)
            if (next >= 0) {
                val nal = buffer.copyOfRange(nalStart, next)
                compact(next)
                nalStart = 0
                scan = startCodeLengthAt(0)
                return nal
            }

            if (eof) {
                if (size > nalStart) {
                    val nal = buffer.copyOfRange(nalStart, size)
                    size = 0; scan = 0; nalStart = -1
                    return nal
                }
                return null
            }
            if (!fillMore()) {
                if (size > nalStart && nalStart >= 0) {
                    val nal = buffer.copyOfRange(nalStart, size)
                    size = 0; scan = 0; nalStart = -1
                    return nal
                }
                return null
            }
        }
    }

    private fun fillMore(): Boolean {
        if (eof) return false
        if (size == buffer.size) {
            buffer = buffer.copyOf(buffer.size * 2)
        }
        val n = input.read(buffer, size, buffer.size - size)
        if (n <= 0) {
            eof = true
            return false
        }
        size += n
        return true
    }

    private fun compact(from: Int) {
        val remaining = size - from
        if (remaining > 0) System.arraycopy(buffer, from, buffer, 0, remaining)
        size = remaining
    }

    /** Returns the index of the next start code at or after `from`, or -1. */
    private fun findStartCode(from: Int): Int {
        var i = maxOf(from, 0)
        val limit = size - 3
        while (i <= limit) {
            if (buffer[i] == 0.toByte() && buffer[i + 1] == 0.toByte()) {
                if (buffer[i + 2] == 1.toByte()) return i
                if (buffer[i + 2] == 0.toByte() && i + 3 < size && buffer[i + 3] == 1.toByte()) return i
            }
            i++
        }
        scan = maxOf(from, size - 3)
        return -1
    }

    private fun startCodeLengthAt(offset: Int): Int {
        if (offset + 3 < size &&
            buffer[offset] == 0.toByte() &&
            buffer[offset + 1] == 0.toByte() &&
            buffer[offset + 2] == 0.toByte() &&
            buffer[offset + 3] == 1.toByte()
        ) return 4
        return 3
    }
}
