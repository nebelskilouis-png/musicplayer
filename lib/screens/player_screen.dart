import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import '../services/audio_player_service.dart';
import '../services/cover_service.dart';
import '../services/settings_service.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/output_indicator.dart';
import '../widgets/headset_toggle.dart';
import '../widgets/lyrics_view.dart';
import 'book_player_screen.dart';
import 'car_mode_screen.dart';
import 'lyrics_screen.dart';

/// Öffnet den Vollbild-Player mit Slide-Up-Animation (über Navigationsleiste).
void openPlayer(BuildContext context, {PlayMode? mode}) {
  final m = mode ?? AudioPlayerService.instance.mode.value;
  Navigator.of(context, rootNavigator: true).push(PageRouteBuilder(
    opaque: false, // beim Runterwischen sieht man die App dahinter
    transitionDuration: const Duration(milliseconds: 280),
    reverseTransitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (_, __, ___) => SwipeDownToClose(
      child: m == PlayMode.book ? const BookPlayerScreen() : const PlayerScreen(),
    ),
    transitionsBuilder: (_, anim, __, child) => SlideTransition(
      position: Tween(begin: const Offset(0, 1), end: Offset.zero)
          .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
      child: child,
    ),
  ));
}

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final AudioPlayerService s = AudioPlayerService.instance;
  double? _dragMs; // Slider-Wert während des Ziehens

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([s.changes, CoverService.instance.version]),
      builder: (context, _) {
        final track = s.currentTrack;
        if (track == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Kein Song aktiv')),
          );
        }
        final cover = CoverService.instance.pathFor(track) ?? s.currentCoverPath;
        return Scaffold(
          body: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [AppColors.headerTop, Color(0xFF0F1E47), Color(0xFF0B0B0B)],
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
                      // Cover nur so groß, dass die Steuerung bequem darunter passt.
                      // Freier Platz wird gleichmäßig oben und unten verteilt.
                      final size = max(120.0, min(box.maxWidth, min(box.maxHeight * 0.5, box.maxHeight - 380)));
                      return SingleChildScrollView(
                        physics: const ClampingScrollPhysics(),
                        child: Column(
                          children: [
                            // Seite 1: der Player, genau eine Bildschirmhöhe
                            SizedBox(
                              height: box.maxHeight,
                              child: Column(
                      children: [
                        _topBar(),
                        const OutputIndicator(), // Kopfhörer oder Lautsprecher?
                        const Spacer(),
                        _SwipeCover(
                              onNext: s.next,
                              onPrevious: s.previous,
                              child: Center(
                                child: Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(8),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withValues(alpha: 0.5),
                                        blurRadius: 40,
                                        offset: const Offset(0, 16),
                                      ),
                                    ],
                                  ),
                                  child: CoverArt(path: cover, size: size, radius: 8),
                                ),
                              ),
                            ),
                        const SizedBox(height: 28),
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(track.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                                  const SizedBox(height: 4),
                                  Text(track.artist,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 16, color: AppColors.textSecondary)),
                                ],
                              ),
                            ),
                            if (track.id != null)
                              ValueListenableBuilder<String>(
                                valueListenable: AppSettings.instance.favoriteIds,
                                builder: (context, _, __) {
                                  final fav = AppSettings.instance.isFavorite(track.id);
                                  return IconButton(
                                    tooltip: fav ? 'Kein Lieblingssong mehr' : 'Als Lieblingssong markieren',
                                    iconSize: 28,
                                    icon: Icon(fav ? Icons.favorite : Icons.favorite_border,
                                        color: fav ? AppColors.accentLight : AppColors.textSecondary),
                                    onPressed: () {
                                      HapticFeedback.lightImpact();
                                      AppSettings.instance.toggleFavorite(track.id!);
                                    },
                                  );
                                },
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _progress(),
                        _controls(),
                        _bottomRow(),
                        const Spacer(),
                        const SizedBox(height: 16),
                      ],
                    )),
                            // Darunter: Lyrics (wie bei Spotify, erst beim Runterscrollen sichtbar)
                            LyricsPreviewCard(onOpen: () => openLyrics(context)),
                            const SizedBox(height: 32),
                          ],
                        ),
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
    final name = s.currentPlaylistName.isEmpty ? 'Warteschlange' : s.currentPlaylistName;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Minimieren',
            icon: const Icon(Icons.keyboard_arrow_down, size: 32),
            onPressed: () => Navigator.pop(context),
          ),
          Expanded(
            child: Column(
              children: [
                const Text('WIEDERGABE AUS PLAYLIST',
                    style: TextStyle(fontSize: 10, color: Colors.white70, letterSpacing: 1.3)),
                const SizedBox(height: 2),
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }

  Widget _progress() {
    return StreamBuilder<Duration>(
      stream: s.player.positionStream,
      builder: (context, snap) {
        // Läuft gerade das Hörbuch, zeigt der Musik-Player die gemerkte Stelle.
        final active = s.musicActive;
        final duration = (active ? s.player.duration : null) ??
            Duration(milliseconds: s.currentTrack?.durationMs ?? 0);
        final maxMs = max(duration.inMilliseconds.toDouble(), 1.0);
        final live = active ? (snap.data ?? Duration.zero) : s.musicPosition;
        final posMs = (_dragMs ?? live.inMilliseconds.toDouble())
            .clamp(0.0, maxMs)
            .toDouble();
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
                  s.seekMusic(Duration(milliseconds: v.round()));
                  setState(() => _dragMs = null);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(formatDuration(Duration(milliseconds: posMs.round())),
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                  Text(formatDuration(duration),
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _toggle(IconData icon, bool active, String tooltip, VoidCallback onTap) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: tooltip,
          icon: Icon(icon, size: 26, color: active ? AppColors.accentLight : Colors.white70),
          onPressed: onTap,
        ),
        Container(
          width: 4,
          height: 4,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? AppColors.accentLight : Colors.transparent,
          ),
        ),
      ],
    );
  }

  Widget _controls() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          ValueListenableBuilder<bool>(
            valueListenable: s.shuffle,
            builder: (context, on, _) => _toggle(Icons.shuffle, on, 'Zufallswiedergabe', s.toggleShuffle),
          ),
          IconButton(
            tooltip: 'Vorheriger Titel',
            iconSize: 42,
            icon: const Icon(Icons.skip_previous, color: Colors.white),
            onPressed: s.previous,
          ),
          StreamBuilder<PlayerState>(
            stream: s.player.playerStateStream,
            builder: (context, snap) {
              final playing = (snap.data?.playing ?? false) && s.isMusicMode;
              return Tooltip(
                message: playing ? 'Pause' : 'Abspielen',
                child: Material(
                  color: Colors.white,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: s.togglePlay,
                    child: SizedBox(
                      width: 68,
                      height: 68,
                      child: Icon(playing ? Icons.pause : Icons.play_arrow, size: 40, color: Colors.black),
                    ),
                  ),
                ),
              );
            },
          ),
          IconButton(
            tooltip: 'Nächster Titel',
            iconSize: 42,
            icon: const Icon(Icons.skip_next, color: Colors.white),
            onPressed: s.next,
          ),
          ValueListenableBuilder<LoopMode>(
            valueListenable: s.loopMode,
            builder: (context, mode, _) => _toggle(
              mode == LoopMode.one ? Icons.repeat_one : Icons.repeat,
              mode != LoopMode.off,
              'Wiederholen',
              s.cycleLoopMode,
            ),
          ),
        ],
      ),
    );
  }

  Widget _bottomRow() {
    return Row(
      children: [
        IconButton(
          tooltip: 'Auto-Modus',
          icon: const Icon(Icons.directions_car_outlined, color: Colors.white70),
          onPressed: () => openCarMode(context),
        ),
        const HeadsetModeToggle(),
        const Spacer(),
        ListenableBuilder(
          listenable: Listenable.merge([s.sleepUntil, s.sleepAtTrackEnd]),
          builder: (context, _) => IconButton(
            tooltip: 'Schlaf-Timer',
            icon: Icon(Icons.bedtime_outlined, color: s.sleepActive ? AppColors.accentLight : Colors.white70),
            onPressed: _showSleepTimer,
          ),
        ),
        IconButton(
          tooltip: 'Warteschlange',
          icon: const Icon(Icons.queue_music, color: Colors.white70),
          onPressed: _showQueue,
        ),
      ],
    );
  }

  void _showSleepTimer() {
    String status() {
      if (s.sleepAtTrackEnd.value) return 'Stoppt am Ende des Songs';
      final until = s.sleepUntil.value;
      if (until == null) return 'Aus';
      final left = until.difference(DateTime.now());
      return 'Stoppt in ${left.inMinutes + 1} Min.';
    }

    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('Schlaf-Timer', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  ),
                  Text(status(), style: const TextStyle(color: AppColors.textSecondary)),
                ],
              ),
            ),
            for (final m in [5, 15, 30, 45, 60])
              SheetItem(
                icon: Icons.timer_outlined,
                label: '$m Minuten',
                onTap: () {
                  s.setSleepTimer(Duration(minutes: m));
                  Navigator.pop(ctx);
                },
              ),
            SheetItem(
              icon: Icons.music_off_outlined,
              label: 'Ende des Songs',
              onTap: () {
                s.setSleepAtTrackEnd();
                Navigator.pop(ctx);
              },
            ),
            if (s.sleepActive)
              SheetItem(
                icon: Icons.close,
                label: 'Timer ausschalten',
                color: Colors.redAccent,
                onTap: () {
                  s.setSleepTimer(null);
                  Navigator.pop(ctx);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showQueue() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.background,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        builder: (ctx, scrollController) => ValueListenableBuilder<int>(
          valueListenable: s.changes,
          builder: (ctx, _, __) {
            final current = s.currentTrack;
            final len = s.currentQueue.length;
            final cur = s.currentIndex;
            final name = s.currentPlaylistName.isEmpty ? 'Warteschlange' : s.currentPlaylistName;

            // Reihenfolge, in der es weitergeht. -1 = Marke "Hier geht's weiter"
            final items = <int>[
              -1,
              for (int i = cur + 1; i < len; i++) i,
              for (int i = 0; i < cur && i < len; i++) i,
            ];

            void onReorder(int oldIndex, int newIndex) {
              if (oldIndex < newIndex) newIndex -= 1;
              final list = List<int>.of(items);
              final moved = list.removeAt(oldIndex);
              list.insert(newIndex, moved);
              final m = list.indexOf(-1);
              // Alles unter der Marke kommt als Nächstes, alles darüber ans Ende
              final order = [...list.sublist(m + 1), ...list.sublist(0, m)];
              s.setUpcoming([for (final i in order) s.currentQueue[i]]);
            }

            return ReorderableListView.builder(
              scrollController: scrollController,
              buildDefaultDragHandles: false,
              padding: const EdgeInsets.only(bottom: 24),
              header: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 10),
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Text('Jetzt läuft', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  ),
                  if (current != null) _queueTile(cur, highlight: true),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 2),
                    child: Text('Als Nächstes aus: $name',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      'Songs am ≡ ziehen zum Verschieben. Die blaue Marke ziehen, um woanders weiterzumachen. '
                      'Gilt nur, bis du eine Playlist neu startest.',
                      style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                    ),
                  ),
                ],
              ),
              itemCount: items.length,
              onReorder: onReorder,
              itemBuilder: (ctx, i) {
                final idx = items[i];
                if (idx == -1) return _continueMarker(i);
                return Material(
                  key: ValueKey('q_$idx'),
                  color: AppColors.background,
                  child: _queueTile(
                    idx,
                    onTap: () => s.playIndex(idx),
                    onRemove: () => s.removeFromQueue(idx),
                    dragIndex: i,
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  /// Ziehbare Marke: Ab hier geht es nach dem aktuellen Song weiter.
  Widget _continueMarker(int listIndex) {
    return Container(
      key: const ValueKey('continue_marker'),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.25),
        border: Border.all(color: AppColors.accentLight),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ReorderableDragStartListener(
        index: listIndex,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.south, color: AppColors.accentLight, size: 20),
              SizedBox(width: 10),
              Expanded(
                child: Text('Hier geht\'s weiter',
                    style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.accentLight)),
              ),
              Icon(Icons.drag_handle, color: AppColors.accentLight),
            ],
          ),
        ),
      ),
    );
  }

  Widget _queueTile(int idx,
      {bool highlight = false, VoidCallback? onTap, VoidCallback? onRemove, int? dragIndex}) {
    final t = s.currentQueue[idx];
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
        child: Row(
          children: [
            CoverArt(path: CoverService.instance.pathFor(t), size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 16, color: highlight ? AppColors.accentLight : Colors.white)),
                  const SizedBox(height: 2),
                  Text(t.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                ],
              ),
            ),
            if (onRemove != null)
              IconButton(
                tooltip: 'Aus Warteschlange entfernen',
                icon: const Icon(Icons.remove_circle_outline, color: AppColors.textSecondary),
                onPressed: onRemove,
              ),
            if (dragIndex != null)
              ReorderableDragStartListener(
                index: dragIndex,
                child: const Padding(
                  padding: EdgeInsets.all(10),
                  child: Icon(Icons.drag_handle, color: AppColors.textSecondary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Cover zum Wischen: links = nächster Song, rechts = vorheriger.
class _SwipeCover extends StatefulWidget {
  final Widget child;
  final VoidCallback onNext;
  final VoidCallback onPrevious;

  const _SwipeCover({required this.child, required this.onNext, required this.onPrevious});

  @override
  State<_SwipeCover> createState() => _SwipeCoverState();
}

class _SwipeCoverState extends State<_SwipeCover> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 180));
  Animation<double>? _anim;
  double _dx = 0;
  double _width = 300;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() {
      final a = _anim;
      if (a != null) setState(() => _dx = a.value);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _animate(double from, double to) async {
    _anim = Tween<double>(begin: from, end: to).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    _ctrl.reset();
    await _ctrl.forward();
  }

  Future<void> _onEnd(DragEndDetails d) async {
    final w = _width;
    final v = d.primaryVelocity ?? 0;
    if (_dx < -w * 0.25 || v < -700) {
      await _animate(_dx, -w);
      widget.onNext();
      await _animate(w, 0);
    } else if (_dx > w * 0.25 || v > 700) {
      await _animate(_dx, w);
      widget.onPrevious();
      await _animate(-w, 0);
    } else {
      await _animate(_dx, 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      _width = c.maxWidth > 0 ? c.maxWidth : 300;
      final fade = (1 - (_dx.abs() / _width) * 0.6).clamp(0.0, 1.0).toDouble();
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => _ctrl.stop(),
        onHorizontalDragUpdate: (d) => setState(() => _dx += d.delta.dx),
        onHorizontalDragEnd: _onEnd,
        child: Opacity(
          opacity: fade,
          child: Transform.translate(offset: Offset(_dx, 0), child: widget.child),
        ),
      );
    });
  }
}
