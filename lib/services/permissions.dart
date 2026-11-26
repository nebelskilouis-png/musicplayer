import 'dart:io';
import 'package:permission_handler/permission_handler.dart';

/// Android: Zugriff auf alle Dateien – nötig, um MP3s in beliebige Playlist-Ordner zu kopieren.
/// Öffnet beim ersten Mal die System-Einstellung „Zugriff auf alle Dateien“.
Future<bool> ensureFullStorageAccess() async {
  if (!Platform.isAndroid) return true;
  try {
    if (await Permission.manageExternalStorage.isGranted) return true;
    if ((await Permission.manageExternalStorage.request()).isGranted) return true;
    return (await Permission.storage.request()).isGranted; // ältere Android-Versionen
  } catch (_) {
    return true;
  }
}

/// Android: Zugriff auf Audio-Dateien (und Cover-Bilder) sicherstellen.
/// Android 13+: "Musik und Audio" + "Fotos". Android 12 und älter: "Speicher".
/// Gibt true zurück, wenn die App Musikdateien lesen darf.
Future<bool> ensureMediaPermission() async {
  if (!Platform.isAndroid) return true;
  try {
    final audio = await Permission.audio.request();
    await Permission.photos.request(); // für Cover-Bilder in Hörbuch-Ordnern, optional
    if (audio.isGranted) return true;
    final storage = await Permission.storage.request(); // ältere Android-Versionen
    return storage.isGranted;
  } catch (_) {
    return true;
  }
}
