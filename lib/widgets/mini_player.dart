import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import '../services/audio_player_service.dart';
import '../services/audiobook_service.dart';
import '../services/cover_service.dart';
import '../services/settings_service.dart';
import '../screens/player_screen.dart';
import '../theme.dart';
import 'common.dart';

/// Kleiner Player über der Navigationsleiste (wie bei Spotify).
/// [show]: welche Seite angezeigt wird. Musik-Tab = Musik, Hörbuch-Tab = Hörbuch,
/// null = das, was gerade läuft. Die nicht laufende Seite zeigt ihren gemerkten Fortschritt.
class MiniPlayer extends StatelessWidget {
  final PlayMode? show;

  const MiniPlayer({super.key, this.show});

  @override
  Widget build(BuildContext context) {
    final s = AudioPlayerService.instance;
    final a = AudiobookService.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([s.changes, s.mode, a.changes, CoverService.instance.version]),
      builder: (context, _) {
        final want = show ?? s.mode.value;
        if (want == PlayMode.book) {
          if (a.current != null) return _bookBar(context, a);
          if (show == PlayMode.book) return const SizedBox.shrink();
        }
        final track = s.currentTrack;
        if (track == null) return const SizedBox.shrink();
        final active = s.musicActive;
        return _shell(
          context,
          mode: PlayMode.music,
          cover: CoverService.instance.pathFor(track) ?? s.currentCoverPath,
          coverIcon: Icons.music_note,
          title: track.title,
          subtitle: track.artist,
          progress: active
              ? const TrackProgressBar(height: 2)
              : TrackProgressBar(height: 2, staticValue: _ratio(s.musicPosition.inMilliseconds, track.durationMs)),
          buttons: [
            IconButton(
              tooltip: 'Vorheriger Titel',
              icon: const Icon(Icons.skip_previous, color: Colors.white),
              onPressed: s.previous,
            ),
            _playButton(s.player, s.togglePlay, () => s.musicActive),
            IconButton(
              tooltip: 'Nächster Titel',
              icon: const Icon(Icons.skip_next, color: Colors.white),
              onPressed: s.next,
            ),
          ],
        );
      },
    );
  }

  static double _ratio(int pos, int total) => total > 0 ? (pos / total).clamp(0.0, 1.0).toDouble() : 0.0;

  Widget _bookBar(BuildContext context, AudiobookService a) {
    final b = a.current!;
    final st = AppSettings.instance;
    final active = a.bookActive;
    return _shell(
      context,
      mode: PlayMode.book,
      cover: b.coverPath,
      coverIcon: Icons.menu_book,
      title: b.title,
      subtitle: a.currentFile?.name ?? '',
      progress: active
          ? const TrackProgressBar(height: 2)
          : TrackProgressBar(
              height: 2,
              staticValue: _ratio(a.filePosition.inMilliseconds, a.currentFile?.durationMs ?? 0),
            ),
      buttons: [
        IconButton(
          tooltip: '${st.bookSkipBack.value} s zurück',
          icon: SkipIcon(forward: false, seconds: st.bookSkipBack.value, size: 28),
          onPressed: a.skipBack,
        ),
        _playButton(a.player, a.togglePlay, () => a.bookActive),
        IconButton(
          tooltip: '${st.bookSkipForward.value} s vor',
          icon: SkipIcon(forward: true, seconds: st.bookSkipForward.value, size: 28),
          onPressed: a.skipForward,
        ),
      ],
    );
  }

  Widget _playButton(AudioPlayer player, VoidCallback onTap, bool Function() isActive) {
    return StreamBuilder<PlayerState>(
      stream: player.playerStateStream,
      builder: (context, snap) {
        final playing = (snap.data?.playing ?? false) && isActive();
        return IconButton(
          tooltip: playing ? 'Pause' : 'Abspielen',
          iconSize: 32,
          icon: Icon(playing ? Icons.pause : Icons.play_arrow, color: Colors.white),
          onPressed: onTap,
        );
      },
    );
  }

  Widget _shell(
    BuildContext context, {
    required PlayMode mode,
    required String? cover,
    required IconData coverIcon,
    required String title,
    required String subtitle,
    required Widget progress,
    required List<Widget> buttons,
  }) {
    final s = AudioPlayerService.instance;
    final a = AudiobookService.instance;
    return _SwipeBar(
      onNext: () {
        if (mode == PlayMode.book) {
          if (a.fileIndex < a.files.length - 1) a.jumpToFile(a.fileIndex + 1);
        } else {
          s.next();
        }
      },
      onPrevious: () {
        if (mode == PlayMode.book) {
          if (a.fileIndex > 0) a.jumpToFile(a.fileIndex - 1);
        } else {
          s.previousTrack(); // direkt vorheriger Song, ohne 4-Sekunden-Regel
        }
      },
      child: Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: Material(
        color: AppColors.miniPlayer,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => openPlayer(context, mode: mode),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 4, 6),
                child: Row(
                  children: [
                    CoverArt(path: cover, size: 42, radius: 4, icon: coverIcon),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 2),
                          Text(subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                        ],
                      ),
                    ),
                    ...buttons,
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: progress,
              ),
            ],
          ),
        ),
      ),
    ),
    );
  }
}

