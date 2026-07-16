package com.chadaustin.isitsnappy.core

import android.view.View
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding

/**
 * Safe-area helpers for edge-to-edge screens.
 *
 * "Safe area" = the union of the system bars (status + navigation, both gesture and
 * 3-button) and any display cutout (notch / punch-hole, which lands on a horizontal
 * edge in landscape). Controls must clear all of them on every device; backgrounds may
 * draw behind them.
 */
object SafeArea {

    private fun types(includeIme: Boolean): Int {
        var t = WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout()
        if (includeIme) t = t or WindowInsetsCompat.Type.ime()
        return t
    }

    /**
     * Pads [view] on the top and horizontal edges by the safe area, preserving the
     * padding declared in the layout. For bars pinned to the top of the screen.
     */
    fun padTop(view: View) = pad(view, top = true)

    /**
     * Pads [view] on the bottom and horizontal edges by the safe area, preserving the
     * padding declared in the layout. For bars pinned to the bottom of the screen.
     * [includeIme] additionally keeps the view above the soft keyboard.
     */
    fun padBottom(view: View, includeIme: Boolean = false) =
        pad(view, top = false, includeIme = includeIme)

    private fun pad(view: View, top: Boolean, includeIme: Boolean = false) {
        val base = Insets.of(view.paddingLeft, view.paddingTop, view.paddingRight, view.paddingBottom)
        ViewCompat.setOnApplyWindowInsetsListener(view) { v, insets ->
            val safe = insets.getInsets(types(includeIme))
            v.updatePadding(
                left = base.left + safe.left,
                right = base.right + safe.right,
                top = if (top) base.top + safe.top else base.top,
                bottom = if (top) base.bottom else base.bottom + safe.bottom,
            )
            insets
        }
    }

    /**
     * Offsets [view]'s layout margins by the safe area on the given edges, preserving the
     * margins declared in the layout. For floating controls (badges, corner buttons) that
     * are positioned by constraints rather than living inside a padded bar.
     */
    fun offsetMargins(
        view: View,
        top: Boolean = false,
        left: Boolean = false,
        right: Boolean = false,
        bottom: Boolean = false,
    ) {
        val lp = view.layoutParams as android.view.ViewGroup.MarginLayoutParams
        val base = Insets.of(lp.leftMargin, lp.topMargin, lp.rightMargin, lp.bottomMargin)
        ViewCompat.setOnApplyWindowInsetsListener(view) { v, insets ->
            val safe = insets.getInsets(types(includeIme = false))
            val p = v.layoutParams as android.view.ViewGroup.MarginLayoutParams
            p.leftMargin = base.left + if (left) safe.left else 0
            p.topMargin = base.top + if (top) safe.top else 0
            p.rightMargin = base.right + if (right) safe.right else 0
            p.bottomMargin = base.bottom + if (bottom) safe.bottom else 0
            v.layoutParams = p
            insets
        }
    }
}
