package com.example.musicplayer

import android.content.Context
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.google.android.gms.tasks.Tasks
import com.google.android.gms.wearable.Wearable
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Nachrichten-Pfade zwischen Handy und Uhr (müssen zur Handy-App passen). */
object P {
    const val CMD = "/mp/cmd"               // Uhr -> Handy: Befehl als Text
    const val STATE = "/mp/state"           // Handy -> Uhr: JSON
    const val COVER = "/mp/cover"           // Handy -> Uhr: JPEG
    const val PLAYLISTS = "/mp/playlists"   // Handy -> Uhr: JSON-Liste
    const val SECTIONS = "/mp/sections"     // Handy -> Uhr: JSON
    const val MANIFEST = "/mp/sync/manifest" // Handy -> Uhr: Playlist zum Offline-Hören
    const val DELETE = "/mp/sync/delete"    // Handy -> Uhr: Playlist-ID entfernen
    const val NEED = "/mp/sync/need"        // Uhr -> Handy: welche Songs noch fehlen
    const val FILE = "/mp/file/"            // Kanal pro Song: /mp/file/<trackId>
}

/** Senden an das Handy. */
object Phone {
    private const val TAG = "MP-Wear"
    private val exec = Executors.newSingleThreadExecutor()
    @Volatile private var nodes: List<String> = emptyList()
    @Volatile private var nodesAt = 0L

    private fun nodeIds(ctx: Context): List<String> {
        val now = SystemClock.elapsedRealtime()
        if (nodes.isEmpty() || now - nodesAt > 30_000) {
            nodes = Tasks.await(Wearable.getNodeClient(ctx).connectedNodes, 5, TimeUnit.SECONDS).map { it.id }
            nodesAt = now
        }
        return nodes
    }

    fun send(ctx: Context, path: String, data: ByteArray = ByteArray(0), onResult: ((Boolean) -> Unit)? = null) {
        val app = ctx.applicationContext
        exec.execute {
            var ok = false
            try {
                val mc = Wearable.getMessageClient(app)
                for (id in nodeIds(app)) {
                    Tasks.await(mc.sendMessage(id, path, data), 5, TimeUnit.SECONDS)
                    ok = true
                }
            } catch (e: Exception) {
                Log.w(TAG, "send $path: $e")
                nodesAt = 0
            }
            onResult?.let { cb -> Handler(Looper.getMainLooper()).post { cb(ok) } }
        }
    }

    fun cmd(ctx: Context, c: String, onResult: ((Boolean) -> Unit)? = null) =
        send(ctx, P.CMD, c.toByteArray(), onResult)
}

/** Zuletzt vom Handy empfangener Stand (Fernbedienung). */
object Remote {
    @Volatile var state: JSONObject? = null
    @Volatile var stateAt = 0L
    @Volatile var cover: Bitmap? = null
    @Volatile var playlists: JSONArray? = null
    @Volatile var sections: JSONObject? = null

    private val main = Handler(Looper.getMainLooper())
    private val listeners = LinkedHashSet<() -> Unit>()

    fun listen(l: () -> Unit) { listeners += l }
    fun unlisten(l: () -> Unit) { listeners -= l }
    fun changed() = main.post { listeners.toList().forEach { it() } }

    /** Aktuelle Position, hochgerechnet seit der letzten Nachricht. */
    fun positionMs(): Long {
        val s = state ?: return 0
        val pos = s.optLong("pos")
        if (!s.optBoolean("playing")) return pos
        val speed = s.optDouble("speed", 1.0)
        val dur = s.optLong("dur")
        val p = pos + ((SystemClock.elapsedRealtime() - stateAt) * speed).toLong()
        return if (dur > 0) p.coerceAtMost(dur) else p
    }
}
