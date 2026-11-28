import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import '../database/database_helper.dart';
import '../models/track.dart';
import 'audiobook_service.dart';
import 'playlist_sort.dart';
import 'settings_service.dart';

/// Was gerade den Player benutzt: Musik oder Hörbuch.
enum PlayMode { music, book }

/// Musik-Wiedergabe mit eigener Warteschlange.
/// Es wird immer nur EINE Datei in den Player geladen -> startet sofort.
/// Hörbücher teilen sich denselben Player; beim Wechsel merkt sich jede Seite ihre Stelle.
class AudioPlayerService {
  static final AudioPlayerService instance = AudioPlayerService._();

  AudioPlayerService._() {
    // Tempo-Funktion ausgeschaltet -> sofort zurück auf 1,0x
    AppSettings.instance.musicSpeedFeature.addListener(_applyMusicSpeed);
    player.processingStateStream.listen((state) {
      if (state != ProcessingState.completed) return;
      if (mode.value == PlayMode.music) {
        _onCompleted();
      } else {
        AudiobookService.instance.onCompleted();
      }
    });
    player.playingStream.listen((playing) {
      if (!playing && mode.value == PlayMode.music) _saveSession();
    });
    Timer.periodic(const Duration(seconds: 10), (_) {
      if (player.playing && mode.value == PlayMode.music) _saveSession();
    });
  }

  final AudioPlayer player = AudioPlayer();

  /// Musik oder Hörbuch
  final ValueNotifier<PlayMode> mode = ValueNotifier(PlayMode.music);
  bool _musicLoaded = false; // ist ein Musik-Song im Player geladen?
  Duration _musicResume = Duration.zero; // Stelle, an der die Musik pausiert wurde

  List<Track> _original = []; // Reihenfolge der Playlist
  List<Track> currentQueue = []; // tatsächliche Abspielreihenfolge
  int currentIndex = -1;

  int? currentPlaylistId;
  String currentPlaylistName = '';
  String? currentCoverPath;

  final ValueNotifier<int> changes = ValueNotifier(0);
  final ValueNotifier<bool> shuffle = ValueNotifier(false);
  final ValueNotifier<LoopMode> loopMode = ValueNotifier(LoopMode.off);

  // Schlaf-Timer (Musik, einfach)
  final ValueNotifier<DateTime?> sleepUntil = ValueNotifier(null);
  final ValueNotifier<bool> sleepAtTrackEnd = ValueNotifier(false);
  Timer? _sleepTimer;

  int _loadToken = 0;

  /// App-eigene Lautstärke (0..1). Wird im Ski-Modus über die Kopfhörer-Tasten geändert.
  double userVolume = 1.0;

  void _notify() => changes.value++;

  Track? get currentTrack =>
      (currentIndex >= 0 && currentIndex < currentQueue.length) ? currentQueue[currentIndex] : null;

  bool isPlayingPlaylist(int playlistId) => currentPlaylistId == playlistId && currentTrack != null;

  bool get isMusicMode => mode.value == PlayMode.music;

  /// Ist die Musik gerade im Player geladen (und nicht das Hörbuch)?
  bool get musicActive => mode.value == PlayMode.music && _musicLoaded;

  /// Gemerkte Musik-Position (live, wenn Musik aktiv ist).
  Duration get musicPosition => musicActive ? player.position : _musicResume;

  /// Spulen in der Musik – auch wenn gerade das Hörbuch läuft (dann nur merken).
  Future<void> seekMusic(Duration d) async {
    if (musicActive) {
      await player.seek(d);
    } else {
      _musicResume = d;
      _notify();
    }
  }

  // ---------- Umschalten Musik <-> Hörbuch ----------

  /// Vom Hörbuch aufgerufen, bevor es den Player übernimmt.
  void suspendMusic() {
    if (mode.value == PlayMode.music && _musicLoaded) {
      _musicResume = player.position;
      _saveSession();
    }
    _musicLoaded = false;
    mode.value = PlayMode.book;
    _notify();
  }

  Future<void> _activateMusic() async {
    if (mode.value != PlayMode.music) {
      await AudiobookService.instance.suspend();
      mode.value = PlayMode.music;
      DatabaseHelper.instance.setSetting('last_mode', 'music');
    }
  }

  // ---------- Starten ----------

