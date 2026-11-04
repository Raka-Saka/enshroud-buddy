import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'live_state.dart';

/// A newer release on GitHub than the installed app.
class Release {
  const Release(this.version, this.url);
  final String version;

  /// The release's APK, else its page.
  final String url;
}

/// Looks once a day at the repo's latest GitHub release (an anonymous GET, nothing about the player is
/// sent) and offers it on Home when it is newer. Only in the friends' build: a build made with AGENT_HOST
/// is updated another way. The repo can be set with --dart-define=UPDATE_REPO=owner/name; GitHub forwards
/// a renamed repo, so the default keeps working.
class Updates {
  static const repo = String.fromEnvironment(
    'UPDATE_REPO',
    defaultValue: 'Raka-Saka/enshroud-buddy',
  );
  static const _channel = MethodChannel('ensh/app');
  static final available = ValueNotifier<Release?>(null);

  /// The installed app's version, once [check] ran.
  static String? mine;

  /// Whether the PC agent is older than this app (they are released together): its version comes with
  /// GET /health, and agents before 0.36 send none.
  static bool agentBehind(String? agent) =>
      mine != null && (agent == null || newer(mine!, agent));

  static Future<void> check() async {
    mine = await appVersion();
    if (Live.defaultHost.isNotEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now().millisecondsSinceEpoch;
      final last = prefs.getInt('update_checked') ?? 0;
      var release = _decode(prefs.getString('update_latest'));
      if (now - last > const Duration(hours: 20).inMilliseconds) {
        release = await _latest() ?? release;
        await prefs.setInt('update_checked', now);
        if (release != null) {
          await prefs.setString(
            'update_latest',
            jsonEncode([release.version, release.url]),
          );
        }
      }
      if (release != null && newer(release.version, mine ?? '')) {
        available.value = release;
      }
    } catch (_) {
      // offline, rate-limited or no release yet: look again next time
    }
  }

  static Release? _decode(String? s) {
    if (s == null) return null;
    final l = jsonDecode(s) as List;
    final url = l[1] as String;
    return url.startsWith('https://github.com/')
        ? Release(l[0] as String, url)
        : null;
  }

  /// The installed app's version (like 0.36.0), null off Android.
  static Future<String?> appVersion() async {
    try {
      return await _channel.invokeMethod<String>('version');
    } catch (_) {
      return null;
    }
  }

  static Future<Release?> _latest() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.getUrl(
        Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
      );
      req.headers.set('Accept', 'application/vnd.github+json');
      req.headers.set('User-Agent', 'EnshroudBuddy');
      final res = await req.close().timeout(const Duration(seconds: 10));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) return null;
      final j = jsonDecode(body) as Map<String, dynamic>;
      final apk = [
        for (final a in (j['assets'] as List? ?? const []))
          if ((a['name'] as String? ?? '').endsWith('.apk'))
            a['browser_download_url'] as String,
      ];
      // only a download from GitHub itself is ever opened
      apk.removeWhere((u) => !u.startsWith('https://github.com/'));
      final page = j['html_url'] as String? ?? '';
      if (!page.startsWith('https://github.com/')) return null;
      final tag = (j['tag_name'] as String? ?? '').replaceFirst(
        RegExp('^v'),
        '',
      );
      return tag.isEmpty
          ? null
          : Release(tag, apk.isNotEmpty ? apk.first : page);
    } finally {
      client.close(force: true);
    }
  }

  /// Whether version a (like 0.35.0) is newer than b; anything after '+' or '-' is ignored.
  static bool newer(String a, String b) {
    List<int> parts(String v) => [
      for (final p in v.split(RegExp('[+-]')).first.split('.'))
        int.tryParse(p) ?? 0,
    ];
    final x = parts(a), y = parts(b);
    for (var i = 0; i < 3; i++) {
      final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
      if (d != 0) return d > 0;
    }
    return false;
  }

  /// Opens the download in the phone's browser, which then offers to install it.
  static Future<void> open(Release r) =>
      _channel.invokeMethod('open', {'url': r.url});
}
