import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../database/database_helper.dart';
import 'audio_player_service.dart';
import 'settings_service.dart';

// =====================================================================
// Modelle
// =====================================================================

class Book {
  final int id;
  String title;
  String author;
  final String folderPath;
  String sortMode; // 'folder' = Ordnerstruktur, 'filename' = Dateiname
  String? coverPath;
  String? currentFile;
  int positionMs;
  int progressMs;
  int totalMs;
  bool finished;
  int lastPlayedAt;

  Book.fromMap(Map<String, dynamic> m)
      : id = m['id'] as int,
        title = m['title'] as String,
        author = (m['author'] as String?) ?? '',
        folderPath = m['folder_path'] as String,
        sortMode = (m['sort_mode'] as String?) ?? 'folder',
        coverPath = m['cover_path'] as String?,
        currentFile = m['current_file'] as String?,
        positionMs = (m['position_ms'] as int?) ?? 0,
        progressMs = (m['progress_ms'] as int?) ?? 0,
        totalMs = (m['total_ms'] as int?) ?? 0,
        finished = ((m['finished'] as int?) ?? 0) == 1,
        lastPlayedAt = (m['last_played_at'] as int?) ?? 0;

  bool get started => !finished && (progressMs > 0 || currentFile != null);
  int get remainingMs => max(0, totalMs - progressMs);
  double get progress => totalMs > 0 ? (progressMs / totalMs).clamp(0.0, 1.0).toDouble() : 0.0;
}

class BookFile {
  final String path;
  final String relPath;
  final int durationMs;
  const BookFile(this.path, this.relPath, this.durationMs);

  String get name => p.basenameWithoutExtension(path);
}

// =====================================================================
// Sortierung (natürlich: "Kapitel 2" vor "Kapitel 10")
// =====================================================================

final _chunkRe = RegExp(r'(\d+|\D+)');

int naturalCompare(String a, String b) {
  final ca = _chunkRe.allMatches(a.toLowerCase()).map((m) => m.group(0)!).toList();
  final cb = _chunkRe.allMatches(b.toLowerCase()).map((m) => m.group(0)!).toList();
  for (int i = 0; i < min(ca.length, cb.length); i++) {
    final x = ca[i];
    final y = cb[i];
    final nx = int.tryParse(x);
    final ny = int.tryParse(y);
    int c;
    if (nx != null && ny != null) {
      c = nx.compareTo(ny);
      if (c == 0) c = x.length.compareTo(y.length);
    } else {
      c = x.compareTo(y);
    }
    if (c != 0) return c;
  }
  return ca.length.compareTo(cb.length);
}

List<String> _segments(String rel) => rel.split(RegExp(r'[\\/]'));

int _folderCompare(String a, String b) {
  final sa = _segments(a);
  final sb = _segments(b);
  for (int i = 0; i < min(sa.length, sb.length); i++) {
    final c = naturalCompare(sa[i], sb[i]);
    if (c != 0) return c;
  }
  return sa.length.compareTo(sb.length);
}

List<BookFile> sortBookFiles(List<BookFile> files, String mode) {
  final list = List.of(files);
  if (mode == 'filename') {
    list.sort((a, b) {
      final c = naturalCompare(p.basename(a.relPath), p.basename(b.relPath));
      return c != 0 ? c : _folderCompare(a.relPath, b.relPath);
    });
  } else {
    list.sort((a, b) => _folderCompare(a.relPath, b.relPath));
  }
  return list;
}

// =====================================================================
// Ordner einlesen (läuft in eigenem Isolate)
// =====================================================================

const _audioExt = ['.mp3', '.m4a', '.m4b', '.aac', '.ogg', '.opus', '.flac', '.wav'];
const _imageExt = ['.jpg', '.jpeg', '.png'];

