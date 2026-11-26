import 'dart:math';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import '../services/audio_player_service.dart';
import '../services/audiobook_service.dart';
import '../services/settings_service.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/output_indicator.dart';
import '../widgets/headset_toggle.dart';
import 'car_mode_screen.dart';

const speedOptions = [50, 75, 80, 90, 100, 110, 120, 125, 130, 140, 150, 175, 200, 225, 250, 275, 300];

String formatSleepRemaining(Duration d) {
  final m = d.inMinutes;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// Hörbuch-Player im Stil von Audible.
class BookPlayerScreen extends StatefulWidget {
  const BookPlayerScreen({super.key});

  @override
  State<BookPlayerScreen> createState() => _BookPlayerScreenState();
}

class _BookPlayerScreenState extends State<BookPlayerScreen> {
  final AudiobookService a = AudiobookService.instance;
  double? _dragMs;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([a.changes, AppSettings.instance.listenable, AudioPlayerService.instance.mode]),
      builder: (context, _) {
        final b = a.current;
        final f = a.currentFile;
        if (b == null || f == null) {
          return Scaffold(appBar: AppBar(), body: const Center(child: Text('Kein Hörbuch aktiv')));
        }
        return Scaffold(
          body: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF1B2F6E), Color(0xFF0E1A3D), Color(0xFF0B0B0B)],
                stops: [0, 0.5, 1],
              ),
            ),
            child: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: LayoutBuilder(builder: (context, box) {
                      final size = max(120.0, min(box.maxWidth, min(box.maxHeight * 0.45, box.maxHeight - 420)));
                      return Column(
                      children: [
                        _topBar(),
                        const OutputIndicator(), // Kopfhörer oder Lautsprecher?
                        const Spacer(),
                        Center(
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8),
                                  boxShadow: [
                                    BoxShadow(
                                        color: Colors.black.withValues(alpha: 0.5),
                                        blurRadius: 40,
                                        offset: const Offset(0, 16)),
                                  ],
                                ),
                                child: CoverArt(path: b.coverPath, size: size, radius: 8, icon: Icons.menu_book),
                              ),
                            ),
                        const SizedBox(height: 24),
                        Text(b.title,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                        if (b.author.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(b.author,
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14, color: AppColors.textSecondary)),
                        ],
                        const SizedBox(height: 6),
                        Text('${f.name}  •  Kapitel ${a.fileIndex + 1} von ${a.files.length}',
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13, color: AppColors.accentLight)),
                        const SizedBox(height: 8),
                        _progress(b, f),
                        _controls(),
                        const SizedBox(height: 8),
                        _bottomRow(),
                        const Spacer(),
                        const SizedBox(height: 16),
                      ],
                    );
                    }),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Minimieren',
            icon: const Icon(Icons.keyboard_arrow_down, size: 32),
            onPressed: () => Navigator.pop(context),
          ),
          const Expanded(
            child: Text('HÖRBUCH',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Colors.white70, letterSpacing: 1.5)),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }

  Widget _progress(Book b, BookFile f) {
    return StreamBuilder<Duration>(
      stream: a.player.positionStream,
      builder: (context, snap) {
        final active = a.isActive;
        final live = active ? (snap.data ?? Duration.zero) : Duration(milliseconds: b.positionMs);
        final duration = (active ? a.player.duration : null) ?? Duration(milliseconds: f.durationMs);
        final maxMs = max(duration.inMilliseconds.toDouble(), 1.0);
        final posMs = (_dragMs ?? live.inMilliseconds.toDouble()).clamp(0.0, maxMs).toDouble();
        final left = Duration(milliseconds: max(0, duration.inMilliseconds - posMs.round()));

        int before = 0;
        for (int i = 0; i < a.fileIndex && i < a.files.length; i++) {
          before += a.files[i].durationMs;
        }
        final remainingBook = max(0, a.totalMs - before - posMs.round());
        final adjusted = (remainingBook / a.speed).round();

        return Column(
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: Colors.white,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
                overlayColor: Colors.white24,
              ),
              child: Slider(
                value: posMs,
                min: 0,
                max: maxMs,
                onChanged: (v) => setState(() => _dragMs = v),
                onChangeEnd: (v) {
                  a.seekInFile(Duration(milliseconds: v.round()));
                  setState(() => _dragMs = null);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Text(formatDuration(Duration(milliseconds: posMs.round())),
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                  Expanded(
                    child: Text(
                      a.totalMs > 0 ? 'Noch ${formatTotal(adjusted)}' : '',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text('-${formatDuration(left)}',
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _controls() {
    final st = AppSettings.instance;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            tooltip: 'Vorheriges Kapitel',
            iconSize: 32,
            icon: const Icon(Icons.skip_previous, color: Colors.white70),
            onPressed: a.previousChapter,
          ),
          IconButton(
            tooltip: '${st.bookSkipBack.value} s zurück',
            icon: SkipIcon(forward: false, seconds: st.bookSkipBack.value, size: 44),
            onPressed: a.skipBack,
          ),
          StreamBuilder<PlayerState>(
            stream: a.player.playerStateStream,
            builder: (context, snap) {
              final playing = (snap.data?.playing ?? false) && a.isActive;
              return Material(
                color: Colors.white,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: a.togglePlay,
                  child: SizedBox(
                    width: 72,
                    height: 72,
                    child: Icon(playing ? Icons.pause : Icons.play_arrow, size: 42, color: Colors.black),
                  ),
                ),
              );
            },
          ),
          IconButton(
            tooltip: '${st.bookSkipForward.value} s vor',
            icon: SkipIcon(forward: true, seconds: st.bookSkipForward.value, size: 44),
            onPressed: a.skipForward,
          ),
          IconButton(
            tooltip: 'Nächstes Kapitel',
            iconSize: 32,
            icon: const Icon(Icons.skip_next, color: Colors.white70),
            onPressed: a.nextChapter,
          ),
        ],
      ),
    );
  }

  Widget _bottomButton({required Widget icon, required String label, required VoidCallback onTap, bool active = false}) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(height: 28, child: Center(child: icon)),
              const SizedBox(height: 4),
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: active ? AppColors.accentLight : AppColors.textSecondary)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bottomRow() {
    final st = AppSettings.instance;
    return Row(
      children: [
        _bottomButton(
          icon: Text(formatSpeed(st.bookSpeedPct.value),
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: st.bookSpeedPct.value != 100 ? AppColors.accentLight : Colors.white)),
          label: 'Tempo',
          active: st.bookSpeedPct.value != 100,
          onTap: () => showSpeedSheet(context),
        ),
        ValueListenableBuilder<Duration?>(
          valueListenable: a.sleepRemaining,
          builder: (context, rem, _) {
            final m = a.sleepSetting;
            final on = m != 0;
            final label = m == -1 ? 'Kapitelende' : (rem != null ? formatSleepRemaining(rem) : 'Schlaf-Timer');
            return _bottomButton(
              icon: Icon(on ? Icons.bedtime : Icons.bedtime_outlined,
                  color: on ? AppColors.accentLight : Colors.white, size: 26),
              label: label,
              active: on,
              onTap: () => showBookSleepSheet(context),
            );
          },
        ),
        _bottomButton(
          icon: const Icon(Icons.format_list_bulleted, color: Colors.white, size: 26),
          label: 'Kapitel',
          onTap: _showChapters,
        ),
        _bottomButton(
          icon: const Icon(Icons.directions_car_outlined, color: Colors.white, size: 26),
          label: 'Auto',
          onTap: () => openCarMode(context),
        ),
        const HeadsetModeToggle(),
      ],
    );
  }

  void _showChapters() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.background,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        builder: (ctx, scroll) => ListenableBuilder(
          listenable: a.changes,
          builder: (ctx, _) => ListView.builder(
            controller: scroll,
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: a.files.length + 1,
            itemBuilder: (ctx, i) {
              if (i == 0) {
                return const Padding(
                  padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
                  child: Text('Kapitel', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                );
              }
              final idx = i - 1;
              final f = a.files[idx];
              final cur = idx == a.fileIndex;
              return InkWell(
                onTap: () {
                  a.jumpToFile(idx);
                  Navigator.pop(ctx);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 36,
                        child: cur
                            ? const Icon(Icons.graphic_eq, color: AppColors.accentLight, size: 18)
                            : Text('${idx + 1}', style: const TextStyle(color: AppColors.textSecondary)),
                      ),
                      Expanded(
                        child: Text(f.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 15, color: cur ? AppColors.accentLight : Colors.white)),
                      ),
                      Text(formatDuration(Duration(milliseconds: f.durationMs)),
                          style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Tempo-Regler mit den letzten 3 Tempi als Schnellwahl.
void showSpeedSheet(BuildContext context) {
  final a = AudiobookService.instance;
  final st = AppSettings.instance;
  int value = st.bookSpeedPct.value;
  showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => SafeArea(
      child: StatefulBuilder(
        builder: (ctx, setSheet) {
          final recent = st.bookSpeedRecentList;
          Widget stepButton(IconData icon, int delta) => IconButton(
                iconSize: 32,
                icon: Icon(icon, color: Colors.white),
                onPressed: () {
                  final v = (value + delta).clamp(50, 300);
                  setSheet(() => value = v);
                  a.setSpeed(v);
                },
              );
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Tempo', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Text(formatSpeed(value),
                    style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w900, color: AppColors.accentLight)),
                Row(
                  children: [
                    stepButton(Icons.remove_circle_outline, -5),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(ctx).copyWith(
                          trackHeight: 6,
                          activeTrackColor: AppColors.accentLight,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: Colors.white,
                          overlayColor: Colors.white24,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 11),
                        ),
                        child: Slider(
                          value: value.toDouble(),
                          min: 50,
                          max: 300,
                          divisions: 50, // Schritte von 0,05x
                          onChanged: (v) {
                            setSheet(() => value = v.round());
                            a.previewSpeed(value);
                          },
                          onChangeEnd: (v) => a.setSpeed(v.round()),
                        ),
                      ),
                    ),
                    stepButton(Icons.add_circle_outline, 5),
                  ],
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 48),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('0,5x', style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                      Text('3,0x', style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Zuletzt benutzt',
                      style: TextStyle(fontSize: 13, color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    for (final r in recent)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Material(
                            color: r == value ? AppColors.accent : const Color(0xFF3A3A3A),
                            shape: const StadiumBorder(),
                            child: InkWell(
                              customBorder: const StadiumBorder(),
                              onTap: () {
                                setSheet(() => value = r);
                                a.setSpeed(r);
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                child: Center(
                                  child: Text(formatSpeed(r),
                                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    ),
  );
}

/// Schlaf-Timer für Hörbücher.
void showBookSleepSheet(BuildContext context) {
  final a = AudiobookService.instance;
  final st = AppSettings.instance;
  showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: ValueListenableBuilder<int>(
        valueListenable: st.bookSleepMinutes,
        builder: (ctx, cur, _) {
          Widget option(int value, String label, IconData icon) => ListTile(
                leading: Icon(icon, color: value == cur ? AppColors.accentLight : AppColors.textSecondary),
                title: Text(label,
                    style: TextStyle(fontSize: 16, color: value == cur ? AppColors.accentLight : Colors.white)),
                trailing: value == cur ? const Icon(Icons.check, color: AppColors.accentLight) : null,
                onTap: () {
                  a.setSleep(value);
                  Navigator.pop(ctx);
                },
              );
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 20, 16, 4),
                  child: Text('Schlaf-Timer', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'Bleibt eingestellt, bis du „Kein Schlaf-Timer“ wählst.'
                    '${st.shakeToExtend.value ? ' Handy schütteln verlängert den Timer.' : ''}',
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                  ),
                ),
                if (cur > 0)
                  ListTile(
                    leading: const Icon(Icons.more_time, color: AppColors.accentLight),
                    title: const Text('Jetzt verlängern', style: TextStyle(fontSize: 16)),
                    onTap: () {
                      a.extendSleep();
                      Navigator.pop(ctx);
                    },
                  ),
                option(0, 'Kein Schlaf-Timer', Icons.close),
                for (final m in st.sleepPresetList) option(m, '$m Minuten', Icons.timer_outlined),
                option(-1, 'Ende des Kapitels', Icons.bookmark_outline),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    ),
  );
}
