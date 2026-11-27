package com.example.musicplayer

import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.AudioManager
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.google.common.util.concurrent.ListenableFuture
import java.util.concurrent.Executors

/** Liste der auf die Uhr übertragenen Playlists. */
class LocalLibraryActivity : Activity() {
    private lateinit var list: RowList
    private var ids: List<Long> = emptyList()
    private val listener: () -> Unit = { render() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        list = RowList(this, "Auf der Uhr")
        list.onClick = { i ->
            val id = ids.getOrNull(i)
            when {
                id == null -> Unit
                id == -1L -> startActivity(Intent(this, LocalPlayerActivity::class.java))
                id >= 0 -> startActivity(Intent(this, LocalPlaylistActivity::class.java).putExtra("playlistId", id))
            }
        }
        setContentView(list.view)
    }

    override fun onResume() {
        super.onResume()
        Library.listen(listener)
        render()
    }

    override fun onPause() {
        super.onPause()
        Library.unlisten(listener)
    }

    private fun render() {
        val pls = Library.playlists(this)
        val rows = ArrayList<Row>()
        val acts = ArrayList<Long>()
        rows += Row("▶  Player öffnen"); acts += -1L
        if (pls.isEmpty()) {
            rows += Row("Noch nichts da", "Am Handy: Playlist → ⋮ → Auf die Uhr übertragen", dim = true)
            acts += -2L
        }
        for (p in pls) {
            val have = p.tracks.count { Library.isPresent(this, it) }
            val sub = if (have == p.tracks.size) "${p.tracks.size} Songs" else "$have / ${p.tracks.size} Songs übertragen…"
            rows += Row(p.name, sub)
            acts += p.id
        }
        ids = acts
        list.set(rows)
    }
}

/** Songs einer Offline-Playlist mit Abschnitten. */
class LocalPlaylistActivity : Activity() {
    private lateinit var list: RowList
    private var playlistId = -1L
    private var actions: List<Pair<String, Long>> = emptyList() // (Art, Track-ID)
    private val listener: () -> Unit = { render() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        playlistId = intent.getLongExtra("playlistId", -1)
        val pl = Library.playlist(this, playlistId)
        list = RowList(this, pl?.name ?: "Playlist")
        list.onClick = { i -> onRow(i) }
        setContentView(list.view)
    }

    override fun onResume() {
        super.onResume()
        Library.listen(listener)
        render()
    }

    override fun onPause() {
        super.onPause()
        Library.unlisten(listener)
    }

    private fun render() {
        val pl = Library.playlist(this, playlistId) ?: return finish()
        val rows = ArrayList<Row>()
        val acts = ArrayList<Pair<String, Long>>()
        rows += Row("▶  Abspielen"); acts += "play" to -1L
        rows += Row("🔀  Zufällig"); acts += "shuffle" to -1L
        for (t in pl.tracks) {
            if (t.section != null) {
                rows += Row(t.section, header = true); acts += "play" to t.id
            }
            val ok = Library.isPresent(this, t)
            rows += Row(t.title, if (ok) t.artist else "wird übertragen…", dim = !ok)
            acts += (if (ok) "play" else "none") to t.id
        }
        actions = acts
        list.set(rows)
    }

    private fun onRow(i: Int) {
        val (kind, id) = actions.getOrNull(i) ?: return
        if (kind == "none") return
        startActivity(Intent(this, LocalPlayerActivity::class.java)
            .putExtra("playlistId", playlistId)
            .putExtra("startId", id)
            .putExtra("shuffle", kind == "shuffle"))
    }
}

/** Offline-Player auf der Uhr. */
class LocalPlayerActivity : Activity() {
    private lateinit var c: Controls
    private var future: ListenableFuture<MediaController>? = null
    private var controller: MediaController? = null
    private val h = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private var coverFor: String? = null

    private val ticker = object : Runnable {
        override fun run() {
            controller?.let { c.setProgress(it.currentPosition, it.duration.coerceAtLeast(0)) }
            h.postDelayed(this, 1000)
        }
    }

