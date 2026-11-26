package com.example.musicplayer

import android.content.Intent
import android.media.MediaRouter2
import android.os.Build
import android.provider.Settings
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// AudioServiceActivity statt FlutterActivity: nötig für Sperrbildschirm-Steuerung (audio_service)
class MainActivity : AudioServiceActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Kanal für den Audio-Ausgang (Kopfhörer / Bluetooth / Lautsprecher)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "musicplayer/output")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openOutputSwitcher" -> result.success(openOutputSwitcher())
                    "openBluetoothSettings" -> result.success(openBluetoothSettings())
                    else -> result.notImplemented()
                }
            }
    }

    /** Öffnet das System-Menü "Medienausgabe". Gibt zurück, welcher Weg benutzt wurde. */
    private fun openOutputSwitcher(): String {
        // Android 14+: offizieller Weg
        if (Build.VERSION.SDK_INT >= 34) {
            try {
                if (MediaRouter2.getInstance(this).showSystemOutputSwitcher()) return "system"
            } catch (e: Exception) {
            }
        }
        // Android 11–13: Medienausgabe-Dialog der Systemoberfläche (nicht auf jedem Handy vorhanden)
        if (Build.VERSION.SDK_INT >= 30) {
            try {
                val intent = Intent("com.android.systemui.action.LAUNCH_MEDIA_OUTPUT_DIALOG")
                    .setPackage("com.android.systemui")
                    .putExtra("package_name", packageName)
                sendBroadcast(intent)
                return "broadcast"
            } catch (e: Exception) {
            }
        }
        return if (openBluetoothSettings()) "bluetooth" else "none"
    }

    private fun openBluetoothSettings(): Boolean {
        return try {
            startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (e: Exception) {
            false
        }
    }
}
