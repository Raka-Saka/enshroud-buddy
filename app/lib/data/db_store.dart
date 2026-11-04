import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'buddy_auth.dart';
import 'game_db.dart';

/// Game data that can be newer than the app: the PC agent serves the latest build (GET /db, from
/// tools/build_db.py) and the phone keeps a copy, so data fixes arrive without reinstalling. New screens
/// and features still come with a new APK.
class DbStore {
  static final _built = RegExp(r'"built"\s*:\s*"([^"]+)"');

  /// The build time written near the start of game.json.
  static String? builtOf(String raw) => _built
      .firstMatch(raw.length > 400 ? raw.substring(0, 400) : raw)
      ?.group(1);

  /// game.json is about 3 MB; a download many times that is refused.
  static const maxBytes = 40 * 1024 * 1024;

  /// A build time that is a real date and not in the future (a copy claiming year 9999 would otherwise
  /// win over every later app update).
  static bool plausible(String? built) {
    final t = built == null ? null : DateTime.tryParse(built);
    return t != null && t.isBefore(DateTime.now().add(const Duration(days: 2)));
  }

  static Future<File> _file() async =>
      File('${(await getApplicationSupportDirectory()).path}/game.json');

  /// The newer of the data bundled in the app and the copy downloaded from the PC.
  static Future<GameDb> load() async {
    final bundled = await rootBundle.loadString('assets/game.json');
    var raw = bundled;
    try {
      final f = await _file();
      if (await f.exists()) {
        final cached = await f.readAsString();
        final a = builtOf(cached), b = builtOf(bundled);
        if (a != null && plausible(a) && (b == null || a.compareTo(b) > 0)) {
          raw = cached;
        }
      }
    } catch (_) {}
    final json = await compute(jsonDecode, raw) as Map<String, dynamic>;
    return GameDb.fromJson(json);
  }

  /// When the PC agent has newer data than [current]: download it, check that it loads, keep it, and
  /// return it. Null when there's nothing newer or the agent can't be reached.
  static Future<GameDb?> update(String host, String key, GameDb current) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    Future<String> get(String path) async {
      final req = await client.getUrl(Uri.parse('http://$host$path'));
      final nonce = BuddyAuth.apply(req, key);
      final res = await req.close().timeout(const Duration(seconds: 90));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      // never more than [maxBytes]: something posing as the agent can't fill the phone's memory
      final b = BytesBuilder(copy: false);
      await for (final chunk in res) {
        b.add(chunk);
        if (b.length > maxBytes)
          throw const HttpException('game data too large');
      }
      final body = b.takeBytes();
      // only the agent can sign it: data from anything else on the network is never kept
      if (!BuddyAuth.replyOk(key, nonce, res, body)) {
        throw const HttpException('not signed by the agent');
      }
      return utf8.decode(body);
    }

    try {
      final v = jsonDecode(await get('/db/version')) as Map<String, dynamic>;
      final built = v['built'] as String?;
      if (built == null ||
          !plausible(built) ||
          (current.built != null && built.compareTo(current.built!) <= 0)) {
        return null;
      }
      final raw = await get('/db');
      if (!plausible(builtOf(raw))) return null;
      final json = await compute(jsonDecode, raw) as Map<String, dynamic>;
      // throws when the download is broken, so the old data stays
      final db = GameDb.fromJson(json);
      await (await _file()).writeAsString(raw);
      return db;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
