import 'package:flutter/material.dart';

import '../data/game_db.dart';
import '../nav.dart';
import 'items_screen.dart';
import 'lore_screen.dart';
import 'sets_screen.dart';

/// Everything the game knows: items and recipes, gear sets, lore and quests.
class CodexScreen extends StatefulWidget {
  const CodexScreen({super.key, required this.db});
  final GameDb db;

  @override
  State<CodexScreen> createState() => _CodexScreenState();
}

class _CodexScreenState extends State<CodexScreen>
    with SingleTickerProviderStateMixin {
  late final tabs = TabController(
    length: 4,
    vsync: this,
    initialIndex: codexTab.value,
  );

  /// Another screen asked for a sub-tab (goTo(Tabs.codex, codex: ...)).
  void _jump() => tabs.animateTo(codexTab.value);

  @override
  void initState() {
    super.initState();
    codexTab.addListener(_jump);
    tabs.addListener(() => codexTab.value = tabs.index);
  }

  @override
  void dispose() {
    codexTab.removeListener(_jump);
    tabs.dispose();
    super.dispose();
  }

  GameDb get db => widget.db;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Codex'),
      bottom: TabBar(
        controller: tabs,
        isScrollable: true,
        tabs: [
          // plain labels fit a phone's width; each tab shows its own count
          const Tab(text: 'Items'),
          const Tab(text: 'Sets'),
          const Tab(text: 'Lore'),
          const Tab(text: 'Quests'),
        ],
      ),
    ),
    body: TabBarView(
      controller: tabs,
      children: [
        ItemsScreen(db: db, embedded: true),
        SetsScreen(db: db, embedded: true),
        DocsScreen(db: db, docs: db.lore, title: 'Lore', embedded: true),
        DocsScreen(db: db, docs: db.quests, title: 'Quests', embedded: true),
      ],
    ),
  );
}
