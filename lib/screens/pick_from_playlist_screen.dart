import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../database/database_helper.dart';
import '../models/track.dart';
import '../services/cover_service.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Ergebnis der Auswahl: Songs in der Reihenfolge der Quell-Playlist,
/// optional mit Abschnittsnamen (nur für komplett gewählte Abschnitte).
class PickedSongs {
  final List<int> trackIds;
  final Map<int, String> sections;
  const PickedSongs(this.trackIds, this.sections);
}

/// Songs aus einer anderen Playlist auswählen – einzeln oder ganze Abschnitte.
Future<PickedSongs?> pickSongsFromPlaylist(BuildContext context, {required int targetPlaylistId}) {
  return Navigator.of(context, rootNavigator: true).push<PickedSongs>(
    MaterialPageRoute(builder: (_) => PickFromPlaylistScreen(targetPlaylistId: targetPlaylistId)),
  );
}

class _Sec {
  final String name;
  final int start; // Index in _tracks
  final int count;
  final bool synthetic; // "Anfang" vor dem ersten echten Abschnitt
  const _Sec(this.name, this.start, this.count, {this.synthetic = false});
}

class PickFromPlaylistScreen extends StatefulWidget {
  final int targetPlaylistId;
  const PickFromPlaylistScreen({super.key, required this.targetPlaylistId});

  @override
  State<PickFromPlaylistScreen> createState() => _PickFromPlaylistScreenState();
}

class _PickFromPlaylistScreenState extends State<PickFromPlaylistScreen> {
  final _scroll = ItemScrollController();

  List<Map<String, dynamic>> _playlists = [];
  Set<int> _inTarget = {};
  bool _loading = true;

  // gewählte Quell-Playlist
  Map<String, dynamic>? _source;
  List<Track> _tracks = [];
  List<_Sec> _sections = [];
  final Set<int> _selected = {}; // Indizes in _tracks
  bool _keepSections = true;

  // Anzeige-Liste: Abschnitts-Köpfe (sec >= 0) und Songs (track >= 0)
  List<(int sec, int track)> _rows = [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final db = DatabaseHelper.instance;
    final all = await db.getPlaylists();
    final target = await db.getTracksForPlaylist(widget.targetPlaylistId);
    if (!mounted) return;
    setState(() {
      _playlists = all.where((p) => p['id'] != widget.targetPlaylistId).toList();
      _inTarget = target.map((r) => r['id'] as int).toSet();
      _loading = false;
    });
  }

  Future<void> _openSource(Map<String, dynamic> pl) async {
    setState(() => _loading = true);
    final rows = await DatabaseHelper.instance.getTracksForPlaylist(pl['id'] as int);
    if (!mounted) return;
    final tracks = rows.map(Track.fromMap).toList();
    // Abschnitte wie in der Playlist-Ansicht
    final starts = <int>[];
    final names = <String>[];
    for (int i = 0; i < rows.length; i++) {
      final s = (rows[i]['section_name'] as String?)?.trim();
      if (s != null && s.isNotEmpty) {
        starts.add(i);
        names.add(s);
      }
    }
    final secs = <_Sec>[];
    if (starts.isNotEmpty && starts.first > 0) secs.add(_Sec('Anfang', 0, starts.first, synthetic: true));
    for (int k = 0; k < starts.length; k++) {
      final end = k + 1 < starts.length ? starts[k + 1] : rows.length;
      secs.add(_Sec(names[k], starts[k], end - starts[k]));
    }
    final list = <(int, int)>[];
    if (secs.isEmpty) {
      for (int i = 0; i < tracks.length; i++) {
        list.add((-1, i));
      }
    } else {
      for (int k = 0; k < secs.length; k++) {
        list.add((k, -1));
        for (int i = secs[k].start; i < secs[k].start + secs[k].count; i++) {
          list.add((-1, i));
        }
      }
    }
    setState(() {
      _source = pl;
      _tracks = tracks;
      _sections = secs;
      _rows = list;
      _selected.clear();
      _loading = false;
    });
  }

  void _closeSource() {
    setState(() {
      _source = null;
      _tracks = [];
      _sections = [];
      _rows = [];
      _selected.clear();
    });
  }

  bool _selectable(int i) => !_inTarget.contains(_tracks[i].id);

  Iterable<int> _secIndices(_Sec s) sync* {
    for (int i = s.start; i < s.start + s.count; i++) {
      if (_selectable(i)) yield i;
    }
  }

  /// true = alle, false = keiner, null = teilweise
  bool? _secState(_Sec s) {
    final idx = _secIndices(s).toList();
    if (idx.isEmpty) return false;
    final n = idx.where(_selected.contains).length;
    if (n == 0) return false;
    if (n == idx.length) return true;
    return null;
  }

  void _toggleSec(_Sec s) {
    HapticFeedback.selectionClick();
    final all = _secState(s) == true;
    setState(() {
      for (final i in _secIndices(s)) {
        all ? _selected.remove(i) : _selected.add(i);
      }
    });
  }

