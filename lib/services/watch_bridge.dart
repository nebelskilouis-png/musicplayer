import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../database/database_helper.dart';
import '../models/track.dart';
import 'audio_player_service.dart';
import 'cover_service.dart';
import 'playlist_sort.dart';
import 'settings_service.dart';

/// Fortschritt einer Übertragung auf die Uhr.
class WatchSync {
  final int playlistId;
  final String name;
  final int done;
  final int total;
  final String? message; // Fertig-/Fehlermeldung
  final bool running;
  const WatchSync(this.playlistId, this.name, this.done, this.total, {this.message, this.running = true});
}

/// Verbindung zur Uhr-App (TicWatch / Wear OS).
/// - Fernbedienung: Uhr schickt Befehle, Handy schickt den Stand zurück (nur solange die Uhr zuschaut)
/// - Offline: Playlists inkl. Songs auf die Uhr übertragen
class WatchBridge {
  WatchBridge._();
  static final WatchBridge instance = WatchBridge._();

  static const _stateP = '/mp/state';
  static const _playlistsP = '/mp/playlists';
  static const _sectionsP = '/mp/sections';
  static const _manifestP = '/mp/sync/manifest';
  static const _deleteP = '/mp/sync/delete';

  final _ch = const MethodChannel('musicplayer/wear');
  final sync = ValueNotifier<WatchSync?>(null);

  DateTime? _subscribedUntil;
  Timer? _debounce;
  Timer? _keepAlive;
  int? _coverTrackId = -1;
  final Map<int, String> _pendingPaths = {}; // trackId -> Datei (für die laufende Übertragung)
  Timer? _syncTimeout;
  bool _started = false;

  AudioPlayerService get _s => AudioPlayerService.instance;

  void start() {
    if (_started || !Platform.isAndroid) return;
    _started = true;
    _ch.setMethodCallHandler(_onCall);
    _s.changes.addListener(_schedule);
    _s.player.playingStream.listen((_) => _schedule());
    _s.player.positionDiscontinuityStream.listen((_) => _schedule());
    _s.player.durationStream.listen((_) => _schedule());
    AppSettings.instance.favoriteIds.addListener(_schedule);
  }

  bool get _subscribed => _subscribedUntil != null && DateTime.now().isBefore(_subscribedUntil!);

  Future<dynamic> _onCall(MethodCall call) async {
    try {
      switch (call.method) {
        case 'cmd':
          await _cmd(call.arguments as String);
        case 'need':
          await _onNeed(call.arguments as String);
        case 'syncProgress':
          final m = Map<String, dynamic>.from(call.arguments as Map);
          final cur = sync.value;
          if (cur != null) {
            sync.value = WatchSync(cur.playlistId, cur.name, m['done'] as int, m['total'] as int);
          }
        case 'syncDone':
          final m = Map<String, dynamic>.from(call.arguments as Map);
          final cur = sync.value;
          final done = m['done'] as int;
          final total = m['total'] as int;
          final ok = m['ok'] == true;
          _pendingPaths.clear();
          sync.value = WatchSync(cur?.playlistId ?? -1, cur?.name ?? '', done, total,
              running: false,
              message: ok
                  ? '„${cur?.name ?? ''}“ ist auf der Uhr ($total Songs übertragen)'
                  : (total > 0 && done == 0
                      ? 'Übertragung fehlgeschlagen – Uhr verbunden?'
                      : 'Übertragung unterbrochen: $done von $total Songs. Nochmal starten setzt fort.'));
      }
    } catch (e) {
      debugPrint('WatchBridge: $e');
    }
    return null;
  }

  Future<void> _send(String path, [Uint8List? data]) async {
    try {
      await _ch.invokeMethod('send', {'path': path, 'data': data ?? Uint8List(0)});
    } catch (e) {
      debugPrint('WatchBridge send: $e');
    }
  }

  Future<void> _sendJson(String path, Object json) =>
      _send(path, Uint8List.fromList(utf8.encode(jsonEncode(json))));