/// Mini-Player nach links/rechts wischen: links = nächster, rechts = vorheriger.
class _SwipeBar extends StatefulWidget {
  final Widget child;
  final VoidCallback onNext;
  final VoidCallback onPrevious;

  const _SwipeBar({required this.child, required this.onNext, required this.onPrevious});

  @override
  State<_SwipeBar> createState() => _SwipeBarState();
}

class _SwipeBarState extends State<_SwipeBar> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 170));
  Animation<double>? _anim;
  double _dx = 0;
  double _width = 400;

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
      HapticFeedback.selectionClick();
      await _animate(_dx, -w); // raus nach links
      widget.onNext();
      await _animate(w, 0); // neuer Song kommt von rechts
    } else if (_dx > w * 0.25 || v > 700) {
      HapticFeedback.selectionClick();
      await _animate(_dx, w); // raus nach rechts
      widget.onPrevious();
      await _animate(-w, 0); // vorheriger Song kommt von links
    } else {
      await _animate(_dx, 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      _width = c.maxWidth > 0 ? c.maxWidth : 400;
      return ClipRect(
        child: GestureDetector(
          onHorizontalDragStart: (_) => _ctrl.stop(),
          onHorizontalDragUpdate: (d) => setState(() => _dx += d.delta.dx),
          onHorizontalDragEnd: _onEnd,
          child: Transform.translate(offset: Offset(_dx, 0), child: widget.child),
        ),
      );
    });
  }
}

/// Dünner Fortschrittsbalken. Ohne [staticValue] live vom Player,
/// mit [staticValue] fester Wert (gemerkter Fortschritt).
class TrackProgressBar extends StatelessWidget {
  final double height;
  final Color color;
  final Color background;
  final double? staticValue;

  const TrackProgressBar({
    super.key,
    this.height = 2,
    this.color = Colors.white,
    this.background = Colors.white24,
    this.staticValue,
  });

  Widget _bar(double v) => ClipRRect(
        borderRadius: BorderRadius.circular(height / 2),
        child: LinearProgressIndicator(
          value: v,
          minHeight: height,
          backgroundColor: background,
          color: color,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final fixed = staticValue;
    if (fixed != null) return _bar(fixed);
    final s = AudioPlayerService.instance;
    return StreamBuilder<Duration>(
      stream: s.player.positionStream,
      builder: (context, snap) {
        final pos = snap.data ?? Duration.zero;
        final dur = s.player.duration ?? Duration.zero;
        final v = dur.inMilliseconds > 0 ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0).toDouble() : 0.0;
        return _bar(v);
      },
    );
  }
}
