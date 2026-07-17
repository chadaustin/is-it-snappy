package com.chadaustin.isitsnappy.about

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.widget.ScrollView
import androidx.activity.enableEdgeToEdge
import androidx.appcompat.app.AppCompatActivity
import com.chadaustin.isitsnappy.R
import com.chadaustin.isitsnappy.core.SafeArea
import com.google.android.material.appbar.MaterialToolbar

class HelpActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_help)
        // Owned toolbar, not the decor action bar; see AboutActivity.
        supportActionBar?.hide()
        enableEdgeToEdge()
        val toolbar: MaterialToolbar = findViewById(R.id.help_toolbar)
        toolbar.setNavigationOnClickListener { finish() }
        SafeArea.padTop(toolbar)
        SafeArea.padBottom(findViewById<ScrollView>(R.id.help_scroll))
    }

    companion object {
        fun newIntent(context: Context): Intent = Intent(context, HelpActivity::class.java)
    }
}
