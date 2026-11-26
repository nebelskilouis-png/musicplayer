import 'dart:io';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../database/database_helper.dart';
import '../models/track.dart';
import 'audiobook_service.dart' show naturalCompare;
import 'cover_service.dart';
import 'settings_service.dart';

/// Dateiname ohne vorangestellte Nummer, z.B. "001 - Song" -> "Song".
/// Die Nummern sind nur für die Reihenfolge im Ordner da und sollen in der App nicht auftauchen.
String cleanFileTitle(String name) {
  final cleaned = name.replaceFirst(RegExp(r'^\s*\d{1,4}\s*[-–._)]+\s*'), '').trim();
  return cleaned.isEmpty ? name : cleaned;
}

class MusicScanner {
  /// Zählt hoch, wenn sich die Bibliothek durch einen Scan geändert hat.
  static final ValueNotifier<int> libraryChanged = ValueNotifier(0);

  /// Alle Playlist-Ordner nach neuen Songs durchsuchen (z.B. beim App-Start).
  static Future<int> scanAllPlaylists() async {
    int total = 0;
    final pls = await DatabaseHelper.instance.getPlaylists();
    for (final pl in pls) {
      if (((pl['folder_path'] as String?) ?? '').isEmpty) continue; // Playlist ohne Ordner
      total += await MusicScanner()
          .scanFolderForPlaylist(Directory(pl['folder_path'] as String), pl['id'] as int);
    }
    return total;
  }

  /// Einmalig: bei Ordner-Playlists das Hinzufüge-Datum aus dem Datei-Datum übernehmen
  /// (vorher hatten alle Songs dasselbe Datum).
  static Future<void> fixAddedDatesOnce() async {
    final helper = DatabaseHelper.instance;
    final settings = await helper.getSettings();
    if (settings['added_dates_fixed'] == '1') return;
    final db = await helper.database;
    final rows = await db.rawQuery('''
      SELECT pt.id AS pt_id, t.file_path FROM playlist_tracks pt
      INNER JOIN tracks t ON t.id = pt.track_id
      INNER JOIN playlists p ON p.id = pt.playlist_id
      WHERE p.folder_path != ''
    ''');
    final batch = db.batch();
    for (final r in rows) {
      try {
        final ms = File(r['file_path'] as String).lastModifiedSync().millisecondsSinceEpoch;
        batch.update('playlist_tracks', {'added_at': ms}, where: 'id = ?', whereArgs: [r['pt_id']]);
      } catch (_) {}
    }
    await batch.commit(noResult: true);
    await helper.setSetting('added_dates_fixed', '1');
    libraryChanged.value++;
  }

