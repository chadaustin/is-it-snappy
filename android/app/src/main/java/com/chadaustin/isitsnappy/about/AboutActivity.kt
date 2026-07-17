package com.chadaustin.isitsnappy.about

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Button
import android.widget.ScrollView
import android.widget.Toast
import androidx.activity.enableEdgeToEdge
import androidx.appcompat.app.AppCompatActivity
import com.chadaustin.isitsnappy.R
import com.chadaustin.isitsnappy.core.SafeArea
import com.google.android.material.appbar.MaterialToolbar

class AboutActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_about)
        // Owned toolbar, not the decor action bar: some devices with enforced edge-to-edge
        // stop offsetting decor content below the bar, so the bar covered the content's title.
        supportActionBar?.hide()
        enableEdgeToEdge()
        val toolbar: MaterialToolbar = findViewById(R.id.about_toolbar)
        toolbar.setNavigationOnClickListener { finish() }
        toolbar.setOnMenuItemClickListener { item ->
            if (item.itemId == R.id.action_help) {
                startActivity(HelpActivity.newIntent(this))
                true
            } else {
                false
            }
        }
        SafeArea.padTop(toolbar)
        SafeArea.padBottom(findViewById<ScrollView>(R.id.about_scroll))

        val websiteButton: Button = findViewById(R.id.about_website_button)
        val githubButton: Button = findViewById(R.id.about_github_button)
        val mastodonButton: Button = findViewById(R.id.about_mastodon_button)

        websiteButton.setOnClickListener {
            openUrl("https://isitsnappy.com")
        }
        githubButton.setOnClickListener {
            openUrl("https://github.com/chadaustin/is-it-snappy")
        }
        mastodonButton.setOnClickListener {
            openUrl("https://mastodon.gamedev.place/@chadaustin")
        }
    }

    private fun openUrl(url: String) {
        try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            startActivity(intent)
        } catch (e: Exception) {
            Toast.makeText(this, R.string.about_no_browser, Toast.LENGTH_SHORT).show()
        }
    }

    companion object {
        fun newIntent(context: Context): Intent = Intent(context, AboutActivity::class.java)
    }
}
