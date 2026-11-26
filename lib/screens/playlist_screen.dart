import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../database/database_helper.dart';
import '../models/track.dart';
import '../services/audio_player_service.dart';
import '../services/cover_service.dart';
import '../services/music_scanner.dart';
import '../services/playlist_sort.dart';
import '../services/permissions.dart';
import 'package:permission_handler/permission_handler.dart' show openAppSettings;
import 'file_browser_screen.dart';
import 'pick_from_playlist_screen.dart';
import '../services/settings_service.dart';
import '../theme.dart';
import '../widgets/add_to_playlist.dart';
import '../widgets/common.dart';

class _Section {
  final String name;
  final int start; // Index des ersten Songs
  final int count;
  final bool synthetic; // "Anfang" vor dem ersten echten Abschnitt
  const _Section(this.name, this.start, this.count, {this.synthetic = false});
}

class PlaylistScreen extends StatefulWidget {
  final int playlistId;
  /// Aus der Suche: zu diesem Song springen und ihn kurz markieren
  final int? focusTrackId;
  final String playlistName;

  const PlaylistScreen({super.key, required this.playlistId, required this.playlistName, this.focusTrackId});

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  final AudioPlayerService _audio = AudioPlayerService.instance;
  final ItemScrollController _itemScroll = ItemScrollController();
  final ItemPositionsListener _itemPositions = ItemPositionsListener.create();

  List<Map<String, dynamic>> _tracksData = [];
  List<Track> _tracks = [];
  List<_Section> _sections = [];
  Map<int, _Section> _sectionStarts = {};
  String _name = '';
  String? _coverPath;
  String _folderPath = ''; // leer = eigene Playlist ohne Ordner

  // Angezeigt wird immer die gespeicherte Reihenfolge (die du selbst verschieben kannst)
  int get _sortMode => 0;
  int? _highlightId; // kurz markierter Song (aus der Suche)
  bool _focusDone = false;
  bool get _custom => true;
  int _totalMs = 0;

  bool _loading = true;
  bool _isScanning = false;
  bool _isReorderMode = false;

  int? _dragSection; // Abschnitt, während am Seitenbalken gezogen wird
  double _dragY = 0;

  static const double _railWidth = 30;

  @override
  void initState() {
    super.initState();
    _itemPositions.itemPositions.addListener(_onScrollSection);
    _name = widget.playlistName;
    _audio.changes.addListener(_onAudioChange);
    AppSettings.instance.listenable.addListener(_onAudioChange);
    CoverService.instance.version.addListener(_load);
    MusicScanner.libraryChanged.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    _itemPositions.itemPositions.removeListener(_onScrollSection);
    _audio.changes.removeListener(_onAudioChange);
    AppSettings.instance.listenable.removeListener(_onAudioChange);
    CoverService.instance.version.removeListener(_load);
    MusicScanner.libraryChanged.removeListener(_load);
    super.dispose();
  }

  void _onAudioChange() {
    if (mounted) setState(() {});
  }

  // ---------- Daten ----------

  Future<void> _load() async {
    final rows = await DatabaseHelper.instance.getTracksForPlaylist(widget.playlistId);
    final pl = await DatabaseHelper.instance.getPlaylist(widget.playlistId);
    if (!mounted) return;
    setState(() {
      _tracksData = sortPlaylistRows(rows, _sortMode);
      _coverPath = pl?['cover_path'] as String?;
      _folderPath = (pl?['folder_path'] as String?) ?? '';
      _name = (pl?['name'] as String?) ?? widget.playlistName;
      _rebuildDerived();
      _loading = false;
    });
    _focusFromSearch();
  }

