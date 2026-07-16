package com.chadaustin.isitsnappy.mark

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.EditText
import android.widget.ProgressBar
import android.widget.TextView
import androidx.annotation.OptIn
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import androidx.lifecycle.lifecycleScope
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.SeekParameters
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import com.chadaustin.isitsnappy.R
import com.chadaustin.isitsnappy.app
import com.chadaustin.isitsnappy.core.Mark
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Locale

/**
 * Mark screen: ExoPlayer preview + frame-accurate scrubbing/marking over one capture.
 * The latency number is computed entirely from FrameIndex PTS (§9), never from player
 * positions. Never crashes: a missing capture, an undecodable file, or a video track with no
 * frames all resolve to the Failed UI with a working Done button.
 */
@OptIn(markerClass = [UnstableApi::class])
class MarkActivity : AppCompatActivity() {

    private lateinit var rootView: View
    private lateinit var playerView: PlayerView
    private lateinit var gestureView: ScrubGestureView
    private lateinit var topBar: View
    private lateinit var bottomBar: View
    private lateinit var nameField: EditText
    private lateinit var doneButton: Button
    private lateinit var markInputButton: Button
    private lateinit var markOutputButton: Button
    private lateinit var locationLabel: TextView
    private lateinit var loadingView: ProgressBar
    private lateinit var failedMessage: TextView

    private var player: ExoPlayer? = null
    private var scrubController: ScrubController? = null
    private var frameIndex: FrameIndex? = null

    private var captureId: String? = null
    private var playerReady = false
    private var frameIndexResult: FrameIndex? = null
    private var isIdle = false
    private var failed = false
    private var gestureStartUs = 0L

    private val playerListener = object : Player.Listener {
        override fun onPlaybackStateChanged(playbackState: Int) {
            if (playbackState == Player.STATE_READY && !playerReady) {
                playerReady = true
                maybeStart()
            }
        }

        override fun onPlayerError(error: PlaybackException) {
            showFailed()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_mark)

        rootView = findViewById(R.id.mark_root)
        playerView = findViewById(R.id.player_view)
        gestureView = findViewById(R.id.scrub_gesture)
        topBar = findViewById(R.id.top_bar)
        bottomBar = findViewById(R.id.bottom_bar)
        nameField = findViewById(R.id.capture_name_field)
        doneButton = findViewById(R.id.done_button)
        markInputButton = findViewById(R.id.mark_input_button)
        markOutputButton = findViewById(R.id.mark_output_button)
        locationLabel = findViewById(R.id.location_label)
        loadingView = findViewById(R.id.loading)
        failedMessage = findViewById(R.id.failed_message)

        playerView.useController = false
        playerView.resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT

        doneButton.setOnClickListener { onDonePressed() }
        markInputButton.setOnClickListener { onMarkInput() }
        markOutputButton.setOnClickListener { onMarkOutput() }
        setupNameField()
        setupGestures()
        setupWindowInsets()

        val id = intent.getStringExtra(EXTRA_CAPTURE_ID)
        captureId = id
        if (id == null) {
            showFailed()
            return
        }
        val capture = app.captureRepository.get(id)
        if (capture == null) {
            showFailed()
            return
        }

        val exo = ExoPlayer.Builder(this).build().also { p ->
            p.setSeekParameters(SeekParameters.EXACT)
            p.setScrubbingModeEnabled(true)
            p.playWhenReady = false
            p.setMediaItem(MediaItem.fromUri(Uri.fromFile(capture.file)))
            p.addListener(playerListener)
            p.prepare()
        }
        player = exo
        playerView.player = exo

        lifecycleScope.launch {
            val index = withContext(Dispatchers.IO) { FrameIndex.build(capture.file) }
            frameIndexResult = index
            maybeStart()
        }
    }

    override fun onDestroy() {
        scrubController?.release()
        scrubController = null
        player?.let {
            it.removeListener(playerListener)
            it.release()
        }
        player = null
        super.onDestroy()
    }

    /** Enters Idle once BOTH the player is ready and the FrameIndex is built (§9.1). */
    private fun maybeStart() {
        if (isIdle || failed) return
        val index = frameIndexResult ?: return
        if (!playerReady) return
        val p = player ?: return
        if (index.frameCount == 0) {
            // No decodable frames: nothing to mark. Render Failed (never crash).
            showFailed()
            return
        }

        val controller = ScrubController(p, index)
        controller.onPositionCommitted = { updateLocationLabel() }
        scrubController = controller
        frameIndex = index
        isIdle = true

        loadingView.visibility = View.GONE
        bottomBar.visibility = View.VISIBLE
        gestureView.visibility = View.VISIBLE

        updateNameField()
        updateButtonLabels()
        controller.aimAt(0L)
        updateLocationLabel()
    }

    private fun showFailed() {
        if (failed) return
        failed = true
        loadingView.visibility = View.GONE
        gestureView.visibility = View.GONE
        bottomBar.visibility = View.GONE
        nameField.visibility = View.INVISIBLE
        failedMessage.visibility = View.VISIBLE
        topBar.visibility = View.VISIBLE
    }

