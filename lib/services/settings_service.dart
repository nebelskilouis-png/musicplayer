import 'package:flutter/foundation.dart';
import '../database/database_helper.dart';

/// App-Einstellungen, gespeichert in der SQLite-Tabelle "settings".
class AppSettings {
  static final AppSettings instance = AppSettings._();
  AppSettings._();

  // ---------- Musik ----------
  final resumeOnStart = ValueNotifier<bool>(true);
  final restartThreshold = ValueNotifier<int>(4); // Sekunden für "Zurück = Neustart"
  /// Playlist als Kreis: vom ersten Song zurück = letzter Song, vom letzten weiter = erster Song
  final playlistWrap = ValueNotifier<bool>(true);
  final showTrackNumbers = ValueNotifier<bool>(true);
  final showTrackCovers = ValueNotifier<bool>(true);
  final showDurations = ValueNotifier<bool>(true);
  final showSectionRail = ValueNotifier<bool>(true);
  final scanOnStart = ValueNotifier<bool>(false);
  /// Wo neue Songs in Playlists landen: 0 = oben (neueste zuerst), 1 = unten,
  /// 2 = wie im Ordner (an der passenden Stelle nach Dateiname).
  /// Danach bleibt die Reihenfolge so, wie du sie verschiebst.
  final newSongsPosition = ValueNotifier<int>(0);
  final onlineLyrics = ValueNotifier<bool>(true); // Lyrics bei lrclib.net suchen
  final carCoverBackground = ValueNotifier<bool>(true); // Auto-Modus: Song-Cover hinter Play-Button
  /// Lieblingssongs (Track-IDs, kommagetrennt). Gilt in allen Playlists.
  final favoriteIds = ValueNotifier<String>('');
  /// Wie oft ein Lieblingssong im Shuffle vorkommt (1 = normal, 2, 3)
  final favoriteWeight = ValueNotifier<int>(2);

  // ---------- Kopfhörer-Steuerung (Ski-Modus) ----------
  /// Funktion überhaupt anbieten (Schalter im Player sichtbar)?
  final headsetFeature = ValueNotifier<bool>(false);
  /// Modus gerade eingeschaltet (Schalter im Player)
  final headsetModeOn = ValueNotifier<bool>(false);
  // Belegung: Index in HeadsetAction (0 nichts, 1 Play/Pause, 2 nächster, 3 vorheriger,
  // 4 vorspulen, 5 zurückspulen, 6 Song neu starten)
  final headsetVolUp2 = ValueNotifier<int>(2);
  final headsetVolDown2 = ValueNotifier<int>(3);
  final headsetPlay1 = ValueNotifier<int>(1);
  final headsetPlay2 = ValueNotifier<int>(2);
  final headsetPlay3 = ValueNotifier<int>(3);
  final headsetWindowMs = ValueNotifier<int>(450); // max. Abstand zwischen zwei Tippern

  // ---------- Hörbücher ----------
  final bookSkipBack = ValueNotifier<int>(30); // Sekunden
  final bookSkipForward = ValueNotifier<int>(30); // Sekunden
  final bookSpeedPct = ValueNotifier<int>(100); // 100 = 1,0x
  final bookRewindOnResume = ValueNotifier<int>(0); // Sekunden zurück beim Fortsetzen
  /// Schlaf-Timer Hörbuch: 0 = kein Timer, -1 = Ende des Kapitels, >0 = Minuten.
  /// Bleibt aktiv, bis "Kein Schlaf-Timer" gewählt wird.
  final bookSleepMinutes = ValueNotifier<int>(0);
  final shakeToExtend = ValueNotifier<bool>(true);
  final sleepPresets = ValueNotifier<String>('5,10,15,20,30,45,60');
  /// Zuletzt gewählte Tempi (in %), neueste zuerst – für die Schnellwahl unter dem Regler
  final bookSpeedRecent = ValueNotifier<String>('100,125,150');

  late final Map<String, ValueNotifier<bool>> _bools = {
    'resume_on_start': resumeOnStart,
    'playlist_wrap': playlistWrap,
    'show_track_numbers': showTrackNumbers,
    'show_track_covers': showTrackCovers,
    'show_durations': showDurations,
    'show_section_rail': showSectionRail,
    'scan_on_start': scanOnStart,
    'shake_to_extend': shakeToExtend,
    'car_cover_background': carCoverBackground,
    'online_lyrics': onlineLyrics,
    'headset_feature': headsetFeature,
    'headset_mode_on': headsetModeOn,
  };

