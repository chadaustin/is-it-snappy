package com.chadaustin.isitsnappy.core

import java.util.Locale

/**
 * One Mark per capture, keyed by Capture.id.
 * input/output are SECONDS: the exact presentation timestamp of the marked frame
 * (frame PTS in microseconds / 1_000_000.0), never an arbitrary player position.
 * Any field may be absent. Field semantics identical to iOS MarkDatabase.Mark.
 */
data class Mark(
    val name: String? = null,
    val input: Double? = null,
    val output: Double? = null,
) {
    /** "%.1f" of (output - input) * 1000, or null if either endpoint is missing. */
    val elapsedMs: String?
        get() {
            val i = input ?: return null
            val o = output ?: return null
            return String.format(Locale.US, "%.1f", (o - i) * 1000.0)
        }

    /**
     * iOS displayLabel semantics, em dash U+2014:
     *   name + elapsed -> "name — 12.3 ms"
     *   name only      -> "name —"
     *   elapsed only   -> "— 12.3 ms"
     *   neither        -> "—"
     * defaultName substitutes for name only when name == null.
     */
    fun displayLabel(defaultName: String? = null): String {
        val n = name ?: defaultName
        val e = elapsedMs
        return when {
            n != null && e != null -> "$n — $e ms"
            n != null -> "$n —"
            e != null -> "— $e ms"
            else -> "—"
        }
    }
}
