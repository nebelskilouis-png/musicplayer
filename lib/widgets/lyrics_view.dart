import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../models/track.dart';
import '../services/audio_player_service.dart';
import '../services/lyrics_service.dart';

/// Lädt die Lyrics des aktuellen Songs und lädt neu, wenn der Song wechselt.
class CurrentTrackLyrics extends StatefulWidget {
  final Widget Function(BuildContext context, Track? track, Lyrics? lyrics, bool loading, VoidCallback reload)
      builder;

  const CurrentTrackLyrics({super.key, required this.builder});

  @override
  State<CurrentTrackLyrics> createState() => _CurrentTrackLyricsState();
}

class _CurrentTrackLyricsState extends State<CurrentTrackLyrics> {
  final AudioPlayerService s = AudioPlayerService.instance;
  Track? _track;
  Lyrics? _lyrics;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    s.changes.addListener(_onChange);
    _load();
  }

  @override
  void dispose() {
    s.changes.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    final t = s.currentTrack;
    if (t?.filePath != _track?.filePath) _load();
  }

  Future<void> _load({bool force = false}) async {
    final t = s.currentTrack;
    setState(() {
      _track = t;
      _loading = true;
    });
    if (t == null) {
      setState(() {
        _lyrics = null;
        _loading = false;
      });
      return;
    }
    final l = await LyricsService.instance.getLyrics(t, forceOnline: force);
    if (!mounted || _track?.filePath != t.filePath) return;
    setState(() {
      _lyrics = l;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _track, _lyrics, _loading, () => _load(force: true));
}

/// Zeigt Lyrics. Zeitgenaue Lyrics scrollen automatisch mit dem Song mit.
/// [interactive]: selbst scrollen + Zeile antippen zum Springen (Vollbild).
class LyricsView extends StatefulWidget {
  final Lyrics lyrics;
  final double fontSize;
  final bool interactive;
  final EdgeInsets padding;
  final double alignment; // wo die aktuelle Zeile steht (0 = oben, 1 = unten)
  final Widget? footer;

  const LyricsView({
    super.key,
    required this.lyrics,
    this.fontSize = 24,
    this.interactive = true,
    this.padding = const EdgeInsets.fromLTRB(24, 24, 24, 160),
    this.alignment = 0.35,
    this.footer,
  });

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  final AudioPlayerService s = AudioPlayerService.instance;
  final ItemScrollController _scroll = ItemScrollController();
  int _currentLine = -2;
  DateTime _lastUserScroll = DateTime(2000);

  int _lineFor(Duration pos) {
    final lines = widget.lyrics.synced;
    int idx = -1;
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].time <= pos + const Duration(milliseconds: 250)) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  void _follow(int line) {
    if (line == _currentLine) return;
    _currentLine = line;
    // Nach eigenem Scrollen 4 Sekunden nicht automatisch mitscrollen
    if (DateTime.now().difference(_lastUserScroll).inSeconds < 4) return;
    if (line >= 0 && _scroll.isAttached) {
      _scroll.scrollTo(
        index: line,
        alignment: widget.alignment,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.lyrics;
    if (!l.isSynced) {
      final text = Text(l.plain,
          style: TextStyle(fontSize: widget.fontSize * 0.85, height: 1.5, fontWeight: FontWeight.w700));
      if (!widget.interactive) {
        return Padding(padding: widget.padding, child: ClipRect(child: text));
      }
      return SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        padding: widget.padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [text, if (widget.footer != null) widget.footer!],
        ),
      );
    }

    return NotificationListener<UserScrollNotification>(
      onNotification: (_) {
        _lastUserScroll = DateTime.now();
        return false;
      },
      child: StreamBuilder<Duration>(
        stream: s.player.positionStream,
        builder: (context, snap) {
          final pos = s.musicActive ? (snap.data ?? Duration.zero) : s.musicPosition;
          final line = _lineFor(pos);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _follow(line);
          });
          final count = l.synced.length + (widget.footer != null ? 1 : 0);
          return ScrollablePositionedList.builder(
            itemScrollController: _scroll,
            physics: widget.interactive ? const ClampingScrollPhysics() : const NeverScrollableScrollPhysics(),
            initialScrollIndex: line > 0 ? line : 0,
            initialAlignment: widget.alignment,
            padding: widget.padding,
            itemCount: count,
            itemBuilder: (context, i) {
              if (i >= l.synced.length) return widget.footer!;
              final ln = l.synced[i];
              final isCur = i == line;
              final past = i < line;
              final textWidget = AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                style: TextStyle(
                  fontSize: widget.fontSize,
                  height: 1.3,
                  fontWeight: FontWeight.w800,
                  color: isCur ? Colors.white : (past ? Colors.white38 : Colors.white60),
                ),
                child: Text(ln.text.isEmpty ? '♪' : ln.text),
              );
              final padded = Padding(padding: EdgeInsets.symmetric(vertical: widget.fontSize * 0.3), child: textWidget);
              if (!widget.interactive) return padded;
              return InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => s.seekMusic(ln.time),
                child: padded,
              );
            },
          );
        },
      ),
    );
  }
}

/// Lyrics-Karte unter dem Player (wie bei Spotify). Antippen = Vollbild.
class LyricsPreviewCard extends StatelessWidget {
  final VoidCallback onOpen;
  const LyricsPreviewCard({super.key, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return CurrentTrackLyrics(
      builder: (context, track, lyrics, loading, reload) {
        Widget body;
        if (loading) {
          body = const Center(
              child: SizedBox(
                  width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)));
        } else if (lyrics == null) {
          body = const Center(
            child: Text('Keine Lyrics gefunden', style: TextStyle(color: Colors.white70, fontSize: 15)),
          );
        } else {
          body = IgnorePointer(
            child: LyricsView(
              key: ValueKey(track?.filePath),
              lyrics: lyrics,
              fontSize: 20,
              interactive: false,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 140),
              alignment: 0.25,
            ),
          );
        }
        return Material(
          color: const Color(0xFF2347A8),
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onOpen,
            child: SizedBox(
              height: 380,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text('Lyrics', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                        ),
                        if (lyrics != null)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.black26,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('Vollbild', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                                SizedBox(width: 4),
                                Icon(Icons.open_in_full, size: 14),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ShaderMask(
                      // unten weich ausblenden
                      shaderCallback: (r) => const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.white, Colors.white, Colors.transparent],
                        stops: [0, 0.8, 1],
                      ).createShader(r),
                      blendMode: BlendMode.dstIn,
                      child: body,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
