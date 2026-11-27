import 'package:flutter/material.dart';
import '../services/audiobook_service.dart';
import '../services/cover_service.dart';
import '../services/media_handler.dart';
import '../services/music_scanner.dart';
import '../services/settings_service.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'book_player_screen.dart' show speedOptions;

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static const _actions = [0, 1, 2, 3, 4, 5, 6];

  String _sec(int v) => v == 0 ? 'Aus' : '$v Sekunden';

  String _sleepLabel(int v) {
    if (v == 0) return 'Kein Schlaf-Timer';
    if (v == -1) return 'Ende des Kapitels';
    return '$v Minuten';
  }

  @override
  Widget build(BuildContext context) {
    final st = AppSettings.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Einstellungen')),
      body: ListenableBuilder(
        listenable: st.listenable,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            // ---------------- Musik ----------------
            const _Header('Musik'),
            _SwitchTile(
              title: 'Beim Start an letzter Stelle weitermachen',
              subtitle: 'Gilt für Musik und Hörbücher',
              notifier: st.resumeOnStart,
            ),
            _SwitchTile(
              title: 'Playlist als Kreis',
              subtitle: 'Beim ersten Song zurück = letzter Song, beim letzten Song weiter = erster Song',
              notifier: st.playlistWrap,
            ),
            _ChoiceTile(
              title: 'Lieblingssongs im Shuffle',
              notifier: st.favoriteWeight,
              options: const [1, 2, 3],
              format: (v) => v == 1 ? 'Normal (1x)' : '${v}x so oft',
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Lieblingssong: Song gedrückt halten → „Als Lieblingssong markieren“. '
                'Die Wiederholungen sind über die Warteschlange verteilt, nie direkt hintereinander.',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
            ),
            _ChoiceTile(
              title: 'Zurück-Taste startet Song neu nach',
              notifier: st.restartThreshold,
              options: const [2, 3, 4, 5, 10],
              format: (v) => '$v Sekunden',
            ),

            const _Header('Lyrics'),
            _SwitchTile(
              title: 'Lyrics online suchen',
              subtitle: 'Bei lrclib.net (kostenlos). Gefundene Lyrics werden gespeichert und gehen danach offline. '
                  'Eigene .lrc-Dateien neben der MP3 haben immer Vorrang.',
              notifier: st.onlineLyrics,
            ),

            const _Header('Auto-Modus'),
            _SwitchTile(
              title: 'Song-Cover hinter dem Play-Button',
              subtitle: 'Nur bei Musik. Aus = einfarbig blau.',
              notifier: st.carCoverBackground,
            ),

            const _Header('Musik-Tempo'),
            _SwitchTile(
              title: 'Tempo-Regler anbieten',
              subtitle: 'Zeigt im Player einen Tempo-Button. Aus = komplett ausgeblendet, Musik läuft mit 1,0x.',
              notifier: st.musicSpeedFeature,
            ),
            if (st.musicSpeedFeature.value)
              _ActionTile(
                icon: Icons.edit_outlined,
                title: 'Schnellwahl-Tempi anpassen',
                subtitle: st.musicSpeedPresetList.map(formatSpeed).join('  '),
                onTap: () async {
                  final input = await showTextInputDialog(
                    context,
                    title: 'Schnellwahl-Tempi',
                    initial: st.musicSpeedPresetList.map((p) => formatSpeed(p).replaceAll('x', '')).join('  '),
                    hint: 'mit Leerzeichen trennen, z.B. 0,5  1  1,5  2',
                  );
                  if (input == null) return;
                  final values = AppSettings.parseSpeedList(input);
                  if (values.isEmpty) return;
                  st.setString(st.musicSpeedPresets, values.take(10).join(','));
                },
              ),

            const _Header('Kopfhörer-Steuerung (Ski-Modus)'),
            _SwitchTile(
              title: 'Kopfhörer-Steuerung anbieten',
              subtitle: 'Zeigt im Player einen Schalter dafür. Aus = komplett ausgeblendet.',
              notifier: st.headsetFeature,
            ),
            if (st.headsetFeature.value) ...[
              _SwitchTile(
                title: 'Modus jetzt aktiv',
                subtitle: 'Geht auch über den Kopfhörer-Schalter im Player',
                notifier: st.headsetModeOn,
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  'Nur am Handy (Android), auch bei gesperrtem Bildschirm. '
                  'Einmal Lauter/Leiser ändert die Lautstärke der App – dreh die Handy-Lautstärke '
                  'vorher hoch. Schnell 2x tippen löst die Aktion aus.',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                ),
              ),
              _ChoiceTile(
                title: '2x Lauter',
                notifier: st.headsetVolUp2,
                options: _actions,
                format: headsetActionLabel,
              ),
              _ChoiceTile(
                title: '2x Leiser',
                notifier: st.headsetVolDown2,
                options: _actions,
                format: headsetActionLabel,
              ),
              _ChoiceTile(
                title: '1x Play-Taste',
                notifier: st.headsetPlay1,
                options: _actions,
                format: headsetActionLabel,
              ),
              _ChoiceTile(
                title: '2x Play-Taste',
                notifier: st.headsetPlay2,
                options: _actions,
                format: headsetActionLabel,
              ),
              _ChoiceTile(
                title: '3x Play-Taste',
                notifier: st.headsetPlay3,
                options: _actions,
                format: headsetActionLabel,
              ),
              _ChoiceTile(
                title: 'Zeit für Doppeltippen',
                notifier: st.headsetWindowMs,
                options: const [300, 400, 450, 500, 600, 800],
                format: (v) => '$v ms',
              ),
            ],

            const _Header('Playlist-Ansicht'),
            _ChoiceTile(
              title: 'Neue Songs einfügen',
              notifier: st.newSongsPosition,
              options: const [0, 1, 2],
              format: (v) => v == 0
                  ? 'Oben (neueste zuerst)'
                  : (v == 1 ? 'Unten (neueste zuletzt)' : 'Wie im Ordner (passende Stelle nach Dateiname)'),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Gilt nur beim Hinzufügen. Danach bleibt die Reihenfolge so, wie du sie verschiebst.',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
            ),
            _SwitchTile(title: 'Songnummern anzeigen', notifier: st.showTrackNumbers),
            _SwitchTile(title: 'Cover anzeigen', notifier: st.showTrackCovers),
            _SwitchTile(title: 'Songdauer anzeigen', notifier: st.showDurations),
            _SwitchTile(
              title: 'Seitlicher Abschnitts-Balken',
              subtitle: 'Zum Springen zwischen Abschnitten',
              notifier: st.showSectionRail,
            ),

            const _Header('Musik-Bibliothek'),
            _SwitchTile(
              title: 'Beim Start nach neuen Songs suchen',
              subtitle: 'Durchsucht alle Playlist-Ordner automatisch',
              notifier: st.scanOnStart,
            ),
            _ActionTile(
              icon: Icons.sync,
              title: 'Jetzt alle Ordner scannen',
              onTap: () async {
                final messenger = ScaffoldMessenger.of(context);
                final n = await MusicScanner.scanAllPlaylists();
                messenger.showSnackBar(
                  SnackBar(content: Text(n == 0 ? 'Keine neuen Songs gefunden' : '$n neue Songs hinzugefügt')),
                );
              },
            ),
            _ActionTile(
              icon: Icons.image_outlined,
              title: 'Song-Cover neu einlesen',
              subtitle: 'Falls Cover fehlen oder sich geändert haben',
              onTap: () {
                CoverService.instance.rebuild();
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Cover werden im Hintergrund neu eingelesen')));
              },
            ),

            // ---------------- Hörbücher ----------------
            const _Header('Hörbücher'),
            _ChoiceTile(
              title: 'Zurückspulen um',
              notifier: st.bookSkipBack,
              options: const [5, 10, 15, 20, 30, 45, 60, 90, 120],
              format: _sec,
            ),
            _ChoiceTile(
              title: 'Vorspulen um',
              notifier: st.bookSkipForward,
              options: const [5, 10, 15, 20, 30, 45, 60, 90, 120],
              format: _sec,
            ),
            _ChoiceTile(
              title: 'Wiedergabe-Tempo',
              notifier: st.bookSpeedPct,
              options: speedOptions,
              format: formatSpeed,
              onSelected: (v) => AudiobookService.instance.setSpeed(v),
            ),
            _ChoiceTile(
              title: 'Beim Fortsetzen zurückspulen',
              notifier: st.bookRewindOnResume,
              options: const [0, 2, 3, 5, 10, 15, 30],
              format: _sec,
            ),

            const _Header('Hörbuch-Schlaf-Timer'),
            _ChoiceTile(
              title: 'Schlaf-Timer',
              notifier: st.bookSleepMinutes,
              options: [0, ...st.sleepPresetList, -1],
              format: _sleepLabel,
            ),
            _ActionTile(
              icon: Icons.edit_outlined,
              title: 'Timer-Zeiten anpassen',
              subtitle: st.sleepPresetList.map((m) => '$m').join(', ') + ' Minuten',
              onTap: () async {
                final input = await showTextInputDialog(
                  context,
                  title: 'Timer-Zeiten (Minuten)',
                  initial: st.sleepPresetList.join(', '),
                  hint: 'z.B. 5, 10, 15, 30, 45, 60',
                );
                if (input == null) return;
                final values = input
                    .split(RegExp(r'[,; ]+'))
                    .map((s) => int.tryParse(s.trim()))
                    .whereType<int>()
                    .where((v) => v > 0 && v <= 600)
                    .toSet()
                    .toList()
                  ..sort();
                if (values.isEmpty) return;
                st.setString(st.sleepPresets, values.join(','));
              },
            ),
            _SwitchTile(
              title: 'Schütteln verlängert den Timer',
              subtitle: 'Nur am Handy. Kurze Vibration als Bestätigung.',
              notifier: st.shakeToExtend,
            ),

            const _Header('Info'),
            const ListTile(
              title: Text('Version'),
              trailing: Text('0.3.0', style: TextStyle(color: AppColors.textSecondary)),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 28, 16, 8),
        child: Text(text, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
      );
}

