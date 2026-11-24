package com.heysnap.extdisplay

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RadialGradient
import android.graphics.Shader
import android.os.SystemClock
import android.view.View
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin

/**
 * The idle backdrop: a deep indigo base with soft, blurred colour fields (violet,
 * indigo, aurora teal, a warm glow) drawn in code, plus a vignette and a fine
 * grain that hides banding. The fields drift very slowly. The animation ticks at
 * ~10 fps and only while the view is actually on screen, so while video is
 * showing (the idle layer is GONE) it costs nothing.
 */
class IdleView(context: Context) : View(context) {
    private class Field(
        val fx: Float, val fy: Float,          // centre, as a fraction of width / height
        val radius: Float,                      // as a fraction of width
        val color: Int, val alpha: Float,
        val periodS: Float, val phase: Float    // drift
    ) {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.DITHER_FLAG)
        var r = 0f
    }

    private val fields = listOf(
        Field(0.20f, 0.26f, 0.52f, 0xFF7A63F2.toInt(), 0.90f, 70f, 0.0f),   // violet
        Field(0.82f, 0.72f, 0.58f, 0xFF3B2A9E.toInt(), 1.00f, 90f, 1.7f),   // indigo
        Field(0.74f, 0.16f, 0.36f, 0xFF3FD0C0.toInt(), 0.55f, 55f, 3.1f),   // aurora teal
        Field(0.28f, 0.92f, 0.34f, 0xFFFF9A55.toInt(), 0.55f, 65f, 4.6f),   // warm glow
        Field(0.52f, 0.52f, 0.30f, 0xFFC45AD0.toInt(), 0.22f, 80f, 5.4f)    // orchid blend
    )
    private val basePaint = Paint(Paint.DITHER_FLAG)
    private val vignettePaint = Paint(Paint.DITHER_FLAG)
    private val grainPaint = Paint()
    private var ticking = false

    private val tick = object : Runnable {
        override fun run() {
            if (!ticking) return
            invalidate()
            postDelayed(this, FRAME_MS)
        }
    }

    init {
        setWillNotDraw(false)
        grainPaint.shader = BitmapShader(makeGrain(), Shader.TileMode.REPEAT, Shader.TileMode.REPEAT)
    }

    private fun makeGrain(): Bitmap {
        val n = 128
        val px = IntArray(n * n)
        val rnd = java.util.Random(7)
        for (i in px.indices) {
            val a = rnd.nextInt(13)                       // 0..12 of 255
            px[i] = if (rnd.nextBoolean()) Color.argb(a, 255, 255, 255) else Color.argb(a, 0, 0, 0)
        }
        return Bitmap.createBitmap(px, n, n, Bitmap.Config.ARGB_8888)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        if (w <= 0 || h <= 0) return
        basePaint.shader = LinearGradient(
            0f, 0f, w * 0.6f, h.toFloat(),
            intArrayOf(0xFF0A0722.toInt(), 0xFF140B3A.toInt(), 0xFF081A2C.toInt()),
            floatArrayOf(0f, 0.55f, 1f), Shader.TileMode.CLAMP
        )
        for (f in fields) {
            f.r = f.radius * w
            val c = f.color and 0x00FFFFFF
            val a = f.alpha
            f.paint.shader = RadialGradient(
                0f, 0f, f.r,
                intArrayOf(
                    c or ((255 * a).toInt() shl 24),
                    c or ((255 * a * 0.55f).toInt() shl 24),
                    c or ((255 * a * 0.16f).toInt() shl 24),
                    c
                ),
                floatArrayOf(0f, 0.35f, 0.7f, 1f), Shader.TileMode.CLAMP
            )
        }
        val vr = hypot(w.toFloat(), h.toFloat()) / 2f
        vignettePaint.shader = RadialGradient(
            w / 2f, h / 2f, vr,
            intArrayOf(0x00000000, 0x00000000, 0x80050314.toInt()),
            floatArrayOf(0f, 0.55f, 1f), Shader.TileMode.CLAMP
        )
    }

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat()
        val h = height.toFloat()
        canvas.drawRect(0f, 0f, w, h, basePaint)
        val t = SystemClock.uptimeMillis() / 1000f
        for (f in fields) {
            val ang = (t / f.periodS) * (2f * Math.PI.toFloat()) + f.phase
            val cx = (f.fx + 0.035f * sin(ang)) * w
            val cy = (f.fy + 0.045f * cos(ang * 0.8f)) * h
            canvas.save()
            canvas.translate(cx, cy)
            canvas.drawCircle(0f, 0f, f.r, f.paint)
            canvas.restore()
        }
        canvas.drawRect(0f, 0f, w, h, vignettePaint)
        canvas.drawRect(0f, 0f, w, h, grainPaint)
    }

    private fun updateTicking() {
        val want = isShown && windowVisibility == VISIBLE
        if (want == ticking) return
        ticking = want
        removeCallbacks(tick)
        if (want) postDelayed(tick, FRAME_MS)
    }

    override fun onAttachedToWindow() { super.onAttachedToWindow(); updateTicking() }
    override fun onDetachedFromWindow() { ticking = false; removeCallbacks(tick); super.onDetachedFromWindow() }
    override fun onVisibilityChanged(changedView: View, visibility: Int) {
        super.onVisibilityChanged(changedView, visibility); updateTicking()
    }
    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(visibility); updateTicking()
    }

    private companion object { const val FRAME_MS = 100L }
}
