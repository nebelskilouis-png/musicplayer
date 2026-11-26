import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../services/audio_player_service.dart';
import '../services/audiobook_service.dart';
import '../services/permissions.dart';
import 'package:permission_handler/permission_handler.dart' show openAppSettings;
import '../services/cover_service.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'car_mode_screen.dart';
import 'player_screen.dart';
import 'settings_screen.dart';

/// Hörbuch-Bibliothek (getrennt von der Musik).
class AudiobooksScreen extends StatefulWidget {
  const AudiobooksScreen({super.key});

  @override
  State<AudiobooksScreen> createState() => _AudiobooksScreenState();
}

class _AudiobooksScreenState extends State<AudiobooksScreen> {
  final AudiobookService a = AudiobookService.instance;
  List<Book> _books = [];
  bool _loading = true;
  bool _busy = false;
  String _filter = 'all'; // all | started | new | finished

  @override
  void initState() {
    super.initState();
    a.libraryChanged.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    a.libraryChanged.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final books = await a.getBooks();
    if (!mounted) return;
    setState(() {
      _books = books;
      _loading = false;
    });
  }

  List<Book> get _filtered {
    switch (_filter) {
      case 'started':
        return _books.where((b) => b.started).toList();
      case 'new':
        return _books.where((b) => !b.started && !b.finished).toList();
      case 'finished':
        return _books.where((b) => b.finished).toList();
      default:
        return _books;
    }
  }

  // ---------- Hinzufügen ----------

