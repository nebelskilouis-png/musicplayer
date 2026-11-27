package com.example.musicplayer

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Color
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView

/** Gemeinsame Player-Oberfläche (Fernbedienung + Offline). Große Tasten, Cover im Hintergrund. */
class Controls(
    private val a: Activity,
    onPrev: () -> Unit,
    onToggle: () -> Unit,
    onNext: () -> Unit,
    onVolDown: () -> Unit,
    onVolUp: () -> Unit,
    middleLabel: String,
    onMiddle: () -> Unit,
    bottomLabel: String,
    onBottom: () -> Unit,
) {
    private val cover = ImageView(a).apply {
        scaleType = ImageView.ScaleType.CENTER_CROP
        alpha = 0.35f
    }
    val title: TextView = Ui.text(a, "", 15f, bold = true)
    val artist: TextView = Ui.text(a, "", 12f, Ui.GREY)
    val status: TextView = Ui.text(a, "", 12f, Ui.LIGHT, lines = 2)
    private val play: ImageButton = Ui.iconButton(a, android.R.drawable.ic_media_play, 64, true) { onToggle() }
    val middle: TextView = Ui.textButton(a, middleLabel, 44, 18f) { onMiddle() }
    private val progress = ProgressBar(a, null, android.R.attr.progressBarStyleHorizontal).apply {
        max = 1000
        progressTintList = android.content.res.ColorStateList.valueOf(Ui.LIGHT)
        progressBackgroundTintList = android.content.res.ColorStateList.valueOf(0x44FFFFFF)
    }
    val bottom: TextView = Ui.text(a, bottomLabel, 13f, Color.WHITE, bold = true).apply {
        background = Ui.rounded(a, Ui.ROW, 16)
        setPadding(Ui.dp(a, 14), Ui.dp(a, 6), Ui.dp(a, 14), Ui.dp(a, 6))
        setOnClickListener { Ui.haptic(it); onBottom() }
    }

    val root: View = FrameLayout(a).apply {
        setBackgroundColor(Ui.BG)
        addView(cover, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        val col = Ui.row(a, horizontal = false).apply {
            val side = Ui.dp(a, 26)
            setPadding(side, Ui.dp(a, 22), side, Ui.dp(a, 14))
            addView(title, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            addView(artist, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            addView(status)
            addView(progress, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, Ui.dp(a, 8)).apply {
                setMargins(Ui.dp(a, 10), Ui.dp(a, 4), Ui.dp(a, 10), Ui.dp(a, 6))
            })
            addView(Ui.row(a).apply {
                addView(Ui.iconButton(a, android.R.drawable.ic_media_previous, 48, false) { onPrev() })
                addView(play)
                addView(Ui.iconButton(a, android.R.drawable.ic_media_next, 48, false) { onNext() })
            })
            addView(Ui.row(a).apply {
                setPadding(0, Ui.dp(a, 6), 0, Ui.dp(a, 6))
                addView(Ui.textButton(a, "−", 40, 22f) { onVolDown() })
                addView(middle)
                addView(Ui.textButton(a, "+", 40, 22f) { onVolUp() })
            })
            addView(bottom)
        }
        addView(col, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
    }

    fun setPlaying(p: Boolean) {
        play.setImageResource(if (p) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play)
    }

    fun setProgress(pos: Long, dur: Long) {
        progress.progress = if (dur > 0) ((pos * 1000) / dur).toInt().coerceIn(0, 1000) else 0
    }

    fun setCover(b: Bitmap?) {
        cover.setImageBitmap(b)
    }

    fun setMiddle(label: String, active: Boolean) {
        middle.text = label
        middle.setTextColor(if (active) Ui.LIGHT else Color.WHITE)
    }
}
