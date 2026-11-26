import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import '../services/audio_player_service.dart';
import '../services/audiobook_service.dart';
import '../services/cover_service.dart';
import '../services/settings_service.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/mini_player.dart';

void openCarMode(BuildContext context) {
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute(builder: (_) => const CarModeScreen(), fullscreenDialog: true),
  );
}

/// Auto-Modus wie bei Audible: riesiger Play-Button, darunter zwei große Tasten.
/// Hörbuch: zurück-/vorspulen. Musik: vorheriger/nächster Song.
class CarModeScreen extends StatelessWidget {
  const CarModeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AudioPlayerService.instance;
    final a = AudiobookService.instance;
    final st = AppSettings.instance;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([s.changes, s.mode, a.changes, st.listenable, CoverService.instance.version]),
          builder: (context, _) {
            final isBook = s.mode.value == PlayMode.book && a.current != null;
            final title = isBook ? a.current!.title : (s.currentTrack?.title ?? 'Nichts läuft');
            final subtitle = isBook
                ? 'Kapitel ${a.fileIndex + 1} von ${a.files.length}'
                : (s.currentTrack?.artist ?? '');

            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                children: [
                  // Fortschrittsbalken ganz oben
                  const TrackProgressBar(height: 8, color: AppColors.accentLight, background: Colors.white12),
                  const SizedBox(height: 6),
                  StreamBuilder<Duration>(
                    stream: s.player.positionStream,
                    builder: (context, snap) {
                      final pos = snap.data ?? Duration.zero;
                      final dur = s.player.duration ?? Duration.zero;
                      return Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(formatDuration(pos),
                              style: const TextStyle(fontSize: 16, color: AppColors.textSecondary)),
                          Text('-${formatDuration(dur > pos ? dur - pos : Duration.zero)}',
                              style: const TextStyle(fontSize: 16, color: AppColors.textSecondary)),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      SizedBox(
                        width: 64,
                        height: 64,
                        child: _CarButton(icon: Icons.close, onTap: () => Navigator.pop(context)),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                            Text(subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 17, color: AppColors.textSecondary)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Großer Play/Pause-Button
                  Expanded(
                    flex: 4,
                    child: StreamBuilder<PlayerState>(
                      stream: s.player.playerStateStream,
                      builder: (context, snap) {
                        final playing = (snap.data?.playing ?? false) &&
                            (isBook ? a.bookActive : s.musicActive);
                        final t = s.currentTrack;
                        final cover = (!isBook && t != null && st.carCoverBackground.value)
                            ? (CoverService.instance.pathFor(t) ?? s.currentCoverPath)
                            : null;
                        return _CarButton(
                          icon: playing ? Icons.pause : Icons.play_arrow,
                          filled: true,
                          backgroundImage: cover,
                          onTap: isBook ? a.togglePlay : s.togglePlay,
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    flex: 1,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: isBook
                          ? [
                              Expanded(
                                child: _CarButton(
                                  iconWidget: (size) =>
                                      SkipIcon(forward: false, seconds: st.bookSkipBack.value, size: size),
                                  onTap: a.skipBack,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: _CarButton(
                                  iconWidget: (size) =>
                                      SkipIcon(forward: true, seconds: st.bookSkipForward.value, size: size),
                                  onTap: a.skipForward,
                                ),
                              ),
                            ]
                          : [
                              Expanded(child: _CarButton(icon: Icons.skip_previous, onTap: s.previous)),
                              const SizedBox(width: 16),
                              Expanded(child: _CarButton(icon: Icons.skip_next, onTap: s.next)),
                            ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _CarButton extends StatelessWidget {
  final IconData? icon;
  final Widget Function(double size)? iconWidget;
  final bool filled;
  final String? backgroundImage; // Cover als Hintergrund
  final VoidCallback onTap;

  const _CarButton({this.icon, this.iconWidget, required this.onTap, this.filled = false, this.backgroundImage});

  @override
  Widget build(BuildContext context) {
    final bg = backgroundImage;
    return Material(
      color: filled ? AppColors.accent : const Color(0xFF1E1E1E),
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (bg != null && bg.isNotEmpty) ...[
            Image.file(
              File(bg),
              fit: BoxFit.cover,
              errorBuilder: (context, error, stack) => const SizedBox.shrink(),
            ),
            Container(color: Colors.black.withValues(alpha: 0.35)), // Icon bleibt gut lesbar
          ],
          InkWell(
            onTap: onTap,
            child: LayoutBuilder(
              builder: (context, c) {
                final size = max(24.0, min(c.maxWidth, c.maxHeight) * 0.55);
                return Center(
                  child: iconWidget != null
                      ? iconWidget!(size)
                      : Icon(icon,
                          size: size,
                          color: Colors.white,
                          shadows: const [Shadow(color: Colors.black54, blurRadius: 12)]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
