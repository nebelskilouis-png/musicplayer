import 'package:flutter/material.dart';
import '../database/database_helper.dart';
import '../models/track.dart';
import '../services/music_scanner.dart';
import '../services/settings_service.dart';
import '../theme.dart';
import 'common.dart';

/// Auswahl: Song zu einer (anderen) Playlist hinzufügen.
Future<void> showAddToPlaylistSheet(BuildContext context, Track track, {int? excludePlaylistId}) async {
  final all = await DatabaseHelper.instance.getPlaylists();
  final pls = all.where((p) => p['id'] != excludePlaylistId).toList();
  // Playlists ohne Ordner zuerst – dafür sind sie gedacht
  pls.sort((a, b) {
    final ma = ((a['folder_path'] as String?) ?? '').isEmpty ? 0 : 1;
    final mb = ((b['folder_path'] as String?) ?? '').isEmpty ? 0 : 1;
    return ma.compareTo(mb);
  });
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);

  Future<void> addTo(int id, String name) async {
    final mode = AppSettings.instance.newSongsPosition.value;
    final ok = await DatabaseHelper.instance.addTrackToPlaylistNew(id, track.id!, atTop: mode == 0);
    if (ok && mode == 2) await MusicScanner.placeByName(id, [track.id!]);
    MusicScanner.libraryChanged.value++;
    messenger.showSnackBar(SnackBar(content: Text(ok ? 'Zu „$name“ hinzugefügt' : 'Schon in „$name“')));
  }

  await showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.8),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SheetHeader(title: track.title, subtitle: 'Zu Playlist hinzufügen'),
              const Divider(height: 1),
              SheetItem(
                icon: Icons.add,
                label: 'Neue Playlist',
                onTap: () async {
                  Navigator.pop(ctx);
                  final name = await showTextInputDialog(context,
                      title: 'Neue Playlist', hint: 'Name der Playlist', confirmLabel: 'Erstellen');
                  if (name == null || name.trim().isEmpty) return;
                  final id = await DatabaseHelper.instance.addPlaylist(name.trim(), '');
                  await addTo(id, name.trim());
                },
              ),
              for (final p in pls)
                ListTile(
                  leading: CoverArt(path: p['cover_path'] as String?, size: 44, icon: Icons.queue_music),
                  title: Text(p['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    ((p['folder_path'] as String?) ?? '').isEmpty
                        ? 'Eigene Playlist • ${p['track_count'] ?? 0} Songs'
                        : 'Ordner-Playlist • ${p['track_count'] ?? 0} Songs',
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    addTo(p['id'] as int, p['name'] as String);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    ),
  );
}