  Future<int> scanFolderForPlaylist(Directory rootDir, int playlistId) async {
    if (!await rootDir.exists()) return 0;

    final db = await DatabaseHelper.instance.database;

    final entities = await rootDir.list(recursive: false, followLinks: false).toList();
    entities.sort((a, b) => a.path.compareTo(b.path));

    // Bereits vorhandene Pfade einmal laden statt pro Datei abzufragen (schneller)
    final existingRows = await db.rawQuery('''
      SELECT t.file_path FROM playlist_tracks pt
      INNER JOIN tracks t ON pt.track_id = t.id
      WHERE pt.playlist_id = ?
    ''', [playlistId]);
    final existing = existingRows.map((r) => r['file_path'] as String).toSet();

    final newFiles = <File>[];
    for (final entity in entities) {
      if (entity is! File) continue;
      if (!entity.path.toLowerCase().endsWith('.mp3')) continue;
      if (!existing.contains(entity.path)) newFiles.add(entity);
    }

    // Umbenannte Dateien erkennen (z.B. "Song.mp3" -> "001 - Song.mp3"):
    // statt neuem Eintrag den alten behalten -> Position und Abschnitte bleiben erhalten.
    String key(String path) => cleanFileTitle(p.basenameWithoutExtension(path)).toLowerCase();
    final idRows = await db.rawQuery('''
      SELECT t.id, t.file_path FROM playlist_tracks pt
      INNER JOIN tracks t ON pt.track_id = t.id
      WHERE pt.playlist_id = ?
    ''', [playlistId]);
    final missing = <String, int>{};
    for (final r in idRows) {
      final fp = r['file_path'] as String;
      if (!File(fp).existsSync()) missing[key(fp)] = r['id'] as int;
    }
    if (missing.isNotEmpty) {
      final stillNew = <File>[];
      for (final f in newFiles) {
        final id = missing.remove(key(f.path));
        if (id == null) {
          stillNew.add(f);
          continue;
        }
        try {
          await db.update('tracks', {'file_path': f.path}, where: 'id = ?', whereArgs: [id]);
        } catch (e) {
          stillNew.add(f); // Pfad schon anderweitig vergeben -> normal hinzufügen
        }
      }
      if (stillNew.length != newFiles.length) libraryChanged.value++;
      newFiles
        ..clear()
        ..addAll(stillNew);
    }

    if (newFiles.isEmpty) return 0;

    final newCount = newFiles.length;
    final insertMode = AppSettings.instance.newSongsPosition.value;
    final atTop = insertMode == 0;
    final newIds = <int>[];

    // Nach Datei-Datum ordnen: oben = neueste zuerst, unten = älteste zuerst
    final times = <String, int>{};
    for (final f in newFiles) {
      try {
        times[f.path] = f.lastModifiedSync().millisecondsSinceEpoch;
      } catch (_) {
        times[f.path] = 0;
      }
    }
    newFiles.sort((a, b) {
      final c = atTop ? times[b.path]!.compareTo(times[a.path]!) : times[a.path]!.compareTo(times[b.path]!);
      return c != 0 ? c : a.path.compareTo(b.path);
    });

    int positionCounter;
    if (atTop) {
      // bestehende Songs nach unten schieben, neue kommen oben rein
      await db.rawUpdate(
        'UPDATE playlist_tracks SET position = position + ? WHERE playlist_id = ?',
        [newCount, playlistId],
      );
      positionCounter = 0;
    } else {
      positionCounter = await DatabaseHelper.instance.getMaxPosition(playlistId) + 1;
    }

    for (final file in newFiles) {
      try {
        final dynamic meta = readMetadata(file, getImage: false);
        final fallbackTitle = cleanFileTitle(p.basenameWithoutExtension(file.path));
        final String? title = (meta?.title as String?)?.trim();
        final String? artist = (meta?.artist as String?)?.trim();
        final String? album = (meta?.album as String?)?.trim();
        final Duration? duration = meta?.duration as Duration?;

        final track = Track(
          filePath: file.path,
          title: (title != null && title.isNotEmpty) ? title : fallbackTitle,
          artist: (artist != null && artist.isNotEmpty) ? artist : 'Unbekannt',
          album: (album != null && album.isNotEmpty) ? album : 'Unbekannt',
          durationMs: duration?.inMilliseconds ?? 0,
          addedAt: DateTime.now().millisecondsSinceEpoch,
        );

        int trackId = await db.insert('tracks', track.toMap(), conflictAlgorithm: ConflictAlgorithm.ignore);
        if (trackId == 0) {
          final rows = await db.query('tracks', columns: ['id'], where: 'file_path = ?', whereArgs: [file.path]);
          if (rows.isNotEmpty) trackId = rows.first['id'] as int;
        }

        // "Hinzugefügt am" = Zeitpunkt, an dem die Datei in den Ordner kam
        int addedAt = DateTime.now().millisecondsSinceEpoch;
        try {
          addedAt = file.lastModifiedSync().millisecondsSinceEpoch;
        } catch (_) {}
        await DatabaseHelper.instance.addTrackToPlaylist(playlistId, trackId, positionCounter, addedAt: addedAt);
        newIds.add(trackId);
        positionCounter++;
      } catch (e) {
        debugPrint('Fehler bei ${file.path}: $e');
      }
    }

    // "Wie im Ordner": neue Songs an die passende Stelle nach Dateiname schieben
    if (insertMode == 2) await placeByName(playlistId, newIds);

    libraryChanged.value++;
    CoverService.instance.run(); // Cover im Hintergrund nachladen
    return newCount;
  }

  /// Neue Songs an die Stelle schieben, an die sie nach Dateiname gehören.
  /// Die Reihenfolge aller anderen Songs bleibt unverändert.
  static Future<void> placeByName(int playlistId, List<int> trackIds) async {
    if (trackIds.isEmpty) return;
    final rows = await DatabaseHelper.instance.getTracksForPlaylist(playlistId); // gespeicherte Reihenfolge
    final ids = trackIds.toSet();
    String name(Map<String, dynamic> r) => p.basename((r['file_path'] as String?) ?? '');
    final result = rows.where((r) => !ids.contains(r['id'])).toList();
    final news = rows.where((r) => ids.contains(r['id'])).toList()
      ..sort((a, b) => naturalCompare(name(a), name(b)));
    for (final n in news) {
      int idx = result.indexWhere((r) => naturalCompare(name(r), name(n)) > 0);
      if (idx < 0) idx = result.length;
      result.insert(idx, n);
    }
    await DatabaseHelper.instance.updatePlaylistOrder(playlistId, result);
    libraryChanged.value++;
  }

