package com.chadaustin.isitsnappy.mark

import android.content.Context
import android.util.AttributeSet
import android.view.MotionEvent
import android.widget.FrameLayout
import kotlin.math.abs
import kotlin.math.pow

/**
 * Transparent overlay covering the player area (buttons/fields sit ABOVE it in z-order and
 * therefore consume their own touches first — iOS hit-test precedence).
 *
 * Zones (iOS SPEC §3.2): edge strips of EDGE_WIDTH_DP=30 at left and right receive TAPS;
 * everything else receives PANS. Taps fire on TOUCH-DOWN (ACTION_DOWN), not up
 * (TapDownGestureRecognizer parity); direction = tap x < width/2 -> backward, else forward.
 * A drag that starts in an edge strip does nothing (edge touches never pan).
 *
 * Pan (SPEC §3.4): on ACTION_DOWN outside the edges, onScrubBegin() fires; on every
 * ACTION_MOVE, offsetSeconds = curve(-(totalDxPx / density)) where
 *     curve(x) = sign(x) * (1.0 / 48000.0) * abs(x).pow(2.1)
 * (EXACT constants: k = 1/48000.0, exponent 2.1, translation negated, x in dp — iOS points
 * map to Android dp). Offsets are absolute from the gesture start, not incremental.
 */
class ScrubGestureView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : FrameLayout(context, attrs) {

    interface Listener {
        /** Edge tap, on touch-down. forward = tap was on the right half of the view. */
        fun onStepTap(forward: Boolean)

        /** Center pan started (capture gestureStart position now). */
        fun onScrubBegin()

        /** Center pan moved; offsetSeconds is the curved absolute offset from gesture start. */
        fun onScrubTo(offsetSeconds: Double)
    }

    var listener: Listener? = null

    private val density: Float = resources.displayMetrics.density
    private val edgeWidthPx: Float = EDGE_WIDTH_DP * density

    private var panning = false
    private var panStartX = 0f

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                val x = event.x
                val onEdge = x < edgeWidthPx || x > width - edgeWidthPx
                if (onEdge) {
                    // Edge tap fires immediately on touch-down; edge touches never pan.
                    panning = false
                    listener?.onStepTap(x >= width / 2f)
                } else {
                    panning = true
                    panStartX = x
                    listener?.onScrubBegin()
                }
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                if (panning) {
                    val totalDxPx = event.x - panStartX
                    listener?.onScrubTo(curve(-(totalDxPx / density).toDouble()))
                }
                return true
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                panning = false
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    private fun curve(x: Double): Double {
        val sign = if (x < 0) -1.0 else 1.0
        return sign * K * abs(x).pow(EXPONENT)
    }

    companion object {
        private const val EDGE_WIDTH_DP = 30f
        private const val K = 1.0 / 48000.0
        private const val EXPONENT = 2.1
    }
}
