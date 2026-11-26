import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import '../database/database_helper.dart';
import '../models/track.dart';

/// Liest Cover aus den MP3s im Hintergrund (eigener Isolate -> UI ruckelt nicht)
/// und speichert sie als kleine Bilddateien im App-Ordner.
class CoverService {
  static final CoverService instance = CoverService._();
  CoverService._();

  final Map<int, String> _paths = {};
  bool _running = false;

  /// Zählt hoch, sobald neue Cover da sind.
  final ValueNotifier<int> version = ValueNotifier(0);

  String? pathFor(Track t) => t.coverPath ?? (t.id == null ? null : _paths[t.id]);

  Future<String> _coverDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}covers');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  Future<void> run() async {
    if (_running) return;
    _running = true;
    try {
      final dir = await _coverDir();
      while (true) {
        final rows = await DatabaseHelper.instance.getTracksWithoutCoverCheck(25);
        if (rows.isEmpty) break;
        final ids = rows.map((r) => r['id'] as int).toList();
        final files = rows.map((r) => r['file_path'] as String).toList();
        final results = await _runBatch(files, ids, dir);
        for (int i = 0; i < ids.length; i++) {
          final p = i < results.length ? results[i] : null;
          await DatabaseHelper.instance.setTrackCover(ids[i], p);
          if (p != null) _paths[ids[i]] = p;
        }
        version.value++;
      }
    } catch (e) {
      debugPrint('Cover-Fehler: $e');
    } finally {
      _running = false;
    }
  }

  /// Cache löschen und alle Cover neu einlesen.
  Future<void> rebuild() async {
    try {
      final dir = await _coverDir();
      await Directory(dir).delete(recursive: true);
    } catch (_) {}
    _paths.clear();
    await DatabaseHelper.instance.resetCoverChecks();
    version.value++;
    await run();
  }
}

Future<List<String?>> _runBatch(List<String> files, List<int> ids, String dir) =>
    Isolate.run(() => _extractBatch(files, ids, dir));

List<String?> _extractBatch(List<String> files, List<int> ids, String dir) {
  final out = <String?>[];
  for (int i = 0; i < files.length; i++) {
    String? result;
    try {
      final dynamic meta = readMetadata(File(files[i]), getImage: true);
      final dynamic pics = meta?.pictures;
      if (pics is List && pics.isNotEmpty) {
        final dynamic pic = pics.first;
        final String mime = (pic.mimetype ?? '').toString();
        final ext = mime.contains('png') ? 'png' : 'jpg';
        final f = File('$dir${Platform.pathSeparator}${ids[i]}.$ext');
        f.writeAsBytesSync(pic.bytes as List<int>);
        result = f.path;
      }
    } catch (_) {
      // kein Cover / Datei defekt -> Platzhalter
    }
    out.add(result);
  }
  return out;
}


/// Gewähltes Cover-Bild dauerhaft speichern.
/// Android legt Bilder aus der Dateiauswahl nur in einen Zwischenspeicher, den das System
/// regelmäßig leert -> Cover verschwanden. Darum wird das Bild in einen festen App-Ordner kopiert.
/// Gibt den neuen Pfad zurück (oder den alten, falls Kopieren nicht klappt).
Future<String> persistCoverImage(String sourcePath, String prefix) async {
  try {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}custom_covers');
    if (!await dir.exists()) await dir.create(recursive: true);
    final dot = sourcePath.lastIndexOf('.');
    final ext = dot >= 0 ? sourcePath.substring(dot).toLowerCase() : '.jpg';
    final target = '${dir.path}${Platform.pathSeparator}${prefix}_${DateTime.now().millisecondsSinceEpoch}$ext';
    await File(sourcePath).copy(target);
    return target;
  } catch (e) {
    debugPrint('Cover konnte nicht gespeichert werden: $e');
    return sourcePath;
  }
}
