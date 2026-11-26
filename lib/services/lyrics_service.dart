import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/track.dart';
import 'settings_service.dart';

class LyricLine {
  final Duration time;
  final String text;
  const LyricLine(this.time, this.text);
}

class Lyrics {
  /// Zeitgenaue Zeilen (leer, wenn nur Text vorhanden ist)
  final List<LyricLine> synced;
  /// Reiner Text (wenn keine Zeitangaben)
  final String plain;
  /// Woher: 'Datei', 'MP3', 'lrclib.net'
  final String source;

  const Lyrics({this.synced = const [], this.plain = '', required this.source});

  bool get isSynced => synced.isNotEmpty;
  bool get isEmpty => synced.isEmpty && plain.trim().isEmpty;
}

/// Sucht Lyrics: .lrc neben der MP3 -> in der MP3 gespeichert -> Cache -> lrclib.net (optional).
class LyricsService {
  static final LyricsService instance = LyricsService._();
  LyricsService._();

  final Map<String, Lyrics?> _memory = {};

  String _key(Track t) => t.id != null ? 't${t.id}' : 'p${t.filePath.hashCode}';

  Future<Directory> _cacheDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}lyrics');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// [forceOnline]: Cache/„nicht gefunden“ ignorieren und neu im Internet suchen.
  Future<Lyrics?> getLyrics(Track t, {bool forceOnline = false}) async {
    final key = _key(t);
    if (!forceOnline && _memory.containsKey(key)) return _memory[key];

    Lyrics? result;

    // 1) .lrc / .txt neben der MP3
    result = await _fromSideFile(t);

    // 2) In der MP3 gespeichert
    result ??= await _fromTag(t);

    // 3) Gespeichert von früherer Online-Suche
    final dir = await _cacheDir();
    final cacheLrc = File('${dir.path}${Platform.pathSeparator}$key.lrc');
    final cacheTxt = File('${dir.path}${Platform.pathSeparator}$key.txt');
    final cacheNone = File('${dir.path}${Platform.pathSeparator}$key.none');
    if (result == null && !forceOnline) {
      if (await cacheLrc.exists()) {
        result = _parse(await cacheLrc.readAsString(), 'lrclib.net');
      } else if (await cacheTxt.exists()) {
        result = Lyrics(plain: await cacheTxt.readAsString(), source: 'lrclib.net');
      } else if (await cacheNone.exists()) {
        _memory[key] = null;
        return null; // schon gesucht, nichts gefunden
      }
    }

    // 4) Online
    if (result == null && AppSettings.instance.onlineLyrics.value) {
      final online = await _fromLrclib(t);
      if (online != null) {
        result = online.$1;
        try {
          if (online.$2 != null) {
            await cacheLrc.writeAsString(online.$2!);
          } else {
            await cacheTxt.writeAsString(result.plain);
          }
          if (await cacheNone.exists()) await cacheNone.delete();
        } catch (_) {}
      } else if (online == null && _lastOnlineWasNotFound) {
        try {
          await cacheNone.writeAsString('');
        } catch (_) {}
      }
    }

    if (result != null && result.isEmpty) result = null;
    _memory[key] = result;
    return result;
  }

  Future<Lyrics?> _fromSideFile(Track t) async {
    final base = p.withoutExtension(t.filePath);
    for (final ext in ['.lrc', '.LRC', '.txt']) {
      final f = File('$base$ext');
      try {
        if (await f.exists()) {
          final text = await f.readAsString();
          return ext.toLowerCase() == '.lrc' ? _parse(text, 'Datei') : Lyrics(plain: text, source: 'Datei');
        }
      } catch (_) {}
    }
    return null;
  }

  Future<Lyrics?> _fromTag(Track t) async {
    try {
      final dynamic meta = readMetadata(File(t.filePath), getImage: false);
      final dynamic raw = meta?.lyrics;
      if (raw is String && raw.trim().isNotEmpty) return _parse(raw, 'MP3');
    } catch (_) {}
    return null;
  }

  bool _lastOnlineWasNotFound = false;

  /// Gibt (Lyrics, LRC-Text oder null) zurück.
  Future<(Lyrics, String?)?> _fromLrclib(Track t) async {
    _lastOnlineWasNotFound = false;
    final artist = t.artist == 'Unbekannt' ? '' : t.artist;
    final album = t.album == 'Unbekannt' ? '' : t.album;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      Map<String, dynamic>? record;
      if (artist.isNotEmpty) {
        record = await _getJson(client, '/api/get', {
          'track_name': t.title,
          'artist_name': artist,
          if (album.isNotEmpty) 'album_name': album,
          if (t.durationMs > 0) 'duration': '${(t.durationMs / 1000).round()}',
        }) as Map<String, dynamic>?;
      }
      if (record == null) {
        final list = await _getJson(client, '/api/search', {
          'track_name': t.title,
          if (artist.isNotEmpty) 'artist_name': artist,
        });
        if (list is List) {
          for (final r in list) {
            if (r is Map<String, dynamic> && (r['syncedLyrics'] != null || r['plainLyrics'] != null)) {
              record = r;
              break;
            }
          }
        }
      }
      if (record == null) {
        _lastOnlineWasNotFound = true;
        return null;
      }
      final synced = record['syncedLyrics'] as String?;
      final plain = record['plainLyrics'] as String?;
      if (synced != null && synced.trim().isNotEmpty) return (_parse(synced, 'lrclib.net'), synced);
      if (plain != null && plain.trim().isNotEmpty) return (Lyrics(plain: plain, source: 'lrclib.net'), null);
      _lastOnlineWasNotFound = true;
      return null;
    } catch (e) {
      debugPrint('Lyrics online: $e'); // z.B. kein Internet -> nicht als "nicht gefunden" merken
      return null;
    } finally {
      client.close();
    }
  }

  Future<Object?> _getJson(HttpClient client, String path, Map<String, String> params) async {
    final req = await client.getUrl(Uri.https('lrclib.net', path, params));
    req.headers.set(HttpHeaders.userAgentHeader, 'musicplayer/0.4 (privater Offline-Player)');
    final res = await req.close().timeout(const Duration(seconds: 12));
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) return null;
    return jsonDecode(body);
  }

  static final _timeTag = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');

  /// LRC-Text in Zeilen mit Zeit zerlegen. Ohne Zeitangaben -> reiner Text.
  Lyrics _parse(String text, String source) {
    final lines = <LyricLine>[];
    for (final raw in const LineSplitter().convert(text)) {
      final matches = _timeTag.allMatches(raw).toList();
      if (matches.isEmpty) continue;
      final content = raw.substring(matches.last.end).trim();
      for (final m in matches) {
        final min = int.parse(m.group(1)!);
        final sec = int.parse(m.group(2)!);
        final fracStr = m.group(3) ?? '0';
        final ms = int.parse(fracStr.padRight(3, '0').substring(0, 3));
        lines.add(LyricLine(Duration(minutes: min, seconds: sec, milliseconds: ms), content));
      }
    }
    if (lines.isEmpty) {
      // Kein LRC -> Metadaten-Zeilen wie [ar:...] entfernen und als Text zeigen
      final plain = const LineSplitter()
          .convert(text)
          .where((l) => !RegExp(r'^\[[a-z]+:.*\]$').hasMatch(l.trim()))
          .join('\n');
      return Lyrics(plain: plain, source: source);
    }
    lines.sort((a, b) => a.time.compareTo(b.time));
    return Lyrics(synced: lines, source: source);
  }
}