  Future<void> playPlaylist(
    List<Track> tracks,
    int startIndex, {
    int? playlistId,
    String playlistName = '',
    String? coverPath,
    bool autoplay = true,
    Duration? position,
    bool load = true,
  }) async {
    if (tracks.isEmpty) return;
    final start = startIndex.clamp(0, tracks.length - 1);
    _original = List.of(tracks);
    currentPlaylistId = playlistId;
    currentPlaylistName = playlistName;
    currentCoverPath = coverPath;
    if (shuffle.value) {
      currentQueue = _shuffledWith(tracks[start]);
      currentIndex = 0;
    } else {
      currentQueue = List.of(tracks);
      currentIndex = start;
    }
    if (!load) {
      // Nur merken (z.B. beim Start, wenn zuletzt ein Hörbuch lief)
      _musicResume = position ?? Duration.zero;
      _musicLoaded = false;
      _notify();
      return;
    }
    await _playAt(currentIndex, autoplay: autoplay, position: position);
  }

  Future<void> playShuffled(
    List<Track> tracks, {
    int? playlistId,
    String playlistName = '',
    String? coverPath,
  }) async {
    if (tracks.isEmpty) return;
    shuffle.value = true;
    await playPlaylist(
      tracks,
      Random().nextInt(tracks.length),
      playlistId: playlistId,
      playlistName: playlistName,
      coverPath: coverPath,
    );
  }

  List<Track> _shuffledWith(Track first) {
    final rnd = Random();
    final st = AppSettings.instance;
    final w = st.favoriteWeight.value.clamp(1, 3);
    final rest = List.of(_original)..remove(first);
    if (w <= 1 || st.favorites.isEmpty) {
      rest.shuffle(rnd);
      return [first, ...rest];
    }
    // Jeder Song bekommt einen Zufallswert 0..1 als Platz in der Warteschlange.
    // Lieblingssongs kommen w-mal vor: je ein Platz pro Abschnitt (1/w der Liste),
    // mit Rand, damit die Kopien nie direkt hintereinander kommen.
    double slot(int j) => (j + 0.15 + 0.7 * rnd.nextDouble()) / w;
    final keyed = <(double, Track)>[];
    for (final t in rest) {
      if (st.isFavorite(t.id)) {
        for (var j = 0; j < w; j++) {
          keyed.add((slot(j), t));
        }
      } else {
        keyed.add((rnd.nextDouble(), t));
      }
    }
    // Startsong ist Lieblingssong: er läuft jetzt (= Kopie 1), weitere Kopien später
    if (st.isFavorite(first.id)) {
      for (var j = 1; j < w; j++) {
        keyed.add((slot(j), first));
      }
    }
    keyed.sort((a, b) => a.$1.compareTo(b.$1));
    return [first, for (final k in keyed) k.$2];
  }

  /// Aktuelles Musik-Tempo (1,0 wenn die Funktion ausgeschaltet ist)
  double get musicSpeed {
    final st = AppSettings.instance;
    return st.musicSpeedFeature.value ? st.musicSpeedPct.value / 100.0 : 1.0;
  }

  /// Tempo setzen. save=false: nur anhören (beim Ziehen am Regler).
  Future<void> setMusicSpeed(int pct, {bool save = true}) async {
    pct = pct.clamp(50, 300);
    if (save) AppSettings.instance.setInt(AppSettings.instance.musicSpeedPct, pct);
    if (mode.value == PlayMode.music && _musicLoaded) await player.setSpeed(pct / 100.0);
  }

  /// Datei, für die das aktuelle Tempo gilt. Neuer Song -> Tempo zurück auf 1,0x.
  String? _speedTrackPath;

  void _applyMusicSpeed() {
    if (mode.value == PlayMode.music && _musicLoaded) player.setSpeed(musicSpeed);
  }

  Future<void> _playAt(int i, {bool autoplay = true, Duration? position}) async {
    if (i < 0 || i >= currentQueue.length) return;
    await _activateMusic();
    currentIndex = i;
    _notify();
    final token = ++_loadToken;
    try {
      await player.setAudioSource(AudioSource.file(currentQueue[i].filePath), initialPosition: position);
      if (token != _loadToken) return; // inzwischen anderer Song gewählt
      _musicLoaded = true;
      _notify(); // UI (Play-Button) weiß jetzt, dass die Musik aktiv ist
      // Anderer Song (Ende erreicht oder neu angetippt) -> Tempo zurück auf 1,0x.
      // Gleicher Song (z.B. Musik nach Hörbuch fortsetzen) behält sein Tempo.
      final path = currentQueue[i].filePath;
      if (path != _speedTrackPath) {
        _speedTrackPath = path;
        final st = AppSettings.instance;
        if (st.musicSpeedPct.value != 100) st.setInt(st.musicSpeedPct, 100);
      }
      await player.setSpeed(musicSpeed);
      await player.setVolume(userVolume);
      await player.setLoopMode(loopMode.value == LoopMode.one ? LoopMode.one : LoopMode.off);
      if (autoplay) player.play();
    } catch (e) {
      debugPrint('Fehler beim Laden: $e');
    }
  }

