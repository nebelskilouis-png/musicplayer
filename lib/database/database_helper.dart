import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._();
  DatabaseHelper._();

  Database? _db;

  Future<Database> get database async {
    _db ??= await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final path = join(await getDatabasesPath(), 'musicplayer.db');
    return openDatabase(
      path,
      version: 6,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) => _createTables(db),
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 3) {
          // Sehr alte Versionen: neu anlegen
          await db.execute('DROP TABLE IF EXISTS playlist_tracks');
          await db.execute('DROP TABLE IF EXISTS playlists');
          await db.execute('DROP TABLE IF EXISTS tracks');
          await _createTables(db);
          return;
        }
        if (oldVersion < 4) {
          // Version 3 -> 4: Daten bleiben erhalten
          await db.execute('ALTER TABLE tracks ADD COLUMN cover_path TEXT');
          await db.execute('ALTER TABLE tracks ADD COLUMN cover_checked INTEGER NOT NULL DEFAULT 0');
          await _createSettingsTable(db);
        }
        if (oldVersion < 5) {
          // Version 4 -> 5: Hörbücher
          await _createBookTables(db);
        }
        if (oldVersion < 6) {
          // Version 5 -> 6: "hinzugefügt am" pro Playlist-Eintrag + Sortierung pro Playlist
          await db.execute('ALTER TABLE playlist_tracks ADD COLUMN added_at INTEGER NOT NULL DEFAULT 0');
          await db.execute(
              'UPDATE playlist_tracks SET added_at = (SELECT added_at FROM tracks WHERE tracks.id = playlist_tracks.track_id)');
          await db.execute('ALTER TABLE playlists ADD COLUMN sort_mode INTEGER');
        }
      },
    );
  }

  Future<void> _createBookTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS books (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        author TEXT NOT NULL DEFAULT '',
        folder_path TEXT NOT NULL UNIQUE,
        sort_mode TEXT NOT NULL DEFAULT 'folder',
        cover_path TEXT,
        current_file TEXT,
        position_ms INTEGER NOT NULL DEFAULT 0,
        progress_ms INTEGER NOT NULL DEFAULT 0,
        total_ms INTEGER NOT NULL DEFAULT 0,
        finished INTEGER NOT NULL DEFAULT 0,
        last_played_at INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS book_files (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL,
        file_path TEXT NOT NULL,
        rel_path TEXT NOT NULL,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
      )
    ''');
  }

  // ---------- Hörbücher ----------

  Future<List<Map<String, dynamic>>> getBooks() async {
    final db = await database;
    return db.query('books', orderBy: 'last_played_at DESC, created_at DESC');
  }

  Future<Map<String, dynamic>?> getBook(int id) async {
    final db = await database;
    final rows = await db.query('books', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first;
  }

  /// Gibt 0 zurück, wenn der Ordner schon als Hörbuch existiert.
  Future<int> addBook({
    required String title,
    required String author,
    required String folderPath,
    String? coverPath,
    required int totalMs,
  }) async {
    final db = await database;
    return db.insert(
      'books',
      {
        'title': title,
        'author': author,
        'folder_path': folderPath,
        'cover_path': coverPath,
        'total_ms': totalMs,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> updateBook(int id, Map<String, Object?> values) async {
    final db = await database;
    await db.update('books', values, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteBook(int id) async {
    final db = await database;
    await db.delete('books', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Map<String, dynamic>>> getBookFiles(int bookId) async {
    final db = await database;
    return db.query('book_files', where: 'book_id = ?', whereArgs: [bookId]);
  }

  /// files: Liste aus [Pfad, relativer Pfad, Dauer in ms]
  Future<void> replaceBookFiles(int bookId, List<List<Object>> files) async {
    final db = await database;
    final batch = db.batch();
    batch.delete('book_files', where: 'book_id = ?', whereArgs: [bookId]);
    for (final f in files) {
      batch.insert('book_files', {
        'book_id': bookId,
        'file_path': f[0],
        'rel_path': f[1],
        'duration_ms': f[2],
      });
    }
    await batch.commit(noResult: true);
  }

  Future<void> _createTables(Database db) async {
    await db.execute('''
      CREATE TABLE tracks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file_path TEXT NOT NULL UNIQUE,
        title TEXT NOT NULL,
        artist TEXT NOT NULL DEFAULT '',
        album TEXT NOT NULL DEFAULT '',
        duration_ms INTEGER NOT NULL DEFAULT 0,
        added_at INTEGER NOT NULL,
        cover_path TEXT,
        cover_checked INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE playlists (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        folder_path TEXT NOT NULL,
        cover_path TEXT,
        sort_mode INTEGER,
        created_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE playlist_tracks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        playlist_id INTEGER NOT NULL,
        section_name TEXT,
        track_id INTEGER NOT NULL,
        position INTEGER NOT NULL,
        added_at INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE,
        FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
      )
    ''');

    await _createSettingsTable(db);
    await _createBookTables(db);
  }

  Future<void> _createSettingsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  // ---------- Einstellungen ----------

  Future<Map<String, String>> getSettings() async {
    final db = await database;
    final rows = await db.query('settings');
    return {for (final r in rows) r['key'] as String: r['value'] as String};
  }

  Future<void> setSetting(String key, String value) async {
    final db = await database;
    await db.insert('settings', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ---------- Playlists ----------

  Future<List<Map<String, dynamic>>> getPlaylists() async {
    final db = await database;
    return db.rawQuery('''
      SELECT p.*, COUNT(pt.id) AS track_count
      FROM playlists p
      LEFT JOIN playlist_tracks pt ON pt.playlist_id = p.id
      GROUP BY p.id
      ORDER BY p.created_at DESC
    ''');
  }

  Future<Map<String, dynamic>?> getPlaylist(int id) async {
    final db = await database;
    final rows = await db.query('playlists', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<int> addPlaylist(String name, String folderPath) async {
    final db = await database;
    return db.insert('playlists', {
      'name': name,
      'folder_path': folderPath,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// null = Standard aus den Einstellungen
  Future<void> setPlaylistSortMode(int id, int? mode) async {
    final db = await database;
    await db.update('playlists', {'sort_mode': mode}, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> renamePlaylist(int id, String name) async {
    final db = await database;
    await db.update('playlists', {'name': name}, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> updatePlaylistCover(int playlistId, String? coverPath) async {
    final db = await database;
    await db.update('playlists', {'cover_path': coverPath}, where: 'id = ?', whereArgs: [playlistId]);
  }

  Future<void> deletePlaylist(int playlistId) async {
    final db = await database;
    await db.delete('playlists', where: 'id = ?', whereArgs: [playlistId]);
  }

  // ---------- Tracks ----------

  Future<List<Map<String, dynamic>>> getTracksForPlaylist(int playlistId) async {
    final db = await database;
    return db.rawQuery('''
      SELECT t.*, pt.section_name, pt.added_at AS pl_added_at
      FROM tracks t
      INNER JOIN playlist_tracks pt ON t.id = pt.track_id
      WHERE pt.playlist_id = ?
      ORDER BY pt.position ASC
    ''', [playlistId]);
  }

  Future<List<Map<String, dynamic>>> searchTracks(String query) async {
    final db = await database;
    final like = '%$query%';
    return db.query(
      'tracks',
      where: 'title LIKE ? OR artist LIKE ? OR album LIKE ?',
      whereArgs: [like, like, like],
      orderBy: 'title COLLATE NOCASE',
      limit: 200,
    );
  }

  /// Suche mit Playlist-Zugehörigkeit (ein Treffer pro Song und Playlist).
  Future<List<Map<String, dynamic>>> searchTracksInPlaylists(String query) async {
    final db = await database;
    final like = '%$query%';
    return db.rawQuery('''
      SELECT t.*, p.id AS pl_id, p.name AS pl_name
      FROM tracks t
      LEFT JOIN playlist_tracks pt ON pt.track_id = t.id
      LEFT JOIN playlists p ON p.id = pt.playlist_id
      WHERE t.title LIKE ? OR t.artist LIKE ? OR t.album LIKE ?
      ORDER BY t.title COLLATE NOCASE, p.name COLLATE NOCASE
      LIMIT 300
    ''', [like, like, like]);
  }

  Future<List<Map<String, dynamic>>> getTracksWithoutCoverCheck(int limit) async {
    final db = await database;
    return db.query('tracks',
        columns: ['id', 'file_path'], where: 'cover_checked = 0', orderBy: 'id', limit: limit);
  }

  Future<void> setTrackCover(int trackId, String? coverPath) async {
    final db = await database;
    await db.update('tracks', {'cover_path': coverPath, 'cover_checked': 1},
        where: 'id = ?', whereArgs: [trackId]);
  }

  Future<void> resetCoverChecks() async {
    final db = await database;
    await db.update('tracks', {'cover_path': null, 'cover_checked': 0});
  }

  Future<int> getMaxPosition(int playlistId) async {
    final db = await database;
    final result =
        await db.rawQuery('SELECT MAX(position) as max_pos FROM playlist_tracks WHERE playlist_id = ?', [playlistId]);
    if (result.isNotEmpty && result.first['max_pos'] != null) {
      return result.first['max_pos'] as int;
    }
    return -1;
  }

  Future<void> addTrackToPlaylist(int playlistId, int trackId, int position,
      {String? sectionName, int? addedAt}) async {
    final db = await database;
    await db.insert('playlist_tracks', {
      'added_at': addedAt ?? DateTime.now().millisecondsSinceEpoch,
      'playlist_id': playlistId,
      'track_id': trackId,
      'position': position,
      'section_name': sectionName,
    });
  }

  /// Song zu einer Playlist hinzufügen – oben (atTop) oder unten. false = war schon drin.
  Future<bool> addTrackToPlaylistNew(int playlistId, int trackId, {required bool atTop}) async {
    final db = await database;
    final exists = await db.query('playlist_tracks',
        columns: ['id'], where: 'playlist_id = ? AND track_id = ?', whereArgs: [playlistId, trackId], limit: 1);
    if (exists.isNotEmpty) return false;
    if (atTop) {
      await db.rawUpdate('UPDATE playlist_tracks SET position = position + 1 WHERE playlist_id = ?', [playlistId]);
      await addTrackToPlaylist(playlistId, trackId, 0);
    } else {
      await addTrackToPlaylist(playlistId, trackId, await getMaxPosition(playlistId) + 1);
    }
    return true;
  }

  /// Mehrere Songs auf einmal in eine Playlist (in der angegebenen Reihenfolge), oben oder unten.
  /// Songs, die schon drin sind, werden übersprungen. sections: optionaler Abschnittsname je Song.
  /// Gibt die IDs der wirklich hinzugefügten Songs zurück.
  Future<List<int>> addTracksToPlaylistBulk(int playlistId, List<int> trackIds,
      {required bool atTop, Map<int, String>? sections}) async {
    final db = await database;
    return db.transaction((txn) async {
      final existing = (await txn.query('playlist_tracks',
              columns: ['track_id'], where: 'playlist_id = ?', whereArgs: [playlistId]))
          .map((r) => r['track_id'] as int)
          .toSet();
      final add = <int>[];
      for (final id in trackIds) {
        if (!existing.contains(id) && !add.contains(id)) add.add(id);
      }
      if (add.isEmpty) return add;
      int start;
      if (atTop) {
        await txn.rawUpdate(
            'UPDATE playlist_tracks SET position = position + ? WHERE playlist_id = ?', [add.length, playlistId]);
        start = 0;
      } else {
        final r = await txn.rawQuery(
            'SELECT MAX(position) AS m FROM playlist_tracks WHERE playlist_id = ?', [playlistId]);
        start = ((r.first['m'] as int?) ?? -1) + 1;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final batch = txn.batch();
      for (int i = 0; i < add.length; i++) {
        batch.insert('playlist_tracks', {
          'playlist_id': playlistId,
          'track_id': add[i],
          'position': start + i,
          'added_at': now - i, // Reihenfolge bleibt auch bei "Zuletzt hinzugefügt" erhalten
          'section_name': sections?[add[i]],
        });
      }
      await batch.commit(noResult: true);
      return add;
    });
  }

  Future<void> updateSectionName(int playlistId, int trackId, String? sectionName) async {
    final db = await database;
    await db.update(
      'playlist_tracks',
      {'section_name': sectionName},
      where: 'playlist_id = ? AND track_id = ?',
      whereArgs: [playlistId, trackId],
    );
  }

  Future<void> removeTrackFromPlaylist(int playlistId, int trackId) async {
    final db = await database;
    await db.delete('playlist_tracks', where: 'playlist_id = ? AND track_id = ?', whereArgs: [playlistId, trackId]);
  }

  Future<void> updatePlaylistOrder(int playlistId, List<Map<String, dynamic>> tracksData) async {
    final db = await database;
    final batch = db.batch();
    for (int i = 0; i < tracksData.length; i++) {
      batch.update(
        'playlist_tracks',
        {'position': i},
        where: 'playlist_id = ? AND track_id = ?',
        whereArgs: [playlistId, tracksData[i]['id']],
      );
    }
    await batch.commit(noResult: true);
  }
}
