import 'dart:io';
import 'dart:math' show max;
import 'package:flutter/material.dart';
import '../theme.dart';

/// Vollbild-Player nach unten wegwischen zum Schließen.
class SwipeDownToClose extends StatefulWidget {
  final Widget child;
  const SwipeDownToClose({super.key, required this.child});

  @override
  State<SwipeDownToClose> createState() => _SwipeDownToCloseState();
}

class _SwipeDownToCloseState extends State<SwipeDownToClose> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
  Animation<double>? _anim;
  double _dy = 0;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() {
      final a = _anim;
      if (a != null) setState(() => _dy = a.value);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _drag(double delta) {
    if (_closing) return;
    setState(() => _dy = max(0, _dy + delta));
  }

  void _end(double velocity) {
    if (_closing) return;
    final h = MediaQuery.of(context).size.height;
    if (_dy > h * 0.18 || (velocity > 800 && _dy > 0)) {
      _closing = true;
      Navigator.of(context).maybePop();
    } else if (_dy > 0) {
      _anim = Tween<double>(begin: _dy, end: 0).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
      _ctrl
        ..reset()
        ..forward();
    }
  }

  /// Scrollbarer Inhalt (z.B. Player mit Lyrics darunter): ganz oben weiter nach unten ziehen = schließen.
  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    if (n is OverscrollNotification && n.dragDetails != null && n.overscroll < 0) {
      _drag(-n.overscroll);
    } else if (n is ScrollUpdateNotification && n.dragDetails != null && _dy > 0) {
      _drag(-(n.scrollDelta ?? 0));
    } else if (n is ScrollEndNotification && _dy > 0) {
      _end(n.dragDetails?.velocity.pixelsPerSecond.dy ?? 0);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: GestureDetector(
        onVerticalDragStart: (_) => _ctrl.stop(),
        onVerticalDragUpdate: (d) => _drag(d.delta.dy),
        onVerticalDragEnd: (d) => _end(d.primaryVelocity ?? 0),
        child: Transform.translate(offset: Offset(0, _dy), child: widget.child),
      ),
    );
  }
}

/// Quadratisches Cover. Ohne Bild: dunkler Verlauf mit Icon.
class CoverArt extends StatelessWidget {
  final String? path;
  final double size;
  final double radius;
  final IconData icon;

  const CoverArt({
    super.key,
    this.path,
    required this.size,
    this.radius = 4,
    this.icon = Icons.music_note,
  });

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    Widget child;
    if (path != null && path!.isNotEmpty) {
      child = Image.file(
        File(path!),
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: (size * dpr).round(), // klein dekodieren -> schneller
        errorBuilder: (context, error, stack) => _placeholder(),
      );
    } else {
      child = _placeholder();
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(width: size, height: size, child: child),
    );
  }

  Widget _placeholder() => Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF3A3A3A), Color(0xFF1F1F1F)],
          ),
        ),
        alignment: Alignment.center,
        child: Icon(icon, color: AppColors.textMuted, size: size * 0.45),
      );
}

/// Eintrag in einem Bottom-Sheet (Spotify-Stil).
class SheetItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;

  const SheetItem({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: color == Colors.white ? AppColors.textSecondary : color, size: 26),
            const SizedBox(width: 18),
            Expanded(child: Text(label, style: TextStyle(fontSize: 16, color: color))),
          ],
        ),
      ),
    );
  }
}

/// Kopfzeile für Bottom-Sheets: Cover + Titel + Untertitel.
class SheetHeader extends StatelessWidget {
  final String? coverPath;
  final IconData icon;
  final String title;
  final String subtitle;

  const SheetHeader({
    super.key,
    this.coverPath,
    this.icon = Icons.music_note,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Row(
        children: [
          CoverArt(path: coverPath, size: 52, icon: icon),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Runder Schwebe-Button (z.B. "nach oben", "zum aktuellen Song").
class RoundFloatingButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const RoundFloatingButton({super.key, required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: const Color(0xEE2A2A2A),
        shape: const CircleBorder(),
        elevation: 6,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: 46, height: 46, child: Icon(icon, color: Colors.white, size: 24)),
        ),
      ),
    );
  }
}

/// Texteingabe-Dialog. Gibt null bei Abbrechen, '' bei [clearLabel] zurück.
Future<String?> showTextInputDialog(
  BuildContext context, {
  required String title,
  String initial = '',
  String hint = '',
  String confirmLabel = 'Speichern',
  String? clearLabel,
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.elevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
      content: TextField(
        controller: controller,
        autofocus: true,
        style: const TextStyle(fontSize: 18),
        onSubmitted: (v) => Navigator.pop(ctx, v),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: AppColors.textMuted),
          enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Colors.white38)),
          focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: AppColors.accentLight, width: 2)),
        ),
      ),
      actions: [
        if (clearLabel != null)
          TextButton(
            onPressed: () => Navigator.pop(ctx, ''),
            child: Text(clearLabel, style: const TextStyle(color: Colors.redAccent)),
          ),
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Abbrechen', style: TextStyle(color: AppColors.textSecondary)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: Text(confirmLabel,
              style: const TextStyle(color: AppColors.accentLight, fontWeight: FontWeight.w700)),
        ),
      ],
    ),
  );
}

/// Spul-Icon wie bei Audible: Kreispfeil mit Sekundenzahl in der Mitte.
class SkipIcon extends StatelessWidget {
  final bool forward;
  final int seconds;
  final double size;
  final Color color;

  const SkipIcon({super.key, required this.forward, required this.seconds, this.size = 40, this.color = Colors.white});

  @override
  Widget build(BuildContext context) {
    final icon = Icon(Icons.replay, size: size, color: color);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          forward ? Transform.flip(flipX: true, child: icon) : icon,
          Padding(
            padding: EdgeInsets.only(top: size * 0.1),
            child: Text(
              '$seconds',
              style: TextStyle(fontSize: size * (seconds >= 100 ? 0.2 : 0.26), fontWeight: FontWeight.w800, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// Sicherheitsabfrage vor dem Löschen/Entfernen. true = bestätigt.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Entfernen',
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.elevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
      content: Text(message, style: const TextStyle(color: AppColors.textSecondary, fontSize: 15)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Abbrechen', style: TextStyle(color: Colors.white)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel,
              style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w700)),
        ),
      ],
    ),
  );
  return ok == true;
}

String formatDuration(Duration d) {
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  if (d.inHours > 0) {
    return '${d.inHours}:${(d.inMinutes % 60).toString().padLeft(2, '0')}:$s';
  }
  return '${d.inMinutes}:$s';
}

String formatTotal(int ms) {
  final d = Duration(milliseconds: ms);
  if (d.inHours > 0) return '${d.inHours} Std. ${d.inMinutes % 60} Min.';
  return '${d.inMinutes} Min.';
}