  // ---------- Steuerung ----------

  /// Play/Pause für Musik. Läuft gerade ein Hörbuch, wird die Musik an der gemerkten Stelle fortgesetzt.
  Future<void> togglePlay() async {
    if (currentTrack == null) return;
    if (mode.value != PlayMode.music || !_musicLoaded) {
      await _playAt(currentIndex, position: _musicResume);
      return;
    }
    if (player.playing) {
      player.pause();
    } else {
      player.play();
    }
  }

  /// Nächster Song – spielt auch los, wenn vorher pausiert war.
  Future<void> next() async {
    if (currentQueue.isEmpty) return;
    if (currentIndex < currentQueue.length - 1) {
      await _playAt(currentIndex + 1);
    } else {
      // Am Ende: Playlist als Kreis -> zurück zum ersten Song und weiterspielen
      final wrap = AppSettings.instance.playlistWrap.value;
      await _playAt(0, autoplay: wrap || loopMode.value == LoopMode.all);
    }
  }

  /// Zurück: nach X Sekunden Neustart, sonst vorheriger Song. Spielt immer los.
  Future<void> previous() async {
    if (currentQueue.isEmpty) return;
    final active = mode.value == PlayMode.music && _musicLoaded;
    final pos = active ? player.position : _musicResume;
    final threshold = AppSettings.instance.restartThreshold.value;
    final wrap = AppSettings.instance.playlistWrap.value && currentQueue.length > 1;
    if (currentIndex <= 0 && wrap && pos.inSeconds < threshold) {
      // Beim ersten Song zurück: ans Ende der Playlist springen
      await _playAt(currentQueue.length - 1);
      return;
    }
    if (pos.inSeconds >= threshold || currentIndex <= 0) {
      if (active) {
        await player.seek(Duration.zero);
        player.play();
      } else {
        await _playAt(currentIndex, position: Duration.zero);
      }
    } else {
      await _playAt(currentIndex - 1);
    }
  }

  Future<void> playIndex(int i) => _playAt(i);

  /// Immer zum vorherigen Song (ohne Neustart-Regel) – für Kopfhörer-Tasten.
  Future<void> previousTrack() async {
    if (currentQueue.isEmpty) return;
    if (currentIndex > 0) {
      await _playAt(currentIndex - 1);
    } else {
      final wrap = AppSettings.instance.playlistWrap.value && currentQueue.length > 1;
      await _playAt(wrap ? currentQueue.length - 1 : 0);
    }
  }

  void _onCompleted() {
    final stop = sleepAtTrackEnd.value;
    if (stop) sleepAtTrackEnd.value = false;
    if (currentIndex < currentQueue.length - 1) {
      _playAt(currentIndex + 1, autoplay: !stop);
    } else {
      final wrap = AppSettings.instance.playlistWrap.value;
      _playAt(0, autoplay: !stop && (wrap || loopMode.value == LoopMode.all));
    }
  }

  void toggleShuffle() {
    final cur = currentTrack;
    shuffle.value = !shuffle.value;
    if (cur == null || _original.isEmpty) return;
    if (shuffle.value) {
      currentQueue = _shuffledWith(cur);
      currentIndex = 0;
    } else {
      currentQueue = List.of(_original);
      final i = currentQueue.indexOf(cur);
      if (i >= 0) {
        currentIndex = i;
      } else {
        currentQueue.insert(0, cur);
        currentIndex = 0;
      }
    }
    _notify(); // Audio läuft unverändert weiter
  }

  void cycleLoopMode() {
    final LoopMode next;
    if (loopMode.value == LoopMode.off) {
      next = LoopMode.all;
    } else if (loopMode.value == LoopMode.all) {
      next = LoopMode.one;
    } else {
      next = LoopMode.off;
    }
    loopMode.value = next;
    if (isMusicMode) player.setLoopMode(next == LoopMode.one ? LoopMode.one : LoopMode.off);
  }

  // ---------- Warteschlange ----------

  /// Warteschlange nach dem aktuellen Song neu setzen (temporär, bis eine neue Playlist startet).
  void setUpcoming(List<Track> rest) {
    final cur = currentTrack;
    if (cur == null) return;
    currentQueue = [cur, ...rest];
    currentIndex = 0;
    _notify();
  }