    private val playerListener = object : Player.Listener {
        override fun onEvents(player: Player, events: Player.Events) = render()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val am = getSystemService(AUDIO_SERVICE) as AudioManager
        c = Controls(
            this,
            onPrev = { controller?.seekToPrevious() },
            onToggle = {
                controller?.let { if (it.isPlaying) it.pause() else it.play() }
            },
            onNext = { controller?.seekToNext() },
            onVolDown = { am.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_LOWER, AudioManager.FLAG_SHOW_UI) },
            onVolUp = { am.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_RAISE, AudioManager.FLAG_SHOW_UI) },
            middleLabel = "🔀",
            onMiddle = { controller?.let { it.shuffleModeEnabled = !it.shuffleModeEnabled } },
            bottomLabel = "☰  Liste",
            onBottom = { finish() },
        )
        setContentView(c.root)
    }

    override fun onStart() {
        super.onStart()
        val token = SessionToken(this, ComponentName(this, PlaybackService::class.java))
        val f = MediaController.Builder(this, token).buildAsync()
        future = f
        f.addListener({
            val ctl = runCatching { f.get() }.getOrNull() ?: return@addListener
            controller = ctl
            ctl.addListener(playerListener)
            startFromIntent(ctl)
            render()
        }, mainExecutor)
        h.post(ticker)
    }

    override fun onStop() {
        super.onStop()
        h.removeCallbacks(ticker)
        controller?.removeListener(playerListener)
        future?.let { MediaController.releaseFuture(it) }
        controller = null
        future = null
    }

    private fun startFromIntent(ctl: MediaController) {
        val pid = intent.getLongExtra("playlistId", -1)
        if (pid < 0) return
        intent.removeExtra("playlistId") // nur einmal starten
        val pl = Library.playlist(this, pid) ?: return
        val present = pl.tracks.filter { Library.isPresent(this, it) }
        if (present.isEmpty()) return
        val items = present.map { t ->
            MediaItem.Builder()
                .setMediaId(t.id.toString())
                .setUri(Uri.fromFile(Library.trackFile(this, t)))
                .setMediaMetadata(
                    MediaMetadata.Builder()
                        .setTitle(t.title)
                        .setArtist(t.artist)
                        .setAlbumTitle(pl.name)
                        .build(),
                )
                .build()
        }
        val shuffle = intent.getBooleanExtra("shuffle", false)
        val startId = intent.getLongExtra("startId", -1)
        var start = present.indexOfFirst { it.id == startId }
        if (start < 0) start = if (shuffle) (present.indices).random() else 0
        ctl.shuffleModeEnabled = shuffle
        ctl.repeatMode = Player.REPEAT_MODE_ALL
        ctl.setMediaItems(items, start, 0)
        ctl.prepare()
        ctl.play()
    }

    private fun render() {
        val ctl = controller ?: return
        val md = ctl.mediaMetadata
        c.title.text = md.title?.toString() ?: if (ctl.mediaItemCount == 0) "Nichts ausgewählt" else ""
        c.artist.text = md.artist?.toString() ?: ""
        c.setPlaying(ctl.isPlaying || (ctl.playWhenReady && ctl.playbackState == Player.STATE_BUFFERING))
        c.setMiddle("🔀", ctl.shuffleModeEnabled)
        c.setProgress(ctl.currentPosition, ctl.duration.coerceAtLeast(0))
        val id = ctl.currentMediaItem?.mediaId
        if (id != coverFor) {
            coverFor = id
            loadCover(id)
        }
    }

    private fun loadCover(id: String?) {
        if (id == null) return c.setCover(null)
        io.execute {
            val path = Library.fileForId(this, id)?.path
            val bmp: Bitmap? = runCatching {
                val r = MediaMetadataRetriever()
                try {
                    if (path == null) return@runCatching null
                    r.setDataSource(path)
                    r.embeddedPicture?.let { bytes ->
                        val opts = BitmapFactory.Options().apply { inSampleSize = 4 }
                        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
                    }
                } finally {
                    r.release()
                }
            }.getOrNull()
            h.post { if (coverFor == id) c.setCover(bmp) }
        }
    }
}
