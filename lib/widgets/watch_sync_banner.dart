import 'package:flutter/material.dart';
import '../services/watch_bridge.dart';
import '../theme.dart';

/// Kleine Leiste über dem Mini-Player: Übertragung auf die Uhr.
class WatchSyncBanner extends StatelessWidget {
  const WatchSyncBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final b = WatchBridge.instance;
    return ValueListenableBuilder<WatchSync?>(
      valueListenable: b.sync,
      builder: (context, s, _) {
        if (s == null) return const SizedBox.shrink();
        final text = s.running
            ? (s.done == 0 && s.total > 0
                ? 'Uhr: „${s.name}“ wird vorbereitet…'
                : 'Uhr: „${s.name}“ ${s.done} / ${s.total} Songs')
            : (s.message ?? '');
        return Material(
          color: AppColors.miniPlayer,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Icon(Icons.watch, size: 18, color: AppColors.accentLight),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13)),
                    ),
                    TextButton(
                      onPressed: () {
                        if (s.running) b.cancelSync();
                        b.sync.value = null;
                      },
                      child: Text(s.running ? 'Abbrechen' : 'OK'),
                    ),
                  ],
                ),
                if (s.running)
                  LinearProgressIndicator(
                    value: s.total > 0 && s.done > 0 ? s.done / s.total : null,
                    minHeight: 3,
                    color: AppColors.accentLight,
                    backgroundColor: Colors.white12,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
