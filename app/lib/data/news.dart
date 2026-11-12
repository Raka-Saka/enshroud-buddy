import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What a post from Keen is about (tools/news.py): patch notes, notes for a test branch (a patch to come),
/// plans and previews (an update to come), anything else.
enum NewsKind { patch, test, plan, news }

/// One of Keen's posts about the game, from Steam's news feed through the PC agent (GET /news). English, as
/// Keen writes them: "# " starts a heading and "- " a list item.
class NewsPost {
  NewsPost(Map<String, dynamic> j)
    : id = j['id'] as String,
      date = DateTime.fromMillisecondsSinceEpoch(
        ((j['date'] as num?) ?? 0).toInt() * 1000,
      ),
      title = j['title'] as String,
      kind = NewsKind.values.asNameMap()[j['kind']] ?? NewsKind.news,
      url = j['url'] as String? ?? '',
      text = j['text'] as String? ?? '';
  final String id, title, url, text;
  final DateTime date;
  final NewsKind kind;

  /// Still to come: a test branch's notes, or plans.
  bool get ahead => kind == NewsKind.test || kind == NewsKind.plan;
}

/// Keen's posts, newest first, and which ones were read on this phone. The agent asks Steam every few hours;
/// the last answer is kept here too.
class KeenNews extends ChangeNotifier {
  List<NewsPost> posts = const [];
  final _seen = <String>{};

  /// When the agent last heard from Steam (null: never).
  DateTime? fetched;

  bool _loaded = false;
  DateTime? _asked;

  /// Posts not opened yet, of the kinds worth telling about (not plain news); the first time, only the newest
  /// few count, not years of posts.
  int get unread =>
      posts
          .where((p) => p.kind != NewsKind.news && !_seen.contains(p.id))
          .length;

  bool isNew(NewsPost p) => !_seen.contains(p.id);

  void read(NewsPost p) {
    if (!_seen.add(p.id)) return;
    notifyListeners();
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setStringList('news_seen', _seen.toList()),
    );
  }

  void readAll() {
    if (!posts.any((p) => _seen.add(p.id))) return;
    notifyListeners();
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setStringList('news_seen', _seen.toList()),
    );
  }

  /// [get] is the agent's GET; asked at most every 30 minutes unless [force].
  Future<void> update(
    Future<String> Function(String path) get, {
    bool force = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (!_loaded) {
      _loaded = true;
      final had = prefs.getStringList('news_seen');
      if (had != null) _seen.addAll(had);
      _first = had == null;
      final cached = prefs.getString('last_news');
      if (cached != null && _take(cached)) await _firstSeen(prefs);
      notifyListeners();
    }
    final now = DateTime.now();
    if (!force && _asked != null && now.difference(_asked!).inMinutes < 30) {
      return;
    }
    _asked = now;
    try {
      final raw = await get('/news');
      // the agent was still asking Steam: ask again in a minute
      if ((jsonDecode(raw) as Map)['fetching'] == true) {
        _asked = now.subtract(const Duration(minutes: 29));
      }
      if (!_take(raw) || posts.isEmpty) return;
      await _firstSeen(prefs);
      await prefs.setString('last_news', raw);
      notifyListeners();
    } catch (_) {} // an older agent without /news, or no agent
  }

  bool _first = false;

  /// The first time there are posts, what's older than the newest three counts as read.
  Future<void> _firstSeen(SharedPreferences prefs) async {
    if (!_first || posts.isEmpty) return;
    _first = false;
    _seen.addAll(posts.skip(3).map((p) => p.id));
    await prefs.setStringList('news_seen', _seen.toList());
  }

  bool _take(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final got = [
        for (final p in j['posts'] as List) NewsPost(p as Map<String, dynamic>),
      ]..sort((a, b) => b.date.compareTo(a.date));
      if (got.isEmpty && posts.isNotEmpty) return false;
      posts = got;
      final at = (j['at'] as num?)?.toInt() ?? 0;
      fetched = at > 0 ? DateTime.fromMillisecondsSinceEpoch(at * 1000) : null;
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// The app's one news list (updated by Live after each refresh, shown on Home and the News screen).
final keenNews = KeenNews();
