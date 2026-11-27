import 'dart:async';
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
      // Ausgang kann auch ohne Geräte-Änderung wechseln (z.B. über das System-Menü)
      Timer.periodic(const Duration(seconds: 5), (_) => _update(session));
    } catch (e) {
      debugPrint('Audio-Ausgang nicht erkennbar: $e');
    }
  }

  static OutputKind _kindOf(AudioDevice d) {
    // Typ als Text prüfen (robust gegenüber verschiedenen Paket-Versionen)
    final t = d.type.toString().toLowerCase();
    // SCO = nur Telefonie (Freisprechen). Smartwatches und BT-Fernbedienungen melden sich oft so
    // an, spielen aber keine Musik -> nicht als Kopfhörer zählen.
    if (t.contains('sco') || t.contains('broadcast')) return OutputKind.unknown;
    if (t.contains('bluetooth') || t.contains('.ble') || t.contains('hearing')) return OutputKind.bluetooth;
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
      // Am genauesten: Android fragen, wohin Medien gerade wirklich gehen (ab Android 13)
      final real = await _realMediaOutput();
      if (real != null && real.kind != OutputKind.speaker && !list.any((o) => o.kind == real.kind && o.name == real.name)) {
        list.insert(0, real);
      }
      final next = real ??
          // Sonst schätzen: Bluetooth hat Vorrang, dann Kabel, sonst Lautsprecher
          list.firstWhere((o) => o.kind == OutputKind.bluetooth,
              orElse: () => list.firstWhere((o) => o.kind == OutputKind.wired,
                  orElse: () => const AudioOutput(OutputKind.speaker)));
      if (!_sameList(devices.value, list)) devices.value = list;
      if (next.kind != output.value.kind || next.name != output.value.name) output.value = next;
    } catch (e) {
      debugPrint('Audio-Ausgang: $e');
    }
  }

  static bool _sameList(List<AudioOutput> a, List<AudioOutput> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].kind != b[i].kind || a[i].name != b[i].name) return false;
    }
    return true;
  }

  Future<AudioOutput?> _realMediaOutput() async {
    if (!Platform.isAndroid) return null;
    try {
      final r = await _channel.invokeMethod<Map>('currentMediaOutput');
      if (r == null) return null;
      final kind = switch (r['kind']) {
        'bluetooth' => OutputKind.bluetooth,
        'wired' => OutputKind.wired,
        'speaker' => OutputKind.speaker,
        _ => OutputKind.unknown,
      };
      if (kind == OutputKind.unknown) return null;
      return AudioOutput(kind, kind == OutputKind.speaker ? '' : ((r['name'] as String?) ?? ''));
    } catch (_) {
      return null;
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
