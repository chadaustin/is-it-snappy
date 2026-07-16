package com.chadaustin.isitsnappy.capture

import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.os.Bundle
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.View
import android.widget.SeekBar
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import com.chadaustin.isitsnappy.R
import com.chadaustin.isitsnappy.app
import com.chadaustin.isitsnappy.core.Capture
import com.chadaustin.isitsnappy.databinding.ActivityCaptureBinding
import com.chadaustin.isitsnappy.mark.MarkActivity

/**
 * Fullscreen camera screen (DESIGN §8.6). Owns the UI state machine; all camera work is delegated
 * to [CaptureEngine]. Must never crash on first boot: if CAMERA permission is somehow not granted
 * (process-death restore after MainActivity gated the launch), the engine is never started and the
 * Failed UI is shown with a working Cancel button — there is no SecurityException path.
 */
class CaptureActivity : AppCompatActivity() {

    private lateinit var binding: ActivityCaptureBinding
    private var engine: CaptureEngine? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityCaptureBinding.inflate(layoutInflater)
        setContentView(binding.root)

        // Enforced edge-to-edge (targetSdk 35): keep Cancel/Record clear of the gesture nav bar
        // and the fps badge / focus toggle clear of the status bar.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        ViewCompat.setOnApplyWindowInsetsListener(binding.root) { _, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            binding.bottomBar.updatePadding(bottom = bars.bottom)
            binding.fpsBadge.updatePadding(top = bars.top)
            insets
        }

        binding.cancelButton.setOnClickListener { onCancelClicked() }
        binding.recordButton.setOnClickListener { onRecordClicked() }
        binding.flipButton.setOnClickListener { engine?.flipCamera() }
        binding.focusToggle.setOnClickListener { onToggleFocusClicked() }

        binding.focusSlider.max = MANUAL_FOCUS_STEPS
        binding.focusSlider.progress = MANUAL_FOCUS_STEPS / 2
        binding.focusSlider.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(seekBar: SeekBar, progress: Int, fromUser: Boolean) {
                if (fromUser) engine?.setManualFocusPosition(progress.toFloat() / MANUAL_FOCUS_STEPS)
            }

            override fun onStartTrackingTouch(seekBar: SeekBar) {}
            override fun onStopTrackingTouch(seekBar: SeekBar) {}
        })

        setupPreviewTouch()

        if (ContextCompat.checkSelfPermission(this, android.Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED
        ) {
            // No engine, no camera bind, no SecurityException. Just the graceful failure surface.
            renderState(CaptureEngine.State.Failed(getString(R.string.capture_unable_to_capture)))
            return
        }

        val newEngine = CaptureEngine(this, binding.previewView, app.captureRepository)
        newEngine.listener = engineListener
        engine = newEngine
        newEngine.start()
    }

    override fun onDestroy() {
        super.onDestroy()
        // Prevent any late finalize callback from touching a destroyed activity.
        engine?.listener = null
    }

    private fun setupPreviewTouch() {
        val detector = GestureDetector(this, object : GestureDetector.SimpleOnGestureListener() {
            override fun onDown(e: MotionEvent): Boolean = true
            override fun onSingleTapUp(e: MotionEvent): Boolean {
                engine?.tapToFocus(e.x, e.y)
                return true
            }
        })
        binding.previewView.setOnTouchListener { v, event ->
            val handled = detector.onTouchEvent(event)
            if (event.actionMasked == MotionEvent.ACTION_UP) v.performClick()
            handled
        }
    }

    private val engineListener = object : CaptureEngine.Listener {
        override fun onStateChanged(state: CaptureEngine.State) = renderState(state)

        override fun onRecordingSaved(capture: Capture) {
            // Every successful recording flows straight into marking (SPEC §1.6).
            startActivity(MarkActivity.newIntent(this@CaptureActivity, capture.id))
            finish()
        }

        override fun onRecordingEnded(cancelled: Boolean) {
            // Cancel dismisses the capture screen; a plain failure leaves us on the (re-emitted)
            // Idle state so the user can retry.
            if (cancelled) finish()
        }

        override fun onAutoFocusDistanceChanged(position: Float) {
            if (engine?.isAutoFocus == true) {
                binding.focusSlider.progress =
                    (position * MANUAL_FOCUS_STEPS).toInt().coerceIn(0, MANUAL_FOCUS_STEPS)
            }
        }
    }

    private fun onCancelClicked() {
        val eng = engine
        if (eng != null && eng.state is CaptureEngine.State.Recording) {
            eng.cancelRecording()
        } else {
            finish()
        }
    }

    private fun onRecordClicked() {
        val eng = engine ?: return
        when (eng.state) {
            is CaptureEngine.State.Idle -> eng.startRecording()
            is CaptureEngine.State.Recording -> eng.stopRecording()
            else -> {}
        }
    }

    private fun onToggleFocusClicked() {
        val eng = engine ?: return
        eng.setAutoFocus(!eng.isAutoFocus)
        renderFocusControls(eng.state)
    }

    private fun renderState(state: CaptureEngine.State) {
        // Lock orientation while recording/finishing (iOS shouldAutorotate parity, DESIGN §8.6).
        requestedOrientation = when (state) {
            is CaptureEngine.State.Recording,
            is CaptureEngine.State.Finishing,
            is CaptureEngine.State.Cancelling,
            -> ActivityInfo.SCREEN_ORIENTATION_LOCKED
            else -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }

        val idle = state as? CaptureEngine.State.Idle
        val isFailed = state is CaptureEngine.State.Failed
        val isIdle = idle != null
        val isRecording = state is CaptureEngine.State.Recording
        val isBusy = state is CaptureEngine.State.Cancelling || state is CaptureEngine.State.Finishing

        // Cancel: on for Failed / Idle / Recording; off for CreatingSession / Cancelling / Finishing.
        binding.cancelButton.isEnabled = isFailed || isIdle || isRecording

        // Record: on for Idle / Recording; label "Done" once recording/finishing.
        binding.recordButton.isEnabled = isIdle || isRecording
        binding.recordButton.text =
            getString(if (isRecording || isBusy) R.string.capture_done else R.string.capture_record)

        // Flip: only in Idle, only if multiple cameras.
        val showFlip = isIdle && idle!!.canFlipCamera
        binding.flipButton.visibility = if (showFlip) View.VISIBLE else View.GONE
        binding.flipButton.isEnabled = showFlip

        renderFocusControls(state)

        // fps badge: shown in Idle (with the achieved label) and kept visible through Recording.
        when {
            isIdle -> {
                binding.fpsBadge.text = idle!!.fpsLabel
                binding.fpsBadge.visibility = View.VISIBLE
            }
            isRecording -> binding.fpsBadge.visibility = View.VISIBLE
            else -> binding.fpsBadge.visibility = View.GONE
        }

        // Failure message.
        if (isFailed) {
            binding.failedMessage.text = (state as CaptureEngine.State.Failed).message
            binding.failedMessage.visibility = View.VISIBLE
            binding.failedHint.visibility = View.VISIBLE
        } else {
            binding.failedMessage.visibility = View.GONE
            binding.failedHint.visibility = View.GONE
        }

        // Busy overlay: dim scrim + spinner (Cancelling / Finishing).
        binding.busyScrim.visibility = if (isBusy) View.VISIBLE else View.GONE
        binding.progressSpinner.visibility = if (isBusy) View.VISIBLE else View.GONE
    }

    private fun renderFocusControls(state: CaptureEngine.State) {
        val idle = state as? CaptureEngine.State.Idle
        val showToggle = idle != null && idle.supportsManualFocus
        binding.focusToggle.visibility = if (showToggle) View.VISIBLE else View.GONE

        val auto = engine?.isAutoFocus ?: true
        binding.focusToggle.text = getString(if (auto) R.string.capture_af else R.string.capture_mf)

        val showSlider = showToggle && !auto
        binding.focusSlider.visibility = if (showSlider) View.VISIBLE else View.INVISIBLE
    }

    companion object {
        private const val MANUAL_FOCUS_STEPS = 1000

        fun newIntent(context: Context): Intent = Intent(context, CaptureActivity::class.java)
    }
}
