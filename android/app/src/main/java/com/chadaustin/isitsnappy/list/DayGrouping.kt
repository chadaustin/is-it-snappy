package com.chadaustin.isitsnappy.list

import com.chadaustin.isitsnappy.core.Capture
import java.text.DateFormat
import java.util.Calendar
import java.util.Date

sealed interface ListRow {
    data class Header(val label: String) : ListRow                 // date, DateFormat.SHORT
    data class Item(val capture: Capture, val timeLabel: String) : ListRow  // time, DateFormat.SHORT
}

object DayGrouping {

    /**
     * Sort captures descending by createdAtMillis (newest first), group into Header+Items by
     * calendar day using year+month+day (DELIBERATE FIX of the iOS year+dayOfMonth bug,
     * SPEC §4.2 — decision recorded in DESIGN.md §13).
     */
    fun group(captures: List<Capture>): List<ListRow> {
        val sorted = captures.sortedByDescending { it.createdAtMillis }

        val dateFormat = DateFormat.getDateInstance(DateFormat.SHORT)
        val timeFormat = DateFormat.getTimeInstance(DateFormat.SHORT)

        val rows = mutableListOf<ListRow>()
        val calendar = Calendar.getInstance()

        var groupYear = Int.MIN_VALUE
        var groupMonth = Int.MIN_VALUE
        var groupDay = Int.MIN_VALUE

        for (capture in sorted) {
            calendar.timeInMillis = capture.createdAtMillis
            val year = calendar.get(Calendar.YEAR)
            val month = calendar.get(Calendar.MONTH)
            val day = calendar.get(Calendar.DAY_OF_MONTH)

            val sameDay = rows.isNotEmpty() && year == groupYear && month == groupMonth && day == groupDay
            if (!sameDay) {
                rows.add(ListRow.Header(dateFormat.format(Date(capture.createdAtMillis))))
                groupYear = year
                groupMonth = month
                groupDay = day
            }
            rows.add(ListRow.Item(capture, timeFormat.format(Date(capture.createdAtMillis))))
        }

        return rows
    }
}