  /// Song-Eintrag für eine Datei anlegen (oder vorhandenen finden). Gibt die Track-ID zurück.
  static Future<int?> trackIdForFile(File file) async {
    final db = await DatabaseHelper.instance.database;
    final dynamic meta = readMetadata(file, getImage: false);
    final fallbackTitle = cleanFileTitle(p.basenameWithoutExtension(file.path));
    final String? title = (meta?.title as String?)?.trim();
    final String? artist = (meta?.artist as String?)?.trim();
    final String? album = (meta?.album as String?)?.trim();
    final Duration? duration = meta?.duration as Duration?;
    final track = Track(
      filePath: file.path,
      title: (title != null && title.isNotEmpty) ? title : fallbackTitle,
      artist: (artist != null && artist.isNotEmpty) ? artist : 'Unbekannt',
      album: (album != null && album.isNotEmpty) ? album : 'Unbekannt',
      durationMs: duration?.inMilliseconds ?? 0,
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );
    int trackId = await db.insert('tracks', track.toMap(), conflictAlgorithm: ConflictAlgorithm.ignore);
    if (trackId == 0) {
      final rows = await db.query('tracks', columns: ['id'], where: 'file_path = ?', whereArgs: [file.path]);
      if (rows.isEmpty) return null;
      trackId = rows.first['id'] as int;
    }
    return trackId;
  }

  /// MP3s zu einer Playlist hinzufügen – in genau der übergebenen Reihenfolge, ganz oben.
  /// Ordner-Playlist: Dateien werden in den Playlist-Ordner kopiert, mit absteigendem Datei-Datum
  /// (erste Datei = neueste), damit auch der Ordner nach Datum richtig sortiert ist.
  /// Gibt (hinzugefügt, Fehlermeldung oder null) zurück.
  static Future<(int, String?)> importFiles(int playlistId, String folderPath, List<String> paths) async {
    if (paths.isEmpty) return (0, null);
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now();
    final targets = <File>[];
    String? error;

    for (int i = 0; i < paths.length; i++) {
      final src = File(paths[i]);
      File target = src;
      if (folderPath.isNotEmpty && p.dirname(src.path) != folderPath) {
        // In den Playlist-Ordner kopieren (Original bleibt, wo es ist)
        final base = p.basenameWithoutExtension(src.path);
        final ext = p.extension(src.path);
        var dest = File(p.join(folderPath, '$base$ext'));
        int n = 2;
        while (dest.existsSync()) {
          dest = File(p.join(folderPath, '$base ($n)$ext'));
          n++;
        }
        try {
          target = await src.copy(dest.path);
        } catch (e) {
          error = 'Konnte nicht in den Ordner kopieren: ${p.basename(src.path)}';
          debugPrint('Kopieren fehlgeschlagen: $e');
          continue;
        }
      }
      // Datum staffeln: erste Datei = neueste (je 1 Sekunde Abstand)
      try {
        target.setLastModifiedSync(now.subtract(Duration(seconds: i)));
      } catch (_) {}
      targets.add(target);
    }

    // Track-IDs holen, schon enthaltene Songs überspringen
    final existing = (await db.query('playlist_tracks',
            columns: ['track_id'], where: 'playlist_id = ?', whereArgs: [playlistId]))
        .map((r) => r['track_id'] as int)
        .toSet();
    final ids = <int>[];
    for (final f in targets) {
      try {
        final id = await trackIdForFile(f);
        if (id != null && !existing.contains(id) && !ids.contains(id)) ids.add(id);
      } catch (e) {
        debugPrint('Fehler bei ${f.path}: $e');
      }
    }
    if (ids.isEmpty) return (0, error);

    // Platz oben schaffen und in genau dieser Reihenfolge einfügen
    await db.rawUpdate(
        'UPDATE playlist_tracks SET position = position + ? WHERE playlist_id = ?', [ids.length, playlistId]);
    for (int i = 0; i < ids.length; i++) {
      await DatabaseHelper.instance.addTrackToPlaylist(playlistId, ids[i], i,
          addedAt: now.subtract(Duration(seconds: i)).millisecondsSinceEpoch);
    }

    libraryChanged.value++;
    CoverService.instance.run();
    return (ids.length, error);
  }
}
