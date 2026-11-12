import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/game_db.dart';
import '../data/live_state.dart';
import '../data/mentions.dart';
import '../data/news.dart';
import '../l10n.dart';
import '../theme.dart';
import 'ask_screen.dart';
import 'journey_screen.dart';
import 'widgets.dart';

String newsKindLabel(NewsKind k) => switch (k) {
  NewsKind.patch => tr('Patch notes'),
  NewsKind.test => tr('Test branch: coming in a patch'),
  NewsKind.plan => tr('Plans and previews'),
  NewsKind.news => tr('News'),
};

(IconData, Color) newsKindStyle(NewsKind k) => switch (k) {
  NewsKind.patch => (Icons.build_circle_outlined, Palette.spring),
  NewsKind.test => (Icons.science_outlined, Palette.flame),
  NewsKind.plan => (Icons.event_note_outlined, Palette.veil),
  NewsKind.news => (Icons.campaign_outlined, Palette.ash),
};

String newsDate(DateTime t) => '${JourneyScreen.day(t)} ${t.year}';

/// Keen's posts about the game, from Steam: patch notes, what a coming patch changes (test branch), and
/// plans for later. Each post names the items, skills and places it touches, those you have first.
class NewsScreen extends StatefulWidget {
  const NewsScreen({super.key, required this.db});
  final GameDb db;

  @override
  State<NewsScreen> createState() => _NewsScreenState();
}

enum _Show { all, patches, ahead, other }

