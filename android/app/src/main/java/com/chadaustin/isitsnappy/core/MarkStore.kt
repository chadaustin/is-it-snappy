package com.chadaustin.isitsnappy.core

import android.util.Log
import androidx.annotation.MainThread
import java.io.File
import java.io.FileOutputStream
import org.json.JSONObject

/**
 * Persistence of marks. All methods @MainThread. Every mutation synchronously rewrites
 * the whole file (iOS behavior) but atomically (temp file + rename).
 * File format: {"marks": {"<captureId>": {"name": ..., "input": ..., "output": ...}}}
 * Null fields are OMITTED when writing; missing keys and JSON nulls are both read as null.
 * A missing or malformed file loads as an empty store (never throws, never crashes).
 */
@MainThread
class MarkStore(private val file: File) {

    private val marks: MutableMap<String, Mark> = loadInitial()

    /** In-memory map, loaded once at construction. */
    fun get(id: String): Mark? = marks[id]

    fun set(id: String, mark: Mark) {
        marks[id] = mark
        persist()
    }

    /** Each setter creates the Mark if absent, otherwise updates only its own field. */
    fun setName(id: String, name: String) = update(id) { it.copy(name = name) }

    fun setInputTime(id: String, input: Double) = update(id) { it.copy(input = input) }

    fun setOutputTime(id: String, output: Double) = update(id) { it.copy(output = output) }

    private fun update(id: String, transform: (Mark) -> Mark) {
        marks[id] = transform(marks[id] ?: Mark())
        persist()
    }

    /** Removes the entry entirely. No-op if absent. */
    fun delete(id: String) {
        if (marks.remove(id) != null) {
            persist()
        }
    }

    private fun loadInitial(): MutableMap<String, Mark> {
        val result = LinkedHashMap<String, Mark>()
        try {
            if (!file.exists()) {
                return result
            }
            val text = file.readText()
            val root = JSONObject(text)
            val marksObj = root.optJSONObject("marks") ?: return result
            val keys = marksObj.keys()
            while (keys.hasNext()) {
                val id = keys.next()
                val entry = marksObj.optJSONObject(id) ?: continue
                // JSONObject.isNull() is also true for a missing key.
                result[id] = Mark(
                    name = if (entry.isNull("name")) null else entry.optString("name"),
                    input = entry.doubleOrNull("input"),
                    output = entry.doubleOrNull("output"),
                )
            }
        } catch (e: Exception) {
            Log.w("MarkStore", "Failed to load $file; starting with an empty store", e)
            result.clear()
        }
        return result
    }

    private fun JSONObject.doubleOrNull(key: String): Double? =
        if (isNull(key)) null else optDouble(key).takeUnless { it.isNaN() }

    private fun persist() {
        try {
            val marksObj = JSONObject()
            for ((id, mark) in marks) {
                val entry = JSONObject()
                mark.name?.let { entry.put("name", it) }
                mark.input?.let { entry.put("input", it) }
                mark.output?.let { entry.put("output", it) }
                marksObj.put(id, entry)
            }
            val root = JSONObject()
            root.put("marks", marksObj)
            val text = root.toString(2)

            val tmp = File(file.parentFile, "${file.name}.tmp")
            file.parentFile?.mkdirs()
            FileOutputStream(tmp).use { stream ->
                stream.write(text.toByteArray(Charsets.UTF_8))
                stream.fd.sync()
            }
            if (!tmp.renameTo(file)) {
                // Fall back: some filesystems/edge cases may fail an in-place rename over an
                // existing destination; delete-then-rename to guarantee the write lands.
                file.delete()
                tmp.renameTo(file)
            }
        } catch (e: Exception) {
            Log.w("MarkStore", "Failed to persist $file", e)
        }
    }
}