  // ---------- Fernbedienung ----------

  Future<void> _cmd(String c) async {
    final s = _s;
    switch (c) {
      case 'hello':
        _subscribedUntil = DateTime.now().add(const Duration(minutes: 3));
        _coverTrackId = -1; // Cover neu schicken
        _keepAlive ??= Timer.periodic(const Duration(seconds: 15), (_) {
          if (!_subscribed) {
            _keepAlive?.cancel();
            _keepAlive = null;
          } else if (s.player.playing) {
            _sendState(); // Position nachkorrigieren
          }
        });
        await _sendState();
        return;
      case 'bye':
        _subscribedUntil = null;
        return;
      case 'toggle':
        if (s.player.playing) {
          await s.player.pause();
        } else {
          await s.togglePlay();
        }
      case 'play':
        if (!s.player.playing) await s.togglePlay();
      case 'pause':
        await s.player.pause();
      case 'next':
        await s.next();
      case 'prev':
        await s.previous();
      case 'fav':
        final id = s.currentTrack?.id;
        if (id != null) AppSettings.instance.toggleFavorite(id);
      case 'playlists':
        await _sendPlaylists();
        return;
      default:
        if (c.startsWith('sections:')) {
          final id = int.tryParse(c.substring(9));
          if (id != null) await _sendSections(id);
          return;
        }
        if (c.startsWith('playat:')) {
          final parts = c.split(':');
          if (parts.length >= 3) await _playAt(int.parse(parts[1]), int.parse(parts[2]), shuffled: false);
        } else if (c.startsWith('shuffleplay:')) {
          await _playAt(int.parse(c.substring(12)), 0, shuffled: true);
        }
    }
    _schedule();
  }

  Future<void> _playAt(int playlistId, int index, {required bool shuffled}) async {
    final db = DatabaseHelper.instance;
    final pls = await db.getPlaylists();
    final pl = pls.where((p) => p['id'] == playlistId).firstOrNull;
    if (pl == null) return;
    final rows = await loadSortedPlaylistTracks(playlistId);
    final tracks = rows.map(Track.fromMap).toList();
    if (tracks.isEmpty) return;
    final name = pl['name'] as String? ?? '';
    final cover = pl['cover_path'] as String?;
    if (shuffled) {
      await _s.playShuffled(tracks, playlistId: playlistId, playlistName: name, coverPath: cover);
    } else {
      if (_s.shuffle.value) _s.toggleShuffle(); // Abschnitt = in Reihenfolge hören
      await _s.playPlaylist(tracks, index.clamp(0, tracks.length - 1),
          playlistId: playlistId, playlistName: name, coverPath: cover);
    }
  }