Map<String, Object?> _scanBookFolder(String folder, String coverBase) {
  final files = <List<Object>>[];
  final images = <String>[];
  String author = '';
  for (final e in Directory(folder).listSync(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    final ext = p.extension(e.path).toLowerCase();
    if (_audioExt.contains(ext)) {
      int dur = 0;
      try {
        final dynamic m = readMetadata(e, getImage: false);
        final dynamic d = m?.duration;
        if (d is Duration) dur = d.inMilliseconds;
        if (author.isEmpty) {
          final dynamic a = m?.artist;
          if (a is String) author = a.trim();
        }
      } catch (_) {}
      files.add([e.path, p.relative(e.path, from: folder), dur]);
    } else if (_imageExt.contains(ext)) {
      images.add(e.path);
    }
  }

  String? cover;
  if (images.isNotEmpty) {
    images.sort((a, b) {
      int score(String s) {
        final n = p.basename(s).toLowerCase();
        if (n.contains('cover')) return 0;
        if (n.contains('folder') || n.contains('front')) return 1;
        return 2;
      }

      final c = score(a).compareTo(score(b));
      return c != 0 ? c : a.length.compareTo(b.length);
    });
    cover = images.first;
  } else if (files.isNotEmpty) {
    files.sort((a, b) => _folderCompare(a[1] as String, b[1] as String));
    try {
      final dynamic meta = readMetadata(File(files.first[0] as String), getImage: true);
      final dynamic pics = meta?.pictures;
      if (pics is List && pics.isNotEmpty) {
        final dynamic pic = pics.first;
        final String mime = (pic.mimetype ?? '').toString();
        final f = File('$coverBase.${mime.contains('png') ? 'png' : 'jpg'}');
        f.writeAsBytesSync(pic.bytes as List<int>);
        cover = f.path;
      }
    } catch (_) {}
  }
  return {'files': files, 'author': author, 'cover': cover};
}

Future<Map<String, Object?>> _runScan(String folder, String coverBase) =>
    Isolate.run(() => _scanBookFolder(folder, coverBase));

// =====================================================================
// Service
// =====================================================================

class AudiobookService {
  static final AudiobookService instance = AudiobookService._();

  AudiobookService._() {
    player.playingStream.listen((playing) {
      if (!isActive) return;
      if (!playing) {
        _pausedAt = DateTime.now();
        saveProgress();
      }
    });
    AppSettings.instance.bookSleepMinutes.addListener(_resetSleep);
    _resetSleep();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  AudioPlayer get player => AudioPlayerService.instance.player;
  bool get isActive => AudioPlayerService.instance.mode.value == PlayMode.book;

  Book? current;
  List<BookFile> files = [];
  int fileIndex = 0;
  bool _loaded = false;
  int _token = 0;
  DateTime? _pausedAt;
  int _tickCount = 0;
  // ignore: unused_field
  Timer? _ticker;

  /// UI-Updates für den laufenden Titel/Kapitel.
  final ValueNotifier<int> changes = ValueNotifier(0);

  /// Bibliothek hat sich geändert (Buch hinzugefügt, Fortschritt, ...).
  final ValueNotifier<int> libraryChanged = ValueNotifier(0);

  void _notify() => changes.value++;

  BookFile? get currentFile => (fileIndex >= 0 && fileIndex < files.length) ? files[fileIndex] : null;

  int get _beforeMs {
    int s = 0;
    for (int i = 0; i < fileIndex && i < files.length; i++) {
      s += files[i].durationMs;
    }
    return s;
  }

  int get totalMs => files.fold(0, (s, f) => s + f.durationMs);

  int get listenedMs {
    final pos = (isActive && _loaded) ? player.position.inMilliseconds : (current?.positionMs ?? 0);
    return _beforeMs + pos;
  }

  double get speed => AppSettings.instance.bookSpeedPct.value / 100.0;

  // ---------- Bibliothek ----------

  Future<List<Book>> getBooks() async {
    final rows = await DatabaseHelper.instance.getBooks();
    return rows.map((r) {
      final b = Book.fromMap(r);
      // Laufendes Buch: aktuelle Daten aus dem Speicher verwenden
      final c = current;
      return (c != null && c.id == b.id) ? c : b;
    }).toList();
  }

  Future<String> _coverDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}book_covers');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  /// Ein Ordner = ein Hörbuch. Gibt 1 zurück wenn hinzugefügt, sonst 0.
  Future<int> addBookFolder(String folder) async {
    final coverBase =
        '${await _coverDir()}${Platform.pathSeparator}book_${DateTime.now().microsecondsSinceEpoch}';
    final res = await _runScan(folder, coverBase);
    final files = (res['files'] as List).cast<List<Object>>();
    if (files.isEmpty) return 0;
    final total = files.fold<int>(0, (s, f) => s + (f[2] as int));
    final id = await DatabaseHelper.instance.addBook(
      title: p.basename(folder),
      author: (res['author'] as String?) ?? '',
      folderPath: folder,
      coverPath: res['cover'] as String?,
      totalMs: total,
    );
    if (id <= 0) return 0; // existiert schon
    await DatabaseHelper.instance.replaceBookFiles(id, files);
    libraryChanged.value++;
    return 1;
  }

  /// Ordner mit mehreren Hörbüchern: jeder Unterordner = ein Buch.
  Future<int> addLibraryFolder(String root) async {
    final dir = Directory(root);
    if (!await dir.exists()) return 0;
    final subs = dir.listSync().whereType<Directory>().toList()
      ..sort((a, b) => naturalCompare(p.basename(a.path), p.basename(b.path)));
    int n = 0;
    for (final d in subs) {
      n += await addBookFolder(d.path);
    }
    if (subs.isEmpty) n += await addBookFolder(root);
    return n;
  }

  Future<List<BookFile>> loadFiles(Book b) async {
    final rows = await DatabaseHelper.instance.getBookFiles(b.id);
    final list = rows
        .map((r) => BookFile(r['file_path'] as String, r['rel_path'] as String, (r['duration_ms'] as int?) ?? 0))
        .toList();
    return sortBookFiles(list, b.sortMode);
  }

  Future<void> rescanBook(Book b) async {
    final coverBase =
        '${await _coverDir()}${Platform.pathSeparator}book_${DateTime.now().microsecondsSinceEpoch}';
    final res = await _runScan(b.folderPath, coverBase);
    final list = (res['files'] as List).cast<List<Object>>();
    final total = list.fold<int>(0, (s, f) => s + (f[2] as int));
    await DatabaseHelper.instance.replaceBookFiles(b.id, list);
    b.totalMs = total;
    b.coverPath ??= res['cover'] as String?;
    await DatabaseHelper.instance.updateBook(b.id, {'total_ms': total, 'cover_path': b.coverPath});
    if (current?.id == b.id) {
      final path = currentFile?.path;
      files = await loadFiles(b);
      final i = files.indexWhere((f) => f.path == path);
      fileIndex = i >= 0 ? i : 0;
      _notify();
    }
    libraryChanged.value++;
  }

  Future<void> setSortMode(Book b, String mode) async {
    b.sortMode = mode;
    await DatabaseHelper.instance.updateBook(b.id, {'sort_mode': mode});
    if (current?.id == b.id) {
      final path = currentFile?.path;
      files = sortBookFiles(files, mode);
      final i = files.indexWhere((f) => f.path == path);
      fileIndex = i >= 0 ? i : 0;
      await saveProgress();
      _notify();
    }
    libraryChanged.value++;
  }

  Future<void> renameBook(Book b, String title) async {
    b.title = title;
    await DatabaseHelper.instance.updateBook(b.id, {'title': title});
    _notify();
    libraryChanged.value++;
  }

  Future<void> setCover(Book b, String path) async {
    b.coverPath = path;
    await DatabaseHelper.instance.updateBook(b.id, {'cover_path': path});
    _notify();
    libraryChanged.value++;
  }

  Future<void> resetProgress(Book b) async {
    if (current?.id == b.id && isActive && _loaded) {
      await player.pause();
      fileIndex = 0;
      await player.seek(Duration.zero);
      if (files.isNotEmpty) await _loadFile(0, Duration.zero, autoplay: false);
    }
    b.currentFile = null;
    b.positionMs = 0;
    b.progressMs = 0;
    b.finished = false;
    await DatabaseHelper.instance.updateBook(
        b.id, {'current_file': null, 'position_ms': 0, 'progress_ms': 0, 'finished': 0});
    _notify();
    libraryChanged.value++;
  }

  /// Als beendet markieren: Hörfortschritt wird gelöscht, nächstes Mal startet es von vorne.
  Future<void> markFinished(Book b) async {
    // Zuerst das Flag setzen, damit beim Pausieren nichts mehr gespeichert wird
    b.finished = true;
    b.progressMs = 0;
    b.currentFile = null;
    b.positionMs = 0;
    await DatabaseHelper.instance.updateBook(
        b.id, {'finished': 1, 'progress_ms': 0, 'current_file': null, 'position_ms': 0});
    if (current?.id == b.id) {
      if (bookActive) {
        await player.pause();
        if (files.isNotEmpty) await _loadFile(0, Duration.zero, autoplay: false);
      } else {
        fileIndex = 0;
      }
    }
    _notify();
    libraryChanged.value++;
  }

  Future<void> removeBook(Book b) async {
    if (current?.id == b.id) {
      if (isActive) await player.stop();
      current = null;
      files = [];
      _loaded = false;
      AudioPlayerService.instance.mode.value = PlayMode.music;
      AudioPlayerService.instance.changes.value++;
    }
    await DatabaseHelper.instance.deleteBook(b.id);
    _notify();
    libraryChanged.value++;
  }

  // ---------- Wiedergabe ----------

  Future<void> openBook(Book book, {bool autoplay = true}) async {
    final b = (current != null && current!.id == book.id) ? current! : book;
    if (identical(b, current) && _loaded && isActive) {
      if (autoplay && !player.playing) await togglePlay();
      return;
    }
    final list = (identical(b, current) && files.isNotEmpty) ? files : await loadFiles(b);
    if (list.isEmpty) return;

    AudioPlayerService.instance.suspendMusic();
    current = b;
    files = list;
    int idx = b.currentFile == null ? 0 : list.indexWhere((f) => f.path == b.currentFile);
    int pos = b.positionMs;
    if (idx < 0) {
      idx = 0;
      pos = 0;
    }
    if (b.finished) {
      idx = 0;
      pos = 0;
      b.finished = false;
      b.progressMs = 0;
    }
    b.lastPlayedAt = DateTime.now().millisecondsSinceEpoch;
    DatabaseHelper.instance.updateBook(b.id, {'last_played_at': b.lastPlayedAt, 'finished': 0});
    DatabaseHelper.instance.setSetting('last_mode', 'book');
    DatabaseHelper.instance.setSetting('last_book_id', '${b.id}');
    await _loadFile(idx, Duration(milliseconds: pos), autoplay: autoplay);
    libraryChanged.value++;
  }

  Future<void> _loadFile(int i, Duration pos, {required bool autoplay}) async {
    if (i < 0 || i >= files.length) return;
    fileIndex = i;
    _notify();
    final token = ++_token;
    try {
      await player.setLoopMode(LoopMode.off);
      await player.setAudioSource(AudioSource.file(files[i].path), initialPosition: pos);
      if (token != _token) return;
      _loaded = true;
      _notify(); // UI (Play-Button) weiß jetzt, dass das Hörbuch aktiv ist
      await player.setSpeed(speed);
      await player.setVolume(AudioPlayerService.instance.userVolume);
      _faded = false;
      if (autoplay) player.play();
      await saveProgress();
    } catch (e) {
      debugPrint('Hörbuch-Datei konnte nicht geladen werden: $e');
    }
  }

  /// Lädt das aktuelle Buch wieder in den Player (z.B. nachdem Musik lief).
  Future<bool> _ensureLoaded() async {
    final b = current;
    if (b == null || files.isEmpty) return false;
    if (!isActive || !_loaded) {
      AudioPlayerService.instance.suspendMusic();
      await _loadFile(fileIndex, Duration(milliseconds: b.positionMs), autoplay: false);
    }
    return true;
  }

  /// Wird von der Musik aufgerufen, bevor sie den Player übernimmt.
  Future<void> suspend() async {
    if (isActive && _loaded) await saveProgress();
    _loaded = false;
    if (_faded) {
      await player.setVolume(AudioPlayerService.instance.userVolume);
      _faded = false;
    }
  }

  Future<void> togglePlay() async {
    if (!await _ensureLoaded()) return;
    if (player.playing) {
      await player.pause();
      return;
    }
    final rw = AppSettings.instance.bookRewindOnResume.value;
    final paused = _pausedAt;
    if (rw > 0 && paused != null && DateTime.now().difference(paused).inSeconds >= 5) {
      await skip(Duration(seconds: -rw));
    }
    _pausedAt = null;
    player.play();
  }

  Future<void> skip(Duration delta) async {
    if (!await _ensureLoaded()) return;
    final wasPlaying = player.playing;
    final dur = player.duration ?? Duration(milliseconds: files[fileIndex].durationMs);
    final target = player.position + delta;
    if (target < Duration.zero) {
      if (fileIndex > 0) {
        final prevDur = Duration(milliseconds: files[fileIndex - 1].durationMs);
        var t = prevDur + target;
        if (t < Duration.zero || prevDur == Duration.zero) t = Duration.zero;
        await _loadFile(fileIndex - 1, t, autoplay: wasPlaying);
      } else {
        await player.seek(Duration.zero);
      }
      return;
    }
    if (dur > Duration.zero && target >= dur) {
      if (fileIndex < files.length - 1) {
        await _loadFile(fileIndex + 1, target - dur, autoplay: wasPlaying);
      } else {
        await player.seek(dur - const Duration(seconds: 1));
      }
      return;
    }
    await player.seek(target);
  }

  Future<void> skipBack() => skip(Duration(seconds: -AppSettings.instance.bookSkipBack.value));
  Future<void> skipForward() => skip(Duration(seconds: AppSettings.instance.bookSkipForward.value));

  Future<void> jumpToFile(int i) async {
    if (!await _ensureLoaded()) return;
    await _loadFile(i, Duration.zero, autoplay: true);
  }

  Future<void> nextChapter() async {
    if (!await _ensureLoaded()) return;
    if (fileIndex < files.length - 1) await _loadFile(fileIndex + 1, Duration.zero, autoplay: player.playing);
  }

  Future<void> previousChapter() async {
    if (!await _ensureLoaded()) return;
    if (player.position.inSeconds > 3 || fileIndex == 0) {
      await player.seek(Duration.zero);
    } else {
      await _loadFile(fileIndex - 1, Duration.zero, autoplay: player.playing);
    }
  }

  Future<void> seekInFile(Duration d) async {
    if (!await _ensureLoaded()) return;
    await player.seek(d);
  }

  /// Tempo festlegen und speichern. Landet in der Liste der letzten 3 Tempi.
  Future<void> setSpeed(int pct) async {
    final st = AppSettings.instance;
    st.setInt(st.bookSpeedPct, pct);
    final recent = [pct, ...st.bookSpeedRecentList.where((v) => v != pct)].take(3).join(',');
    st.setString(st.bookSpeedRecent, recent);
    if (isActive && _loaded) await player.setSpeed(pct / 100.0);
    _notify();
  }

  /// Tempo nur hören (während man am Regler zieht), noch nicht speichern.
  Future<void> previewSpeed(int pct) async {
    if (isActive && _loaded) await player.setSpeed(pct / 100.0);
  }

  /// Vom Player aufgerufen, wenn eine Datei zu Ende ist.
  void onCompleted() {
    final stopAtChapterEnd = AppSettings.instance.bookSleepMinutes.value == -1;
    if (fileIndex < files.length - 1) {
      _loadFile(fileIndex + 1, Duration.zero, autoplay: !stopAtChapterEnd);
      if (stopAtChapterEnd) _sleepFiredAt = DateTime.now();
    } else {
      final b = current;
      if (b != null) markFinished(b);
    }
  }

  Future<void> saveProgress() async {
    final b = current;
    final f = currentFile;
    if (b == null || f == null || !_loaded || !isActive || b.finished) return;
    final pos = player.position.inMilliseconds;
    b.currentFile = f.path;
    b.positionMs = pos;
    b.progressMs = _beforeMs + pos;
    b.lastPlayedAt = DateTime.now().millisecondsSinceEpoch;
    await DatabaseHelper.instance.updateBook(b.id, {
      'current_file': f.path,
      'position_ms': pos,
      'progress_ms': b.progressMs,
      'last_played_at': b.lastPlayedAt,
    });
  }

  /// Letztes Hörbuch wiederherstellen. load=false: nur merken (für den Mini-Player),
  /// der Player bleibt bei der Musik.
  Future<void> restoreLast({bool load = true}) async {
    final m = await DatabaseHelper.instance.getSettings();
    final id = int.tryParse(m['last_book_id'] ?? '');
    if (id == null) return;
    final row = await DatabaseHelper.instance.getBook(id);
    if (row == null) return;
    final b = Book.fromMap(row);
    if (load) {
      await openBook(b, autoplay: false);
      return;
    }
    final list = await loadFiles(b);
    if (list.isEmpty || current != null) return;
    current = b;
    files = list;
    final idx = b.currentFile == null ? 0 : list.indexWhere((f) => f.path == b.currentFile);
    fileIndex = idx < 0 ? 0 : idx;
    _loaded = false;
    _notify();
  }

  /// Ist das Hörbuch gerade im Player geladen?
  bool get bookActive => isActive && _loaded;

  /// Position im aktuellen Kapitel (live, wenn aktiv – sonst gespeichert).
  Duration get filePosition =>
      bookActive ? player.position : Duration(milliseconds: current?.positionMs ?? 0);

  // ---------- Schlaf-Timer (nur Hörbücher) ----------

  /// Restzeit des Timers. null = kein Minuten-Timer aktiv.
  final ValueNotifier<Duration?> sleepRemaining = ValueNotifier(null);
  DateTime? _sleepFiredAt;
  bool _faded = false;
  StreamSubscription<UserAccelerometerEvent>? _shakeSub;
  DateTime _lastShake = DateTime(2000);
  final List<DateTime> _peaks = [];

  int get sleepSetting => AppSettings.instance.bookSleepMinutes.value;

  void setSleep(int minutes) => AppSettings.instance.setInt(AppSettings.instance.bookSleepMinutes, minutes);

  void _resetSleep() {
    final m = sleepSetting;
    sleepRemaining.value = m > 0 ? Duration(minutes: m) : null;
    if (_faded) {
      player.setVolume(AudioPlayerService.instance.userVolume);
      _faded = false;
    }
  }

  void _tick() {
    if (isActive && _loaded && player.playing) {
      _tickCount++;
      if (_tickCount % 5 == 0) saveProgress();
    }
    _tickSleep();
    _updateShakeListener();
  }

  void _tickSleep() {
    final m = sleepSetting;
    if (m <= 0) {
      if (sleepRemaining.value != null) sleepRemaining.value = null;
      return;
    }
    sleepRemaining.value ??= Duration(minutes: m);
    if (!isActive || !player.playing) return;
    final left = sleepRemaining.value! - const Duration(seconds: 1);
    if (left <= Duration.zero) {
      player.pause();
      player.setVolume(AudioPlayerService.instance.userVolume);
      _faded = false;
      _sleepFiredAt = DateTime.now();
      // Timer bleibt eingestellt -> beim nächsten Abspielen läuft er wieder voll
      sleepRemaining.value = Duration(minutes: m);
    } else {
      sleepRemaining.value = left;
      if (left.inSeconds <= 10) {
        player.setVolume(AudioPlayerService.instance.userVolume * left.inSeconds / 10); // sanft leiser werden
        _faded = true;
      } else if (_faded) {
        player.setVolume(AudioPlayerService.instance.userVolume);
        _faded = false;
      }
    }
  }

  /// Timer wieder auf volle Zeit setzen (Schütteln oder Button).
  void extendSleep() {
    final m = sleepSetting;
    if (m <= 0) return;
    sleepRemaining.value = Duration(minutes: m);
    if (_faded) {
      player.setVolume(AudioPlayerService.instance.userVolume);
      _faded = false;
    }
    HapticFeedback.heavyImpact();
    Future.delayed(const Duration(milliseconds: 180), HapticFeedback.heavyImpact);
    final fired = _sleepFiredAt;
    if (fired != null && DateTime.now().difference(fired).inMinutes < 3 && isActive && !player.playing) {
      player.play(); // kurz nach dem Einschlafen geschüttelt -> weiter
    }
    _sleepFiredAt = null;
  }

  bool get _shakeSupported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  void _updateShakeListener() {
    final fired = _sleepFiredAt;
    final want = _shakeSupported &&
        AppSettings.instance.shakeToExtend.value &&
        sleepSetting > 0 &&
        isActive &&
        (player.playing || (fired != null && DateTime.now().difference(fired).inMinutes < 3));
    if (want && _shakeSub == null) {
      try {
        _shakeSub = userAccelerometerEventStream(samplingPeriod: SensorInterval.gameInterval)
            .listen(_onAccel, onError: (_) {});
      } catch (e) {
        debugPrint('Sensor nicht verfügbar: $e');
      }
    } else if (!want && _shakeSub != null) {
      _shakeSub!.cancel();
      _shakeSub = null;
    }
  }

  void _onAccel(UserAccelerometerEvent e) {
    final g = sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    if (g < 14) return;
    final now = DateTime.now();
    _peaks.removeWhere((t) => now.difference(t).inMilliseconds > 800);
    _peaks.add(now);
    if (_peaks.length >= 3 && now.difference(_lastShake).inMilliseconds > 2000) {
      _lastShake = now;
      _peaks.clear();
      extendSleep();
    }
  }
}
