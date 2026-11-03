import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data/db_store.dart';
import 'data/game_db.dart';
import 'data/item_icons.dart';
import 'data/live_state.dart';
import 'data/pins.dart';
import 'data/planner.dart';
import 'nav.dart';
import 'screens/character_screen.dart';
import 'screens/codex_screen.dart';
import 'screens/home_screen.dart';
import 'screens/map_screen.dart';
import 'screens/plans_screen.dart';
import 'theme.dart';

void main() {
  // the bundled font's license, next to the packages' on the licenses page (Setup)
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Cinzel font',
    ], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
  runApp(const CompanionApp());
}

class CompanionApp extends StatefulWidget {
  const CompanionApp({super.key});

  @override
  State<CompanionApp> createState() => _CompanionAppState();
}

class _CompanionAppState extends State<CompanionApp> {
  final live = Live()..start();
  final pins = Pins()..load();
  final goals = Goals()..load();
  late Future<GameDb> db = _load();

  static Future<GameDb> _load() async {
    final icons = Future.wait([ItemIcons.load(), MapIcons.load()]);
    final db = await DbStore.load();
    await icons;
    return db;
  }

  final messenger = GlobalKey<ScaffoldMessengerState>();
  DateTime? _checked;

  @override
  void initState() {
    super.initState();
    live.addListener(_maybeUpdate);
  }

  @override
  void dispose() {
    live.removeListener(_maybeUpdate);
    super.dispose();
  }

  /// When the PC agent is reachable, at most every 10 minutes: take newer game data without a reinstall.
  Future<void> _maybeUpdate() async {
    if (live.error != null || live.state == null) return;
    final now = DateTime.now();
    if (_checked != null && now.difference(_checked!).inMinutes < 10) return;
    _checked = now;
    final current = await db;
    final fresh = await DbStore.update(live.host, live.key, current);
    if (fresh == null || !mounted) return;
    setState(() => db = Future.value(fresh));
    messenger.currentState?.showSnackBar(
      SnackBar(
        content: Text('Game data updated from your PC (${fresh.built})'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LiveScope(
    live: live,
    child: GoalsScope(
      goals: goals,
      child: MaterialApp(
        scaffoldMessengerKey: messenger,
        title: 'Enshrouded Companion',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: FutureBuilder<GameDb>(
          future: db,
          builder: (context, snap) {
            if (snap.hasError) {
              return Scaffold(
                body: Center(
                  child: Text('Could not load game data\n${snap.error}'),
                ),
              );
            }
            if (!snap.hasData) return const _Splash();
            // a new key when the data changes, so every screen starts over with it
            return Home(
              key: ValueKey(snap.data!.built),
              db: snap.data!,
              pins: pins,
            );
          },
        ),
      ),
    ),
  );
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.local_fire_department, size: 56, color: Palette.flame),
          SizedBox(height: 16),
          Text(
            'Kindling the Flame…',
            style: TextStyle(
              fontFamily: 'Cinzel',
              fontSize: 18,
              color: Palette.bone,
            ),
          ),
        ],
      ),
    ),
  );
}

class Home extends StatefulWidget {
  const Home({super.key, required this.db, required this.pins});
  final GameDb db;
  final Pins pins;

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  @override
  void initState() {
    super.initState();
    appTab.addListener(_changed);
    mapFocus.addListener(_toMap);
    showShopping.addListener(_toMap);
  }

  @override
  void dispose() {
    appTab.removeListener(_changed);
    mapFocus.removeListener(_toMap);
    showShopping.removeListener(_toMap);
    super.dispose();
  }

  void _changed() => setState(() {});

  void _toMap() {
    // the Shopping layer turned on from the map itself (its chips or Layers sheet) leaves that sheet open
    final fromMap = mapFocus.value == null && appTab.value == Tabs.map;
    if (!fromMap && (mapFocus.value != null || showShopping.value)) {
      Navigator.of(context).popUntil((r) => r.isFirst);
      goTo(Tabs.map);
    }
  }

  @override
  Widget build(BuildContext context) {
    final goals = GoalsScope.of(context).all.length;
    final pages = [
      HomeScreen(db: widget.db),
      PlansScreen(db: widget.db),
      MapScreen(db: widget.db, pins: widget.pins),
      CharacterScreen(db: widget.db),
      CodexScreen(db: widget.db),
    ];
    return PopScope(
      // back on another tab goes Home first, like the system apps
      canPop: appTab.value == Tabs.home,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) goTo(Tabs.home);
      },
      child: Scaffold(
        body: IndexedStack(index: appTab.value, children: pages),
        bottomNavigationBar: NavigationBar(
          selectedIndex: appTab.value,
          onDestinationSelected: (i) {
            HapticFeedback.selectionClick();
            goTo(i);
          },
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: 'Home',
            ),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: goals > 0,
                label: Text('$goals'),
                child: const Icon(Icons.checklist_outlined),
              ),
              selectedIcon: Badge(
                isLabelVisible: goals > 0,
                label: Text('$goals'),
                child: const Icon(Icons.checklist),
              ),
              label: 'Plan',
            ),
            const NavigationDestination(
              icon: Icon(Icons.map_outlined),
              selectedIcon: Icon(Icons.map),
              label: 'Map',
            ),
            const NavigationDestination(
              icon: Icon(Icons.shield_outlined),
              selectedIcon: Icon(Icons.shield),
              label: 'Character',
            ),
            const NavigationDestination(
              icon: Icon(Icons.auto_stories_outlined),
              selectedIcon: Icon(Icons.auto_stories),
              label: 'Codex',
            ),
          ],
        ),
      ),
    );
  }
}
