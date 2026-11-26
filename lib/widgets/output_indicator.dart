import 'package:flutter/material.dart';
import '../services/output_service.dart';
import '../theme.dart';

IconData _iconFor(OutputKind k) => switch (k) {
      OutputKind.wired => Icons.headphones,
      OutputKind.bluetooth => Icons.bluetooth_audio,
      _ => Icons.volume_up,
    };

String _labelFor(AudioOutput o) => switch (o.kind) {
      OutputKind.wired => 'Kopfhörer (Kabel)',
      OutputKind.bluetooth => o.name.isNotEmpty ? 'Bluetooth: ${o.name}' : 'Bluetooth-Kopfhörer',
      _ => 'Handy-Lautsprecher',
    };

Color _colorFor(OutputKind k) => k == OutputKind.speaker ? Colors.orangeAccent : AppColors.accentLight;

/// Zeigt im Player, wohin der Ton geht. Lautsprecher = orange als Warnung.
/// Antippen: alle verbundenen Ausgänge + Ausgabe wechseln.
class OutputIndicator extends StatelessWidget {
  const OutputIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AudioOutput>(
      valueListenable: AudioOutputService.instance.output,
      builder: (context, out, _) {
        if (out.kind == OutputKind.unknown) return const SizedBox.shrink();
        final color = _colorFor(out.kind);
        return Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 4),
          child: Material(
            color: color.withValues(alpha: 0.15),
            shape: StadiumBorder(side: BorderSide(color: color.withValues(alpha: 0.6))),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: () => showOutputSheet(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_iconFor(out.kind), size: 16, color: color),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(_labelFor(out),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color)),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.expand_more, size: 16, color: color),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Liste der verbundenen Ausgänge + Umschalten über das System.
void showOutputSheet(BuildContext context) {
  final svc = AudioOutputService.instance;
  showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => SafeArea(
      child: ValueListenableBuilder<List<AudioOutput>>(
        valueListenable: svc.devices,
        builder: (ctx, list, _) {
          final current = svc.output.value;
          final items = list.isEmpty ? [const AudioOutput(OutputKind.speaker)] : list;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
                child: Text('Audio-Ausgabe', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              for (final o in items)
                ListTile(
                  leading: Icon(_iconFor(o.kind), color: _colorFor(o.kind)),
                  title: Text(_labelFor(o)),
                  trailing: (o.kind == current.kind && o.name == current.name)
                      ? const Icon(Icons.check, color: AppColors.accentLight)
                      : null,
                ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.swap_horiz, color: Colors.white),
                title: const Text('Ausgabe wechseln', style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: const Text('Öffnet die Medienausgabe von Android',
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                onTap: () async {
                  Navigator.pop(ctx);
                  final how = await svc.openOutputSwitcher();
                  if (how == 'broadcast' && context.mounted) {
                    // Ob das Menü aufging, lässt sich nicht prüfen -> kurzer Hinweis mit Alternative
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: const Text('Kein Menü zu sehen? Dann über die Bluetooth-Einstellungen wechseln.'),
                      action: SnackBarAction(label: 'Öffnen', onPressed: svc.openBluetoothSettings),
                    ));
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.bluetooth, color: AppColors.textSecondary),
                title: const Text('Bluetooth-Einstellungen'),
                onTap: () {
                  Navigator.pop(ctx);
                  svc.openBluetoothSettings();
                },
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 4, 20, 16),
                child: Text(
                  'Android lässt Apps den Ausgang nicht selbst umschalten – das geht nur über das System-Menü. '
                  'Kabel-Kopfhörer haben Vorrang, sobald sie eingesteckt sind.',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