class _SwitchTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final ValueNotifier<bool> notifier;

  const _SwitchTile({required this.title, required this.notifier, this.subtitle});

  @override
  Widget build(BuildContext context) => SwitchListTile(
        title: Text(title, style: const TextStyle(fontSize: 16)),
        subtitle: subtitle == null
            ? null
            : Text(subtitle!, style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
        value: notifier.value,
        activeTrackColor: AppColors.accent,
        onChanged: (v) => AppSettings.instance.setBool(notifier, v),
      );
}

class _ChoiceTile extends StatelessWidget {
  final String title;
  final ValueNotifier<int> notifier;
  final List<int> options;
  final String Function(int) format;
  final void Function(int)? onSelected;

  const _ChoiceTile({
    required this.title,
    required this.notifier,
    required this.options,
    required this.format,
    this.onSelected,
  });

  @override
  Widget build(BuildContext context) => ListTile(
        title: Text(title, style: const TextStyle(fontSize: 16)),
        subtitle: Text(format(notifier.value), style: const TextStyle(color: AppColors.accentLight)),
        trailing: const Icon(Icons.chevron_right, color: AppColors.textSecondary),
        onTap: () => showModalBottomSheet(
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
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                      child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                    ),
                    for (final o in options)
                      ListTile(
                        title: Text(format(o)),
                        trailing: o == notifier.value ? const Icon(Icons.check, color: AppColors.accentLight) : null,
                        onTap: () {
                          if (onSelected != null) {
                            onSelected!(o);
                          } else {
                            AppSettings.instance.setInt(notifier, o);
                          }
                          Navigator.pop(ctx);
                        },
                      ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  const _ActionTile({required this.icon, required this.title, required this.onTap, this.subtitle});

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(icon, color: AppColors.textSecondary),
        title: Text(title, style: const TextStyle(fontSize: 16)),
        subtitle: subtitle == null
            ? null
            : Text(subtitle!, style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
        onTap: onTap,
      );
}
