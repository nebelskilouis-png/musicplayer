import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../database/database_helper.dart';
import '../services/audio_player_service.dart';
import '../services/cover_service.dart';
import '../services/music_scanner.dart';
import '../services/permissions.dart';
import 'package:permission_handler/permission_handler.dart' show openAppSettings;
import '../theme.dart';
import '../widgets/common.dart';
import 'car_mode_screen.dart';
import 'playlist_screen.dart';
import 'settings_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<Map<String, dynamic>> _playlists = [];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    MusicScanner.libraryChanged.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    MusicScanner.libraryChanged.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final pls = await DatabaseHelper.instance.getPlaylists();
    if (!mounted) return;
    setState(() {
      _playlists = pls;
      _loading = false;
    });
  }

  /// Auswahl: Playlist aus Ordner oder eigene (leere) Playlist.
  void _createPlaylist() {
    showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text('Playlist erstellen', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            SheetItem(
              icon: Icons.folder_outlined,
              label: 'Aus Ordner (Songs kommen automatisch)',
              onTap: () {
                Navigator.pop(ctx);
                _createFolderPlaylist();
              },
            ),
            SheetItem(
              icon: Icons.playlist_add,
              label: 'Eigene Playlist (Songs selbst hinzufügen)',
              onTap: () {
                Navigator.pop(ctx);
                _createManualPlaylist();
              },
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 16),
              child: Text(
                'Songs fügst du bei jedem Song über ⋮ → „Zu Playlist hinzufügen“ hinzu.',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createManualPlaylist() async {
    final name = await showTextInputDialog(context,
        title: 'Eigene Playlist', hint: 'Name der Playlist', confirmLabel: 'Erstellen');
    if (name == null || name.trim().isEmpty) return;
    await DatabaseHelper.instance.addPlaylist(name.trim(), '');
    await _load();
  }

  Future<void> _createFolderPlaylist() async {
    if (!await ensureMediaPermission()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Die App darf deine Musikdateien noch nicht lesen.'),
        action: SnackBarAction(label: 'Erlauben', onPressed: openAppSettings),
      ));
      return;
    }
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Wähle den Musikordner für diese Playlist',
    );
    if (dir == null || !mounted) return;

    final name = await showTextInputDialog(
      context,
      title: 'Playlist erstellen',
      initial: dir.split(Platform.pathSeparator).last,
      hint: 'Name der Playlist',
      confirmLabel: 'Erstellen',
    );
    if (name == null || name.trim().isEmpty) return;

    setState(() => _busy = true);
    final id = await DatabaseHelper.instance.addPlaylist(name.trim(), dir);
    final added = await MusicScanner().scanFolderForPlaylist(Directory(dir), id);
    await _load();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(added == 0
          ? 'Keine MP3s gefunden in: $dir'
          : '$added Songs hinzugefügt'),
    ));
  }

  void _openPlaylist(Map<String, dynamic> pl) {
    Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (_) => PlaylistScreen(playlistId: pl['id'] as int, playlistName: pl['name'] as String),
        ))
        .then((_) => _load());
  }

  void _showOptions(Map<String, dynamic> pl) {
    showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SheetHeader(
              coverPath: pl['cover_path'] as String?,
              icon: Icons.queue_music,
              title: pl['name'] as String,
              subtitle: 'Playlist • ${pl['track_count'] ?? 0} Songs',
            ),
            const Divider(height: 1),
            SheetItem(
              icon: Icons.edit_outlined,
              label: 'Umbenennen',
              onTap: () async {
                Navigator.pop(ctx);
                final n = await showTextInputDialog(context, title: 'Umbenennen', initial: pl['name'] as String);
                if (n != null && n.trim().isNotEmpty) {
                  await DatabaseHelper.instance.renamePlaylist(pl['id'] as int, n.trim());
                  _load();
                }
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
                  final path = await persistCoverImage(picked, 'playlist_${pl['id']}');
                  await DatabaseHelper.instance.updatePlaylistCover(pl['id'] as int, path);
                  _load();
                }
              },
            ),
            SheetItem(
              icon: Icons.delete_outline,
              label: 'Playlist löschen',
              color: Colors.redAccent,
              onTap: () async {
                Navigator.pop(ctx);
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (d) => AlertDialog(
                    backgroundColor: AppColors.elevated,
                    title: const Text('Playlist löschen?'),
                    content: Text('„${pl['name']}“ wird gelöscht. Deine MP3-Dateien bleiben erhalten.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Abbrechen')),
                      TextButton(
                        onPressed: () => Navigator.pop(d, true),
                        child: const Text('Löschen', style: TextStyle(color: Colors.redAccent)),
                      ),
                    ],
                  ),
                );
                if (ok == true) {
                  await DatabaseHelper.instance.deletePlaylist(pl['id'] as int);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  const CircleAvatar(
                    radius: 16,
                    backgroundColor: AppColors.accent,
                    child: Icon(Icons.person, size: 18, color: Colors.white),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text('Deine Bibliothek', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                  ),
                  IconButton(
                    tooltip: 'Auto-Modus',
                    icon: const Icon(Icons.directions_car_outlined, size: 26),
                    onPressed: () => openCarMode(context),
                  ),
                  IconButton(
                    tooltip: 'Einstellungen',
                    icon: const Icon(Icons.settings_outlined, size: 26),
                    onPressed: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
                  ),
                  IconButton(
                    tooltip: 'Playlist erstellen',
                    icon: const Icon(Icons.add, size: 30),
                    onPressed: _busy ? null : _createPlaylist,
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 2,
              child: _busy
                  ? const LinearProgressIndicator(backgroundColor: Colors.transparent)
                  : const SizedBox.shrink(),
            ),
            _buildResumeBanner(),
            Expanded(
              child: _loading
                  ? const SizedBox.shrink()
                  : _playlists.isEmpty
                      ? _buildEmpty()
                      : ValueListenableBuilder<int>(
                          valueListenable: AudioPlayerService.instance.changes,
                          builder: (context, _, __) => ListView.builder(
                            padding: const EdgeInsets.only(top: 4, bottom: 16),
                            itemCount: _playlists.length,
                            itemBuilder: (context, i) => _buildRow(_playlists[i]),
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  /// Läuft gerade ein Hörbuch: Musik genau an der gemerkten Stelle fortsetzen.
  Widget _buildResumeBanner() {
    final s = AudioPlayerService.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([s.changes, s.mode]),
      builder: (context, _) {
        final t = s.currentTrack;
        if (s.isMusicMode || t == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Material(
            color: AppColors.elevated,
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: s.togglePlay,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  children: [
                    CoverArt(path: CoverService.instance.pathFor(t) ?? s.currentCoverPath, size: 48),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Musik fortsetzen',
                              style: TextStyle(fontSize: 12, color: AppColors.accentLight, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 2),
                          Text(t.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                          Text(s.currentPlaylistName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                        ],
                      ),
                    ),
                    const Icon(Icons.play_circle_fill, size: 40, color: AppColors.accentLight),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildRow(Map<String, dynamic> pl) {
    final isPlaying = AudioPlayerService.instance.isPlayingPlaylist(pl['id'] as int);
    return InkWell(
      onTap: () => _openPlaylist(pl),
      onLongPress: () => _showOptions(pl),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
        child: Row(
          children: [
            CoverArt(path: pl['cover_path'] as String?, size: 64, icon: Icons.queue_music),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    pl['name'] as String,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: isPlaying ? AppColors.accentLight : Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (isPlaying)
                        const Padding(
                          padding: EdgeInsets.only(right: 4),
                          child: Icon(Icons.volume_up, size: 14, color: AppColors.accentLight),
                        ),
                      Text(
                        '${((pl['folder_path'] as String?) ?? '').isEmpty ? 'Eigene Playlist' : 'Playlist'} • ${pl['track_count'] ?? 0} Songs',
                        style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Optionen',
              icon: const Icon(Icons.more_vert, color: AppColors.textSecondary),
              onPressed: () => _showOptions(pl),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Erstelle deine erste Playlist',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            const Text('Wähle einen Ordner mit MP3-Dateien.',
                textAlign: TextAlign.center, style: TextStyle(color: AppColors.textSecondary)),
            const SizedBox(height: 24),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                shape: const StadiumBorder(),
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
              ),
              onPressed: _busy ? null : _createPlaylist,
              child: const Text('Playlist erstellen', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            ),
          ],
        ),
      ),
    );
  }
}