  /// Nach dem aktuellen Song bei tracks[startIndex] weitermachen (temporär).
  /// Läuft gerade nichts, startet die Wiedergabe direkt dort.
  Future<void> continueWith(
    List<Track> tracks,
    int startIndex, {
    int? playlistId,
    String playlistName = '',
    String? coverPath,
  }) async {
    if (tracks.isEmpty) return;
    final cur = currentTrack;
    if (cur == null) {
      await playPlaylist(tracks, startIndex,
          playlistId: playlistId, playlistName: playlistName, coverPath: coverPath);
      return;
    }
    final start = startIndex.clamp(0, tracks.length - 1);
    final rest = <Track>[...tracks.sublist(start), ...tracks.sublist(0, start)]
      ..removeWhere((t) => identical(t, cur) || (t.id != null && t.id == cur.id));
    if (playlistId != null) {
      _original = List.of(tracks);
      currentPlaylistId = playlistId;
      currentPlaylistName = playlistName;
      currentCoverPath = coverPath;
    }
    currentQueue = [cur, ...rest];
    currentIndex = 0;
    _notify();
  }

  Future<void> playNext(Track track) async {
    if (currentTrack == null) {
      await playPlaylist([track], 0, playlistName: 'Warteschlange');
      return;
    }
    currentQueue.insert(currentIndex + 1, track);
    _notify();
  }

  /// Mehrere Songs direkt nach dem aktuellen Song einreihen (Reihenfolge bleibt).
  Future<void> playNextAll(List<Track> tracks) async {
    if (tracks.isEmpty) return;
    if (currentTrack == null) {
      await playPlaylist(tracks, 0, playlistName: 'Warteschlange');
      return;
    }
    currentQueue.insertAll(currentIndex + 1, tracks);
    _notify();
  }

  /// Mehrere Songs ans Ende der Warteschlange.
  Future<void> addToQueueEnd(List<Track> tracks) async {
    if (tracks.isEmpty) return;
    if (currentTrack == null) {
      await playPlaylist(tracks, 0, playlistName: 'Warteschlange');
      return;
    }
    currentQueue.addAll(tracks);
    _notify();
  }

  void removeFromQueue(int index) {
    if (index < 0 || index >= currentQueue.length || index == currentIndex) return;
    currentQueue.removeAt(index);
    if (index < currentIndex) currentIndex--;
    _notify();
  }

  // ---------- Schlaf-Timer (Musik) ----------

  void setSleepTimer(Duration? d) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    sleepAtTrackEnd.value = false;
    if (d == null) {
      sleepUntil.value = null;
      return;
    }
    sleepUntil.value = DateTime.now().add(d);
    _sleepTimer = Timer(d, () {
      if (isMusicMode) player.pause();
      sleepUntil.value = null;
    });
  }

  void setSleepAtTrackEnd() {
    setSleepTimer(null);
    sleepAtTrackEnd.value = true;
  }

  bool get sleepActive => sleepUntil.value != null || sleepAtTrackEnd.value;

  // ---------- Letzte Wiedergabe merken ----------

  void _saveSession() {
    final t = currentTrack;
    if (t == null || t.id == null || currentPlaylistId == null) return;
    final pos = (mode.value == PlayMode.music && _musicLoaded) ? player.position : _musicResume;
    final db = DatabaseHelper.instance;
    db.setSetting('last_playlist_id', '$currentPlaylistId');
    db.setSetting('last_track_id', '${t.id}');
    db.setSetting('last_position_ms', '${pos.inMilliseconds}');
  }

  Future<void> restoreSession() async {
    try {
      final db = DatabaseHelper.instance;
      final m = await db.getSettings();
      final resume = AppSettings.instance.resumeOnStart.value;
      final lastMode = m['last_mode'] ?? 'music';
      final bookActive = resume && lastMode == 'book';
      // Beide Seiten vorbereiten, damit ihr Fortschritt unten sichtbar ist.
      await _restoreMusic(m, load: resume && !bookActive);
      await AudiobookService.instance.restoreLast(load: bookActive);
    } catch (e) {
      debugPrint('Wiederherstellen fehlgeschlagen: $e');
    }
  }

  Future<void> _restoreMusic(Map<String, String> m, {required bool load}) async {
    final db = DatabaseHelper.instance;
    final pid = int.tryParse(m['last_playlist_id'] ?? '');
    final tid = int.tryParse(m['last_track_id'] ?? '');
    final pos = int.tryParse(m['last_position_ms'] ?? '') ?? 0;
    if (pid == null || tid == null) return;
    final pl = await db.getPlaylist(pid);
    if (pl == null) return;
    final rows = await loadSortedPlaylistTracks(pid);
    final tracks = rows.map(Track.fromMap).toList();
    final i = tracks.indexWhere((t) => t.id == tid);
    if (i < 0) return;
    await playPlaylist(
      tracks,
      i,
      playlistId: pid,
      playlistName: pl['name'] as String,
      coverPath: pl['cover_path'] as String?,
      autoplay: false,
      position: Duration(milliseconds: pos),
      load: load,
    );
  }
}
