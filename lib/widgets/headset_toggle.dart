import 'package:flutter/material.dart';
import '../services/media_handler.dart';
import '../services/settings_service.dart';
import '../theme.dart';

/// Schalter für den Ski-Modus im Player. Unsichtbar, wenn die Funktion in den Einstellungen aus ist.
class HeadsetModeToggle extends StatelessWidget {
  const HeadsetModeToggle({super.key});

  @override
  Widget build(BuildContext context) {
    final st = AppSettings.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([st.headsetFeature, st.headsetModeOn]),
      builder: (context, _) {
        if (!st.headsetFeature.value) return const SizedBox.shrink();
        final on = st.headsetModeOn.value;
        return IconButton(
          tooltip: on ? 'Ski-Modus ausschalten' : 'Ski-Modus einschalten (Kopfhörer-Tasten)',
          icon: Icon(on ? Icons.headset : Icons.headset_off, color: on ? AppColors.accentLight : Colors.white70),
          onPressed: () {
            st.setBool(st.headsetModeOn, !on);
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              duration: const Duration(seconds: 3),
              content: Text(!on
                  ? 'Ski-Modus an • 2x Lauter: ${headsetActionLabel(st.headsetVolUp2.value)} • '
                      '2x Leiser: ${headsetActionLabel(st.headsetVolDown2.value)}'
                  : 'Ski-Modus aus'),
            ));
          },
        );
      },
    );
  }
}