  void _toggleAll() {
    final selectable = [for (int i = 0; i < _tracks.length; i++) if (_selectable(i)) i];
    final all = selectable.isNotEmpty && selectable.every(_selected.contains);
    setState(() => all ? _selected.clear() : _selected.addAll(selectable));
  }

  bool get _anyFullSection =>
      _sections.any((s) => !s.synthetic && _secState(s) == true);

  void _finish() {
    final order = _selected.toList()..sort();
    final ids = [for (final i in order) _tracks[i].id!];
    final sections = <int, String>{};
    if (_keepSections) {
      for (final s in _sections) {
        if (s.synthetic || _secState(s) != true) continue;
        final first = _secIndices(s).first;
        sections[_tracks[first].id!] = s.name;
      }
    }
    Navigator.pop(context, PickedSongs(ids, sections));
  }

  void _jumpToSection(int k) {
    final row = _rows.indexWhere((r) => r.$1 == k);
    if (row >= 0 && _scroll.isAttached) _scroll.jumpTo(index: row);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _source == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _source != null) _closeSource();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_source == null ? 'Aus Playlist hinzufügen' : (_source!['name'] as String)),
          actions: _source == null
              ? null
              : [
                  if (_sections.length > 1)
                    PopupMenuButton<int>(
                      tooltip: 'Zu Abschnitt springen',
                      icon: const Icon(Icons.segment),
                      onSelected: _jumpToSection,
                      itemBuilder: (_) => [
                        for (int k = 0; k < _sections.length; k++)
                          PopupMenuItem(value: k, child: Text('${_sections[k].name} (${_sections[k].count})')),
                      ],
                    ),
                  TextButton(onPressed: _toggleAll, child: const Text('Alle')),
                ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : (_source == null ? _buildPlaylistList() : _buildSongList()),
        bottomNavigationBar: _source == null ? null : _buildBottomBar(),
      ),
    );
  }

  Widget _buildPlaylistList() {
    if (_playlists.isEmpty) {
      return const Center(
        child: Text('Keine anderen Playlists', style: TextStyle(color: AppColors.textSecondary)),
      );
    }
    return ListView.builder(
      itemCount: _playlists.length,
      itemBuilder: (context, i) {
        final p = _playlists[i];
        return ListTile(
          leading: CoverArt(path: p['cover_path'] as String?, size: 48),
          title: Text(p['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${p['track_count'] ?? 0} Songs', style: const TextStyle(color: AppColors.textSecondary)),
          trailing: const Icon(Icons.chevron_right, color: AppColors.textSecondary),
          onTap: () => _openSource(p),
        );
      },
    );
  }

  Widget _buildSongList() {
    if (_tracks.isEmpty) {
      return const Center(child: Text('Playlist ist leer', style: TextStyle(color: AppColors.textSecondary)));
    }
    return ScrollablePositionedList.builder(
      itemScrollController: _scroll,
      itemCount: _rows.length,
      itemBuilder: (context, r) {
        final (sec, track) = _rows[r];
        if (sec >= 0) return _sectionRow(_sections[sec]);
        return _trackRow(track);
      },
    );
  }

  Widget _sectionRow(_Sec s) {
    final state = _secState(s);
    final selectable = _secIndices(s).isNotEmpty;
    return Material(
      color: AppColors.elevated,
      child: InkWell(
        onTap: selectable ? () => _toggleSec(s) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 16, 6),
          child: Row(
            children: [
              Checkbox(
                tristate: true,
                value: state,
                onChanged: selectable ? (_) => _toggleSec(s) : null,
              ),
              Expanded(
                child: Text(s.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              ),
              Text(selectable ? 'ganzer Abschnitt • ${s.count}' : 'schon drin',
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _trackRow(int i) {
    final t = _tracks[i];
    final ok = _selectable(i);
    final sel = _selected.contains(i);
    return InkWell(
      onTap: ok ? () => setState(() => sel ? _selected.remove(i) : _selected.add(i)) : null,
      child: Opacity(
        opacity: ok ? 1 : 0.45,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 16, 4),
          child: Row(
            children: [
              Checkbox(
                value: ok ? sel : true,
                onChanged: ok ? (_) => setState(() => sel ? _selected.remove(i) : _selected.add(i)) : null,
              ),
              CoverArt(path: CoverService.instance.pathFor(t), size: 42),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: sel ? AppColors.accentLight : Colors.white)),
                    Text(ok ? t.artist : 'schon in der Playlist',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    final n = _selected.length;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_anyFullSection)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Abschnitts-Namen übernehmen'),
                value: _keepSections,
                onChanged: (v) => setState(() => _keepSections = v),
              ),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                onPressed: n == 0 ? null : _finish,
                child: Text(n == 0 ? 'Songs auswählen' : '$n ${n == 1 ? 'Song' : 'Songs'} hinzufügen'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
