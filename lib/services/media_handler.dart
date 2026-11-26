import 'dart:async';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'audio_player_service.dart';
import 'audiobook_service.dart';
import 'cover_service.dart';
import 'settings_service.dart';

/// Mögliche Belegungen der Kopfhörer-Tasten (Reihenfolge = gespeicherter Index!).
enum HeadsetAction { none, playPause, next, previous, skipForward, skipBack, restart }

const headsetActionLabels = <HeadsetAction, String>{
  HeadsetAction.none: 'Nichts',
  HeadsetAction.playPause: 'Play / Pause',
  HeadsetAction.next: 'Nächster Song / Kapitel',
  HeadsetAction.previous: 'Vorheriger Song / Kapitel',
  HeadsetAction.skipForward: 'Vorspulen',
  HeadsetAction.skipBack: 'Zurückspulen',
  HeadsetAction.restart: 'Song neu starten',
};

String headsetActionLabel(int i) =>
    headsetActionLabels[HeadsetAction.values[i.clamp(0, HeadsetAction.values.length - 1)]]!;

/// Verbindet die App mit Android/iOS:
/// - Steuerung im Sperrbildschirm und in der Benachrichtigung (wie Spotify)
/// - Kopfhörer-Tasten (Ski-Modus): Doppeltippen auf Lauter/Leiser/Play
class AppAudioHandler extends BaseAudioHandler with SeekHandler {
  static AppAudioHandler? instance;

  final AudioPlayerService s = AudioPlayerService.instance;
  final AudiobookService a = AudiobookService.instance;
  final AppSettings st = AppSettings.instance;

  AppAudioHandler() {
    instance = this;
    s.player.playbackEventStream.listen((_) => _updateState(), onError: (_) {});
    s.player.playingStream.listen((_) => _updateState());
    s.player.durationStream.listen((_) => _updateItem());
    s.changes.addListener(_updateItem);
    s.mode.addListener(_updateItem);
    a.changes.addListener(_updateItem);
    CoverService.instance.version.addListener(_updateItem);
    st.headsetFeature.addListener(_applyHeadsetMode);
    st.headsetModeOn.addListener(_applyHeadsetMode);
    _updateItem();
    _applyHeadsetMode();
  }

  bool get _isBook => s.mode.value == PlayMode.book && a.current != null;

  // ---------- Anzeige im Sperrbildschirm ----------

  Uri? _uri(String? p) => (p == null || p.isEmpty) ? null : Uri.file(p);

  void _updateItem() {
    MediaItem? item;
    if (_isBook) {
      final b = a.current!;
      final f = a.currentFile;
      item = MediaItem(
        id: f?.path ?? 'book_${b.id}',
        title: f?.name ?? b.title,
        artist: b.title,
        album: b.author.isEmpty ? 'Hörbuch' : b.author,
        duration: a.bookActive ? s.player.duration : (f == null ? null : Duration(milliseconds: f.durationMs)),
        artUri: _uri(b.coverPath),
      );
    } else {
      final t = s.currentTrack;
      if (t != null) {
        item = MediaItem(
          id: t.filePath,
          title: t.title,
          artist: t.artist,
          album: s.currentPlaylistName,
          duration: s.musicActive ? s.player.duration : Duration(milliseconds: t.durationMs),
          artUri: _uri(CoverService.instance.pathFor(t) ?? s.currentCoverPath),
        );
      }
    }
    mediaItem.add(item);
    _updateState();
  }

