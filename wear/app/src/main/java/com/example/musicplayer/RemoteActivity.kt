package com.example.musicplayer

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.WindowManager

/** Fernbedienung für die Handy-App. Spricht direkt mit der App, nicht über die System-Mediensteuerung. */
class RemoteActivity : Activity() {
    private lateinit var c: Controls
    private val h = Handler(Looper.getMainLooper())
    private var openedAt = 0L
    private var localPlaying: Boolean? = null // sofortige Anzeige nach Tippen
    private var localPlayingAt = 0L

    private val listener: () -> Unit = { render() }

    private val ticker = object : Runnable {
        override fun run() {
            renderProgress()
            renderStatus()
            h.postDelayed(this, 1000)
        }
    }

    private val hello = object : Runnable {
        override fun run() {
            // Abo erneuern: Handy schickt den Stand nur, solange die Uhr zuschaut
            Phone.cmd(this@RemoteActivity, "hello")
            h.postDelayed(this, 60_000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        c = Controls(
            this,
            onPrev = { Phone.cmd(this, "prev") },
            onToggle = {
                val now = !(currentPlaying())
                localPlaying = now
                localPlayingAt = SystemClock.elapsedRealtime()
                c.setPlaying(now)
                Phone.cmd(this, "toggle")
            },
            onNext = { Phone.cmd(this, "next") },
            onVolDown = { Phone.cmd(this, "vol-") },
            onVolUp = { Phone.cmd(this, "vol+") },
            middleLabel = "♡",
            onMiddle = {
                val fav = Remote.state?.optBoolean("fav") ?: false
                c.setMiddle(if (!fav) "♥" else "♡", !fav)
                Phone.cmd(this, "fav")
            },
            bottomLabel = "☰  Playlists",
            onBottom = { startActivity(Intent(this, RemoteBrowseActivity::class.java)) },
        )
        setContentView(c.root)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        render()
    }

    override fun onResume() {
        super.onResume()
        openedAt = SystemClock.elapsedRealtime()
        Remote.listen(listener)
        h.post(hello)
        h.post(ticker)
        render()
    }

    override fun onPause() {
        super.onPause()
        Remote.unlisten(listener)
        h.removeCallbacks(hello)
        h.removeCallbacks(ticker)
        Phone.cmd(this, "bye")
    }

    private fun currentPlaying(): Boolean {
        val lp = localPlaying
        if (lp != null && SystemClock.elapsedRealtime() - localPlayingAt < 2500 &&
            Remote.stateAt < localPlayingAt) return lp
        return Remote.state?.optBoolean("playing") ?: false
    }

    private fun render() {
        val s = Remote.state
        if (s == null) {
            c.title.text = "Verbinde mit Handy…"
            c.artist.text = ""
        } else {
            c.title.text = s.optString("title").ifEmpty { "Nichts ausgewählt" }
            c.artist.text = s.optString("artist")
            val fav = s.optBoolean("fav")
            c.setMiddle(if (fav) "♥" else "♡", fav)
        }
        c.setPlaying(currentPlaying())
        c.setCover(Remote.cover)
        renderProgress()
        renderStatus()
    }

    private fun renderProgress() {
        val s = Remote.state ?: return c.setProgress(0, 0)
        c.setProgress(Remote.positionMs(), s.optLong("dur"))
        if (localPlaying != null && Remote.stateAt >= localPlayingAt) localPlaying = null
        c.setPlaying(currentPlaying())
    }

    private fun renderStatus() {
        val waited = SystemClock.elapsedRealtime() - openedAt
        c.status.text = when {
            Remote.state == null && waited > 4000 -> "Keine Antwort – ist die App am Handy offen?"
            Remote.state != null && Remote.stateAt < openedAt && waited > 4000 -> "Alter Stand – Handy-App offen?"
            else -> ""
        }
    }
}
