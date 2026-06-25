package com.heysnap.extdisplay

import android.app.Activity
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Bundle
import android.view.Gravity
import android.view.MotionEvent
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
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

private const val LISTEN_PORT = 5000
private const val TOUCH_PORT = 5001
private const val DISCOVERY_PORT = 5002
private const val TOUCH_MAGIC = 0x48585450 // 'HXTP'
private const val DISCOVERY_QUERY = "EXTDISP?v1"
private const val DISCOVERY_REPLY_PREFIX = "EXTDISP!v1|"
// Placeholder size — MediaCodec adapts to the real resolution carried in the SPS.
private const val INITIAL_WIDTH = 320
private const val INITIAL_HEIGHT = 240
private const val MIME_AVC = "video/avc"
private const val MIME_HEVC = "video/hevc"

class MainActivity : Activity(), SurfaceHolder.Callback {
    private lateinit var rootLayout: FrameLayout
    private lateinit var surfaceView: SurfaceView
    private lateinit var statusView: TextView
    private var receiver: H264TcpReceiver? = null
    private val touchUplink = TouchUplink()
    private val discovery = DiscoveryResponder()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestWindowFeature(Window.FEATURE_NO_TITLE)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        surfaceView = SurfaceView(this)
        surfaceView.holder.addCallback(this)
        touchUplink.start()
        discovery.start(applicationContext)

        // Forward touches on the video area as normalized coordinates so the
        // host can inject them onto the matching display rectangle.
        // Protocol v2: one packet per pointer per event (multi-touch aware).
        surfaceView.setOnTouchListener { view, event ->
            if (view.width > 0 && view.height > 0) {
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN ->
                        sendPointer(view, event, event.actionIndex, 0)
                    MotionEvent.ACTION_POINTER_UP, MotionEvent.ACTION_UP ->
                        sendPointer(view, event, event.actionIndex, 2)
                    MotionEvent.ACTION_CANCEL ->
                        for (i in 0 until event.pointerCount) sendPointer(view, event, i, 3)
                    MotionEvent.ACTION_MOVE ->
                        for (i in 0 until event.pointerCount) sendPointer(view, event, i, 1)
                }
            }
            true
        }

        // S Pen hover arrives on the generic-motion path, not onTouch.
        surfaceView.setOnGenericMotionListener { view, event ->
            val type = when (event.actionMasked) {
                MotionEvent.ACTION_HOVER_MOVE -> 4
                MotionEvent.ACTION_HOVER_EXIT -> 5
                else -> -1
            }
            if (type >= 0 && view.width > 0 && view.height > 0) {
                touchUplink.send(
                    type = type,
                    tool = toolCode(event.getToolType(0)),
                    pointerId = event.getPointerId(0),
                    pointerCount = 0,
                    pressure = 0f,
                    nx = (event.getX(0) / view.width).coerceIn(0f, 1f),
                    ny = (event.getY(0) / view.height).coerceIn(0f, 1f),
                    timestampUs = event.eventTime * 1000
                )
                true
            } else {
                false
            }
        }

        statusView = TextView(this).apply {
            val ip = localWifiIp()
            text = if (ip != null) "Ready  •  Wi-Fi $ip  •  USB ready" else "Waiting on TCP $LISTEN_PORT"
            setTextColor(0xFFFFFFFF.toInt())
            setBackgroundColor(0x99000000.toInt())
            textSize = 14f
            setPadding(18, 10, 18, 10)
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
        }

        setContentView(rootLayout)
        hideSystemUi()
    }

    /** Emits one v2 packet for the pointer at index [i] of [event]. */
    private fun sendPointer(view: View, event: MotionEvent, i: Int, type: Int) {
        touchUplink.send(
            type = type,
            tool = toolCode(event.getToolType(i)),
            pointerId = event.getPointerId(i),
            pointerCount = event.pointerCount,
            pressure = event.getPressure(i),
            nx = (event.getX(i) / view.width).coerceIn(0f, 1f),
            ny = (event.getY(i) / view.height).coerceIn(0f, 1f),
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

    private fun toolCode(toolType: Int): Int = when (toolType) {
        MotionEvent.TOOL_TYPE_STYLUS -> 1
        MotionEvent.TOOL_TYPE_ERASER -> 2
        else -> 0
    }

    // Letterbox: size the SurfaceView to the video's aspect ratio so 16:9
    // streams aren't stretched onto the 16:10 panel.
    private fun applyVideoSize(videoWidth: Int, videoHeight: Int) {
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
        discovery.stop()
        super.onDestroy()
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        receiver?.stop()
        receiver = H264TcpReceiver(
            surface = holder.surface,
            onStatus = { status -> runOnUiThread { statusView.text = status } },
            onVideoSize = { w, h -> runOnUiThread { applyVideoSize(w, h) } }
        ).also { it.start() }
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
                    val splitter = AnnexBNalSplitter(socket.getInputStream())
                    while (running.get()) {
                        val nal = splitter.nextNal() ?: break
                        nalQueue.put(nal)
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
                val reasm = UdpReassembler { nal ->
                    if (running.get()) nalQueue.offer(nal)
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
    private val queue = LinkedBlockingQueue<ByteArray>(256)

    fun start() {
        if (!running.compareAndSet(false, true)) return
        thread(name = "touch-uplink") {
            while (running.get()) {
                try {
                    server = ServerSocket().apply {
                        reuseAddress = true
                        bind(InetSocketAddress(TOUCH_PORT))
                    }
                    server!!.accept().use { socket ->
                        socket.tcpNoDelay = true
                        queue.clear()
                        val out = socket.getOutputStream()
                        while (running.get()) {
                            val packet = queue.poll(500, TimeUnit.MILLISECONDS) ?: continue
                            out.write(packet)
                            out.flush()
                        }
                    }
                } catch (_: Exception) {
                    if (running.get()) Thread.sleep(500)
                } finally {
                    try {
                        server?.close()
                    } catch (_: Exception) {
                    }
                    server = null
                }
            }
        }
    }

    fun stop() {
        running.set(false)
        try {
            server?.close()
        } catch (_: Exception) {
        }
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
        queue.offer(buf.array())
    }
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
