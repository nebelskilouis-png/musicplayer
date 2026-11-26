import 'package:path/path.dart' as p;
import '../database/database_helper.dart';
import 'audiobook_service.dart' show naturalCompare;

/// Sortierung in Playlists (gespeicherter Index!):
/// 0 = eigene Reihenfolge, 1 = zuletzt hinzugefügt zuerst, 2 = älteste zuerst,
/// 3 = Titel A–Z, 4 = Künstler A–Z, 5 = wie im Ordner (Dateiname, „2“ vor „10“)
const playlistSortLabels = [
  'Eigene Reihenfolge',
  'Zuletzt hinzugefügt zuerst',
  'Älteste zuerst',
  'Titel A–Z',
  'Künstler A–Z',
  'Wie im Ordner (nach Dateiname)',
];

String playlistSortLabel(int mode) => playlistSortLabels[mode.clamp(0, playlistSortLabels.length - 1)];

/// rows kommen in eigener Reihenfolge (position) aus der Datenbank.
List<Map<String, dynamic>> sortPlaylistRows(List<Map<String, dynamic>> rows, int mode) {
  if (mode <= 0) return List.of(rows);
  int added(Map<String, dynamic> m) => (m['pl_added_at'] as int?) ?? 0;
  String str(Map<String, dynamic> m, String k) => ((m[k] as String?) ?? '').toLowerCase();

  final indexed = List.generate(rows.length, (i) => MapEntry(i, rows[i]));
  indexed.sort((a, b) {
    int c;
    switch (mode) {
      case 1:
        c = added(b.value).compareTo(added(a.value));
        break;
      case 2:
        c = added(a.value).compareTo(added(b.value));
        break;
      case 3:
        c = str(a.value, 'title').compareTo(str(b.value, 'title'));
        break;
      case 5:
        c = naturalCompare(p.basename((a.value['file_path'] as String?) ?? ''),
            p.basename((b.value['file_path'] as String?) ?? ''));
        break;
      case 4:
        c = str(a.value, 'artist').compareTo(str(b.value, 'artist'));
        if (c == 0) c = str(a.value, 'title').compareTo(str(b.value, 'title'));
        break;
      default:
        c = 0;
    }
    return c != 0 ? c : a.key.compareTo(b.key); // bei Gleichstand: eigene Reihenfolge
  });
  return indexed.map((e) => e.value).toList();
}

/// Songs einer Playlist in ihrer gespeicherten Reihenfolge.
Future<List<Map<String, dynamic>>> loadSortedPlaylistTracks(int playlistId) =>
    DatabaseHelper.instance.getTracksForPlaylist(playlistId);

/// Playlist einmalig dauerhaft sortieren (schreibt die neue Reihenfolge in die Datenbank).
Future<void> sortPlaylistPermanently(int playlistId, int mode) async {
  final rows = await DatabaseHelper.instance.getTracksForPlaylist(playlistId);
  await DatabaseHelper.instance.updatePlaylistOrder(playlistId, sortPlaylistRows(rows, mode));
}
