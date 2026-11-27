package com.example.musicplayer

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.google.android.gms.tasks.Tasks
import com.google.android.gms.wearable.MessageClient
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Wearable
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Verbindung zur Uhr-App (Wear OS): Befehle empfangen, Stand/Cover/Songs senden. */
class WearBridge(context: Context, messenger: BinaryMessenger) : MessageClient.OnMessageReceivedListener {
    companion object {
        private const val TAG = "MP-WearBridge"
        const val CMD = "/mp/cmd"
        const val COVER = "/mp/cover"
        const val NEED = "/mp/sync/need"
        const val FILE = "/mp/file/"

        private var current: WearBridge? = null

        fun attach(context: Context, messenger: BinaryMessenger) {
            current?.dispose()
            current = try {
                WearBridge(context.applicationContext, messenger)
            } catch (e: Exception) {
                Log.w(TAG, "Wear nicht verfügbar: $e")
                null
            }
        }
    }

    private val ctx = context.applicationContext
    private val channel = MethodChannel(messenger, "musicplayer/wear")
    private val main = Handler(Looper.getMainLooper())
    private val msgExec = Executors.newSingleThreadExecutor()
    private val fileExec = Executors.newSingleThreadExecutor()
    @Volatile private var nodes: List<String> = emptyList()
    @Volatile private var nodesAt = 0L
    @Volatile private var cancelSync = false

    init {
        Wearable.getMessageClient(ctx).addListener(this)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "send" -> {
                    val path = call.argument<String>("path") ?: ""
                    val data = call.argument<ByteArray>("data") ?: ByteArray(0)
                    msgExec.execute { sendNow(path, data) }
                    result.success(null)
                }
                "sendCover" -> {
                    val path = call.argument<String>("path")
                    msgExec.execute { sendNow(COVER, coverBytes(path)) }
                    result.success(null)
                }
                "sendFiles" -> {
                    @Suppress("UNCHECKED_CAST")
                    val files = (call.argument<List<Map<String, Any>>>("files") ?: emptyList())
                    cancelSync = false
                    fileExec.execute { sendFiles(files) }
                    result.success(null)
                }
                "cancelSync" -> {
                    cancelSync = true
                    result.success(null)
                }
                "watchConnected" -> {
                    msgExec.execute {
                        val ok = runCatching { nodeIds(force = true).isNotEmpty() }.getOrDefault(false)
                        main.post { result.success(ok) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun dispose() {
        runCatching { Wearable.getMessageClient(ctx).removeListener(this) }
        channel.setMethodCallHandler(null)
    }

    override fun onMessageReceived(e: MessageEvent) {
        val text = String(e.data ?: ByteArray(0))
        when (e.path) {
            CMD -> when (text) {
                // Lautstärke direkt am Handy, ohne Umweg über Dart -> schneller
                "vol+" -> adjustVolume(AudioManager.ADJUST_RAISE)
                "vol-" -> adjustVolume(AudioManager.ADJUST_LOWER)
                else -> main.post { channel.invokeMethod("cmd", text) }
            }
            NEED -> main.post { channel.invokeMethod("need", text) }
        }
    }

    private fun adjustVolume(dir: Int) {
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        am.adjustStreamVolume(AudioManager.STREAM_MUSIC, dir, 0)
    }

    private fun nodeIds(force: Boolean = false): List<String> {
        val now = SystemClock.elapsedRealtime()
        if (force || nodes.isEmpty() || now - nodesAt > 30_000) {
            nodes = Tasks.await(Wearable.getNodeClient(ctx).connectedNodes, 5, TimeUnit.SECONDS).map { it.id }
            nodesAt = now
        }
        return nodes
    }

    private fun sendNow(path: String, data: ByteArray) {
        try {
            val mc = Wearable.getMessageClient(ctx)
            for (id in nodeIds()) Tasks.await(mc.sendMessage(id, path, data), 5, TimeUnit.SECONDS)
        } catch (e: Exception) {
            Log.w(TAG, "send $path: $e")
            nodesAt = 0
        }
    }

    /** Cover klein rechnen (Uhr-Display), als JPEG. Leer = kein Cover. */
    private fun coverBytes(path: String?): ByteArray {
        if (path.isNullOrEmpty() || !File(path).exists()) return ByteArray(0)
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= 240 && bounds.outHeight / (sample * 2) >= 240) sample *= 2
            val bmp = BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
                ?: return ByteArray(0)
            val scaled = if (bmp.width > 320) Bitmap.createScaledBitmap(bmp, 320, (320f * bmp.height / bmp.width).toInt(), true) else bmp
            val out = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, 70, out)
            out.toByteArray()
        } catch (e: Exception) {
            ByteArray(0)
        }
    }

    /** Songs nacheinander über einen Kanal pro Datei an die Uhr schicken. */
    private fun sendFiles(files: List<Map<String, Any>>) {
        val total = files.size
        var done = 0
        var failed = 0
        val cc = Wearable.getChannelClient(ctx)
        val targets = runCatching { nodeIds(force = true) }.getOrDefault(emptyList())
        if (targets.isEmpty()) {
            main.post { channel.invokeMethod("syncDone", mapOf("ok" to false, "done" to 0, "total" to total)) }
            return
        }
        for (f in files) {
            if (cancelSync) break
            val id = f["id"].toString()
            val path = f["path"] as? String ?: continue
            val file = File(path)
            var ok = false
            if (file.exists()) {
                for (node in targets) {
                    try {
                        val ch = Tasks.await(cc.openChannel(node, FILE + id), 20, TimeUnit.SECONDS)
                        // Stream schließen = Datei fertig. Den Kanal schließt die Uhr nach dem Lesen.
                        val out = Tasks.await(cc.getOutputStream(ch), 20, TimeUnit.SECONDS)
                        out.use { o -> file.inputStream().use { it.copyTo(o, 64 * 1024) } }
                        ok = true
                    } catch (e: Exception) {
                        Log.w(TAG, "Datei $id: $e")
                    }
                }
            }
            if (ok) done++ else failed++
            val d = done
            main.post { channel.invokeMethod("syncProgress", mapOf("done" to d, "total" to total)) }
        }
        val d = done
        val fl = failed
        main.post {
            channel.invokeMethod("syncDone", mapOf("ok" to (fl == 0 && !cancelSync), "done" to d, "total" to total))
        }
    }
}