    // --- Window insets (edge-to-edge, targetSdk 35) -------------------------------------

    /**
     * targetSdk 35 forces edge-to-edge, so the system bars draw over the content. Pad the top bar
     * clear of the status bar and the bottom bar clear of the gesture/navigation bar so neither
     * gets drawn under a system-inset region (Finding 4).
     */
    private fun setupWindowInsets() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        ViewCompat.setOnApplyWindowInsetsListener(rootView) { _, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            topBar.updatePadding(top = bars.top)
            bottomBar.updatePadding(bottom = bars.bottom)
            insets
        }
    }

    // --- Gestures -----------------------------------------------------------------------

    private fun setupGestures() {
        gestureView.listener = object : ScrubGestureView.Listener {
            override fun onStepTap(forward: Boolean) {
                commitNameIfEditing()
                scrubController?.stepFrames(if (forward) 1 else -1)
            }

            override fun onScrubBegin() {
                commitNameIfEditing()
                gestureStartUs = scrubController?.currentPositionUs ?: 0L
            }

            override fun onScrubTo(offsetSeconds: Double) {
                scrubController?.aimAt(gestureStartUs + (offsetSeconds * 1_000_000).toLong())
            }
        }
    }

    // --- Marking ------------------------------------------------------------------------

    private fun onMarkInput() {
        val id = captureId ?: return
        val controller = scrubController ?: return
        app.markStore.setInputTime(id, controller.currentFrameTimeSeconds())
        updateNameField()
        updateLocationLabel()
        updateButtonLabels()
    }

    private fun onMarkOutput() {
        val id = captureId ?: return
        val controller = scrubController ?: return
        app.markStore.setOutputTime(id, controller.currentFrameTimeSeconds())
        updateNameField()
        updateLocationLabel()
        updateButtonLabels()
    }

    // --- Name field ---------------------------------------------------------------------

    private fun setupNameField() {
        nameField.setOnFocusChangeListener { _, hasFocus ->
            if (hasFocus) {
                val id = captureId
                nameField.setText(if (id != null) app.markStore.get(id)?.name ?: "" else "")
            }
        }
        nameField.setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_DONE) {
                commitName()
                true
            } else {
                false
            }
        }
    }

    private fun onDonePressed() {
        if (failed) {
            finish()
            return
        }
        if (nameField.hasFocus()) commitName() else finish()
    }

    private fun commitNameIfEditing() {
        if (nameField.hasFocus()) commitName()
    }

    private fun commitName() {
        val id = captureId
        if (id != null) {
            app.markStore.setName(id, nameField.text.toString())
        }
        clearNameFocus()
        updateNameField()
    }

    private fun clearNameFocus() {
        // Move focus to the focusable root container so clearing sticks: clearFocus() alone would
        // bounce straight back to the name field when it is the only focusable view (seed bug).
        nameField.clearFocus()
        rootView.requestFocus()
        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
        imm?.hideSoftInputFromWindow(nameField.windowToken, 0)
    }

    // --- Readouts (§9.6) ----------------------------------------------------------------

    private fun updateNameField() {
        if (nameField.hasFocus()) return
        val id = captureId ?: return
        val mark = app.markStore.get(id) ?: Mark()
        nameField.setText(mark.displayLabel(getString(R.string.mark_default_name)))
    }

    private fun updateLocationLabel() {
        val id = captureId ?: return
        val index = frameIndex ?: return
        val controller = scrubController ?: return
        val frame = controller.currentFrame()
        val timeStr = String.format(Locale.US, "%.1f", index.ptsUsFor(frame) / 1000.0)
        val input = app.markStore.get(id)?.input
        val frameOffset = if (input != null) {
            val n = frame - index.frameNumberFor(input)
            if (n > 0) "(+$n)" else "($n)"
        } else {
            ""
        }
        val framePart = getString(R.string.mark_frame, frame) + frameOffset
        locationLabel.text = getString(R.string.mark_location, framePart, timeStr)
    }

    private fun updateButtonLabels() {
        val id = captureId ?: return
        val index = frameIndex ?: return
        val mark = app.markStore.get(id)
        val inputLabel = mark?.input?.let { getString(R.string.mark_frame, index.frameNumberFor(it)) }
            ?: getString(R.string.mark_no_mark)
        val outputLabel = mark?.output?.let { getString(R.string.mark_frame, index.frameNumberFor(it)) }
            ?: getString(R.string.mark_no_mark)
        markInputButton.text = getString(R.string.mark_input_button, inputLabel)
        markOutputButton.text = getString(R.string.mark_output_button, outputLabel)
    }

    companion object {
        const val EXTRA_CAPTURE_ID = "capture_id"

        fun newIntent(context: Context, captureId: String): Intent =
            Intent(context, MarkActivity::class.java).putExtra(EXTRA_CAPTURE_ID, captureId)
    }
}
