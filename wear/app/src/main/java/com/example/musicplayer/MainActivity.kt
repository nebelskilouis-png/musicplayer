package com.example.musicplayer

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.LinearLayout
import android.widget.ScrollView

/** Start: Handy steuern oder offline auf der Uhr hören. */
class MainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val col = Ui.row(this, horizontal = false).apply {
            setBackgroundColor(Ui.BG)
            val h = resources.displayMetrics.heightPixels
            setPadding(0, h / 7, 0, h / 7)
            addView(Ui.text(this@MainActivity, "Kobalt", 20f, Ui.LIGHT, bold = true).apply {
                setPadding(0, 0, 0, Ui.dp(this@MainActivity, 10))
            })
            addView(Ui.pill(this@MainActivity, "📱  Handy steuern", Ui.ACCENT) {
                startActivity(Intent(this@MainActivity, RemoteActivity::class.java))
            })
            addView(Ui.pill(this@MainActivity, "⌚  Auf der Uhr") {
                startActivity(Intent(this@MainActivity, LocalLibraryActivity::class.java))
            })
        }
        val scroll = ScrollView(this).apply {
            setBackgroundColor(Ui.BG)
            isFillViewport = true
            addView(col, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        }
        Ui.enableRotary(scroll) { scroll.scrollBy(0, it) }
        setContentView(scroll)
    }
}
