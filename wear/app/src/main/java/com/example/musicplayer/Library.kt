package com.example.musicplayer

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.android.gms.tasks.Tasks
import com.google.android.gms.wearable.ChannelClient
import com.google.android.gms.wearable.Wearable
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.TimeUnit

/** Ein Song auf der Uhr. */
data class LocalTrack(
    val id: Long,
    val ext: String,
    val size: Long,
    val title: String,
    val artist: String,
    val section: String?,
)

data class LocalPlaylist(val id: Long, val name: String, val tracks: List<LocalTrack>)

/** Offline-Bibliothek auf der Uhr: Songs liegen einmal unter tracks/, Playlists als JSON. */
object Library {
    private const val TAG = "MP-Wear"
    private val main = Handler(Looper.getMainLooper())
    private val listeners = LinkedHashSet<() -> Unit>()

    fun listen(l: () -> Unit) { listeners += l }
    fun unlisten(l: () -> Unit) { listeners -= l }
    private fun changed() = main.post { listeners.toList().forEach { it() } }

    private fun root(ctx: Context) = File(ctx.filesDir, "music").apply { mkdirs() }
    private fun tracksDir(ctx: Context) = File(root(ctx), "tracks").apply { mkdirs() }
    private fun playlistsDir(ctx: Context) = File(root(ctx), "playlists").apply { mkdirs() }

    fun trackFile(ctx: Context, t: LocalTrack) = File(tracksDir(ctx), "${t.id}.${t.ext}")

    /** Datei zu einer Track-ID (egal welche Endung). */
    fun fileForId(ctx: Context, id: String): File? =
        tracksDir(ctx).listFiles { f -> f.name.startsWith("$id.") && !f.name.endsWith(".part") }?.firstOrNull()

    fun isPresent(ctx: Context, t: LocalTrack): Boolean {
        val f = trackFile(ctx, t)
        return f.exists() && (t.size <= 0 || f.length() == t.size)
    }

    fun playlists(ctx: Context): List<LocalPlaylist> =
        playlistsDir(ctx).listFiles { f -> f.name.endsWith(".json") }
            ?.mapNotNull { f -> runCatching { parse(JSONObject(f.readText())) }.getOrNull() }
            ?.sortedBy { it.name.lowercase() }
            ?: emptyList()

    fun playlist(ctx: Context, id: Long): LocalPlaylist? {
        val f = File(playlistsDir(ctx), "$id.json")
        if (!f.exists()) return null
        return runCatching { parse(JSONObject(f.readText())) }.getOrNull()
    }

    private fun parse(o: JSONObject): LocalPlaylist {
        val arr = o.getJSONArray("tracks")
        val list = ArrayList<LocalTrack>(arr.length())
        for (i in 0 until arr.length()) {
            val t = arr.getJSONObject(i)
            list += LocalTrack(
                id = t.getLong("id"),
                ext = t.optString("ext", "mp3").ifEmpty { "mp3" },
                size = t.optLong("size", 0),
                title = t.optString("title"),
                artist = t.optString("artist"),
                section = t.optString("section").takeIf { it.isNotBlank() },
            )
        }
        return LocalPlaylist(o.getLong("id"), o.optString("name", "Playlist"), list)
    }

    /** Handy schickt eine Playlist -> speichern, fehlende Songs anfordern. */
    fun onManifest(ctx: Context, json: String) {
        val o = JSONObject(json)
        val pl = parse(o)
        File(playlistsDir(ctx), "${pl.id}.json").writeText(json)
        cleanup(ctx)
        val need = JSONArray()
        for (t in pl.tracks) if (!isPresent(ctx, t)) need.put(t.id)
        Phone.send(ctx, P.NEED, JSONObject().put("playlistId", pl.id).put("ids", need).toString().toByteArray())
        changed()
    }

    fun deletePlaylist(ctx: Context, id: Long) {
        File(playlistsDir(ctx), "$id.json").delete()
        cleanup(ctx)
        changed()
    }

    /** Song-Dateien löschen, die in keiner Playlist mehr vorkommen. */
    private fun cleanup(ctx: Context) {
        val used = HashSet<String>()
        for (p in playlists(ctx)) for (t in p.tracks) used += "${t.id}.${t.ext}"
        tracksDir(ctx).listFiles()?.forEach { f ->
            val name = f.name.removeSuffix(".part")
            if (name !in used) f.delete()
        }
    }

    /** Einen Song über einen Kanal empfangen (blockiert bis fertig). */
    fun receive(ctx: Context, ch: ChannelClient.Channel, trackId: String) {
        val cc = Wearable.getChannelClient(ctx)
        var ext = "mp3"
        // Endung aus den Playlists heraussuchen
        outer@ for (p in playlists(ctx)) for (t in p.tracks) if (t.id.toString() == trackId) { ext = t.ext; break@outer }
        val dest = File(tracksDir(ctx), "$trackId.$ext")
        val tmp = File(tracksDir(ctx), "$trackId.$ext.part")
        try {
            val input = Tasks.await(cc.getInputStream(ch), 30, TimeUnit.SECONDS)
            input.use { inp -> tmp.outputStream().use { out -> inp.copyTo(out, 64 * 1024) } }
            if (tmp.length() > 0) {
                dest.delete()
                tmp.renameTo(dest)
            } else {
                tmp.delete()
            }
        } catch (e: Exception) {
            Log.w(TAG, "Empfang $trackId fehlgeschlagen: $e")
            tmp.delete()
        } finally {
            runCatching { cc.close(ch) }
        }
        changed()
    }
}
