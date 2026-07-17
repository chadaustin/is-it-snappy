package com.chadaustin.isitsnappy.list

import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView
import com.chadaustin.isitsnappy.R
import com.chadaustin.isitsnappy.core.Capture
import com.chadaustin.isitsnappy.core.Mark
import com.chadaustin.isitsnappy.core.MarkStore

/**
 * RecyclerView adapter for the capture list. Two view types: day header and capture row.
 * Row primary text is the mark's display label (SPEC §4.3 parity, including the plain "—"
 * placeholder when no mark record exists yet); secondary text is the precomputed time label.
 */
class CaptureListAdapter(
    private val markStore: MarkStore,
    private val onRowClick: (Capture) -> Unit,
) : RecyclerView.Adapter<RecyclerView.ViewHolder>() {

    private companion object {
        const val VIEW_TYPE_HEADER = 0
        const val VIEW_TYPE_ITEM = 1
    }

    private var rows: List<ListRow> = emptyList()

    /** Replaces the row list and diffs the whole adapter. Call on the main thread. */
    fun submit(newRows: List<ListRow>) {
        rows = newRows
        notifyDataSetChanged()
    }

    /** The capture backing the item at [position], or null if it is a header row. */
    fun captureAt(position: Int): Capture? = (rows.getOrNull(position) as? ListRow.Item)?.capture

    override fun getItemCount(): Int = rows.size

    override fun getItemViewType(position: Int): Int =
        when (rows[position]) {
            is ListRow.Header -> VIEW_TYPE_HEADER
            is ListRow.Item -> VIEW_TYPE_ITEM
        }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder {
        val inflater = LayoutInflater.from(parent.context)
        return if (viewType == VIEW_TYPE_HEADER) {
            HeaderViewHolder(inflater.inflate(R.layout.item_day_header, parent, false))
        } else {
            ItemViewHolder(inflater.inflate(R.layout.item_capture_row, parent, false))
        }
    }

    override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
        when (val row = rows[position]) {
            is ListRow.Header -> (holder as HeaderViewHolder).bind(row)
            is ListRow.Item -> (holder as ItemViewHolder).bind(row)
        }
    }

    private class HeaderViewHolder(itemView: View) : RecyclerView.ViewHolder(itemView) {
        private val label = itemView as TextView

        fun bind(row: ListRow.Header) {
            label.text = row.label
        }
    }

    private inner class ItemViewHolder(itemView: View) : RecyclerView.ViewHolder(itemView) {
        private val primaryLabel = itemView.findViewById<TextView>(R.id.primaryLabel)
        private val secondaryLabel = itemView.findViewById<TextView>(R.id.secondaryLabel)

        fun bind(row: ListRow.Item) {
            primaryLabel.text = markStore.get(row.capture.id)?.displayLabel() ?: Mark().displayLabel()
            secondaryLabel.text = row.timeLabel
            itemView.setOnClickListener { onRowClick(row.capture) }
        }
    }
}
