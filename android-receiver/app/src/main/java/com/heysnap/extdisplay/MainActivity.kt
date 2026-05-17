package com.heysnap.extdisplay

import android.app.Activity
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Bundle
import android.view.Gravity
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
import java.io.BufferedInputStream
import java.net.ServerSocket
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

private const val LISTEN_PORT = 5000
private const val VIDEO_WIDTH = 2560
private const val VIDEO_HEIGHT = 1600
private const val MIME_AVC = "video/avc"

class MainActivity : Activity(), SurfaceHolder.Callback {
    private lateinit var surfaceView: SurfaceView
    private lateinit var statusView: TextView
    private var receiver: H264TcpReceiver? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestWindowFeature(Window.FEATURE_NO_TITLE)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        surfaceView = SurfaceView(this)
        surfaceView.holder.addCallback(this)

        statusView = TextView(this).apply {
            text = "Waiting on TCP $LISTEN_PORT"
            setTextColor(0xFFFFFFFF.toInt())
            setBackgroundColor(0x99000000.toInt())
            textSize = 14f
            setPadding(18, 10, 18, 10)
        }

        val root = FrameLayout(this).apply {
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

        setContentView(root)
        hideSystemUi()
    }

    override fun onDestroy() {
        receiver?.stop()
        receiver = null
        super.onDestroy()
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        receiver?.stop()
        receiver = H264TcpReceiver(holder.surface) { status ->
            runOnUiThread { statusView.text = status }
        }.also { it.start() }
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

private class H264TcpReceiver(
    private val surface: Surface,
    private val onStatus: (String) -> Unit
) {
    private val running = AtomicBoolean(false)
    private var server: ServerSocket? = null
    private var codec: MediaCodec? = null

    fun start() {
        if (!running.compareAndSet(false, true)) return

        thread(name = "h264-tcp-receiver") {
            while (running.get()) {
                try {
                    onStatus("Listening on TCP $LISTEN_PORT")
                    server = ServerSocket(LISTEN_PORT)
                    server!!.reuseAddress = true

                    server!!.accept().use { socket ->
                        socket.tcpNoDelay = true
                        onStatus("Connected: ${socket.inetAddress.hostAddress}")
                        decodeStream(BufferedInputStream(socket.getInputStream(), 1 shl 20))
                    }
                } catch (ex: Exception) {
                    if (running.get()) {
                        onStatus("Receiver error: ${ex.message ?: ex.javaClass.simpleName}")
                        Thread.sleep(500)
                    }
                } finally {
                    closeCodec()
                    closeServer()
                }
            }
        }
    }

    fun stop() {
        running.set(false)
        closeServer()
        closeCodec()
    }

    private fun decodeStream(input: BufferedInputStream) {
        val decoder = MediaCodec.createDecoderByType(MIME_AVC)
        codec = decoder

        val format = MediaFormat.createVideoFormat(MIME_AVC, VIDEO_WIDTH, VIDEO_HEIGHT).apply {
            setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 1 shl 20)
        }

        decoder.configure(format, surface, null, 0)
        decoder.start()

        val splitter = AnnexBNalSplitter(input)
        val info = MediaCodec.BufferInfo()
        var presentationUs = 0L

        while (running.get()) {
            val nal = splitter.nextNal() ?: break
            val inputIndex = decoder.dequeueInputBuffer(10_000)
            if (inputIndex >= 0) {
                val buffer = decoder.getInputBuffer(inputIndex)
                if (buffer != null) {
                    buffer.clear()
                    buffer.put(nal)
                    decoder.queueInputBuffer(inputIndex, 0, nal.size, presentationUs, 0)
                    presentationUs += 16_666L
                }
            }

            while (true) {
                val outputIndex = decoder.dequeueOutputBuffer(info, 0)
                if (outputIndex >= 0) {
                    decoder.releaseOutputBuffer(outputIndex, true)
                } else {
                    break
                }
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

    private fun closeCodec() {
        try {
            codec?.stop()
        } catch (_: Exception) {
        }
        try {
            codec?.release()
        } catch (_: Exception) {
        }
        codec = null
    }
}

private class AnnexBNalSplitter(private val input: BufferedInputStream) {
    private val pending = ArrayDeque<Byte>()
    private var eof = false

    fun nextNal(): ByteArray? {
        if (eof && pending.isEmpty()) return null

        while (!eof) {
            val value = input.read()
            if (value < 0) {
                eof = true
                break
            }
            pending.addLast(value.toByte())

            val secondStart = findSecondStartCode()
            if (secondStart > 0) {
                val nal = ByteArray(secondStart)
                for (i in nal.indices) {
                    nal[i] = pending.removeFirst()
                }
                return nal
            }
        }

        if (pending.isEmpty()) return null
        val nal = ByteArray(pending.size)
        for (i in nal.indices) {
            nal[i] = pending.removeFirst()
        }
        return nal
    }

    private fun findSecondStartCode(): Int {
        if (pending.size < 8) return -1

        val bytes = pending.toByteArray()
        var seenFirst = false
        var i = 0
        while (i <= bytes.size - 3) {
            val length = startCodeLength(bytes, i)
            if (length > 0) {
                if (!seenFirst) {
                    seenFirst = true
                    i += length
                    continue
                }
                return i
            }
            i++
        }
        return -1
    }

    private fun startCodeLength(bytes: ByteArray, offset: Int): Int {
        if (offset + 3 <= bytes.size &&
            bytes[offset] == 0.toByte() &&
            bytes[offset + 1] == 0.toByte() &&
            bytes[offset + 2] == 1.toByte()
        ) {
            return 3
        }
        if (offset + 4 <= bytes.size &&
            bytes[offset] == 0.toByte() &&
            bytes[offset + 1] == 0.toByte() &&
            bytes[offset + 2] == 0.toByte() &&
            bytes[offset + 3] == 1.toByte()
        ) {
            return 4
        }
        return 0
    }
}
