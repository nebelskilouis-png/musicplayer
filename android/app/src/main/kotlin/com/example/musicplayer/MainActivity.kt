package com.example.musicplayer

import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
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
        // Uhr-App (Wear OS)
        WearBridge.attach(this, flutterEngine.dartExecutor.binaryMessenger)
        // Kanal für den Audio-Ausgang (Kopfhörer / Bluetooth / Lautsprecher)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "musicplayer/output")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openOutputSwitcher" -> result.success(openOutputSwitcher())
                    "openBluetoothSettings" -> result.success(openBluetoothSettings())
                    "currentMediaOutput" -> result.success(currentMediaOutput())
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

    /** Wohin Musik gerade wirklich geht (Android 13+). null = unbekannt. */
    private fun currentMediaOutput(): Map<String, String>? {
        if (Build.VERSION.SDK_INT < 33) return null
        return try {
            val am = getSystemService(AUDIO_SERVICE) as AudioManager
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build()
            val d = am.getAudioDevicesForAttributes(attrs).firstOrNull() ?: return null
            val kind = when (d.type) {
                AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                AudioDeviceInfo.TYPE_BLE_HEADSET,
                AudioDeviceInfo.TYPE_BLE_SPEAKER,
                AudioDeviceInfo.TYPE_HEARING_AID -> "bluetooth"
                AudioDeviceInfo.TYPE_WIRED_HEADSET,
                AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                AudioDeviceInfo.TYPE_USB_HEADSET,
                AudioDeviceInfo.TYPE_USB_DEVICE,
                AudioDeviceInfo.TYPE_USB_ACCESSORY,
                AudioDeviceInfo.TYPE_LINE_ANALOG,
                AudioDeviceInfo.TYPE_LINE_DIGITAL,
                AudioDeviceInfo.TYPE_AUX_LINE -> "wired"
                AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
                else -> return null
            }
            mapOf("kind" to kind, "name" to (d.productName?.toString() ?: ""))
        } catch (e: Exception) {
            null
        }
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
