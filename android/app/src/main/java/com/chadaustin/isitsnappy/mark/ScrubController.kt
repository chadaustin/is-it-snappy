package com.chadaustin.isitsnappy.mark

import androidx.annotation.MainThread
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer

/**
 * Coalescing seek queue over ExoPlayer + FrameIndex. Exactly one player seek in flight at a
 * time; while one is in flight, newer targets replace each other and only the latest is
 * issued when the in-flight seek completes (iOS .seeking / .seekingWithPendingSeek).
 * Seek completion is detected via Player.Listener: after issuing seekTo(), the seek is
 * complete at the first callback (onPositionDiscontinuity / onPlaybackStateChanged) after
 * which playbackState == STATE_READY. All @MainThread.
 */
@MainThread
class ScrubController(
    private val player: ExoPlayer,
    private val frameIndex: FrameIndex,
) {
    /** Authoritative playhead in µs (may be between frame PTS values during a pan). Starts 0. */
    var currentPositionUs: Long = 0L
        private set

    /** Invoked (main thread) every time a seek completes or a target is committed — the
     *  activity refreshes its labels here. */
    var onPositionCommitted: (() -> Unit)? = null

    /** PTS of the last frame; the upper clamp bound (iOS clamps to item duration). */
    private val lastPtsUs: Long =
        if (frameIndex.frameCount > 0) frameIndex.ptsUsFor(frameIndex.frameCount - 1) else 0L

    private var seeking = false
    private var pendingSeekMs: Long? = null

    // A freshly-prepared ExoPlayer sits at position 0 ms. Seeding lastSeekMs to 0 means an
    // initial aim at frame 0 (the common case where the first frame's PTS rounds to 0 ms)
    // issues no redundant seek — a redundant seek to the current position may not emit a
    // discontinuity callback and would otherwise strand the in-flight `seeking` flag.
    private var lastSeekMs: Long = 0L

    private val listener = object : Player.Listener {
        override fun onPositionDiscontinuity(
            oldPosition: Player.PositionInfo,
            newPosition: Player.PositionInfo,
            reason: Int,
        ) = maybeCompleteSeek()

        override fun onPlaybackStateChanged(playbackState: Int) = maybeCompleteSeek()
    }

    init {
        player.addListener(listener)
    }

    /** iOS aimAt(time:): set currentPositionUs = timeUs (clamped to [0, lastPts]), snap to
     *  frame via frameIndex, and issue/coalesce a player seek to the snapped frame (§9.3). */
    fun aimAt(timeUs: Long) {
        if (frameIndex.frameCount == 0) {
            currentPositionUs = 0L
            onPositionCommitted?.invoke()
            return
        }
        val clamped = timeUs.coerceIn(0L, lastPtsUs)
        currentPositionUs = clamped
        val frame = frameIndex.frameNumberFor(clamped)
        requestSeek(frameIndex.ptsUsFor(frame))
        onPositionCommitted?.invoke()
    }

    /** Step relative to the CURRENT frame: frame = frameNumberFor(currentPositionUs) + delta,
     *  clamped by ptsUsFor; then aimAt(ptsUsFor(frame)). delta ±1 for edge taps. */
    fun stepFrames(delta: Int) {
        val frame = frameIndex.frameNumberFor(currentPositionUs) + delta
        aimAt(frameIndex.ptsUsFor(frame))
    }

    /** Current frame number (for labels): frameIndex.frameNumberFor(currentPositionUs). */
    fun currentFrame(): Int = frameIndex.frameNumberFor(currentPositionUs)

    /** iOS currentFrameTime: the current frame's exact PTS in seconds — the value stored by
     *  Mark Input / Mark Output. */
    fun currentFrameTimeSeconds(): Double = frameIndex.ptsUsFor(currentFrame()) / 1_000_000.0

    /** Detach from the player. Safe to call once; the player itself is owned by the activity. */
    fun release() {
        player.removeListener(listener)
    }

    private fun requestSeek(snappedPtsUs: Long) {
        // Round the snapped frame's PTS up to the next whole ms so an EXACT seek lands within
        // [pts, nextPts) and therefore displays exactly the intended frame (§9.3).
        val seekMs = (snappedPtsUs + 999) / 1000
        when {
            seeking -> pendingSeekMs = seekMs
            seekMs != lastSeekMs -> performSeek(seekMs)
            // else: already displaying this frame; no player seek needed.
        }
    }

    private fun performSeek(seekMs: Long) {
        seeking = true
        lastSeekMs = seekMs
        player.seekTo(seekMs)
    }

    private fun maybeCompleteSeek() {
        if (!seeking || player.playbackState != Player.STATE_READY) return
        seeking = false
        val pending = pendingSeekMs
        pendingSeekMs = null
        if (pending != null && pending != lastSeekMs) {
            performSeek(pending)
        }
        onPositionCommitted?.invoke()
    }
}