  /// Aus der Suche gekommen: direkt zum Song springen und ihn kurz hervorheben.
  void _focusFromSearch() {
    final id = widget.focusTrackId;
    if (id == null || _focusDone) return;
    final i = _tracks.indexWhere((t) => t.id == id);
    if (i < 0) return;
    _focusDone = true;
    setState(() => _highlightId = id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_itemScroll.isAttached) return;
      _itemScroll.jumpTo(index: i + 1, alignment: 0.3);
    });
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _highlightId = null);
    });
  }

  void _rebuildDerived() {
    _tracks = _tracksData.map(Track.fromMap).toList();
    _totalMs = _tracks.fold(0, (sum, t) => sum + t.durationMs);

    // Abschnitte gibt es nur in der eigenen Reihenfolge
    if (!_custom) {
      _sections = [];
      _sectionStarts = {};
      return;
    }

    final starts = <int>[];
    final names = <String>[];
    for (int i = 0; i < _tracksData.length; i++) {
      final s = (_tracksData[i]['section_name'] as String?)?.trim();
      if (s != null && s.isNotEmpty) {
        starts.add(i);
        names.add(s);
      }
    }
    final result = <_Section>[];
    if (starts.isNotEmpty && starts.first > 0) {
      result.add(_Section('Anfang', 0, starts.first, synthetic: true));
    }
    for (int k = 0; k < starts.length; k++) {
      final end = k + 1 < starts.length ? starts[k + 1] : _tracksData.length;
      result.add(_Section(names[k], starts[k], end - starts[k]));
    }
    _sections = result;
    _sectionStarts = {for (final s in result) if (!s.synthetic) s.start: s};
  }

  bool get _isThisPlaylist => _audio.isPlayingPlaylist(widget.playlistId);

  bool get _showRail =>
      _sections.length > 1 && !_isReorderMode && AppSettings.instance.showSectionRail.value;

  void _playTrack(int i) {
    _audio.playPlaylist(_tracks, i, playlistId: widget.playlistId, playlistName: _name, coverPath: _coverPath);
  }

  void _onPlayButton() {
    if (_isThisPlaylist) {
      _audio.togglePlay();
      return;
    }
    if (_tracks.isEmpty) return;
    if (_audio.shuffle.value) {
      _audio.playShuffled(_tracks, playlistId: widget.playlistId, playlistName: _name, coverPath: _coverPath);
    } else {
      _playTrack(0);
    }
  }

  bool get _hasFolder => _folderPath.isNotEmpty;

  /// MP3s auswählen und oben in die Playlist (und in den Playlist-Ordner) einfügen.
  Future<void> _addMp3s() async {
    if (!await ensureFullStorageAccess()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Die App braucht „Zugriff auf alle Dateien“, um MP3s in den Ordner zu kopieren.'),
        action: SnackBarAction(label: 'Erlauben', onPressed: openAppSettings),
      ));
      return;
    }
    if (!mounted) return;
    final paths = await pickMp3Files(context);
    if (paths == null || paths.isEmpty || !mounted) return;
    setState(() => _isScanning = true);
    final (added, error) = await MusicScanner.importFiles(widget.playlistId, _folderPath, paths);
    await _load();
    if (!mounted) return;
    setState(() => _isScanning = false);
    if (added > 0 && _itemScroll.isAttached) _itemScroll.jumpTo(index: 0);
    final msg = added == 0
        ? (error ?? 'Die Songs sind schon in der Playlist')
        : '$added ${added == 1 ? 'Song' : 'Songs'} oben hinzugefügt${error != null ? ' • $error' : ''}';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Songs aus einer anderen Playlist übernehmen (nur Playlists ohne Ordner).
  Future<void> _addFromPlaylist() async {
    final picked = await pickSongsFromPlaylist(context, targetPlaylistId: widget.playlistId);
    if (picked == null || picked.trackIds.isEmpty || !mounted) return;
    final mode = AppSettings.instance.newSongsPosition.value;
    final atTop = mode != 1;
    final db = DatabaseHelper.instance;
    final firstBefore = _tracksData.isEmpty ? null : _tracksData.first;
    final added = await db.addTracksToPlaylistBulk(widget.playlistId, picked.trackIds,
        atTop: atTop, sections: picked.sections.isEmpty ? null : picked.sections);
    if (added.isNotEmpty && mode == 2) await MusicScanner.placeByName(widget.playlistId, added);
    // Oben eingefügte Abschnitte würden sonst die bisherigen Songs ohne Abschnitt "schlucken"
    if (added.isNotEmpty && atTop && mode == 0 && picked.sections.isNotEmpty && firstBefore != null) {
      final oldSec = ((firstBefore['section_name'] as String?) ?? '').trim();
      if (oldSec.isEmpty) await db.updateSectionName(widget.playlistId, firstBefore['id'] as int, 'Bisher');
    }
    MusicScanner.libraryChanged.value++;
    await _load();
    if (!mounted) return;
    if (added.isNotEmpty && atTop && _itemScroll.isAttached) _itemScroll.jumpTo(index: 0);
    final n = added.length;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(n == 0
          ? 'Die Songs sind schon in der Playlist'
          : '$n ${n == 1 ? 'Song' : 'Songs'} hinzugefügt'),
    ));
  }

  Future<void> _rescanFolder() async {
    if (!_hasFolder) return;
    setState(() => _isScanning = true);
    final pl = await DatabaseHelper.instance.getPlaylist(widget.playlistId);
    int added = 0;
    if (pl != null) {
      added = await MusicScanner().scanFolderForPlaylist(Directory(pl['folder_path'] as String), widget.playlistId);
      await _load();
    }
    if (!mounted) return;
    setState(() => _isScanning = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(added == 0 ? 'Keine neuen Songs gefunden' : '$added neue Songs hinzugefügt')),
    );
  }

  Future<void> _setSection(int index) async {
    final current = (_tracksData[index]['section_name'] as String?) ?? '';
    final input = await showTextInputDialog(
      context,
      title: 'Abschnitt hier beginnen',
      initial: current,
      hint: 'z.B. Schub 1',
      clearLabel: current.isEmpty ? null : 'Entfernen',
    );
    if (input == null) return;
    final value = input.trim().isEmpty ? null : input.trim();
    if (value == null && current.isNotEmpty) {
      if (!mounted) return;
      final ok = await showConfirmDialog(
        context,
        title: 'Abschnitt entfernen?',
        message: 'Der Abschnitt „$current“ wird entfernt. Die Songs bleiben in der Playlist.',
      );
      if (!ok) return;
    }
    await DatabaseHelper.instance.updateSectionName(widget.playlistId, _tracks[index].id!, value);
    _load();
  }

  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      if (oldIndex < newIndex) newIndex -= 1;
      final item = _tracksData.removeAt(oldIndex);
      _tracksData.insert(newIndex, item);
      _rebuildDerived();
    });
    DatabaseHelper.instance.updatePlaylistOrder(widget.playlistId, _tracksData);
  }

  // ---------- Springen ----------

  double get _topBarHeight => MediaQuery.of(context).padding.top + 56;

  void _jumpToTop() {
    _itemScroll.scrollTo(index: 0, duration: const Duration(milliseconds: 400), curve: Curves.easeInOutCubic);
  }

  void _jumpToCurrent() {
    final id = _audio.currentTrack?.id;
    final i = _tracks.indexWhere((t) => t.id == id);
    if (i < 0) return;
    _itemScroll.scrollTo(
      index: i + 1,
      alignment: 0.35,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOutCubic,
    );
  }

  int? _lastScrollSection;

  /// Beim normalen Scrollen: kurzes Vibrieren, wenn ein neuer Abschnitt beginnt.
  void _onScrollSection() {
    if (_sections.length < 2 || _dragSection != null) return;
    final k = _visibleSection(_itemPositions.itemPositions.value);
    if (_lastScrollSection != null && k != _lastScrollSection) HapticFeedback.lightImpact();
    _lastScrollSection = k;
  }

  int _visibleSection(Iterable<ItemPosition> positions) {
    if (positions.isEmpty || _sections.isEmpty) return 0;
    int first = 1 << 30;
    for (final p in positions) {
      if (p.itemTrailingEdge > 0.15 && p.index < first) first = p.index;
    }
    final trackIdx = first - 1;
    int k = 0;
    for (int j = 0; j < _sections.length; j++) {
      if (_sections[j].start <= trackIdx) k = j;
    }
    return k;
  }

  void _railTo(double dy, double railHeight, double railTop) {
    final n = _sections.length;
    if (n < 2) return;
    const thumb = 40.0;
    final frac = ((dy - thumb / 2) / (railHeight - thumb)).clamp(0.0, 1.0);
    final k = (frac * (n - 1)).round();
    if (k != _dragSection) {
      HapticFeedback.lightImpact();
      _lastScrollSection = k; // nicht doppelt vibrieren
      final sec = _sections[k];
      if (sec.synthetic) {
        _itemScroll.jumpTo(index: 0);
      } else {
        final vh = MediaQuery.of(context).size.height;
        _itemScroll.jumpTo(index: sec.start + 1, alignment: vh > 0 ? _topBarHeight / vh : 0);
      }
    }
    setState(() {
      _dragSection = k;
      _dragY = railTop + dy;
    });
  }

  void _endRailDrag() {
    if (_dragSection != null) setState(() => _dragSection = null);
  }

  // ---------- Menüs ----------

  void _showPlaylistMenu() {
    showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SheetHeader(
              coverPath: _coverPath,
              icon: Icons.queue_music,
              title: _name,
              subtitle: 'Playlist • ${_tracks.length} Songs',
            ),
            const Divider(height: 1),
            SheetItem(
              icon: Icons.library_add_outlined,
              label: _hasFolder ? 'MP3s hinzufügen (auch in den Ordner)' : 'MP3s hinzufügen',
              onTap: () {
                Navigator.pop(ctx);
                _addMp3s();
              },
            ),
            if (!_hasFolder)
            SheetItem(
              icon: Icons.playlist_add,
              label: 'Songs aus anderer Playlist hinzufügen',
              onTap: () {
                Navigator.pop(ctx);
                _addFromPlaylist();
              },
            ),
            SheetItem(
              icon: Icons.swap_vert,
              label: 'Reihenfolge bearbeiten',
              onTap: () {
                Navigator.pop(ctx);
                _startReorder();
              },
            ),
            if (_hasFolder)
            SheetItem(
              icon: Icons.sync,
              label: 'Nach neuen Songs suchen',
              onTap: () {
                Navigator.pop(ctx);
                _rescanFolder();
              },
            ),
            SheetItem(
              icon: Icons.image_outlined,
              label: 'Cover-Bild ändern',
              onTap: () async {
                Navigator.pop(ctx);
                final res = await FilePicker.platform.pickFiles(type: FileType.image);
                final picked = res?.files.single.path;
                if (picked != null) {
                  final path = await persistCoverImage(picked, 'playlist_${widget.playlistId}');
                  await DatabaseHelper.instance.updatePlaylistCover(widget.playlistId, path);
                  _load();
                }
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showSongOptions(int index) {
    final t = _tracks[index];
    final hasSection = ((_tracksData[index]['section_name'] as String?) ?? '').trim().isNotEmpty;
    showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SheetHeader(
                coverPath: CoverService.instance.pathFor(t) ?? _coverPath, title: t.title, subtitle: t.artist),
            const Divider(height: 1),
            Builder(builder: (_) {
              final fav = AppSettings.instance.isFavorite(t.id);
              return SheetItem(
                icon: fav ? Icons.favorite : Icons.favorite_border,
                label: fav ? 'Kein Lieblingssong mehr' : 'Als Lieblingssong markieren',
                onTap: () {
                  Navigator.pop(ctx);
                  if (t.id == null) return;
                  HapticFeedback.lightImpact();
                  final now = AppSettings.instance.toggleFavorite(t.id!);
                  setState(() {});
                  final w = AppSettings.instance.favoriteWeight.value;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(now
                        ? (w > 1 ? '♥ Lieblingssong – kommt im Shuffle ${w}x vor' : '♥ Lieblingssong')
                        : 'Kein Lieblingssong mehr'),
                  ));
                },
              );
            }),
            SheetItem(
              icon: Icons.low_priority,
              label: 'Hier weitermachen (nach aktuellem Song)',
              onTap: () {
                Navigator.pop(ctx);
                final wasPlaying = _audio.currentTrack != null;
                _audio.continueWith(_tracks, index,
                    playlistId: widget.playlistId, playlistName: _name, coverPath: _coverPath);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(wasPlaying
                      ? 'Nach dem aktuellen Song geht es mit „${t.title}“ weiter'
                      : 'Spielt ab „${t.title}“'),
                ));
              },
            ),
            SheetItem(
              icon: Icons.playlist_play,
              label: 'Als Nächstes spielen',
              onTap: () {
                Navigator.pop(ctx);
                _audio.playNext(t);
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Wird als Nächstes gespielt')));
              },
            ),
            SheetItem(
              icon: Icons.playlist_add,
              label: 'Zu Playlist hinzufügen',
              onTap: () {
                Navigator.pop(ctx);
                showAddToPlaylistSheet(context, t, excludePlaylistId: widget.playlistId);
              },
            ),
            if (_custom)
            SheetItem(
              icon: Icons.bookmark_add_outlined,
              label: hasSection ? 'Abschnitt bearbeiten' : 'Abschnitt hier beginnen',
              onTap: () {
                Navigator.pop(ctx);
                _setSection(index);
              },
            ),
            SheetItem(
              icon: Icons.remove_circle_outline,
              label: 'Aus Playlist entfernen',
              color: Colors.redAccent,
              onTap: () async {
                Navigator.pop(ctx);
                final ok = await showConfirmDialog(
                  context,
                  title: 'Song entfernen?',
                  message: '„${t.title}“ wird aus der Playlist entfernt. Die MP3-Datei bleibt erhalten.',
                );
                if (!ok) return;
                await DatabaseHelper.instance.removeTrackFromPlaylist(widget.playlistId, t.id!);
                _load();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    if (_isReorderMode) return _buildReorder();
    final topPad = MediaQuery.of(context).padding.top;
    final empty = _tracks.isEmpty;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                ScrollablePositionedList.builder(
                  itemScrollController: _itemScroll,
                  itemPositionsListener: _itemPositions,
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: empty ? 2 : _tracks.length + 1,
                  itemBuilder: (context, i) {
                    if (i == 0) return _buildHeader(topPad);
                    if (empty) {
                      return Padding(
                        padding: const EdgeInsets.all(32),
                        child: Center(
                          child: Text(
                              _hasFolder
                                  ? 'Keine Songs. Tippe auf  ⟳  um den Ordner zu scannen.'
                                  : 'Noch leer. Tippe oben auf  ☰+  um Songs aus einer anderen Playlist zu übernehmen.',
                              textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textSecondary)),
                        ),
                      );
                    }
                    return _buildTrackRow(i - 1);
                  },
                ),
                _buildTopBar(topPad),
                if (_showRail) _buildSectionRail(topPad),
                if (_dragSection != null) _buildDragBubble(),
                _buildJumpButtons(),
              ],
            ),
    );
  }

  Widget _buildTopBar(double topPad) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: ValueListenableBuilder<Iterable<ItemPosition>>(
        valueListenable: _itemPositions.itemPositions,
        builder: (context, positions, _) {
          ItemPosition? header;
          for (final p in positions) {
            if (p.index == 0) header = p;
          }
          final solid = header == null || header.itemTrailingEdge < 0.3;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: topPad + 56,
            padding: EdgeInsets.only(top: topPad),
            color: solid ? AppColors.topBar : Colors.transparent,
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Zurück',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.maybePop(context),
                ),
                Expanded(
                  child: AnimatedOpacity(
                    opacity: solid ? 1 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: Text(_name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                  ),
                ),
                IconButton(
                  tooltip: 'Optionen',
                  icon: const Icon(Icons.more_vert),
                  onPressed: _showPlaylistMenu,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildHeader(double topPad) {
    final width = MediaQuery.of(context).size.width;
    final wide = width >= 720;
    final coverSize = wide ? 220.0 : (width * 0.62).clamp(160.0, 280.0).toDouble();
    final realSections = _sections.where((s) => !s.synthetic).length;
    var stats = '${_tracks.length} Songs • ${formatTotal(_totalMs)}';
    if (realSections > 0) stats += ' • $realSections Abschnitte';

    final cover = Container(
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 40, offset: const Offset(0, 12)),
        ],
      ),
      child: CoverArt(path: _coverPath, size: coverSize, icon: Icons.queue_music),
    );

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.headerTop, AppColors.headerMid, AppColors.background],
          stops: [0, 0.6, 1],
        ),
      ),
      padding: EdgeInsets.fromLTRB(16, topPad + 64, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (wide)
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                cover,
                const SizedBox(width: 24),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Playlist', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      Text(_name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 48, fontWeight: FontWeight.w900, height: 1.05)),
                      const SizedBox(height: 14),
                      Text(stats, style: const TextStyle(fontSize: 14, color: AppColors.textSecondary)),
                    ],
                  ),
                ),
              ],
            )
          else ...[
            Center(child: cover),
            const SizedBox(height: 24),
            Text(_name, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(stats, style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          ],
          const SizedBox(height: 8),
          _buildActionRow(),
        ],
      ),
    );
  }

  // ---------- Sortierung ----------

  /// Einmalig sortieren – die neue Reihenfolge wird gespeichert und bleibt.
  Future<void> _sortPermanently(int mode) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Playlist sortieren?',
      message: 'Die Reihenfolge wird dauerhaft auf „${playlistSortLabel(mode)}“ geändert. '
          'Danach kannst du wie gewohnt verschieben.'
          '${_sections.isNotEmpty ? ' Abschnitte bleiben an ihrem ersten Song hängen und können dadurch verrutschen.' : ''}',
      confirmLabel: 'Sortieren',
    );
    if (!ok) return;
    await sortPlaylistPermanently(widget.playlistId, mode);
    await _load();
  }

  Future<void> _startReorder() async {
    if (mounted) setState(() => _isReorderMode = true);
  }

  void _showSortSheet() {
    showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, 4),
              child: Text('Einmalig sortieren', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Die neue Reihenfolge wird gespeichert und bleibt so.',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
            ),
            for (final m in const [5, 1, 2, 3, 4])
              ListTile(
                title: Text(playlistSortLabel(m), style: const TextStyle(fontSize: 16)),
                onTap: () {
                  Navigator.pop(ctx);
                  _sortPermanently(m);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildActionRow() {
    return Row(
      children: [
        IconButton(
          tooltip: 'MP3s hinzufügen',
          icon: const Icon(Icons.library_add_outlined, color: AppColors.textSecondary),
          onPressed: _isScanning ? null : _addMp3s,
        ),
        if (!_hasFolder)
        IconButton(
          tooltip: 'Aus anderer Playlist hinzufügen',
          icon: const Icon(Icons.playlist_add, color: AppColors.textSecondary),
          onPressed: _isScanning ? null : _addFromPlaylist,
        ),
        IconButton(
          tooltip: 'Einmalig sortieren',
          icon: const Icon(Icons.sort, color: AppColors.textSecondary),
          onPressed: _showSortSheet,
        ),
        IconButton(
          tooltip: 'Reihenfolge bearbeiten',
          icon: const Icon(Icons.swap_vert, color: AppColors.textSecondary),
          onPressed: _startReorder,
        ),
        if (_hasFolder)
        IconButton(
          tooltip: 'Nach neuen Songs suchen',
          icon: _isScanning
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.sync, color: AppColors.textSecondary),
          onPressed: _isScanning ? null : _rescanFolder,
        ),
        const Spacer(),
        ValueListenableBuilder<bool>(
          valueListenable: _audio.shuffle,
          builder: (context, on, _) => IconButton(
            tooltip: 'Zufallswiedergabe',
            iconSize: 28,
            icon: Icon(Icons.shuffle, color: on ? AppColors.accentLight : AppColors.textSecondary),
            onPressed: _audio.toggleShuffle,
          ),
        ),
        const SizedBox(width: 8),
        StreamBuilder<PlayerState>(
          stream: _audio.player.playerStateStream,
          builder: (context, snap) {
            final playing = (snap.data?.playing ?? false) && _isThisPlaylist && _audio.isMusicMode;
            return Tooltip(
              message: playing ? 'Pause' : 'Abspielen',
              child: Material(
                color: AppColors.accent,
                shape: const CircleBorder(),
                elevation: 4,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _onPlayButton,
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: Icon(playing ? Icons.pause : Icons.play_arrow, size: 32, color: Colors.white),
                  ),
                ),
              ),
            );
          },
        ),
        SizedBox(width: _showRail ? _railWidth - 8 : 0),
      ],
    );
  }

  Widget _buildTrackRow(int i) {
    final t = _tracks[i];
    final section = _sectionStarts[i];
    final isCurrent = _isThisPlaylist && _audio.currentTrack?.id == t.id;
    final st = AppSettings.instance;
    final showNumbers = st.showTrackNumbers.value;
    final showCovers = st.showTrackCovers.value;
    final numWidth = (_tracks.length >= 1000 ? 44.0 : (_tracks.length >= 100 ? 36.0 : 28.0));

    final row = Material(
      color: (_highlightId != null && t.id == _highlightId)
          ? AppColors.accent.withValues(alpha: 0.35)
          : Colors.transparent,
      child: InkWell(
      onTap: () => _playTrack(i),
      onLongPress: () => _showSongOptions(i),
      child: Padding(
        padding: EdgeInsets.fromLTRB(showNumbers ? 8 : 16, 6, _showRail ? _railWidth : 4, 6),
        child: Row(
          children: [
            if (showNumbers)
              SizedBox(
                width: numWidth,
                child: isCurrent
                    ? const Icon(Icons.graphic_eq, color: AppColors.accentLight, size: 18)
                    : Text('${i + 1}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppColors.textSecondary, fontSize: 14)),
              ),
            if (showNumbers) const SizedBox(width: 8),
            if (showCovers) ...[
              CoverArt(path: CoverService.instance.pathFor(t), size: 46),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: isCurrent ? AppColors.accentLight : Colors.white,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (isCurrent && !showNumbers)
                        const Padding(
                          padding: EdgeInsets.only(right: 4),
                          child: Icon(Icons.graphic_eq, size: 14, color: AppColors.accentLight),
                        ),
                      if (st.isFavorite(t.id))
                        const Padding(
                          padding: EdgeInsets.only(right: 4),
                          child: Icon(Icons.favorite, size: 13, color: AppColors.accentLight),
                        ),
                      Expanded(
                        child: Text(t.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13.5, color: AppColors.textSecondary)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (st.showDurations.value)
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Text(formatDuration(Duration(milliseconds: t.durationMs)),
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
              ),
            IconButton(
              tooltip: 'Optionen',
              icon: const Icon(Icons.more_vert, color: AppColors.textSecondary, size: 20),
              onPressed: () => _showSongOptions(i),
            ),
          ],
        ),
      ),
    ));

    if (section == null) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16, 28, _showRail ? _railWidth + 4 : 16, 6),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 22,
                decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(section.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              ),
              Text('${section.count} Songs',
                  style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
            ],
          ),
        ),
        row,
      ],
    );
  }

  /// Seitlicher Balken: Ziehen springt von Abschnitt zu Abschnitt.
  Widget _buildSectionRail(double topPad) {
    final railTop = topPad + 72;
    return Positioned(
      top: railTop,
      bottom: 90,
      right: 0,
      width: _railWidth,
      child: LayoutBuilder(
        builder: (context, c) {
          final h = c.maxHeight;
          const thumb = 40.0;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (d) => _railTo(d.localPosition.dy, h, railTop),
            onVerticalDragUpdate: (d) => _railTo(d.localPosition.dy, h, railTop),
            onVerticalDragEnd: (_) => _endRailDrag(),
            onVerticalDragCancel: _endRailDrag,
            onTapDown: (d) => _railTo(d.localPosition.dy, h, railTop),
            onTapUp: (_) => Future.delayed(const Duration(milliseconds: 700), () {
              if (mounted) _endRailDrag();
            }),
            child: ValueListenableBuilder<Iterable<ItemPosition>>(
              valueListenable: _itemPositions.itemPositions,
              builder: (context, positions, _) {
                final n = _sections.length;
                final active = _dragSection ?? _visibleSection(positions);
                double yFor(int k) => n <= 1 ? 0 : k / (n - 1) * (h - thumb);
                return Stack(
                  children: [
                    for (int k = 0; k < n; k++)
                      Positioned(
                        top: yFor(k) + thumb / 2 - 2,
                        right: 11,
                        child: Container(
                          width: 4,
                          height: 4,
                          decoration: const BoxDecoration(color: Colors.white24, shape: BoxShape.circle),
                        ),
                      ),
                    AnimatedPositioned(
                      duration: Duration(milliseconds: _dragSection != null ? 0 : 120),
                      top: yFor(active),
                      right: 9,
                      child: Container(
                        width: 8,
                        height: thumb,
                        decoration: BoxDecoration(
                          color: _dragSection != null ? AppColors.accentLight : Colors.white54,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildDragBubble() {
    final sec = _sections[_dragSection!];
    return Positioned(
      right: _railWidth + 10,
      top: _dragY - 22,
      child: IgnorePointer(
        child: Material(
          color: AppColors.elevated,
          elevation: 8,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(sec.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                Text('${sec.count} Songs', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildJumpButtons() {
    return Positioned(
      right: _showRail ? _railWidth + 6 : 14,
      bottom: 16,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_isThisPlaylist) ...[
            RoundFloatingButton(icon: Icons.my_location, tooltip: 'Zum aktuellen Song', onTap: _jumpToCurrent),
            const SizedBox(height: 10),
          ],
          RoundFloatingButton(icon: Icons.keyboard_arrow_up, tooltip: 'Nach oben', onTap: _jumpToTop),
        ],
      ),
    );
  }

  Widget _buildReorder() {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.topBar,
        automaticallyImplyLeading: false,
        title: const Text('Reihenfolge bearbeiten'),
        actions: [
          TextButton(
            onPressed: () => setState(() => _isReorderMode = false),
            child: const Text('Fertig',
                style: TextStyle(color: AppColors.accentLight, fontWeight: FontWeight.w800, fontSize: 16)),
          ),
        ],
      ),
      body: ReorderableListView.builder(
        buildDefaultDragHandles: false,
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: _tracks.length,
        onReorder: _onReorder,
        itemBuilder: (context, i) {
          final t = _tracks[i];
          final section = _sectionStarts[i];
          return Material(
            key: ValueKey(t.id),
            color: AppColors.background,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (section != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 2),
                    child: Text(section.name,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w800, color: AppColors.accentLight)),
                  ),
                ListTile(
                  leading: CoverArt(path: CoverService.instance.pathFor(t), size: 44),
                  title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(t.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.textSecondary)),
                  trailing: ReorderableDragStartListener(
                    index: i,
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(Icons.drag_handle, color: AppColors.textSecondary),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
