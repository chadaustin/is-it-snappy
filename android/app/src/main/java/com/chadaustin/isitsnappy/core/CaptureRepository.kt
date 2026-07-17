package com.chadaustin.isitsnappy.core

import androidx.annotation.MainThread
import androidx.annotation.WorkerThread
import java.io.File
import java.util.UUID

/**
 * One recorded clip. id is the UUID string that is also the file's base name
 * (the Android replacement for PHAsset.localIdentifier — see SPEC §1.7).
 */
data class Capture(
    val id: String,
    val file: File,
    val createdAtMillis: Long,
)

/**
 * Repository over the app-private captures directory (filesDir/captures).
 * Files are named <uuid>.mp4. createdAtMillis = File.lastModified().
 */
class CaptureRepository(private val dir: File) {

    /**
     * New unique *pending* target file (dir created on demand). Recording writes here; the file only
     * becomes a listable `<uuid>.mp4` via [finalizePending] on a successful finalize. Does not create
     * the file. @MainThread.
     *
     * The `.tmp` suffix keeps an un-finalized (crash/OOM-orphaned) recording out of [list], so a file
     * with bytes but no moov atom can never surface as an undecodable junk row (Finding 3).
     */
    @MainThread
    fun newCaptureFile(): File {
        dir.mkdirs()
        val id = UUID.randomUUID().toString()
        return File(dir, "$id$PENDING_SUFFIX")
    }

    /**
     * Promote a successfully-finalized pending file to `<uuid>.mp4`. Returns the final file, or null
     * if the rename failed (caller should then delete the pending file). @WorkerThread-safe.
     */
    fun finalizePending(pending: File): File? {
        val id = pending.name.removeSuffix(PENDING_SUFFIX)
        val target = File(dir, "$id.mp4")
        return if (pending.renameTo(target)) target else null
    }

    /** All captures (unsorted). Blocking directory scan — call on Dispatchers.IO. */
    @WorkerThread
    fun list(): List<Capture> {
        val files = dir.listFiles() ?: return emptyList()
        // Prune orphaned pending files (never-finalized recordings) so they don't accumulate; they
        // are already excluded from the result by the `.mp4` filter below.
        files.filter { it.isFile && it.name.endsWith(PENDING_SUFFIX) }.forEach { runCatching { it.delete() } }
        return files
            .filter { it.isFile && it.name.endsWith(".mp4") }
            .map { Capture(id = it.nameWithoutExtension, file = it, createdAtMillis = it.lastModified()) }
    }

    /** Capture for id, or null if its file does not exist. @MainThread (single stat, cheap). */
    @MainThread
    fun get(id: String): Capture? {
        val file = File(dir, "$id.mp4")
        if (!file.exists()) return null
        return Capture(id = id, file = file, createdAtMillis = file.lastModified())
    }

    /** Deletes the video file. Returns true iff the file no longer exists. */
    @WorkerThread
    fun delete(id: String): Boolean {
        val file = File(dir, "$id.mp4")
        if (!file.exists()) return true
        file.delete()
        return !file.exists()
    }

    private companion object {
        const val PENDING_SUFFIX = ".mp4.tmp"
    }
}
