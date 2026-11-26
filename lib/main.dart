import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'theme.dart';
import 'screens/audiobooks_screen.dart';
import 'screens/library_screen.dart';
import 'screens/search_screen.dart';
import 'services/audio_player_service.dart';
import 'services/audiobook_service.dart';
import 'services/cover_service.dart';
import 'services/media_handler.dart';
import 'services/output_service.dart';
import 'services/permissions.dart';
import 'services/music_scanner.dart';
import 'services/settings_service.dart';
import 'widgets/mini_player.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  JustAudioMediaKit.ensureInitialized(linux: true, windows: true);
  if (Platform.isLinux || Platform.isWindows) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: AppColors.navBar,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  try {
    await AppSettings.instance.load();
  } catch (e) {
    debugPrint('Einstellungen konnten nicht geladen werden: $e');
  }

  await initMediaHandler(); // Sperrbildschirm + Kopfhörer-Tasten (Android)

  runApp(const MyApp());

  // Android: beim Start nach Zugriff auf Musikdateien und Benachrichtigungen fragen
  if (Platform.isAndroid) {
    await ensureMediaPermission();
    try {
      await Permission.notification.request(); // für die Steuerung im Sperrbildschirm
    } catch (_) {}
  }

  // Hintergrund-Aufgaben nach dem Start
  AudiobookService.instance; // startet Fortschritt-Speicherung + Schlaf-Timer
  AudioOutputService.instance.start(); // erkennt Kopfhörer / Lautsprecher
  AudioPlayerService.instance.restoreSession();
  CoverService.instance.run();
  MusicScanner.fixAddedDatesOnce().then((_) {
    if (AppSettings.instance.scanOnStart.value) MusicScanner.scanAllPlaylists();
  });
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Musik',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: const AppShell(),
      );
}

/// Grundgerüst wie bei Spotify: Inhalt + Mini-Player + Navigationsleiste unten.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tab = 0;
  final _navKeys = [GlobalKey<NavigatorState>(), GlobalKey<NavigatorState>(), GlobalKey<NavigatorState>()];

  void _selectTab(int i) {
    if (i == _tab) {
      _navKeys[i].currentState?.popUntil((r) => r.isFirst);
    } else {
      setState(() => _tab = i);
    }
  }

  Widget _tabNavigator(int i, Widget root) => Navigator(
        key: _navKeys[i],
        onGenerateRoute: (settings) => MaterialPageRoute(builder: (_) => root),
      );

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        final nav = _navKeys[_tab].currentState;
        if (nav != null && nav.canPop()) {
          nav.pop();
        } else if (_tab != 0) {
          setState(() => _tab = 0);
        } else {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        body: IndexedStack(
          index: _tab,
          children: [
            _tabNavigator(0, const LibraryScreen()),
            _tabNavigator(1, const AudiobooksScreen()),
            _tabNavigator(2, const SearchScreen()),
          ],
        ),
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MiniPlayer(show: _tab == 0 ? PlayMode.music : (_tab == 1 ? PlayMode.book : null)),
            _BottomNav(current: _tab, onTap: _selectTab),
          ],
        ),
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  final int current;
  final ValueChanged<int> onTap;

  const _BottomNav({required this.current, required this.onTap});

  Widget _item(int i, IconData icon, IconData activeIcon, String label) {
    final sel = i == current;
    return Expanded(
      child: InkWell(
        onTap: () => onTap(i),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(sel ? activeIcon : icon, color: sel ? Colors.white : AppColors.textSecondary, size: 26),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: sel ? Colors.white : AppColors.textSecondary,
                fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.navBar,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 60,
          child: Row(
            children: [
              _item(0, Icons.library_music_outlined, Icons.library_music, 'Musik'),
              _item(1, Icons.headphones_outlined, Icons.headphones, 'Hörbücher'),
              _item(2, Icons.search, Icons.search, 'Suchen'),
            ],
          ),
        ),
      ),
    );
  }
}
