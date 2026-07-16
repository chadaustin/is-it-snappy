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

    /** Creates Mark(name=name) if absent; otherwise updates only the name field. */
    fun setName(id: String, name: String) {
        val existing = marks[id] ?: Mark()
        marks[id] = existing.copy(name = name)
        persist()
    }

    /** Creates Mark(input=input) if absent; otherwise updates only the input field. */
    fun setInputTime(id: String, input: Double) {
        val existing = marks[id] ?: Mark()
        marks[id] = existing.copy(input = input)
        persist()
    }

    /** Creates Mark(output=output) if absent; otherwise updates only the output field. */
    fun setOutputTime(id: String, output: Double) {
        val existing = marks[id] ?: Mark()
        marks[id] = existing.copy(output = output)
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
                val name = if (entry.isNull("name") || !entry.has("name")) null else entry.optString("name")
                val input = if (entry.isNull("input") || !entry.has("input")) null else entry.optDouble("input")
                val output = if (entry.isNull("output") || !entry.has("output")) null else entry.optDouble("output")
                result[id] = Mark(
                    name = name,
                    input = if (input?.isNaN() == true) null else input,
                    output = if (output?.isNaN() == true) null else output,
                )
            }
        } catch (e: Exception) {
            Log.w("MarkStore", "Failed to load $file; starting with an empty store", e)
            result.clear()
        }
        return result
    }

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
