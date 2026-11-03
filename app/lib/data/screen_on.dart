import 'package:flutter/services.dart';

/// Keeps the phone's screen from sleeping (Android's FLAG_KEEP_SCREEN_ON, set by MainActivity on
/// channel "ensh/screen"). Only while the window is shown: leaving the app lets it sleep as usual.
class ScreenOn {
  static const _channel = MethodChannel('ensh/screen');
  static bool _on = false;

  static Future<void> set(bool on) async {
    if (on == _on) return;
    _on = on;
    try {
      await _channel.invokeMethod('keepOn', {'on': on});
    } catch (_) {}
  }
}