class _NewsScreenState extends State<NewsScreen> {
  var show = _Show.all;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    LiveScope.of(context).updateNews();
  }

  @override
  Widget build(BuildContext context) {
    final live = LiveScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('News from Keen')),
        actions: [
          IconButton(
            tooltip: tr('Mark all read'),
            icon: const Icon(Icons.done_all),
            onPressed: keenNews.readAll,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: keenNews,
        builder: (context, _) {
          final posts = [
            for (final p in keenNews.posts)
              if (switch (show) {
                _Show.all => true,
                _Show.patches => p.kind == NewsKind.patch,
                _Show.ahead => p.ahead,
                _Show.other => p.kind == NewsKind.news,
              })
                p,
          ];
          return RefreshIndicator(
            onRefresh: () => live.updateNews(force: true),
            child: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Wrap(
                    spacing: 6,
                    children: [
                      for (final (s, label) in [
                        (_Show.all, tr('All')),
                        (_Show.ahead, tr('Coming')),
                        (_Show.patches, tr('Patch notes')),
                        (_Show.other, tr('Other')),
                      ])
                        ChoiceChip(
                          label: Text(label),
                          selected: show == s,
                          onSelected: (_) => setState(() => show = s),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
                  child: Text(
                    show == _Show.ahead
                        ? tr(
                          'Notes for the test branch say what the next patch will change; plans and previews tell what comes later.',
                        )
                        : tr(
                          'Keen\'s posts on Steam, in English as they write them. The PC program checks every few hours.',
                        ),
                    style: const TextStyle(color: Palette.ash, fontSize: 12),
                  ),
                ),
                if (keenNews.posts.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      tr(
                        'No news yet: the PC program fetches it from Steam when it can reach the internet.',
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                if (keenNews.posts.isNotEmpty && posts.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      tr('No posts of this kind lately.'),
                      textAlign: TextAlign.center,
                    ),
                  ),
                for (final p in posts) NewsTile(db: widget.db, post: p),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// One post in a list: its kind, date and title, a dot while unread.
class NewsTile extends StatelessWidget {
  const NewsTile({super.key, required this.db, required this.post});
  final GameDb db;
  final NewsPost post;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = newsKindStyle(post.kind);
    final fresh = keenNews.isNew(post);
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(
        post.title,
        style: TextStyle(fontWeight: fresh ? FontWeight.w600 : null),
      ),
      subtitle: Text(
        '${newsKindLabel(post.kind)} · ${newsDate(post.date)}',
        style: const TextStyle(color: Palette.ash, fontSize: 12),
      ),
      trailing:
          fresh
              ? const Icon(Icons.circle, size: 10, color: Palette.flame)
              : null,
      onTap: () {
        keenNews.read(post);
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => NewsPostScreen(db: db, post: post)),
        );
      },
    );
  }
}

/// A post in full: what it names that you have first, then its text.
class NewsPostScreen extends StatelessWidget {
  const NewsPostScreen({super.key, required this.db, required this.post});
  final GameDb db;
  final NewsPost post;

  @override
  Widget build(BuildContext context) {
    final s = LiveScope.of(context).state;
    final found = <String, Mention>{};
    for (final m in Mentions.of(db).find(post.text)) {
      found.putIfAbsent(m.key, () => m);
    }
    bool mine(Mention m) => switch (m.kind) {
      MentionKind.item =>
        s != null &&
            (s.owned(m.item!.id) > 0 ||
                s.equipment.any((e) => e.itemId == m.item!.id)),
      MentionKind.skill => s?.skills.containsKey(m.skill!.id) ?? false,
      MentionKind.place => false,
    };
    final yours = [
      for (final m in found.values)
        if (mine(m)) m,
    ];
    final others = [
      for (final m in found.values)
        if (!mine(m)) m,
    ];
    final (icon, color) = newsKindStyle(post.kind);
    Widget chip(Mention m, bool have) => ActionChip(
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      avatar: Icon(
        switch (m.kind) {
          MentionKind.item => Icons.inventory_2_outlined,
          MentionKind.skill => Icons.auto_awesome,
          MentionKind.place => Icons.place_outlined,
        },
        size: 16,
        color: have ? Palette.gold : Palette.ash,
      ),
      label: Text(gt(m.name)),
      onPressed: () => showMention(context, db, m),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(newsKindLabel(post.kind)),
        actions: [
          if (post.url.isNotEmpty)
            IconButton(
              tooltip: tr('Copy the link to the post'),
              icon: const Icon(Icons.link),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: post.url));
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(tr('Link copied'))));
              },
            ),
        ],
      ),
      body: SelectionArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 18),
                const SizedBox(width: 6),
                Text(
                  newsDate(post.date),
                  style: const TextStyle(color: Palette.ash),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(post.title, style: Theme.of(context).textTheme.titleLarge),
            if (yours.isNotEmpty) ...[
              SectionTitle(tr('Touches what you have')),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [for (final m in yours) chip(m, true)],
              ),
            ],
            if (others.isNotEmpty) ...[
              SectionTitle(tr('Also named')),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [for (final m in others.take(30)) chip(m, false)],
              ),
            ],
            const SizedBox(height: 12),
            for (final line in post.text.split('\n'))
              if (line.startsWith('# '))
                Padding(
                  padding: const EdgeInsets.only(top: 14, bottom: 4),
                  child: Text(
                    line.substring(2),
                    style: Theme.of(
                      context,
                    ).textTheme.titleMedium?.copyWith(color: Palette.flame),
                  ),
                )
              else if (line.startsWith('- '))
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('•  '),
                      Expanded(
                        child: Text(
                          line.substring(2),
                          style: const TextStyle(height: 1.35),
                        ),
                      ),
                    ],
                  ),
                )
              else if (line.isEmpty)
                const SizedBox(height: 8)
              else
                Text(line, style: const TextStyle(height: 1.4)),
          ],
        ),
      ),
    );
  }
}

/// Home: the newest posts that matter (patch notes, a coming patch, plans), with how many are unread.
class NewsCard extends StatelessWidget {
  const NewsCard({super.key, required this.db});
  final GameDb db;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: keenNews,
    builder: (context, _) {
      final top =
          keenNews.posts.where((p) => p.kind != NewsKind.news).take(3).toList();
      if (top.isEmpty) return const SizedBox.shrink();
      final n = keenNews.unread;
      return DashCard(
        title:
            n > 0
                ? tr('News from Keen · {n} new', {'n': n})
                : tr('News from Keen'),
        icon: Icons.campaign_outlined,
        color: Palette.flame,
        action: tr('All'),
        onAction:
            () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => NewsScreen(db: db)),
            ),
        child: Column(
          children: [for (final p in top) NewsTile(db: db, post: p)],
        ),
      );
    },
  );
}
