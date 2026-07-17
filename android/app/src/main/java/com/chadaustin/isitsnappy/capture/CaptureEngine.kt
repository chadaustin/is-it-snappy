package com.chadaustin.isitsnappy.capture

import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.util.Range
import androidx.annotation.MainThread
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.camera2.interop.Camera2CameraControl
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.camera2.interop.CaptureRequestOptions
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.Camera
import androidx.camera.core.CameraInfo
import androidx.camera.core.CameraSelector
import androidx.camera.core.ExperimentalSessionConfig
import androidx.camera.core.ExtendableBuilder
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.Preview
import androidx.camera.core.SessionConfig
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.ExperimentalHighSpeedVideo
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.HighSpeedVideoSessionConfig
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import com.chadaustin.isitsnappy.R
import com.chadaustin.isitsnappy.core.Capture
import com.chadaustin.isitsnappy.core.CaptureRepository
import java.io.File

/**
 * All CameraX interaction (DESIGN §8). Created in CaptureActivity.onCreate, started once.
 * Every listener callback arrives on the main thread. No CameraX call is allowed to escape as a
 * crash: every rung of the fallback ladder and every hand-off is wrapped so a failure degrades to
 * the next rung or to [State.Failed], never throws.
 */
@MainThread
@OptIn(
    ExperimentalHighSpeedVideo::class,
    ExperimentalSessionConfig::class,
)
@androidx.annotation.OptIn(markerClass = [ExperimentalCamera2Interop::class])
class CaptureEngine(
    private val activity: AppCompatActivity,
    private val previewView: PreviewView,
    private val repository: CaptureRepository,
) {
    sealed interface State {
        object CreatingSession : State
        /** Terminal: no usable camera / bind failed at every ladder rung. UI shows message; Cancel works. */
        data class Failed(val message: String) : State
        /** Ready. fpsLabel e.g. "240 fps", "120 fps", "60 fps", "30 fps". */
        data class Idle(val fpsLabel: String, val canFlipCamera: Boolean, val supportsManualFocus: Boolean) : State
        object Recording : State
        object Cancelling : State
        object Finishing : State
    }

    interface Listener {
        fun onStateChanged(state: State)
        /** Recording finalized and file is in the repository. Fired once, after Finishing. */
        fun onRecordingSaved(capture: Capture)
        /** Recording failed or was cancelled; file already deleted. Engine returns to Idle (or Failed). */
        fun onRecordingEnded(cancelled: Boolean)
        /** Mirrors iOS lensPosition KVO: reports AF-driven focus distance while in auto mode. */
        fun onAutoFocusDistanceChanged(position: Float)
    }

    var listener: Listener? = null

    var state: State = State.CreatingSession
        private set

    val isAutoFocus: Boolean
        get() = autoFocus

    private val mainExecutor = ContextCompat.getMainExecutor(activity)

    private var started = false
    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null

    /** true = the back camera is currently selected/desired; false = front. */
    private var usingBackCamera = true
    private var canFlip = false

    private var activeVideoCapture: VideoCapture<Recorder>? = null
    private var recording: Recording? = null
    private var currentFile: File? = null
    private var cancelledFlag = false
    private var currentFpsLabel = ""

    private var autoFocus = true
    private var manualPosition = 0.5f
    private var minimumFocusDistance: Float? = null
    private var supportsManualFocus = false

    /** Last AF-settled LENS_FOCUS_DISTANCE seen by the capture callback (camera thread only). */
    private var lastObservedDiopters = Float.NaN

    // region Public API -----------------------------------------------------------------------

    /** Kick off provider init + fallback ladder bind for the back camera. Call once from onCreate. */
    fun start() {
        if (started) return
        started = true
        setState(State.CreatingSession)
        val future = ProcessCameraProvider.getInstance(activity)
        future.addListener({
            val provider = try {
                future.get()
            } catch (e: Throwable) {
                null
            }
            if (provider == null) {
                fail()
                return@addListener
            }
            cameraProvider = provider
            usingBackCamera = true
            runLadderForDesired(provider)
        }, mainExecutor)
    }

    /** Toggle back/front. Re-runs the full fallback ladder on the new camera. No-op unless Idle. */
    fun flipCamera() {
        if (state !is State.Idle || !canFlip) return
        val provider = cameraProvider ?: return
        usingBackCamera = !usingBackCamera
        setState(State.CreatingSession)
        runLadderForDesired(provider)
    }

    /** Begin recording to repository.newCaptureFile(). No-op unless Idle. */
    fun startRecording() {
        if (state !is State.Idle) return
        val videoCapture = activeVideoCapture ?: return
        val file = repository.newCaptureFile()
        currentFile = file
        cancelledFlag = false
        val options = FileOutputOptions.Builder(file).build()
        val rec = try {
            // Video-only: no withAudioEnabled() -> no RECORD_AUDIO permission needed.
            videoCapture.output
                .prepareRecording(activity, options)
                .start(mainExecutor) { event -> handleRecordEvent(event) }
        } catch (e: Throwable) {
            deleteQuietly(file)
            currentFile = null
            return
        }
        recording = rec
        // Optimistic Recording state (iOS parity); the Start event corroborates it.
        setState(State.Recording)
    }

    /** Finish and save. No-op unless Recording. */
    fun stopRecording() {
        if (state !is State.Recording) return
        setState(State.Finishing)
        try {
            recording?.stop()
        } catch (e: Throwable) {
            // Finalize will still fire; nothing to do here.
        }
    }

    /** Abort and delete the file. No-op unless Recording. */
    fun cancelRecording() {
        if (state !is State.Recording) return
        cancelledFlag = true
        setState(State.Cancelling)
        try {
            recording?.stop()
        } catch (e: Throwable) {
            // Finalize will still fire with the cancelled flag set.
        }
    }

    /** Tap-to-focus at PreviewView coordinates; continuous AF/AE at point. No-op in manual mode. */
    fun tapToFocus(x: Float, y: Float) {
        if (!autoFocus) return
        val cam = camera ?: return
        val point = try {
            previewView.meteringPointFactory.createPoint(x, y)
        } catch (e: Throwable) {
            return
        }
        val action = FocusMeteringAction.Builder(
            point,
            FocusMeteringAction.FLAG_AF or FocusMeteringAction.FLAG_AE,
        ).build()
        try {
            cam.cameraControl.startFocusAndMetering(action)
        } catch (e: Throwable) {
            // Focus request rejected by the device; ignore.
        }
    }

    /** true = continuous AF (default); false = lock focus at current position (manual mode). */
    fun setAutoFocus(enabled: Boolean) {
        if (!enabled && !supportsManualFocus) {
            // Manual focus unavailable on this camera; stay in auto.
            autoFocus = true
            return
        }
        autoFocus = enabled
        val cam = camera ?: return
        if (enabled) {
            try {
                Camera2CameraControl.from(cam.cameraControl).clearCaptureRequestOptions()
            } catch (e: Throwable) {
                // Continuous AF resumes on its own; ignore.
            }
        } else {
            applyManualFocus(cam, manualPosition)
        }
    }

    /** Manual focus, position in [0,1] (0 = nearest). Only meaningful when !isAutoFocus. */
    fun setManualFocusPosition(position: Float) {
        manualPosition = position.coerceIn(0f, 1f)
        if (autoFocus) return
        val cam = camera ?: return
        applyManualFocus(cam, manualPosition)
    }

    // endregion

    // region Fallback ladder ------------------------------------------------------------------

    private fun runLadderForDesired(provider: ProcessCameraProvider) {
        val selector = resolveSelector(provider)
        if (selector == null) {
            fail()
            return
        }
        val cameraInfo = try {
            provider.getCameraInfo(selector)
        } catch (e: Throwable) {
            fail()
            return
        }
        try {
            provider.unbindAll()
        } catch (e: Throwable) {
            // Nothing bound yet, or already clear.
        }
        val bound = tryHighSpeed(provider, selector, cameraInfo) ||
            tryNormalSession(provider, selector, cameraInfo, fps = 60) ||
            tryNormalSession(provider, selector, cameraInfo, fps = null)
        if (!bound) {
            fail()
        }
    }

    /**
     * Resolves the camera selector for the currently desired position, falling back to the other
     * position if the desired one is absent. Also computes [canFlip]. Returns null if neither
     * camera exists (e.g. camera-less emulator).
     */
    private fun resolveSelector(provider: ProcessCameraProvider): CameraSelector? {
        val hasBack = safeHasCamera(provider, CameraSelector.DEFAULT_BACK_CAMERA)
        val hasFront = safeHasCamera(provider, CameraSelector.DEFAULT_FRONT_CAMERA)
        canFlip = hasBack && hasFront
        val desiredHas = if (usingBackCamera) hasBack else hasFront
        if (desiredHas) {
            return if (usingBackCamera) CameraSelector.DEFAULT_BACK_CAMERA else CameraSelector.DEFAULT_FRONT_CAMERA
        }
        if (usingBackCamera && hasFront) {
            usingBackCamera = false
            return CameraSelector.DEFAULT_FRONT_CAMERA
        }
        if (!usingBackCamera && hasBack) {
            usingBackCamera = true
            return CameraSelector.DEFAULT_BACK_CAMERA
        }
        return null
    }

    private fun safeHasCamera(provider: ProcessCameraProvider, selector: CameraSelector): Boolean =
        try {
            provider.hasCamera(selector)
        } catch (e: Throwable) {
            false
        }

    /**
     * High-speed rungs (240 then 120). Returns false (and binds nothing) when the device has no
     * high-speed support, so the ladder continues to the normal-session rungs.
     */
    private fun tryHighSpeed(
        provider: ProcessCameraProvider,
        selector: CameraSelector,
        cameraInfo: CameraInfo,
    ): Boolean {
        // Null capabilities is the crash guard: binding a HighSpeedVideoSessionConfig on an
        // unsupported device throws. Treat any failure of the query as "no high-speed".
        val highSpeedSupported = try {
            Recorder.getHighSpeedVideoCapabilities(cameraInfo) != null
        } catch (e: Throwable) {
            false
        }
        if (!highSpeedSupported) return false

        // The presence of capabilities is enough to build the config; a default Recorder lets
        // CameraX choose a resolution compatible with the requested high frame rate.
        val preview = buildPreview(highSpeed = true)
        val recorder = Recorder.Builder().build()
        val videoCapture = VideoCapture.withOutput(recorder)

        val ranges: Collection<Range<Int>> = try {
            val queryConfig = HighSpeedVideoSessionConfig.Builder(videoCapture)
                .setPreview(preview)
                .setSlowMotionEnabled(false)
                .build()
            cameraInfo.getSupportedFrameRateRanges(queryConfig)
        } catch (e: Throwable) {
            emptyList()
        }

        for (range in orderHighSpeedRanges(ranges)) {
            val config = try {
                HighSpeedVideoSessionConfig.Builder(videoCapture)
                    .setPreview(preview)
                    .setFrameRateRange(range)
                    .setSlowMotionEnabled(false)
                    .build()
            } catch (e: Throwable) {
                continue
            }
            try {
                provider.unbindAll()
                val cam = provider.bindToLifecycle(activity, selector, config)
                onBound(cam, cameraInfo, videoCapture, fpsLabel(range.upper))
                return true
            } catch (e: Throwable) {
                // Xiaomi/Samsung high-speed bind class of failures — try the next candidate.
            }
        }
        return false
    }

    /**
     * Orders candidate high-speed ranges: 240-tier first (prefer fixed [240,240]), then 120-tier
     * (prefer fixed [120,120]); higher achievable frame rate wins ties.
     */
    private fun orderHighSpeedRanges(ranges: Collection<Range<Int>>): List<Range<Int>> {
        val tier240 = ranges.filter { it.upper >= 240 }.sortedWith(highSpeedComparator(240))
        val tier120 = ranges.filter { it.upper in 120..239 }.sortedWith(highSpeedComparator(120))
        return tier240 + tier120
    }

    private fun highSpeedComparator(target: Int): Comparator<Range<Int>> =
        compareByDescending<Range<Int>> { it.lower == target && it.upper == target }
            .thenByDescending { it.lower == it.upper }
            .thenByDescending { it.upper }

    /**
     * Normal-session rungs (never the high-speed API). With [fps] set, binds with a fixed
     * frame-rate range and only if the device actually reports a supported range topping out
     * at [fps], so the deterministic frame-rate contract is satisfied. With null, binds
     * unconstrained — the terminal rung that always works.
     */
    private fun tryNormalSession(
        provider: ProcessCameraProvider,
        selector: CameraSelector,
        cameraInfo: CameraInfo,
        fps: Int?,
    ): Boolean {
        val preview = buildPreview(highSpeed = false)
        val videoCapture = buildNormalVideoCapture()
        val useCases = listOf(preview, videoCapture)
        val config = if (fps != null) {
            val ranges: Collection<Range<Int>> = try {
                cameraInfo.getSupportedFrameRateRanges(SessionConfig(useCases = useCases))
            } catch (e: Throwable) {
                emptyList()
            }
            // Prefer a fixed [fps,fps] range; otherwise any supported range topping out at fps.
            val target = ranges.filter { it.upper == fps }.maxByOrNull { it.lower } ?: return false
            SessionConfig(useCases = useCases, frameRateRange = target)
        } else {
            SessionConfig(useCases = useCases)
        }
        return try {
            provider.unbindAll()
            val cam = provider.bindToLifecycle(activity, selector, config)
            onBound(cam, cameraInfo, videoCapture, fpsLabel(fps ?: 30))
            true
        } catch (e: Throwable) {
            false
        }
    }

    private fun onBound(
        cam: Camera,
        cameraInfo: CameraInfo,
        videoCapture: VideoCapture<Recorder>,
        label: String,
    ) {
        camera = cam
        activeVideoCapture = videoCapture
        currentFpsLabel = label
        minimumFocusDistance = readMinimumFocusDistance(cameraInfo)
        supportsManualFocus = (minimumFocusDistance ?: 0f) > 0f
        autoFocus = true
        manualPosition = 0.5f
        lastObservedDiopters = Float.NaN
        emitIdle()
    }

    private fun emitIdle() {
        setState(State.Idle(currentFpsLabel, canFlip, supportsManualFocus))
    }

    private fun fpsLabel(fps: Int): String = activity.getString(R.string.capture_fps_format, fps)

    // endregion

    // region Use-case construction ------------------------------------------------------------

    private fun buildPreview(highSpeed: Boolean): Preview {
        val builder = Preview.Builder()
        // No capture-request *options* in high-speed mode: constrained high-speed sessions restrict
        // capture-request keys, and stabilization is inherently disabled there anyway, so injecting
        // a request option risks the OEM request-list crash class for no behavioral gain. The focus
        // observer is a read-only capture callback (no request keys), safe in both modes.
        if (!highSpeed) applyStabilizationOff(builder)
        attachFocusObserver(builder)
        val preview = builder.build()
        preview.surfaceProvider = previewView.surfaceProvider
        return preview
    }

    /**
     * Read-only session capture callback that tracks the AF-settled lens position (DESIGN §8.4
     * permits a capture callback and forbids only a raw camera2 session; this injects no request
     * keys). While in auto mode it caches LENS_FOCUS_DISTANCE into [manualPosition] and feeds
     * [Listener.onAutoFocusDistanceChanged], so toggling to manual focus holds the current position
     * instead of racking to the slider midpoint (Finding 1). Best-effort: if unavailable, the
     * callback never fires and manual focus falls back to the last position, exactly as §8.4 allows.
     */
    private fun attachFocusObserver(builder: Preview.Builder) {
        try {
            Camera2Interop.Extender(builder).setSessionCaptureCallback(
                object : CameraCaptureSession.CaptureCallback() {
                    override fun onCaptureCompleted(
                        session: CameraCaptureSession,
                        request: CaptureRequest,
                        result: TotalCaptureResult,
                    ) {
                        if (!autoFocus) return
                        val diopters = result.get(CaptureResult.LENS_FOCUS_DISTANCE) ?: return
                        val prev = lastObservedDiopters
                        // Steady-state dedup: skip runnables when the lens has not moved.
                        if (!prev.isNaN() && kotlin.math.abs(prev - diopters) < FOCUS_EPSILON) return
                        lastObservedDiopters = diopters
                        mainExecutor.execute { onAutoFocusDistanceObserved(diopters) }
                    }
                },
            )
        } catch (e: Throwable) {
            // Interop/capture callback unavailable on this device; degrade to never firing.
        }
    }

    private fun onAutoFocusDistanceObserved(diopters: Float) {
        if (!autoFocus) return
        val minFocus = minimumFocusDistance ?: return
        if (minFocus <= 0f) return
        // Invert into the slider/manual convention (position 0 = nearest), matching applyManualFocus.
        val position = (1f - (diopters / minFocus)).coerceIn(0f, 1f)
        manualPosition = position
        listener?.onAutoFocusDistanceChanged(position)
    }

    private fun buildNormalVideoCapture(): VideoCapture<Recorder> {
        val recorder = Recorder.Builder().build()
        val builder = VideoCapture.Builder(recorder)
        applyStabilizationOff(builder)
        return builder.build()
    }

    /** Force CONTROL_VIDEO_STABILIZATION_MODE_OFF (DESIGN §8.2 / deviation #4). Never throws. */
    private fun <T> applyStabilizationOff(builder: ExtendableBuilder<T>) {
        try {
            Camera2Interop.Extender(builder).setCaptureRequestOption(
                CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE,
                CameraMetadata.CONTROL_VIDEO_STABILIZATION_MODE_OFF,
            )
        } catch (e: Throwable) {
            // Interop unavailable on this builder/device; leave defaults.
        }
    }

    private fun readMinimumFocusDistance(cameraInfo: CameraInfo): Float? =
        try {
            Camera2CameraInfo.from(cameraInfo)
                .getCameraCharacteristic(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE)
        } catch (e: Throwable) {
            null
        }

    private fun applyManualFocus(cam: Camera, position: Float) {
        val minFocus = minimumFocusDistance ?: return
        if (minFocus <= 0f) return
        // LENS_FOCUS_DISTANCE is in diopters: 0 = infinity (far), minFocus = nearest. iOS slider
        // and DESIGN §8.1 define position 0 = nearest, so invert (see final-message deviation note).
        val diopters = (1f - position.coerceIn(0f, 1f)) * minFocus
        val options = CaptureRequestOptions.Builder()
            .setCaptureRequestOption(CaptureRequest.CONTROL_AF_MODE, CameraMetadata.CONTROL_AF_MODE_OFF)
            .setCaptureRequestOption(CaptureRequest.LENS_FOCUS_DISTANCE, diopters)
            .build()
        try {
            Camera2CameraControl.from(cam.cameraControl).setCaptureRequestOptions(options)
        } catch (e: Throwable) {
            // Manual focus rejected by the device; ignore.
        }
    }

    // endregion

    // region Recording events -----------------------------------------------------------------

    private fun handleRecordEvent(event: VideoRecordEvent) {
        when (event) {
            is VideoRecordEvent.Finalize -> handleFinalize(event)
            else -> {
                // Start / Status / Pause / Resume: Recording state was already set optimistically
                // in startRecording(); no additional handling is needed.
            }
        }
    }

    private fun handleFinalize(event: VideoRecordEvent.Finalize) {
        val file = currentFile
        recording = null
        currentFile = null
        val wasCancelled = cancelledFlag
        cancelledFlag = false

        val error = event.error
        // A normal stop reports ERROR_NONE; unbinding the lifecycle mid-record (e.g. backgrounding)
        // reports the benign ERROR_SOURCE_INACTIVE with a still-valid file.
        val benign = error == VideoRecordEvent.Finalize.ERROR_NONE ||
            error == VideoRecordEvent.Finalize.ERROR_SOURCE_INACTIVE
        val fileOk = file != null && file.exists() && file.length() > 0L

        // Promote the pending (.tmp) recording to a listable <uuid>.mp4 only on success, so a killed
        // mid-recording never leaves a junk row (Finding 3).
        val finalFile = if (fileOk) repository.finalizePending(file!!) else null

        if (wasCancelled || !benign || finalFile == null) {
            deleteQuietly(file)
            emitIdle()
            listener?.onRecordingEnded(wasCancelled)
        } else {
            val capture = Capture(
                id = finalFile.nameWithoutExtension,
                file = finalFile,
                createdAtMillis = finalFile.lastModified(),
            )
            listener?.onRecordingSaved(capture)
        }
    }

    // endregion

    private fun fail() {
        camera = null
        activeVideoCapture = null
        supportsManualFocus = false
        canFlip = false
        setState(State.Failed(activity.getString(R.string.capture_unable_to_capture)))
    }

    private fun setState(newState: State) {
        state = newState
        listener?.onStateChanged(newState)
    }

    private fun deleteQuietly(file: File?) {
        if (file == null) return
        try {
            file.delete()
        } catch (e: Throwable) {
            // Best effort.
        }
    }

    private companion object {
        /** Ignore sub-epsilon LENS_FOCUS_DISTANCE jitter so a still lens posts no runnables. */
        const val FOCUS_EPSILON = 0.01f
    }
}