  late final Map<String, ValueNotifier<int>> _ints = {
    'restart_threshold': restartThreshold,
    'new_songs_position': newSongsPosition,
    'book_skip_back': bookSkipBack,
    'book_skip_forward': bookSkipForward,
    'book_speed_pct': bookSpeedPct,
    'book_rewind_on_resume': bookRewindOnResume,
    'book_sleep_minutes': bookSleepMinutes,
    'headset_vol_up2': headsetVolUp2,
    'headset_vol_down2': headsetVolDown2,
    'headset_play1': headsetPlay1,
    'headset_play2': headsetPlay2,
    'headset_play3': headsetPlay3,
    'headset_window_ms': headsetWindowMs,
    'favorite_weight': favoriteWeight,
  };

  late final Map<String, ValueNotifier<String>> _strings = {
    'sleep_presets': sleepPresets,
    'book_speed_recent': bookSpeedRecent,
    'favorite_ids': favoriteIds,
  };

  /// Feuert bei jeder Änderung irgendeiner Einstellung.
  late final Listenable listenable =
      Listenable.merge([..._bools.values, ..._ints.values, ..._strings.values]);

  /// Schlaf-Timer-Zeiten als sortierte Liste (Minuten).
  List<int> get sleepPresetList {
    final list = sleepPresets.value
        .split(RegExp(r'[,; ]+'))
        .map((s) => int.tryParse(s.trim()))
        .whereType<int>()
        .where((v) => v > 0 && v <= 600)
        .toSet()
        .toList()
      ..sort();
    return list;
  }

  List<int> get bookSpeedRecentList => bookSpeedRecent.value
      .split(',')
      .map((s) => int.tryParse(s.trim()))
      .whereType<int>()
      .where((v) => v >= 50 && v <= 300)
      .take(3)
      .toList();

  // ---------- Lieblingssongs ----------
  Set<int>? _favCache;
  String? _favCacheSrc;

  Set<int> get favorites {
    if (_favCache == null || _favCacheSrc != favoriteIds.value) {
      _favCacheSrc = favoriteIds.value;
      _favCache = favoriteIds.value.split(',').map((s) => int.tryParse(s.trim())).whereType<int>().toSet();
    }
    return _favCache!;
  }

  bool isFavorite(int? trackId) => trackId != null && favorites.contains(trackId);

  /// Umschalten. Gibt den neuen Zustand zurück.
  bool toggleFavorite(int trackId) {
    final s = Set<int>.of(favorites);
    final now = !s.remove(trackId);
    if (now) s.add(trackId);
    setString(favoriteIds, s.join(','));
    return now;
  }

  Future<void> load() async {
    final m = await DatabaseHelper.instance.getSettings();
    _bools.forEach((key, n) {
      final v = m[key];
      if (v != null) n.value = v == 'true';
    });
    _ints.forEach((key, n) {
      final v = int.tryParse(m[key] ?? '');
      if (v != null) n.value = v;
    });
    _strings.forEach((key, n) {
      final v = m[key];
      if (v != null) n.value = v;
    });
  }

  void setBool(ValueNotifier<bool> n, bool value) {
    n.value = value;
    final key = _bools.entries.firstWhere((e) => identical(e.value, n)).key;
    DatabaseHelper.instance.setSetting(key, '$value');
  }

  void setInt(ValueNotifier<int> n, int value) {
    n.value = value;
    final key = _ints.entries.firstWhere((e) => identical(e.value, n)).key;
    DatabaseHelper.instance.setSetting(key, '$value');
  }

  void setString(ValueNotifier<String> n, String value) {
    n.value = value;
    final key = _strings.entries.firstWhere((e) => identical(e.value, n)).key;
    DatabaseHelper.instance.setSetting(key, value);
  }
}

String formatSpeed(int pct) {
  final v = pct / 100;
  var s = v.toStringAsFixed(2);
  if (s.endsWith('0')) s = s.substring(0, s.length - 1);
  return '${s.replaceAll('.', ',')}x';
}
