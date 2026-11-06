import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../l10n.dart';

/// Speech in and out for Ask, through the phone's own recognizer and text-to-speech (MainActivity,
/// channel "ensh/voice"). Nothing is recorded by the app.
class Voice {
  static const _ch = MethodChannel('ensh/voice');

  /// The text being read aloud, or null.
  static final speaking = ValueNotifier<String?>(null);
  static var _ready = false;

  static void _setup() {
    if (_ready) return;
    _ready = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'spoken') speaking.value = null;
    });
  }

  /// What the player said, or null when they cancelled. Throws with a short reason.
  static Future<String?> listen() async {
    try {
      return await _ch.invokeMethod<String>('listen', {'lang': L10n.lang.tag});
    } on PlatformException catch (e) {
      throw StateError(e.message ?? tr('No speech recognition'));
    } on MissingPluginException {
      throw StateError(tr('No speech recognition'));
    }
  }

  static Future<void> speak(String text) async {
    _setup();
    speaking.value = text;
    try {
      await _ch.invokeMethod('speak', {
        'text': forSpeech(text),
        'lang': L10n.lang.tag,
      });
    } catch (_) {
      speaking.value = null;
    }
  }

  static Future<void> stop() async {
    speaking.value = null;
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
  }

  /// An answer as it should sound: no bullets, no "Source:" line, positions said as words.
  static String forSpeech(String text) => text
      .split('\n')
      .where((l) => !l.trim().startsWith('Source:'))
      .map((l) => l.replaceFirst(RegExp(r'^\s*[-•]\s*'), ''))
      .join('\n')
      .replaceAll('**', '')
      .replaceAllMapped(
        RegExp(r'\(?x\s*(\d{1,4})\s*,\s*y\s*(\d{1,4})\)?'),
        (m) => tr('at {x}, {y}', {'x': m[1], 'y': m[2]}),
      );
}
