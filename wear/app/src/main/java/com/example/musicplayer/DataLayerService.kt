package com.example.musicplayer

import android.graphics.BitmapFactory
import android.os.SystemClock
import android.util.Log
import com.google.android.gms.wearable.ChannelClient
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.WearableListenerService
import org.json.JSONArray
import org.json.JSONObject

/** Empfängt alles vom Handy – auch wenn die Uhr-App gerade nicht offen ist. */
class DataLayerService : WearableListenerService() {

    override fun onMessageReceived(e: MessageEvent) {
        val d = e.data ?: ByteArray(0)
        try {
            when (e.path) {
                P.STATE -> {
                    Remote.state = JSONObject(String(d))
                    Remote.stateAt = SystemClock.elapsedRealtime()
                    Remote.changed()
                }
                P.COVER -> {
                    Remote.cover = if (d.isEmpty()) null else BitmapFactory.decodeByteArray(d, 0, d.size)
                    Remote.changed()
                }
                P.PLAYLISTS -> {
                    Remote.playlists = JSONArray(String(d))
                    Remote.changed()
                }
                P.SECTIONS -> {
                    Remote.sections = JSONObject(String(d))
                    Remote.changed()
                }
                P.MANIFEST -> Library.onManifest(this, String(d))
                P.DELETE -> String(d).trim().toLongOrNull()?.let { Library.deletePlaylist(this, it) }
            }
        } catch (ex: Exception) {
            Log.w("MP-Wear", "Nachricht ${e.path}: $ex")
        }
    }

    override fun onChannelOpened(channel: ChannelClient.Channel) {
        val path = channel.path
        if (path.startsWith(P.FILE)) {
            Library.receive(this, channel, path.removePrefix(P.FILE))
        }
    }
}