  void _updateState() {
    final p = s.player;
    final playing = p.playing;
    final book = _isBook;
    playbackState.add(playbackState.value.copyWith(
      controls: book
          ? [MediaControl.rewind, playing ? MediaControl.pause : MediaControl.play, MediaControl.fastForward]
          : [MediaControl.skipToPrevious, playing ? MediaControl.pause : MediaControl.play, MediaControl.skipToNext],
      systemActions: const {MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[p.processingState]!,
      playing: playing,
      updatePosition: p.position,
      bufferedPosition: p.bufferedPosition,
      speed: p.speed,
    ));
  }

  // ---------- Befehle vom Sperrbildschirm / Benachrichtigung ----------

  @override
  Future<void> play() async {
    if (s.player.playing) return;
    if (_isBook) {
      await a.togglePlay();
    } else {
      await s.togglePlay();
    }
  }

  @override
  Future<void> pause() => s.player.pause();

  @override
  Future<void> stop() => s.player.pause();

  @override
  Future<void> skipToNext() => _isBook ? a.skipForward() : s.next();

  @override
  Future<void> skipToPrevious() => _isBook ? a.skipBack() : s.previous();

  @override
  Future<void> fastForward() => _isBook ? a.skipForward() : _seekMusicBy(const Duration(seconds: 15));

  @override
  Future<void> rewind() => _isBook ? a.skipBack() : _seekMusicBy(const Duration(seconds: -15));

  @override
  Future<void> seek(Duration position) => _isBook ? a.seekInFile(position) : s.seekMusic(position);

  Future<void> _seekMusicBy(Duration d) {
    var t = s.musicPosition + d;
    if (t < Duration.zero) t = Duration.zero;
    return s.seekMusic(t);
  }

  // ---------- Kopfhörer-Steuerung (Ski-Modus) ----------

  bool get headsetOn => st.headsetFeature.value && st.headsetModeOn.value && !kIsWeb && Platform.isAndroid;

  Duration get _window => Duration(milliseconds: st.headsetWindowMs.value);

  static const int _maxVol = 20;
  int _vol = _maxVol;

  void _applyHeadsetMode() {
    try {
      if (headsetOn) {
        // Lautstärke-Tasten kommen jetzt bei der App an (auch bei gesperrtem Bildschirm)
        _setVol(_vol);
      } else {
        androidPlaybackInfo.add(LocalAndroidPlaybackInfo());
        s.userVolume = 1.0;
        s.player.setVolume(1.0);
      }
    } catch (e) {
      debugPrint('Kopfhörer-Modus: $e');
    }
  }

  void _setVol(int v) {
    _vol = v.clamp(0, _maxVol);
    final f = _vol / _maxVol;
    s.userVolume = f * f; // angenehmere Lautstärke-Kurve
    s.player.setVolume(s.userVolume);
    androidPlaybackInfo.add(RemoteAndroidPlaybackInfo(
      volumeControlType: AndroidVolumeControlType.relative,
      maxVolume: _maxVol,
      volume: _vol,
    ));
  }

  int _lastDir = 0;
  DateTime _lastVolAt = DateTime(2000);
  int _volBeforeFirst = _maxVol;

  @override
  Future<void> androidAdjustRemoteVolume(AndroidVolumeDirection direction) async {
    if (!headsetOn || direction == AndroidVolumeDirection.same) return;
    final dir = direction == AndroidVolumeDirection.raise ? 1 : -1;
    final now = DateTime.now();
    final action = dir > 0 ? st.headsetVolUp2.value : st.headsetVolDown2.value;
    final isDouble = dir == _lastDir && now.difference(_lastVolAt) < _window && action != 0;
    _lastVolAt = now;
    if (isDouble) {
      // Doppeltipp: Lautstärke vom ersten Tipp zurücknehmen, Aktion ausführen
      _setVol(_volBeforeFirst);
      _lastDir = 0;
      _runAction(action);
      return;
    }
    _lastDir = dir;
    _volBeforeFirst = _vol;
    _setVol(_vol + dir);
  }

  @override
  Future<void> androidSetRemoteVolume(int volumeIndex) async {
    if (headsetOn) _setVol(volumeIndex);
  }

  int _mediaClicks = 0;
  Timer? _mediaTimer;

  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    if (!headsetOn) return super.click(button);
    switch (button) {
      case MediaButton.media:
        _mediaClicks++;
        _mediaTimer?.cancel();
        _mediaTimer = Timer(_window, () {
          final n = _mediaClicks;
          _mediaClicks = 0;
          _runAction(n >= 3 ? st.headsetPlay3.value : (n == 2 ? st.headsetPlay2.value : st.headsetPlay1.value));
        });
        break;
      case MediaButton.next: // manche Geräte melden Doppelklick selbst als "next"
        _runAction(st.headsetPlay2.value);
        break;
      case MediaButton.previous:
        _runAction(st.headsetPlay3.value);
        break;
    }
  }

  void _runAction(int index) {
    final act = HeadsetAction.values[index.clamp(0, HeadsetAction.values.length - 1)];
    switch (act) {
      case HeadsetAction.none:
        break;
      case HeadsetAction.playPause:
        s.player.playing ? pause() : play();
        break;
      case HeadsetAction.next:
        _isBook ? a.nextChapter() : s.next();
        break;
      case HeadsetAction.previous:
        _isBook ? a.previousChapter() : s.previousTrack();
        break;
      case HeadsetAction.skipForward:
        fastForward();
        break;
      case HeadsetAction.skipBack:
        rewind();
        break;
      case HeadsetAction.restart:
        _isBook ? a.seekInFile(Duration.zero) : s.seekMusic(Duration.zero);
        break;
    }
  }
}

/// Startet die Sperrbildschirm-Steuerung (nur Android/iOS).
Future<void> initMediaHandler() async {
  if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
  try {
    await AudioService.init(
      builder: () => AppAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.example.musicplayer.audio',
        androidNotificationChannelName: 'Wiedergabe',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    );
  } catch (e) {
    debugPrint('Sperrbildschirm-Steuerung nicht verfügbar: $e');
  }
}
