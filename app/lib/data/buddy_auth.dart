import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Signed requests to the PC agent (agent.py, class Guard): the pairing code never crosses the network.
/// Each request carries the time, a fresh nonce and HMAC-SHA256(code, method, path, time, nonce); the
/// agent signs its reply to that nonce (X-Buddy-Reply), so a device on the network can neither replay a
/// request nor pass itself off as the agent.
class BuddyAuth {
  /// The PC's clock minus the phone's, in seconds: learned from a refusal, which carries the PC's time.
  static int skew = 0;
  static final _rand = Random.secure();

  static String sign(String key, List<Object> parts) =>
      Hmac(
        sha256,
        utf8.encode(key),
      ).convert(utf8.encode(parts.join('\n'))).toString();

  /// The headers that sign a [method] request for [path] with [key], and their nonce (to check the reply
  /// with).
  static ({Map<String, String> headers, String nonce}) headers(
    String key,
    String method,
    String path,
  ) {
    final t = DateTime.now().millisecondsSinceEpoch ~/ 1000 + skew;
    final nonce =
        [
          for (var i = 0; i < 16; i++)
            _rand.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ].join();
    return (
      headers: {
        'X-Buddy-Time': '$t',
        'X-Buddy-Nonce': nonce,
        'X-Buddy-Sig': sign(key, [method, path, t, nonce]),
      },
      nonce: nonce,
    );
  }

  /// Signs a request's [body] for [nonce] (X-Buddy-Body): the agent checks it where the body matters
  /// (POST /target), so nobody on the network can swap it.
  static String bodySig(String key, String nonce, List<int> body) =>
      sign(key, [nonce, sha256.convert(body).toString()]);

  /// Whether [body] is the agent's own reply to the request signed with [nonce] ([got]: its X-Buddy-Reply).
  static bool replyOk(String key, String nonce, String? got, List<int> body) {
    return got != null &&
        got == sign(key, [nonce, sha256.convert(body).toString()]);
  }

  /// After a 401: the PC's clock from its body, so the next request is signed with the right time.
  /// True when the clocks were off (then a retry can succeed).
  static bool learnClock(List<int> body) {
    try {
      final j = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      final now = j['now'];
      if (now is! int) return false;
      final s = now - DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final off = (s - skew).abs() > 60;
      skew = s;
      return off;
    } catch (_) {
      return false;
    }
  }
}
