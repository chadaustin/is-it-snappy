package com.chadaustin.isitsnappy.mark

import android.media.MediaExtractor
import android.media.MediaFormat
import androidx.annotation.WorkerThread
import java.io.File

/**
 * The definitive per-frame presentation-timestamp table for one video file.
 * Built with MediaExtractor (no decoding): first "video/" track, all sample times collected,
 * then SORTED ascending (extractor yields decode order; B-frames require the sort — exactly
 * the iOS frameTimes construction, SPEC §2.4). Ground truth for all latency math; ExoPlayer
 * positions are never used for math (risk doc §2).
 */
class FrameIndex private constructor(val frameTimesUs: LongArray) {

    val frameCount: Int get() = frameTimesUs.size

    /** Index of the last frame with pts <= timeUs; 0 if timeUs precedes the first frame.
     *  (iOS frameNumber(for:) semantics, SPEC §2.5 — implemented as binary search.) */
    fun frameNumberFor(timeUs: Long): Int {
        if (frameTimesUs.isEmpty()) return 0
        var lo = 0
        var hi = frameTimesUs.size - 1
        var ans = 0
        while (lo <= hi) {
            val mid = (lo + hi) ushr 1
            if (frameTimesUs[mid] <= timeUs) {
                ans = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return ans
    }

    /** Stored-seconds variant with the iOS +1 ms epsilon (SPEC §2.5):
     *  frameNumberFor(((seconds + 0.001) * 1_000_000).toLong()) */
    fun frameNumberFor(seconds: Double): Int =
        frameNumberFor(((seconds + 0.001) * 1_000_000).toLong())

    /** Exact PTS of frame (µs), index clamped to [0, frameCount-1]; 0 if empty. */
    fun ptsUsFor(frame: Int): Long {
        if (frameTimesUs.isEmpty()) return 0L
        return frameTimesUs[frame.coerceIn(0, frameTimesUs.size - 1)]
    }

    companion object {
        /** Blocking MediaExtractor pass. Returns an empty index (frameCount == 0) on any
         *  error or if no video track exists — callers render the Failed state, never crash. */
        @WorkerThread
        fun build(file: File): FrameIndex {
            val extractor = MediaExtractor()
            try {
                extractor.setDataSource(file.absolutePath)
                var videoTrack = -1
                for (i in 0 until extractor.trackCount) {
                    val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME)
                    if (mime != null && mime.startsWith("video/")) {
                        videoTrack = i
                        break
                    }
                }
                if (videoTrack < 0) return FrameIndex(LongArray(0))
                extractor.selectTrack(videoTrack)

                // Walk every sample's presentation timestamp (µs) without decoding.
                val times = ArrayList<Long>()
                while (true) {
                    val t = extractor.sampleTime
                    if (t < 0) break // -1 == no more samples
                    times.add(t)
                    if (!extractor.advance()) break
                }

                // Extractor yields decode order; sort into presentation order so frame N is
                // frameTimesUs[N] (H.264+ can store frames out of presentation order).
                val arr = LongArray(times.size)
                for (i in times.indices) arr[i] = times[i]
                arr.sort()
                return FrameIndex(arr)
            } catch (t: Throwable) {
                return FrameIndex(LongArray(0))
            } finally {
                try {
                    extractor.release()
                } catch (_: Throwable) {
                    // release() may throw on a never-initialized extractor; ignore.
                }
            }
        }
    }
}
