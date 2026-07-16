package com.chadaustin.isitsnappy.about

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.Menu
import android.view.MenuItem
import android.widget.Button
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.chadaustin.isitsnappy.R

class AboutActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_about)
        supportActionBar?.setDisplayHomeAsUpEnabled(true)
        supportActionBar?.title = getString(R.string.about_title_toolbar)

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

    override fun onCreateOptionsMenu(menu: Menu?): Boolean {
        menuInflater.inflate(R.menu.menu_about, menu)
        return true
    }

    override fun onOptionsItemSelected(item: MenuItem): Boolean {
        return when (item.itemId) {
            android.R.id.home -> {
                finish()
                true
            }
            R.id.action_help -> {
                startActivity(HelpActivity.newIntent(this))
                true
            }
            else -> super.onOptionsItemSelected(item)
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
