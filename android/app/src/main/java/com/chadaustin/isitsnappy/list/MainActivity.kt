package com.chadaustin.isitsnappy.list

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.util.TypedValue
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updateLayoutParams
import androidx.core.view.updatePadding
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.ItemTouchHelper
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.chadaustin.isitsnappy.R
import com.chadaustin.isitsnappy.about.AboutActivity
import com.chadaustin.isitsnappy.app
import com.chadaustin.isitsnappy.capture.CaptureActivity
import com.chadaustin.isitsnappy.core.Capture
import com.chadaustin.isitsnappy.databinding.ActivityMainBinding
import com.chadaustin.isitsnappy.mark.MarkActivity
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * "All Captures" screen: toolbar (info + camera buttons), RecyclerView, lazy CAMERA permission
 * flow, swipe-to-delete dialog. Launches Capture/Mark/About via their frozen newIntent factories
 * only (DESIGN.md §6.5).
 */
class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding
    private lateinit var adapter: CaptureListAdapter

    // Registered unconditionally in onCreate for process-death safety (DESIGN.md §11).
    private lateinit var requestCameraPermission: androidx.activity.result.ActivityResultLauncher<String>

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        // Theme.IsItSnappy is the ActionBar variant (module A, frozen), so AppCompat already
        // supplies a decor action bar; hide it rather than calling setSupportActionBar (which
        // would throw on top of a decor-supplied bar) and use the custom MaterialToolbar below
        // as a plain view with its own menu, per §11.
        supportActionBar?.hide()

        // Enforced edge-to-edge (targetSdk 35): without inset handling the toolbar renders under
        // the status bar, whose window also swallows taps on the buttons' upper half.
        val tv = TypedValue()
        theme.resolveAttribute(androidx.appcompat.R.attr.actionBarSize, tv, true)
        val toolbarBaseHeight = TypedValue.complexToDimensionPixelSize(tv.data, resources.displayMetrics)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        ViewCompat.setOnApplyWindowInsetsListener(binding.root) { _, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            binding.toolbar.updatePadding(top = bars.top)
            binding.toolbar.updateLayoutParams { height = toolbarBaseHeight + bars.top }
            binding.captureList.clipToPadding = false
            binding.captureList.updatePadding(bottom = bars.bottom)
            insets
        }

        requestCameraPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            onCameraPermissionResult(granted)
        }

        adapter = CaptureListAdapter(
            markStore = app.markStore,
            onRowClick = { capture -> startActivity(MarkActivity.newIntent(this, capture.id)) },
        )
        binding.captureList.layoutManager = LinearLayoutManager(this)
        binding.captureList.adapter = adapter

        ItemTouchHelper(SwipeToDeleteCallback()).attachToRecyclerView(binding.captureList)

        binding.toolbar.setOnMenuItemClickListener { item ->
            when (item.itemId) {
                R.id.action_info -> {
                    startActivity(AboutActivity.newIntent(this))
                    true
                }
                R.id.action_capture -> {
                    onCaptureButtonClicked()
                    true
                }
                else -> false
            }
        }
    }

    override fun onStart() {
        super.onStart()
        // Re-enable the camera action once we are back on this screen. This is the single point that
        // undoes the launch guard in onCaptureButtonClicked(), so a double-tap cannot start a second
        // CaptureActivity before the first one takes over (Finding 2).
        setCaptureActionEnabled(true)
        refresh()
    }

    private fun refresh() {
        lifecycleScope.launch {
            val rows = withContext(Dispatchers.IO) {
                DayGrouping.group(app.captureRepository.list())
            }
            adapter.submit(rows)
        }
    }

    // --- Lazy CAMERA permission flow (DESIGN.md §11, mirrors iOS lazy-request behavior) ---

    private fun onCaptureButtonClicked() {
        setCaptureActionEnabled(false)
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            // Stay disabled until onStart() re-enables us on return. Re-enabling synchronously here
            // would let a queued second menu-click launch a second CaptureActivity (Finding 2).
            startActivity(CaptureActivity.newIntent(this))
        } else {
            requestCameraPermission.launch(Manifest.permission.CAMERA)
        }
    }

    private fun onCameraPermissionResult(granted: Boolean) {
        if (granted) {
            // Leaves this screen; onStart() re-enables the action on return.
            startActivity(CaptureActivity.newIntent(this))
        } else {
            // Denied: we stay on this screen, so re-enable the action for the next attempt.
            setCaptureActionEnabled(true)
            showCameraPermissionDeniedDialog()
        }
    }

    private fun showCameraPermissionDeniedDialog() {
        MaterialAlertDialogBuilder(this)
            .setTitle(R.string.list_permission_camera_title)
            .setMessage(getString(R.string.list_permission_camera_message, getString(R.string.app_name)))
            .setNegativeButton(R.string.list_permission_cancel, null)
            .setPositiveButton(R.string.list_permission_settings) { _, _ ->
                val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
                startActivity(intent)
            }
            .show()
    }

    private fun setCaptureActionEnabled(enabled: Boolean) {
        binding.toolbar.menu.findItem(R.id.action_capture)?.isEnabled = enabled
    }

    // --- Swipe-to-delete (DESIGN.md §11 / SPEC §4.4, with the delete-ordering fix) ---

    private fun showDeleteDialog(capture: Capture) {
        val options = arrayOf(
            getString(R.string.list_delete_clear_marks),
            getString(R.string.list_delete_video_and_marks),
            getString(R.string.list_delete_cancel),
        )
        MaterialAlertDialogBuilder(this)
            .setItems(options) { _, which ->
                when (which) {
                    0 -> {
                        app.markStore.delete(capture.id)
                        refresh()
                    }
                    1 -> {
                        lifecycleScope.launch {
                            val deleted = withContext(Dispatchers.IO) {
                                app.captureRepository.delete(capture.id)
                            }
                            // Deliberate fix of iOS's unconditional mark deletion (DESIGN.md §13):
                            // only clear the mark entry if the video file was actually deleted.
                            if (deleted) {
                                app.markStore.delete(capture.id)
                            }
                            refresh()
                        }
                    }
                    else -> Unit // Cancel: dismiss only.
                }
            }
            .show()
    }

    private inner class SwipeToDeleteCallback : ItemTouchHelper.SimpleCallback(0, ItemTouchHelper.LEFT) {
        override fun getSwipeDirs(recyclerView: RecyclerView, viewHolder: RecyclerView.ViewHolder): Int {
            val position = viewHolder.bindingAdapterPosition
            if (position == RecyclerView.NO_POSITION || adapter.captureAt(position) == null) {
                return 0
            }
            return super.getSwipeDirs(recyclerView, viewHolder)
        }

        override fun onMove(
            recyclerView: RecyclerView,
            viewHolder: RecyclerView.ViewHolder,
            target: RecyclerView.ViewHolder,
        ): Boolean = false

        override fun onSwiped(viewHolder: RecyclerView.ViewHolder, direction: Int) {
            val position = viewHolder.bindingAdapterPosition
            if (position == RecyclerView.NO_POSITION) return
            val capture = adapter.captureAt(position) ?: return
            // Snap back immediately; the row is only actually removed via refresh() after the
            // user picks a destructive option in the dialog (DESIGN.md §11).
            adapter.notifyItemChanged(position)
            showDeleteDialog(capture)
        }
    }
}
