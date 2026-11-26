import 'dart:io';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum OutputKind { unknown, speaker, wired, bluetooth }

class AudioOutput {
  final OutputKind kind;
  final String name;
  const AudioOutput(this.kind, [this.name = '']);
}

/// Erkennt, wohin der Ton gerade geht: Handy-Lautsprecher, Kabel-Kopfhörer (AUX/USB) oder Bluetooth.
class AudioOutputService {
  static final AudioOutputService instance = AudioOutputService._();
  AudioOutputService._();

  static const _channel = MethodChannel('musicplayer/output');

  /// Wahrscheinlich aktiver Ausgang (Android spielt Medien auf Bluetooth/Kopfhörer, wenn verbunden)
  final ValueNotifier<AudioOutput> output = ValueNotifier(const AudioOutput(OutputKind.unknown));

  /// Alle verbundenen Ausgänge
  final ValueNotifier<List<AudioOutput>> devices = ValueNotifier(const []);

  bool _started = false;

  bool get supported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  Future<void> start() async {
    if (_started || !supported) return;
    _started = true;
    try {
      final session = await AudioSession.instance;
      await _update(session);
      session.devicesChangedEventStream.listen((_) => _update(session));
    } catch (e) {
      debugPrint('Audio-Ausgang nicht erkennbar: $e');
    }
  }

  static OutputKind _kindOf(AudioDevice d) {
    // Typ als Text prüfen (robust gegenüber verschiedenen Paket-Versionen)
    final t = d.type.toString().toLowerCase();
    if (t.contains('bluetooth') || t.contains('.ble')) return OutputKind.bluetooth;
    if (t.contains('wired') ||
        t.contains('headset') ||
        t.contains('headphone') ||
        t.contains('usb') ||
        t.contains('line') ||
        t.contains('aux')) {
      return OutputKind.wired;
    }
    if (t.contains('speaker')) return OutputKind.speaker;
    return OutputKind.unknown;
  }

  Future<void> _update(AudioSession session) async {
    try {
      final all = await session.getDevices(includeInputs: false);
      final list = <AudioOutput>[];
      final seen = <String>{};
      for (final d in all) {
        final k = _kindOf(d);
        if (k == OutputKind.unknown) continue;
        final key = '${k.name}|${d.name}';
        if (seen.add(key)) list.add(AudioOutput(k, d.name));
      }
      devices.value = list;
      // Bluetooth hat Vorrang, dann Kabel, sonst Lautsprecher
      output.value = list.firstWhere((o) => o.kind == OutputKind.bluetooth,
          orElse: () => list.firstWhere((o) => o.kind == OutputKind.wired,
              orElse: () => const AudioOutput(OutputKind.speaker)));
    } catch (e) {
      debugPrint('Audio-Ausgang: $e');
    }
  }

  /// System-Menü "Medienausgabe" öffnen. Rückgabe: 'system', 'broadcast', 'bluetooth' oder 'none'.
  Future<String> openOutputSwitcher() async {
    try {
      return (await _channel.invokeMethod<String>('openOutputSwitcher')) ?? 'none';
    } catch (_) {
      return 'none';
    }
  }

  Future<void> openBluetoothSettings() async {
    try {
      await _channel.invokeMethod('openBluetoothSettings');
    } catch (_) {}
  }
}
