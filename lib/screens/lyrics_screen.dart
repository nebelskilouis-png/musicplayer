import 'dart:math';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import '../services/audio_player_service.dart';
import '../widgets/common.dart';
import '../widgets/lyrics_view.dart';

/// Vollbild-Lyrics öffnen (von unten reinschieben, nach unten wegwischen zum Schließen).
void openLyrics(BuildContext context) {
  Navigator.of(context, rootNavigator: true).push(PageRouteBuilder(
    opaque: false,
    transitionDuration: const Duration(milliseconds: 260),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (_, __, ___) => const SwipeDownToClose(child: LyricsScreen()),
    transitionsBuilder: (_, anim, __, child) => SlideTransition(
      position: Tween(begin: const Offset(0, 1), end: Offset.zero)
          .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
      child: child,
    ),
  ));
}

const _lyricsBg = Color(0xFF1B3A8F);

/// Lyrics im Vollbild wie bei Spotify: scrollen automatisch mit, Zeile antippen = dorthin springen,
/// unten Fortschrittsbalken und Play/Pause.
class LyricsScreen extends StatefulWidget {
  const LyricsScreen({super.key});

  @override
  State<LyricsScreen> createState() => _LyricsScreenState();
}

class _LyricsScreenState extends State<LyricsScreen> {
  final AudioPlayerService s = AudioPlayerService.instance;
  double? _dragMs;

  @override
  Widget build(BuildContext context) {
    return CurrentTrackLyrics(
      builder: (context, track, lyrics, loading, reload) {
        return Scaffold(
          backgroundColor: _lyricsBg,
          body: SafeArea(
            child: Column(
              children: [
                // Kopf
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Schließen',
                        icon: const Icon(Icons.keyboard_arrow_down, size: 32),
                        onPressed: () => Navigator.pop(context),
                      ),
                      Expanded(
                        child: Column(
                          children: [
                            Text(track?.title ?? 'Lyrics',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                            Text(track?.artist ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13, color: Colors.white70)),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Online neu suchen',
                        icon: const Icon(Icons.refresh),
                        onPressed: loading ? null : reload,
                      ),
                    ],
                  ),
                ),
                // Lyrics
                Expanded(
                  child: loading
                      ? const Center(child: CircularProgressIndicator(color: Colors.white))
                      : lyrics == null
                          ? _buildNone(reload)
                          : ShaderMask(
                              shaderCallback: (r) => const LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
                                stops: [0, 0.06, 0.9, 1],
                              ).createShader(r),
                              blendMode: BlendMode.dstIn,
                              child: LyricsView(
                                key: ValueKey(track?.filePath),
                                lyrics: lyrics,
                                fontSize: 26,
                                interactive: true,
                                padding: const EdgeInsets.fromLTRB(24, 32, 24, 120),
                                footer: Padding(
                                  padding: const EdgeInsets.only(top: 32),
                                  child: Text(
                                    'Quelle: ${lyrics.source}${lyrics.isSynced ? '' : ' (ohne Zeitangaben)'}',
                                    style: const TextStyle(fontSize: 12, color: Colors.white54),
                                  ),
                                ),
                              ),
                            ),
                ),
                // Steuerung
                _controls(),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _controls() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          StreamBuilder<Duration>(
            stream: s.player.positionStream,
            builder: (context, snap) {
              final active = s.musicActive;
              final duration = (active ? s.player.duration : null) ??
                  Duration(milliseconds: s.currentTrack?.durationMs ?? 0);
              final maxMs = max(duration.inMilliseconds.toDouble(), 1.0);
              final live = active ? (snap.data ?? Duration.zero) : s.musicPosition;
              final posMs = (_dragMs ?? live.inMilliseconds.toDouble()).clamp(0.0, maxMs).toDouble();
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
                            style: const TextStyle(color: Colors.white70, fontSize: 12)),
                        Text(formatDuration(duration), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: 'Vorheriger Titel',
                iconSize: 36,
                icon: const Icon(Icons.skip_previous, color: Colors.white),
                onPressed: s.previous,
              ),
              const SizedBox(width: 20),
              StreamBuilder<PlayerState>(
                stream: s.player.playerStateStream,
                builder: (context, snap) {
                  final playing = (snap.data?.playing ?? false) && s.musicActive;
                  return Material(
                    color: Colors.white,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: s.togglePlay,
                      child: SizedBox(
                        width: 60,
                        height: 60,
                        child: Icon(playing ? Icons.pause : Icons.play_arrow, size: 36, color: Colors.black),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(width: 20),
              IconButton(
                tooltip: 'Nächster Titel',
                iconSize: 36,
                icon: const Icon(Icons.skip_next, color: Colors.white),
                onPressed: s.next,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNone(VoidCallback reload) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.notes, size: 56, color: Colors.white38),
            const SizedBox(height: 16),
            const Text('Keine Lyrics gefunden',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800), textAlign: TextAlign.center),
            const SizedBox(height: 8),
            const Text(
              'Tipp: Leg eine .lrc-Datei mit gleichem Namen neben die MP3 '
              '(z.B. „Song.mp3“ und „Song.lrc“).',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                shape: const StadiumBorder(),
              ),
              onPressed: reload,
              icon: const Icon(Icons.refresh),
              label: const Text('Online erneut suchen'),
            ),
          ],
        ),
      ),
    );
  }
}
