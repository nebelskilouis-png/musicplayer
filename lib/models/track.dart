class Track {
  final int? id;
  final String filePath;
  final String title;
  final String artist;
  final String album;
  final int durationMs;
  final int addedAt;
  final String? coverPath; // aus der MP3 extrahiertes Cover (Cache-Datei)

  Track({
    this.id,
    required this.filePath,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationMs,
    required this.addedAt,
    this.coverPath,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'file_path': filePath,
        'title': title,
        'artist': artist,
        'album': album,
        'duration_ms': durationMs,
        'added_at': addedAt,
        'cover_path': coverPath,
      };

  factory Track.fromMap(Map<String, dynamic> map) => Track(
        id: map['id'] as int?,
        filePath: map['file_path'] as String,
        title: map['title'] as String,
        artist: map['artist'] as String,
        album: map['album'] as String,
        durationMs: map['duration_ms'] as int,
        addedAt: map['added_at'] as int,
        coverPath: map['cover_path'] as String?,
      );
}
