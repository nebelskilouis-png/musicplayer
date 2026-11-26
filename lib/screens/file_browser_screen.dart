import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../services/audiobook_service.dart' show naturalCompare;
import '../theme.dart';

/// Eigene Dateiauswahl für MP3s: mehrere markieren, ganzen Ordner markieren,
/// Reihenfolge = Reihenfolge des Markierens (Nummern zeigen sie an).
/// Gibt die Pfade in dieser Reihenfolge zurück.
Future<List<String>?> pickMp3Files(BuildContext context) {
  return Navigator.of(context, rootNavigator: true).push<List<String>>(
    MaterialPageRoute(builder: (_) => const FileBrowserScreen(), fullscreenDialog: true),
  );
}

class FileBrowserScreen extends StatefulWidget {
  const FileBrowserScreen({super.key});

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends State<FileBrowserScreen> {
  late Directory _dir;
  List<Directory> _folders = [];
  List<File> _files = [];
  final List<String> _selected = []; // Reihenfolge = Reihenfolge des Markierens
  String? _error;

  static String get _root {
    if (Platform.isAndroid) return '/storage/emulated/0';
    return Platform.environment['HOME'] ?? '/';
  }

  List<(String, String)> get _shortcuts {
    final r = _root;
    if (Platform.isAndroid) {
      return [('Download', '$r/Download'), ('Musik', '$r/Music'), ('Speicher', r)];
    }
    return [('Downloads', '$r/Downloads'), ('Musik', '$r/Musik'), ('Home', r)];
  }

  @override
  void initState() {
    super.initState();
    final start = _shortcuts.map((s) => Directory(s.$2)).firstWhere((d) => d.existsSync(), orElse: () => Directory(_root));
    _open(start);
  }

  void _open(Directory d) {
    try {
      final entries = d.listSync(followLinks: false);
      final folders = entries.whereType<Directory>().where((x) => !p.basename(x.path).startsWith('.')).toList()
        ..sort((a, b) => naturalCompare(p.basename(a.path), p.basename(b.path)));
      final files = entries
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.mp3'))
          .toList()
        ..sort((a, b) => naturalCompare(p.basename(a.path), p.basename(b.path)));
      setState(() {
        _dir = d;
        _folders = folders;
        _files = files;
        _error = null;
      });
    } catch (e) {
      setState(() {
        _dir = d;
        _folders = [];
        _files = [];
        _error = 'Ordner kann nicht gelesen werden';
      });
    }
  }

  void _toggle(String path) {
    setState(() {
      if (_selected.contains(path)) {
        _selected.remove(path);
      } else {
        _selected.add(path);
      }
    });
  }

  bool get _allSelected => _files.isNotEmpty && _files.every((f) => _selected.contains(f.path));

  void _toggleAll() {
    setState(() {
      if (_allSelected) {
        _selected.removeWhere((x) => _files.any((f) => f.path == x));
      } else {
        // in der angezeigten Reihenfolge hinzufügen
        for (final f in _files) {
          if (!_selected.contains(f.path)) _selected.add(f.path);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final canGoUp = _dir.parent.path != _dir.path && _dir.path != '/storage/emulated';
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
        title: const Text('MP3s auswählen'),
        actions: [
          if (_files.isNotEmpty)
            TextButton(
              onPressed: _toggleAll,
              child: Text(_allSelected ? 'Keine' : 'Alle markieren',
                  style: const TextStyle(color: AppColors.accentLight, fontWeight: FontWeight.w700)),
            ),
        ],
      ),
      body: Column(
        children: [
          // Schnellzugriff
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              children: [
                for (final s in _shortcuts)
                  if (Directory(s.$2).existsSync())
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ActionChip(
                        label: Text(s.$1),
                        backgroundColor: const Color(0xFF2A2A2A),
                        side: BorderSide.none,
                        shape: const StadiumBorder(),
                        onPressed: () => _open(Directory(s.$2)),
                      ),
                    ),
              ],
            ),
          ),
          // aktueller Pfad + hoch
          ListTile(
            dense: true,
            leading: IconButton(
              tooltip: 'Eine Ebene hoch',
              icon: const Icon(Icons.arrow_upward),
              onPressed: canGoUp ? () => _open(_dir.parent) : null,
            ),
            title: Text(p.basename(_dir.path).isEmpty ? _dir.path : p.basename(_dir.path),
                style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(_dir.path,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.textSecondary)),
          ),
          const Divider(height: 1),
          Expanded(
            child: _error != null
                ? Center(child: Text(_error!, style: const TextStyle(color: AppColors.textSecondary)))
                : ListView(
                    padding: const EdgeInsets.only(bottom: 100),
                    children: [
                      for (final d in _folders)
                        ListTile(
                          leading: const Icon(Icons.folder, color: AppColors.textSecondary),
                          title: Text(p.basename(d.path)),
                          trailing: const Icon(Icons.chevron_right, color: AppColors.textSecondary),
                          onTap: () => _open(d),
                        ),
                      for (final f in _files) _fileTile(f),
                      if (_folders.isEmpty && _files.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(32),
                          child: Center(
                              child: Text('Keine Ordner oder MP3s hier',
                                  style: TextStyle(color: AppColors.textSecondary))),
                        ),
                    ],
                  ),
          ),
        ],
      ),
      bottomNavigationBar: _selected.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('${_selected.length} ausgewählt',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    ),
                    TextButton(
                      onPressed: () => setState(_selected.clear),
                      child: const Text('Leeren', style: TextStyle(color: AppColors.textSecondary)),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: Colors.white,
                        shape: const StadiumBorder(),
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                      ),
                      onPressed: () => Navigator.pop(context, List<String>.of(_selected)),
                      child: const Text('Hinzufügen', style: TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _fileTile(File f) {
    final idx = _selected.indexOf(f.path);
    final sel = idx >= 0;
    return ListTile(
      onTap: () => _toggle(f.path),
      leading: Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: sel ? AppColors.accent : Colors.transparent,
          border: Border.all(color: sel ? AppColors.accent : Colors.white38, width: 2),
        ),
        // Nummer = Position, an der der Song eingefügt wird
        child: sel
            ? Text('${idx + 1}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13))
            : null,
      ),
      title: Text(p.basenameWithoutExtension(f.path),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: sel ? AppColors.accentLight : Colors.white)),
    );
  }
}
