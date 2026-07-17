package com.chadaustin.isitsnappy

import android.app.Application
import android.content.Context
import com.chadaustin.isitsnappy.core.CaptureRepository
import com.chadaustin.isitsnappy.core.MarkStore
import java.io.File

class App : Application() {
    lateinit var markStore: MarkStore
        private set
    lateinit var captureRepository: CaptureRepository
        private set

    override fun onCreate() {
        super.onCreate()
        markStore = MarkStore(File(filesDir, "snappy-database.json"))
        captureRepository = CaptureRepository(File(filesDir, "captures"))
    }
}

val Context.app: App
    get() = applicationContext as App