  void _showAddMenu() {
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
              child: Text('Hörbücher hinzufügen', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            SheetItem(
              icon: Icons.menu_book_outlined,
              label: 'Ein Hörbuch (ein Ordner)',
              onTap: () {
                Navigator.pop(ctx);
                _add(single: true);
              },
            ),
            SheetItem(
              icon: Icons.folder_copy_outlined,
              label: 'Ordner mit mehreren Hörbüchern',
              onTap: () {
                Navigator.pop(ctx);
                _add(single: false);
              },
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 16),
              child: Text(
                'Bei mehreren Hörbüchern wird jeder Unterordner zu einem eigenen Buch.',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _add({required bool single}) async {
    if (!await ensureMediaPermission()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Die App darf deine Musikdateien noch nicht lesen.'),
        action: SnackBarAction(label: 'Erlauben', onPressed: openAppSettings),
      ));
      return;
    }
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: single ? 'Ordner des Hörbuchs wählen' : 'Ordner mit Hörbüchern wählen',
    );
    if (dir == null || !mounted) return;
    setState(() => _busy = true);
    final n = single ? await a.addBookFolder(dir) : await a.addLibraryFolder(dir);
    await _load();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(n == 0
          ? 'Keine neuen Hörbücher gefunden'
          : (n == 1 ? '1 Hörbuch hinzugefügt' : '$n Hörbücher hinzugefügt')),
    ));
  }

  // ---------- Optionen ----------

  Future<void> _play(Book b) async {
    await a.openBook(b);
    if (mounted) openPlayer(context);
  }

  void _showOptions(Book b) {
    showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SheetHeader(
                coverPath: b.coverPath,
                icon: Icons.menu_book,
                title: b.title,
                subtitle: b.author.isEmpty ? 'Hörbuch' : b.author,
              ),
              const Divider(height: 1),
              SheetItem(
                icon: Icons.play_arrow,
                label: b.started ? 'Weiterhören' : 'Abspielen',
                onTap: () {
                  Navigator.pop(ctx);
                  _play(b);
                },
              ),
              SheetItem(
                icon: Icons.sort,
                label: 'Sortierung: ${b.sortMode == 'filename' ? 'nach Dateiname' : 'nach Ordnerstruktur'}',
                onTap: () {
                  Navigator.pop(ctx);
                  _showSortSheet(b);
                },
              ),
              SheetItem(
                icon: Icons.sync,
                label: 'Dateien neu einlesen',
                onTap: () async {
                  Navigator.pop(ctx);
                  setState(() => _busy = true);
                  await a.rescanBook(b);
                  if (mounted) setState(() => _busy = false);
                },
              ),
              SheetItem(
                icon: Icons.edit_outlined,
                label: 'Umbenennen',
                onTap: () async {
                  Navigator.pop(ctx);
                  final t = await showTextInputDialog(context, title: 'Umbenennen', initial: b.title);
                  if (t != null && t.trim().isNotEmpty) a.renameBook(b, t.trim());
                },
              ),
              SheetItem(
                icon: Icons.image_outlined,
                label: 'Cover ändern',
                onTap: () async {
                  Navigator.pop(ctx);
                  final res = await FilePicker.platform.pickFiles(type: FileType.image);
                  final path = res?.files.single.path;
                  if (path != null) a.setCover(b, await persistCoverImage(path, 'book_${b.id}'));
                },
              ),
              if (!b.finished)
                SheetItem(
                  icon: Icons.check_circle_outline,
                  label: 'Als beendet markieren',
                  onTap: () {
                    Navigator.pop(ctx);
                    a.markFinished(b);
                  },
                ),
              SheetItem(
                icon: Icons.restart_alt,
                label: 'Fortschritt zurücksetzen',
                onTap: () async {
                  Navigator.pop(ctx);
                  final ok = await showConfirmDialog(
                    context,
                    title: 'Fortschritt zurücksetzen?',
                    message: '„${b.title}“ startet danach wieder ganz von vorne.',
                    confirmLabel: 'Zurücksetzen',
                  );
                  if (ok) a.resetProgress(b);
                },
              ),
              SheetItem(
                icon: Icons.delete_outline,
                label: 'Hörbuch entfernen',
                color: Colors.redAccent,
                onTap: () async {
                  Navigator.pop(ctx);
                  final ok = await showConfirmDialog(
                    context,
                    title: 'Hörbuch entfernen?',
                    message: '„${b.title}“ wird aus der App entfernt, inklusive Fortschritt. '
                        'Die Dateien auf dem Gerät bleiben erhalten.',
                  );
                  if (ok) a.removeBook(b);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  void _showSortSheet(Book b) {
    showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      builder: (ctx) {
        Widget option(String mode, String title, String desc) => ListTile(
              title: Text(title, style: const TextStyle(fontSize: 16)),
              subtitle: Text(desc, style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
              trailing: b.sortMode == mode ? const Icon(Icons.check, color: AppColors.accentLight) : null,
              onTap: () {
                Navigator.pop(ctx);
                a.setSortMode(b, mode);
              },
            );
        return _sortSheetBody(option);
      },
    );
  }

  Widget _sortSheetBody(Widget Function(String, String, String) option) {
    return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text('Kapitel sortieren', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            option('folder', 'Nach Ordnerstruktur', 'Erst Ordner für Ordner (z.B. CD 1, CD 2), darin nach Name'),
            option('filename', 'Nach Dateiname', 'Alle Dateien nur nach ihrem Namen, egal in welchem Ordner'),
            const SizedBox(height: 8),
          ],
        ),
    );
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  const CircleAvatar(
                    radius: 16,
                    backgroundColor: AppColors.accent,
                    child: Icon(Icons.headphones, size: 18, color: Colors.white),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text('Hörbücher', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                  ),
                  IconButton(
                    tooltip: 'Auto-Modus',
                    icon: const Icon(Icons.directions_car_outlined, size: 26),
                    onPressed: () => openCarMode(context),
                  ),
                  IconButton(
                    tooltip: 'Einstellungen',
                    icon: const Icon(Icons.settings_outlined, size: 26),
                    onPressed: () =>
                        Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
                  ),
                  IconButton(
                    tooltip: 'Hörbücher hinzufügen',
                    icon: const Icon(Icons.add, size: 30),
                    onPressed: _busy ? null : _showAddMenu,
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                children: [
                  _chip('all', 'Alle'),
                  _chip('started', 'Angefangen'),
                  _chip('new', 'Neu'),
                  _chip('finished', 'Beendet'),
                ],
              ),
            ),
            SizedBox(
              height: 2,
              child: _busy
                  ? const LinearProgressIndicator(backgroundColor: Colors.transparent)
                  : const SizedBox.shrink(),
            ),
            Expanded(
              child: _loading
                  ? const SizedBox.shrink()
                  : _books.isEmpty
                      ? _buildEmpty()
                      : ListenableBuilder(
                          listenable: Listenable.merge([a.changes, AudioPlayerService.instance.mode]),
                          builder: (context, _) {
                            final list = _filtered;
                            if (list.isEmpty) {
                              return const Center(
                                child: Text('Keine Hörbücher in dieser Ansicht',
                                    style: TextStyle(color: AppColors.textSecondary)),
                              );
                            }
                            return ListView.builder(
                              padding: const EdgeInsets.only(top: 4, bottom: 16),
                              itemCount: list.length,
                              itemBuilder: (context, i) => _buildRow(list[i]),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String key, String label) {
    final sel = _filter == key;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: sel ? AppColors.accent : const Color(0xFF2A2A2A),
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () => setState(() => _filter = key),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
        ),
      ),
    );
  }

  Widget _buildRow(Book b) {
    final isCurrent = a.current?.id == b.id && AudioPlayerService.instance.mode.value == PlayMode.book;
    Widget status;
    if (b.finished) {
      status = const Row(
        children: [
          Icon(Icons.check_circle, size: 14, color: AppColors.accentLight),
          SizedBox(width: 4),
          Text('Beendet', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
        ],
      );
    } else if (b.started) {
      status = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: b.progress,
              minHeight: 3,
              backgroundColor: Colors.white12,
              color: AppColors.accentLight,
            ),
          ),
          const SizedBox(height: 4),
          Text('Noch ${formatTotal(b.remainingMs)}',
              style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
        ],
      );
    } else {
      status = Text(b.totalMs > 0 ? 'Neu • ${formatTotal(b.totalMs)}' : 'Neu',
          style: const TextStyle(fontSize: 13, color: AppColors.textSecondary));
    }

    return InkWell(
      onTap: () => _play(b),
      onLongPress: () => _showOptions(b),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(
          children: [
            CoverArt(path: b.coverPath, size: 76, icon: Icons.menu_book),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (isCurrent)
                        const Padding(
                          padding: EdgeInsets.only(right: 4),
                          child: Icon(Icons.volume_up, size: 15, color: AppColors.accentLight),
                        ),
                      Expanded(
                        child: Text(b.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: isCurrent ? AppColors.accentLight : Colors.white,
                            )),
                      ),
                    ],
                  ),
                  if (b.author.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(b.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                    ),
                  const SizedBox(height: 8),
                  status,
                ],
              ),
            ),
            IconButton(
              tooltip: 'Optionen',
              icon: const Icon(Icons.more_vert, color: AppColors.textSecondary),
              onPressed: () => _showOptions(b),
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
            const Icon(Icons.headphones, size: 56, color: AppColors.textMuted),
            const SizedBox(height: 16),
            const Text('Füge dein erstes Hörbuch hinzu',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            const Text('Wähle den Ordner eines Hörbuchs oder einen Ordner mit mehreren Hörbüchern.',
                textAlign: TextAlign.center, style: TextStyle(color: AppColors.textSecondary)),
            const SizedBox(height: 24),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                shape: const StadiumBorder(),
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
              ),
              onPressed: _busy ? null : _showAddMenu,
              child: const Text('Hörbücher hinzufügen', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            ),
          ],
        ),
      ),
    );
  }
}
