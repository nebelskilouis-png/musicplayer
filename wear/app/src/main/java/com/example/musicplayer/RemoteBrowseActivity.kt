package com.example.musicplayer

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/** Playlists am Handy auswählen (ohne Extra) bzw. Abschnitte einer Playlist (mit playlistId). */
class RemoteBrowseActivity : Activity() {
    private lateinit var list: RowList
    private var playlistId: Long = -1
    private var actions: List<String> = emptyList() // Befehl pro Zeile
    private val listener: () -> Unit = { render() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        playlistId = intent.getLongExtra("playlistId", -1)
        val name = intent.getStringExtra("name") ?: "Playlists"
        list = RowList(this, if (playlistId >= 0) name else "Playlists")
        list.onClick = { i -> onRow(i) }
        setContentView(list.view)
        if (playlistId >= 0) {
            Remote.sections = null
            Phone.cmd(this, "sections:$playlistId")
        } else {
            Phone.cmd(this, "playlists")
        }
        render()
    }

    override fun onResume() {
        super.onResume()
        Remote.listen(listener)
    }

    override fun onPause() {
        super.onPause()
        Remote.unlisten(listener)
    }

    private fun render() {
        if (playlistId < 0) renderPlaylists() else renderSections()
    }

    private fun renderPlaylists() {
        val arr = Remote.playlists
        if (arr == null) {
            actions = emptyList()
            list.set(listOf(Row("Lade…", dim = true)))
            return
        }
        val current = Remote.state?.optLong("playlistId", -2) ?: -2
        val rows = ArrayList<Row>()
        val acts = ArrayList<String>()
        for (i in 0 until arr.length()) {
            val p = arr.getJSONObject(i)
            val id = p.getLong("id")
            rows += Row(p.optString("name"), "${p.optInt("count")} Songs", highlight = id == current)
            acts += "open:$id:${p.optString("name")}"
        }
        if (rows.isEmpty()) rows += Row("Keine Playlists", dim = true)
        actions = acts
        list.set(rows)
    }

    private fun renderSections() {
        val rows = ArrayList<Row>()
        val acts = ArrayList<String>()
        rows += Row("▶  Von vorne"); acts += "playat:$playlistId:0"
        rows += Row("🔀  Zufällig"); acts += "shuffleplay:$playlistId"
        val s = Remote.sections
        if (s == null || s.optLong("playlistId", -1) != playlistId) {
            rows += Row("Lade Abschnitte…", dim = true); acts += ""
        } else {
            val arr = s.optJSONArray("sections")
            if (arr != null) for (i in 0 until arr.length()) {
                val sec = arr.getJSONObject(i)
                rows += Row(sec.optString("name"), "${sec.optInt("count")} Songs", header = true)
                acts += "playat:$playlistId:${sec.optInt("index")}"
            }
        }
        actions = acts
        list.set(rows)
    }

    private fun onRow(i: Int) {
        val a = actions.getOrNull(i) ?: return
        if (a.isEmpty()) return
        if (a.startsWith("open:")) {
            val parts = a.split(":", limit = 3)
            startActivity(Intent(this, RemoteBrowseActivity::class.java)
                .putExtra("playlistId", parts[1].toLong())
                .putExtra("name", parts.getOrElse(2) { "" }))
            return
        }
        Phone.cmd(this, a)
        // zurück zur Fernbedienung
        startActivity(Intent(this, RemoteActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        finish()
    }
}