  void _schedule() {
    if (!_subscribed) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), _sendState);
  }

  Future<void> _sendState() async {
    if (!_subscribed) return;
    final s = _s;
    final t = s.currentTrack;
    final dur = s.musicActive ? (s.player.duration?.inMilliseconds ?? t?.durationMs ?? 0) : (t?.durationMs ?? 0);
    await _sendJson(_stateP, {
      'title': t?.title ?? '',
      'artist': t?.artist ?? '',
      'playing': s.player.playing && s.isMusicMode,
      'pos': s.musicPosition.inMilliseconds,
      'dur': dur,
      'speed': s.musicSpeed,
      'fav': AppSettings.instance.isFavorite(t?.id),
      'playlistId': s.currentPlaylistId,
      'playlistName': s.currentPlaylistName,
      'trackId': t?.id,
    });
    if (t?.id != _coverTrackId) {
      _coverTrackId = t?.id;
      final path = t == null ? null : CoverService.instance.pathFor(t);
      try {
        await _ch.invokeMethod('sendCover', {'path': path});
      } catch (_) {}
    }
  }

  Future<void> _sendPlaylists() async {
    final pls = await DatabaseHelper.instance.getPlaylists();
    await _sendJson(_playlistsP, [
      for (final p in pls) {'id': p['id'], 'name': p['name'], 'count': p['track_count'] ?? 0},
    ]);
  }

  Future<void> _sendSections(int playlistId) async {
    final rows = await loadSortedPlaylistTracks(playlistId);
    final secs = <Map<String, Object>>[];
    for (int i = 0; i < rows.length; i++) {
      final n = ((rows[i]['section_name'] as String?) ?? '').trim();
      if (n.isEmpty) continue;
      if (secs.isEmpty && i > 0) secs.add({'name': 'Anfang', 'index': 0, 'count': i});
      secs.add({'name': n, 'index': i, 'count': 0});
    }
    for (int k = 0; k < secs.length; k++) {
      final start = secs[k]['index'] as int;
      final end = k + 1 < secs.length ? secs[k + 1]['index'] as int : rows.length;
      secs[k]['count'] = end - start;
    }
    await _sendJson(_sectionsP, {'playlistId': playlistId, 'sections': secs});
  }

  // ---------- Offline auf die Uhr ----------

  Future<bool> watchConnected() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('watchConnected') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Playlist (Reihenfolge + Abschnitte) an die Uhr schicken. Die Uhr meldet, welche Songs fehlen,
  /// danach werden nur diese übertragen -> abgebrochene Übertragungen setzen einfach fort.
  Future<void> syncPlaylist(int playlistId, String name) async {
    final rows = await loadSortedPlaylistTracks(playlistId);
    _pendingPaths.clear();
    final tracks = <Map<String, Object?>>[];
    for (final r in rows) {
      final id = r['id'] as int;
      final path = r['file_path'] as String;
      final f = File(path);
      if (!f.existsSync()) continue;
      final dot = path.lastIndexOf('.');
      final ext = dot >= 0 ? path.substring(dot + 1).toLowerCase() : 'mp3';
      _pendingPaths[id] = path;
      final sec = ((r['section_name'] as String?) ?? '').trim();
      tracks.add({
        'id': id,
        'ext': ext,
        'size': f.lengthSync(),
        'title': r['title'],
        'artist': r['artist'],
        if (sec.isNotEmpty) 'section': sec,
      });
    }
    sync.value = WatchSync(playlistId, name, 0, tracks.length);
    await _sendJson(_manifestP, {'id': playlistId, 'name': name, 'tracks': tracks});
    _syncTimeout?.cancel();
    _syncTimeout = Timer(const Duration(seconds: 20), () {
      final cur = sync.value;
      if (cur != null && cur.running && cur.playlistId == playlistId && cur.done == 0 && _pendingPaths.isNotEmpty) {
        sync.value = WatchSync(playlistId, name, 0, cur.total,
            running: false, message: 'Keine Antwort von der Uhr – ist die Uhr-App installiert und die Uhr verbunden?');
      }
    });
  }

  Future<void> _onNeed(String json) async {
    _syncTimeout?.cancel();
    final m = jsonDecode(json) as Map<String, dynamic>;
    final ids = (m['ids'] as List).map((e) => (e as num).toInt()).toList();
    final cur = sync.value;
    final name = cur?.name ?? '';
    final pid = (m['playlistId'] as num).toInt();
    if (ids.isEmpty) {
      sync.value = WatchSync(pid, name, 0, 0, running: false, message: '„$name“ ist schon komplett auf der Uhr');
      return;
    }
    final files = [
      for (final id in ids)
        if (_pendingPaths[id] != null) {'id': id, 'path': _pendingPaths[id]},
    ];
    sync.value = WatchSync(pid, name, 0, files.length);
    await _ch.invokeMethod('sendFiles', {'files': files});
  }

  Future<void> cancelSync() async {
    try {
      await _ch.invokeMethod('cancelSync');
    } catch (_) {}
  }

  Future<void> removeFromWatch(int playlistId) => _send(_deleteP, Uint8List.fromList(utf8.encode('$playlistId')));
}
