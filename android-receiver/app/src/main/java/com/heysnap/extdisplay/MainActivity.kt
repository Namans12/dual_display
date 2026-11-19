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
// How long a status message stays up once video is on screen.
private const val STATUS_LINGER_MS = 2500L
private const val MIME_AVC = "video/avc"
private const val MIME_HEVC = "video/hevc"
// Pairing codes: 8 characters from an alphabet without the look-alikes I, O, 0, 1
// (the same alphabet both hosts generate from).
private const val CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
private const val CODE_LENGTH = 8
// Why the pairing prompt is being asked for.
private const val PAIR_NEEDS_CODE = 1    // encrypted stream, no key on this tablet
private const val PAIR_WRONG_SAVED = 2   // encrypted stream, the saved key does not open it
// After the prompt is dismissed with Back it stays away this long.
private const val PAIR_SNOOZE_MS = 30_000L

/** True if [b] begins with an Annex-B start code (00 00 01 / 00 00 00 01), i.e. it
 *  is a plaintext NAL. A sealed blob begins with its nonce, whose first byte is the
 *  sender's video domain byte 0x01, so it can never look like one. */
private fun startsWithStartCode(b: ByteArray): Boolean =
    b.size >= 4 && b[0] == 0.toByte() && b[1] == 0.toByte() &&
        (b[2] == 1.toByte() || (b[2] == 0.toByte() && b[3] == 1.toByte()))

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
    // prefix[0]=0x00 domain-separates tablet->PC touch nonces from the sender's
    // video (0x01) and audio (0x02) streams under the shared key — a random byte 0
    // could collide with a sender prefix and reuse nonces across channels.
    private val prefix = ByteArray(4).also { SecureRandom().nextBytes(it); it[0] = 0 }
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
    // Opaque black sheet over the video, shown whenever there is no live
    // picture. Without it the last decoded frame stayed on screen after the host
    // stopped, looking like a frozen desktop.
    private lateinit var idleCover: View
    // Pairing prompt: a centred card over a dimmed screen. Hidden unless an
    // encrypted stream has arrived that this tablet cannot open.
    private lateinit var pairOverlay: FrameLayout
    private lateinit var pairReason: TextView
    private lateinit var pairInput: EditText
    private lateinit var pairMessage: TextView
    private lateinit var pairFieldBg: GradientDrawable
    // The sealed frame that triggered the prompt. A typed code is checked against
    // it on the spot, so a wrong code is reported at once and never saved.
    private var pairProbe: ByteArray? = null
    private var pairChecking = false
    private var pairShowsError = false
    private var pairSnoozedUntil = 0L
    private val dismissPairPrompt = Runnable { hidePairPrompt() }
    private var receiver: H264TcpReceiver? = null
    private val touchUplink = TouchUplink()
    private val audioReceiver = AudioReceiver()
    private val discovery = DiscoveryResponder()
    @Volatile private var pairingKey: ByteArray? = null

    // The status label is for when there is no picture (waiting, connecting, a
    // decoder reset). Once video is on screen it would just sit on top of the
    // desktop, so any message then shows briefly and fades out.
    private var videoShowing = false
    private val hideStatus = Runnable { statusView.visibility = View.GONE }

    private fun showStatus(text: String) {
        statusView.removeCallbacks(hideStatus)
        statusView.text = text
        statusView.visibility = View.VISIBLE
        if (videoShowing) statusView.postDelayed(hideStatus, STATUS_LINGER_MS)
    }

    private fun setVideoShowing(showing: Boolean) {
        videoShowing = showing
        statusView.removeCallbacks(hideStatus)
        idleCover.visibility = if (showing) View.GONE else View.VISIBLE
        if (showing) {
            // A picture means no code is needed (plaintext, or the key works).
            if (!pairChecking) hidePairPrompt()
            statusView.postDelayed(hideStatus, STATUS_LINGER_MS)
        } else {
            statusView.visibility = View.VISIBLE
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestWindowFeature(Window.FEATURE_NO_TITLE)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        surfaceView = SurfaceView(this)
        surfaceView.holder.addCallback(this)
        touchUplink.start()
        audioReceiver.start()
        discovery.start(applicationContext)

        // Remember pairing: the derived key from a previously entered code is stored
        // (app-private prefs) so the code is typed once, ever. Applied before any
        // connection arrives; if the PC streams unencrypted instead, the receiver
        // detects it (EXVE marker on TCP / first-packet latch on UDP) and disables
        // touch sealing for that session, so nothing breaks on a mismatch.
        getSharedPreferences("pairing", MODE_PRIVATE).getString("key_b64", null)?.let {
            try {
                val key = android.util.Base64.decode(it, android.util.Base64.NO_WRAP)
                if (key.size == 32) {
                    pairingKey = key
                    touchUplink.setKey(key)
                    audioReceiver.setKey(key)
                    Log.i(TAG, "Paired from saved key (${Crypto.hex(key).take(8)}…)")
                }
            } catch (_: Exception) {}
        }

        statusView = TextView(this).apply {
            val ip = localWifiIp()
            text = if (ip != null) "Ready  •  Wi-Fi $ip  •  USB ready" else "Waiting on TCP $LISTEN_PORT"
            setTextColor(0xFFFFFFFF.toInt())
            setBackgroundColor(0x99000000.toInt())
            textSize = 14f
            setPadding(18, 10, 18, 10)
            // Long-press: forget the saved pairing code (after a confirmation).
            setOnLongClickListener { confirmForgetPairing(); true }
        }

        pairOverlay = buildPairPrompt()

        idleCover = View(this).apply { setBackgroundColor(0xFF000000.toInt()) }

        rootLayout = FrameLayout(this).apply {
            setBackgroundColor(0xFF000000.toInt())
            addView(surfaceView, FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            ))
            // Above the video, below the status label and pairing prompt.
            addView(idleCover, FrameLayout.LayoutParams(
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
            addView(pairOverlay, FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            ))
        }

        setContentView(rootLayout)
        // Nothing takes focus on launch (no keyboard); the pairing field only gets
        // it when the prompt is shown.
        rootLayout.isFocusableInTouchMode = true
        // The root covers the whole screen; once the window leaves touch mode (a
        // hardware keyboard, or key events) Android would draw its default focus
        // highlight over it, i.e. a grey wash over the picture and the black cover.
        rootLayout.defaultFocusHighlightEnabled = false
        rootLayout.requestFocus()
        hideSystemUi()
        Log.i(TAG, "onCreate done; touch capture via dispatchTouchEvent is active")
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density + 0.5f).toInt()

    // ------------------------------------------------------------ pairing prompt
    //
    // Shown only when it is needed: an encrypted stream has arrived and this tablet
    // has no key, or its saved key does not open it. A plaintext session, or a
    // saved key that works, never shows it.

    private fun buildPairPrompt(): FrameLayout {
        val title = TextView(this).apply {
            text = "Enter the 8-character code shown on your computer"
            setTextColor(0xFFFFFFFF.toInt())
            textSize = 22f
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
        }
        pairReason = TextView(this).apply {
            setTextColor(0xFFB8B8C0.toInt())
            textSize = 15f
            gravity = Gravity.CENTER
            setPadding(0, dp(8), 0, dp(20))
        }
        pairFieldBg = GradientDrawable().apply {
            setColor(0xFF0E0E12.toInt())
            cornerRadius = dp(14).toFloat()
            setStroke(dp(2), 0xFF4C8DD6.toInt())
        }
        // Only characters a code can contain get in; lower case is accepted and
        // shown as upper case.
        val codeFilter = InputFilter { src, start, end, _, _, _ ->
            val kept = StringBuilder(end - start)
            for (i in start until end) {
                val c = src[i].uppercaseChar()
                if (CODE_ALPHABET.indexOf(c) >= 0) kept.append(c)
            }
            if (kept.length < end - start) {
                setPairMessage("Codes use A–Z and 2–9, never I, O, 0 or 1.", 0xFFE0B050.toInt())
                pairShowsError = true
            }
            kept.toString()
        }
        pairInput = EditText(this).apply {
            hint = "--------"
            setTextColor(0xFFFFFFFF.toInt())
            setHintTextColor(0xFF4A4A52.toInt())
            background = pairFieldBg
            setPadding(dp(16), dp(14), dp(16), dp(14))
            textSize = 44f
            typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
            letterSpacing = 0.3f
            gravity = Gravity.CENTER
            isSingleLine = true
            filters = arrayOf(codeFilter, InputFilter.LengthFilter(CODE_LENGTH))
            // "Visible password" turns off prediction/autocorrect, which would
            // otherwise rewrite a code as it is typed.
            inputType = InputType.TYPE_CLASS_TEXT or
                InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS or
                InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS or
                InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
            imeOptions = EditorInfo.IME_ACTION_DONE or EditorInfo.IME_FLAG_NO_EXTRACT_UI
            setOnEditorActionListener { _, actionId, _ ->
                if (actionId == EditorInfo.IME_ACTION_DONE) { submitPairingCode(text.toString()); true }
                else false
            }
            // The code is checked as soon as the 8th character is in. Deferred via
            // post{} so that character is drawn before the field reacts.
            addTextChangedListener(object : TextWatcher {
                override fun afterTextChanged(s: Editable?) {
                    val n = s?.length ?: 0
                    if (n == CODE_LENGTH) { val c = s.toString(); post { submitPairingCode(c) } }
                }
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, cc: Int) {}
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, cc: Int) {
                    // Typing again clears the last error (not the one the filter
                    // just raised for this very keystroke: that adds no character).
                    if (pairShowsError && cc > 0 && !pairChecking) {
                        pairShowsError = false
                        setPairMessage("", 0)
                        pairFieldBg.setStroke(dp(2), 0xFF4C8DD6.toInt())
                    }
                }
            })
        }
        pairMessage = TextView(this).apply {
            textSize = 16f
            gravity = Gravity.CENTER
            minHeight = dp(26)
            setPadding(0, dp(14), 0, 0)
        }
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(32), dp(28), dp(32), dp(24))
            background = GradientDrawable().apply {
                setColor(0xFF1C1C22.toInt())
                cornerRadius = dp(22).toFloat()
                setStroke(dp(1), 0xFF3A3A44.toInt())
            }
            isClickable = true  // taps on the card are not "outside" taps
            addView(title)
            addView(pairReason)
            addView(pairInput, LinearLayout.LayoutParams(dp(420), LinearLayout.LayoutParams.WRAP_CONTENT))
            addView(pairMessage)
        }
        return FrameLayout(this).apply {
            setBackgroundColor(0xB3000000.toInt())
            visibility = View.GONE
            isClickable = true  // swallow touches: nothing behind the prompt is usable
            // Horizontally centred, in the upper part of the screen so the on-screen
            // keyboard does not cover it.
            addView(card, FrameLayout.LayoutParams(
                dp(560), FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.TOP or Gravity.CENTER_HORIZONTAL
            ).apply { topMargin = dp(72) })
        }
    }

    private fun setPairMessage(text: String, color: Int) {
        pairMessage.text = text
        if (color != 0) pairMessage.setTextColor(color)
    }

    private fun pairPromptVisible() = ::pairOverlay.isInitialized && pairOverlay.visibility == View.VISIBLE

    private fun inputMethod() =
        getSystemService(INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager

    /** Called (on the UI thread) when an encrypted stream arrived that the current
     *  key cannot open. [probe] is one sealed frame of that stream. */
    private fun showPairPrompt(reason: Int, probe: ByteArray) {
        // A report that raced a successful pairing: the key we hold opens it.
        pairingKey?.let { if (Sealer(it).open(probe, 0, probe.size) != null) return }
        pairProbe = probe
        if (pairChecking) return
        pairReason.text = if (reason == PAIR_WRONG_SAVED)
            "The code saved on this tablet does not match this computer."
        else
            "This computer encrypts the picture, so the tablet needs its code once."
        if (pairPromptVisible()) return                       // keep what is being typed
        if (android.os.SystemClock.uptimeMillis() < pairSnoozedUntil) return
        pairOverlay.removeCallbacks(dismissPairPrompt)
        pairShowsError = false
        setPairMessage("", 0)
        pairFieldBg.setStroke(dp(2), 0xFF4C8DD6.toInt())
        pairInput.setTextColor(0xFFFFFFFF.toInt())
        pairInput.isEnabled = true
        pairInput.setText("")
        pairOverlay.visibility = View.VISIBLE
        pairInput.requestFocus()
        pairInput.post { inputMethod().showSoftInput(pairInput, 0) }
        Log.i(TAG, "Pairing prompt shown (${if (reason == PAIR_WRONG_SAVED) "saved key does not match" else "no key"})")
    }

    private fun hidePairPrompt() {
        if (!pairPromptVisible()) return
        pairOverlay.removeCallbacks(dismissPairPrompt)
        pairOverlay.visibility = View.GONE
        inputMethod().hideSoftInputFromWindow(pairInput.windowToken, 0)
        rootLayout.requestFocus()
        hideSystemUi()
    }

    // Derives the key from the typed code (same KDF as both hosts) and checks it
    // against the sealed frame that raised the prompt. Only a code that opens that
    // frame is adopted and saved, so a wrong code gets an answer at once and never
    // replaces a working saved key.
    private fun submitPairingCode(code: String) {
        if (pairChecking || !pairPromptVisible() || code.length != CODE_LENGTH) return
        val probe = pairProbe ?: return
        pairChecking = true
        pairInput.isEnabled = false
        setPairMessage("Checking…", 0xFFB8B8C0.toInt())
        thread(name = "pair-check") {
            val key = try { Crypto.deriveKey(code) } catch (_: Exception) { null }
            val ok = key != null && Sealer(key).open(probe, 0, probe.size) != null
            runOnUiThread { onPairingChecked(if (ok) key else null) }
        }
    }

    private fun onPairingChecked(key: ByteArray?) {
        pairChecking = false
        if (key == null) {
            Log.i(TAG, "Pairing: the entered code does not match the stream")
            pairShowsError = true
            setPairMessage("That code doesn't match. Check it on your computer and try again.",
                0xFFFF6B6B.toInt())
            pairFieldBg.setStroke(dp(2), 0xFFFF6B6B.toInt())
            pairInput.isEnabled = true
            pairInput.setText("")
            pairInput.requestFocus()
            pairInput.post { inputMethod().showSoftInput(pairInput, 0) }
            return
        }
        pairingKey = key
        touchUplink.setKey(key)     // touch encrypts per-packet (reads key live)
        audioReceiver.setKey(key)   // audio decrypts per-frame (reads key live)
        receiver?.setKey(key)       // video decrypts per-frame
        // Remember the derived key so the code is typed once, ever.
        getSharedPreferences("pairing", MODE_PRIVATE).edit()
            .putString("key_b64", android.util.Base64.encodeToString(key, android.util.Base64.NO_WRAP))
            .apply()
        Log.i(TAG, "Paired: encryption enabled (key ${Crypto.hex(key).take(8)}…)")
        setPairMessage("Paired", 0xFF5FD68A.toInt())
        pairFieldBg.setStroke(dp(2), 0xFF5FD68A.toInt())
        pairInput.setTextColor(0xFF5FD68A.toInt())
        showStatus("Paired — waiting for the picture")
        // Get out of the way; the host retries by itself and the picture follows.
        pairOverlay.postDelayed(dismissPairPrompt, 900)
    }

    private fun confirmForgetPairing() {
        if (pairingKey == null) {
            Toast.makeText(this, "No pairing code is saved on this tablet.", Toast.LENGTH_SHORT).show()
            return
        }
        android.app.AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
            .setTitle("Forget the saved pairing code?")
            .setMessage("The tablet will ask for the code again the next time a computer " +
                "streams with Encrypt on. Streaming without Encrypt is not affected.")
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Forget") { _, _ -> forgetPairing() }
            .setOnDismissListener { hideSystemUi() }
            .show()
    }

    // Really forgets: the key in use AND the saved copy. (Before, clearing the key
    // in memory left the saved one, which came back on the next start.)
    private fun forgetPairing() {
        pairingKey = null
        pairProbe = null
        touchUplink.setKey(null)
        audioReceiver.setKey(null)
        receiver?.setKey(null)
        getSharedPreferences("pairing", MODE_PRIVATE).edit().remove("key_b64").commit()
        Log.i(TAG, "Pairing forgotten (saved key removed)")
        showStatus("Pairing code forgotten")
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (pairPromptVisible()) {
            // Dismiss for now; it comes back if an encrypted stream still needs it.
            pairSnoozedUntil = android.os.SystemClock.uptimeMillis() + PAIR_SNOOZE_MS
            hidePairPrompt()
        } else {
            @Suppress("DEPRECATION")
            super.onBackPressed()
        }
    }

    // Capture EVERY touch at the window level, before any child view can consume
    // it. This is far more reliable than a per-view OnTouchListener (a SurfaceView
    // in particular does not always deliver touches to a listener). We still call
    // through to super so the normal view hierarchy keeps working.
    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        // While the pairing prompt is up, touches are for the prompt, not the host.
        if (pairPromptVisible()) return super.dispatchTouchEvent(event)
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
        if (type >= 0 && !pairPromptVisible()) sendPointer(event, 0, type)
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
            onStatus = { status -> runOnUiThread { showStatus(status) } },
            onVideoShowing = { showing -> runOnUiThread { setVideoShowing(showing) } },
            onVideoSize = { w, h -> runOnUiThread { applyVideoSize(w, h) } },
            onEncrypted = { enc ->
                touchUplink.setKey(if (enc) pairingKey else null)
                // A plaintext session needs no code: make sure no prompt is up.
                if (!enc) runOnUiThread { hidePairPrompt() }
            },
            onPairingNeeded = { reason, probe -> runOnUiThread { showPairPrompt(reason, probe) } }
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
    private val onVideoSize: (Int, Int) -> Unit,
    // true once a decoded frame has been presented, false when the host's
    // connection ends — drives hiding/showing the on-screen status label.
    private val onVideoShowing: (Boolean) -> Unit = {},
    // Reports whether the incoming video stream is encrypted (TCP: EXVE marker;
    // UDP: first-packet latch) so the activity can match the touch channel to the
    // session — a saved key against an unencrypted sender must not seal touches.
    private val onEncrypted: (Boolean) -> Unit = {},
    // An encrypted stream arrived that cannot be opened: there is no key
    // (PAIR_NEEDS_CODE) or the key in use fails on it (PAIR_WRONG_SAVED). The
    // ByteArray is one sealed frame of that stream, for checking a typed code.
    private val onPairingNeeded: (Int, ByteArray) -> Unit = { _, _ -> }
) {
    private val running = AtomicBoolean(false)
    private var server: ServerSocket? = null
    private var udpSocket: java.net.DatagramSocket? = null
    private var codec: MediaCodec? = null
    @Volatile private var videoSealer: Sealer? = null
    @Volatile private var videoShowing = false

    // Bumped each time a host connects over TCP. A new connection is a new
    // stream and may use the other codec (H.264 <-> HEVC), so the running decode
    // session ends and the next one re-detects from the new stream's parameter
    // sets. (Before this the decoder chosen for the first stream was kept for
    // the life of the app, and switching codec on the host gave no picture.)
    private val streamGeneration = java.util.concurrent.atomic.AtomicInteger(0)
    // A NAL the decode thread had already taken from the queue when it noticed
    // the generation change; handed to the next session so the new stream's
    // first parameter set is not lost. Decode thread only.
    private var carriedNal: ByteArray? = null

    private fun setShowing(showing: Boolean) {
        if (videoShowing != showing) {
            videoShowing = showing
            onVideoShowing(showing)
        }
    }

    // A frame was presented by the decode session started at [generation]. Frames
    // still queued in the decoder keep coming out for a moment after the host
    // disconnects; without the generation check they flipped the state back to
    // "showing" right after endTcpStream() and the frozen last frame reappeared.
    private fun frameShown(generation: Int) = synchronized(streamGeneration) {
        if (streamGeneration.get() == generation) setShowing(true)
    }

    /** The host's TCP stream ended: stop the decode session, drop what is left of
     *  the stream and blank the picture. Returns true if a picture was showing. */
    private fun endTcpStream(): Boolean = synchronized(streamGeneration) {
        streamGeneration.incrementAndGet()
        nalQueue.clear()
        val wasShowing = videoShowing
        setShowing(false)
        wasShowing
    }

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
            var accepted = false
            try {
                server = ServerSocket().apply {
                    reuseAddress = true
                    receiveBufferSize = 1 shl 20
                    bind(InetSocketAddress(LISTEN_PORT))
                }
                server!!.accept().use { socket ->
                    accepted = true
                    socket.tcpNoDelay = true
                    nalQueue.clear()  // leftovers of the previous stream
                    streamGeneration.incrementAndGet()
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
                        onEncrypted(true)
                        // Length-prefixed encrypted frames [4B BE len][nonce+ct+tag].
                        // videoSealer is read PER-FRAME: before pairing it's null so we
                        // DRAIN frames (no garbage decode / no picture-of-noise); once
                        // you enter the code the next frames decrypt and video appears —
                        // all on the same connection, no reconnect.
                        val inp = java.io.DataInputStream(pin)
                        val lenBuf = ByteArray(4)
                        var opened = false     // a frame of this connection decrypted
                        var lastAsk = 0L       // when the pairing prompt was last asked for
                        while (running.get()) {
                            inp.readFully(lenBuf)
                            val n = ((lenBuf[0].toInt() and 0xff) shl 24) or
                                    ((lenBuf[1].toInt() and 0xff) shl 16) or
                                    ((lenBuf[2].toInt() and 0xff) shl 8) or
                                    (lenBuf[3].toInt() and 0xff)
                            if (n <= 0 || n > (8 shl 20)) break  // sanity / desync
                            val frame = ByteArray(n)
                            inp.readFully(frame)
                            val s = videoSealer
                            if (s == null) {
                                // Not keyed (yet, or the pairing was just forgotten):
                                // drain, blank any picture, and ask for the code. Asked
                                // again every few seconds in case the prompt was dismissed.
                                val now = android.os.SystemClock.uptimeMillis()
                                if (lastAsk == 0L || now - lastAsk >= 5000) {
                                    lastAsk = now
                                    endTcpStream()
                                    onPairingNeeded(PAIR_NEEDS_CODE, frame)
                                }
                                continue
                            }
                            val nal = s.open(frame, 0, frame.size)
                            if (nal == null) {
                                // The first frame not opening means a different pairing
                                // code; later on it is tampering/desync. Either way the
                                // connection is closed (the host notices and retries).
                                if (!opened) onPairingNeeded(PAIR_WRONG_SAVED, frame)
                                break
                            }
                            opened = true
                            nalQueue.put(nal)
                        }
                    } else {
                        onEncrypted(false)  // plaintext session (e.g. saved key, Encrypt off)
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
                // The picture on screen is now a frozen last frame: cover it and
                // say so. (Only after a real connection, so a failed bind does not
                // end a UDP session.)
                if (accepted && endTcpStream() && running.get()) {
                    onStatus("Disconnected — waiting for the computer")
                }
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
                // Each reassembled blob says what it is: a plaintext NAL begins with
                // an Annex-B start code, a sealed one with its nonce (first byte 0x01).
                // So a saved key against an UNENCRYPTED sender still shows the video,
                // and an encrypted sender is recognised even with no key (before, its
                // sealed blobs were fed to the decoder as if they were video).
                var udpMode = 0  // 0 = undecided, 1 = encrypted (a blob opened), 2 = plaintext
                var failures = 0
                var lastAsk = 0L
                val reasm = UdpReassembler { blob ->
                    if (!running.get()) return@UdpReassembler
                    if (startsWithStartCode(blob)) {
                        if (udpMode != 2) { udpMode = 2; onEncrypted(false) }
                        nalQueue.offer(blob)
                        return@UdpReassembler
                    }
                    val s = videoSealer
                    val pt = s?.open(blob, 0, blob.size)
                    if (pt != null) {
                        if (udpMode != 1) { udpMode = 1; failures = 0; onEncrypted(true) }
                        nalQueue.offer(pt)
                        return@UdpReassembler
                    }
                    // Sealed, and not openable: no key, or a different pairing code
                    // (once the session has opened blobs, a stray failure is just a
                    // damaged or forged packet and is dropped).
                    if (s != null && (udpMode == 1 || ++failures < 3)) return@UdpReassembler
                    val now = android.os.SystemClock.uptimeMillis()
                    if (lastAsk == 0L || now - lastAsk >= 5000) {
                        lastAsk = now
                        onPairingNeeded(if (s == null) PAIR_NEEDS_CODE else PAIR_WRONG_SAVED, blob)
                    }
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

    // A decode session may only begin at a parameter set: H.264 SPS (type 7) or
    // HEVC VPS/SPS/PPS (32-34). Anything else can neither identify the codec nor
    // be decoded yet, so it is skipped until one arrives (hosts send them with
    // every keyframe). H.264 PPS (8) is deliberately not accepted: an HEVC IDR's
    // first byte also reads as 8 under the H.264 mask.
    private fun startsStream(nal: ByteArray): Boolean {
        val sc = if (nal.size >= 4 && nal[2] == 0.toByte()) 4 else 3
        if (nal.size <= sc) return false
        val header = nal[sc].toInt() and 0xFF
        if (header and 0x80 != 0) return false
        val hevcType = (header shr 1) and 0x3F
        return hevcType in 32..34 || (header and 0x1F) == 7
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
        // Wait for a parameter set to pick H.264 vs HEVC (no codec header needed).
        var firstNal: ByteArray? = null
        while (running.get() && firstNal == null) {
            val candidate = carriedNal ?: nalQueue.poll(500, TimeUnit.MILLISECONDS)
            carriedNal = null
            if (candidate != null && startsStream(candidate)) firstNal = candidate
        }
        val first = firstNal ?: return
        val generation = streamGeneration.get()
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
                // Short poll, and drain on every idle wake-up: a frame finishes
                // decoding a few ms AFTER its NAL is queued, so the drain right
                // after queueInputBuffer misses it. Waiting for the next NAL to
                // drain left the newest frame undisplayed whenever the host
                // paused (the Mac host only sends frames when the screen changes).
                val current = nal ?: nalQueue.poll(4, TimeUnit.MILLISECONDS)
                if (streamGeneration.get() != generation) {
                    // A new host connection started: end this session (the
                    // finally below releases the decoder) and let the next one
                    // pick the codec again.
                    carriedNal = current
                    return
                }
                if (current == null) {
                    drainOutput(decoder, info, generation)
                    continue
                }
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
                        drainOutput(decoder, info, generation)
                    }
                }
                drainOutput(decoder, info, generation)
            }
        } finally {
            try { decoder.stop() } catch (_: Exception) {}
            try { decoder.release() } catch (_: Exception) {}
            if (codec === decoder) codec = null
        }
    }

    private fun drainOutput(decoder: MediaCodec, info: MediaCodec.BufferInfo, generation: Int) {
        while (true) {
            val outputIndex = decoder.dequeueOutputBuffer(info, 0)
            when {
                outputIndex >= 0 -> {
                    decoder.releaseOutputBuffer(outputIndex, true)
                    frameShown(generation)
                }
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
