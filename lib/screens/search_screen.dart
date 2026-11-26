import 'package:flutter/material.dart';
import '../database/database_helper.dart';
import '../models/track.dart';
import '../services/audio_player_service.dart';
import '../services/cover_service.dart';
import '../services/playlist_sort.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'playlist_screen.dart';

/// Lokale Suche über alle Songs.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  List<Track> _results = [];
  List<Map<String, dynamic>> _rows = []; // gleiche Reihenfolge wie _results, mit pl_id / pl_name
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onChanged(String q) async {
    _query = q;
    if (q.trim().isEmpty) {
      setState(() {
        _results = [];
        _rows = [];
      });
      return;
    }
    final rows = await DatabaseHelper.instance.searchTracksInPlaylists(q.trim());
    if (!mounted || q != _query) return;
    setState(() {
      _rows = rows;
      _results = rows.map(Track.fromMap).toList();
    });
  }

  /// Direkt abspielen – innerhalb seiner Playlist, danach geht es dort normal weiter.
  Future<void> _playResult(int i) async {
    final r = _rows[i];
    final plId = r['pl_id'] as int?;
    final t = _results[i];
    final s = AudioPlayerService.instance;
    if (plId == null) {
      await s.playPlaylist([t], 0, playlistName: 'Suche');
      return;
    }
    final rows = await loadSortedPlaylistTracks(plId);
    final tracks = rows.map(Track.fromMap).toList();
    final idx = tracks.indexWhere((x) => x.id == t.id);
    final pl = await DatabaseHelper.instance.getPlaylist(plId);
    await s.playPlaylist(
      tracks,
      idx < 0 ? 0 : idx,
      playlistId: plId,
      playlistName: (r['pl_name'] as String?) ?? '',
      coverPath: pl?['cover_path'] as String?,
    );
  }

  /// Treffer antippen: zur Playlist springen, genau an die Stelle des Songs.
  void _openResult(int i) {
    final r = _rows[i];
    final plId = r['pl_id'] as int?;
    final t = _results[i];
    if (plId == null) {
      // Song gehört zu keiner Playlist mehr -> direkt abspielen
      AudioPlayerService.instance.playPlaylist([t], 0, playlistName: 'Suche');
      return;
    }
    FocusScope.of(context).unfocus();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlaylistScreen(
        playlistId: plId,
        playlistName: (r['pl_name'] as String?) ?? '',
        focusTrackId: t.id,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final s = AudioPlayerService.instance;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Text('Suchen', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _controller,
                onChanged: _onChanged,
                style: const TextStyle(color: Colors.black, fontSize: 16),
                cursorColor: Colors.black,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.white,
                  hintText: 'Was willst du hören?',
                  hintStyle: const TextStyle(color: Color(0xFF535353)),
                  prefixIcon: const Icon(Icons.search, color: Colors.black),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, color: Colors.black),
                          onPressed: () {
                            _controller.clear();
                            _onChanged('');
                          },
                        ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
                  enabledBorder:
                      OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
                  focusedBorder:
                      OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _results.isEmpty
                  ? Center(
                      child: Text(
                        _query.trim().isEmpty ? 'Suche nach Titel, Künstler oder Album' : 'Keine Treffer',
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                    )
                  : ValueListenableBuilder<int>(
                      valueListenable: s.changes,
                      builder: (context, _, __) => ListView.builder(
                        padding: const EdgeInsets.only(bottom: 16),
                        itemCount: _results.length,
                        itemBuilder: (context, i) {
                          final t = _results[i];
                          final isCurrent = s.currentTrack?.id == t.id;
                          return InkWell(
                            onTap: () => _openResult(i),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
                              child: Row(
                                children: [
                                  CoverArt(path: CoverService.instance.pathFor(t), size: 48),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(t.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 16,
                                              color: isCurrent ? AppColors.accentLight : Colors.white,
                                            )),
                                        const SizedBox(height: 2),
                                        Text(
                                            _rows[i]['pl_name'] != null
                                                ? '${t.artist} • in ${_rows[i]['pl_name']}'
                                                : 'Song • ${t.artist}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Abspielen',
                                    icon: const Icon(Icons.play_circle_outline, color: AppColors.textSecondary),
                                    onPressed: () => _playResult(i),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
