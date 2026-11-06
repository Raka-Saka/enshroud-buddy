import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'data/db_store.dart';
import 'data/game_db.dart';
import 'data/guide.dart';
import 'data/item_icons.dart';
import 'data/live_state.dart';
import 'data/pins.dart';
import 'data/planner.dart';
import 'data/tracker.dart';
import 'data/updates.dart';
import 'data/where.dart';
import 'l10n.dart';
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
    // the Android libraries the app is built with, which Flutter doesn't list itself
    yield LicenseEntryWithLineBreaks([
      'AndroidX',
      'Kotlin standard library',
    ], await rootBundle.loadString('assets/licenses/apache-2.0.txt'));
    yield const LicenseEntryWithLineBreaks(
      ['Google code scanner'],
      'QR pairing uses Google Play services\' code scanner (com.google.android.gms:'
      'play-services-code-scanner), under the Google APIs Terms of Service and the ML Kit Terms: '
      'https://developers.google.com/terms and https://developers.google.com/ml-kit/terms. Google may '
      'collect usage metrics for the scanner, as its privacy notice describes: '
      'https://policies.google.com/privacy',
    );
  });
  runApp(const CompanionApp());
  Updates.check();
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
    final icons = Future.wait([ItemIcons.load(), MapIcons.load(), L10n.load()]);
    final db = await DbStore.load();
    await icons;
    return db;
  }

  final messenger = GlobalKey<ScaffoldMessengerState>();
  DateTime? _checked;

  @override
  void initState() {
    super.initState();
    L10n.changed.addListener(_relang);
    live.addListener(_maybeUpdate);
    navTarget.addListener(_sendTarget);
    _sendTarget();
    for (final l in [goals, live, live.pos]) {
      l.addListener(_trackSoon);
    }
    _trackSoon();
  }

  Timer? _trackTimer;

  /// The plan's next tasks go to the PC's overlay too, at most every 2 s (moving changes what's close by).
  void _trackSoon() =>
      _trackTimer ??= Timer(const Duration(seconds: 2), _track);

  Future<void> _track() async {
    final current = await db;
    final terrain = await Terrain.instance;
    _trackTimer = null;
    final tracker = trackerOf(
      current,
      live.state,
      goals.all,
      terrain,
      live.pos.value,
    );
    // the PC shows its tray, pairing window and overlay in the app's language
    live.setTracker(
      tracker == null ? null : {...tracker, 'lang': L10n.lang.code},
    );
  }

  /// The guide's target goes to the PC as well, which marks it over the game (tools/overlay.py).
  void _sendTarget() {
    final t = navTarget.value;
    live.setTarget(
      t == null
          ? null
          : {'title': gt(t.title), 'x': t.x, 'y': t.y, 'h': t.height},
    );
  }

  /// Another language picked in Setup: load its texts, then every screen starts over in it.
  Future<void> _relang() async {
    await L10n.load();
    if (!mounted) return;
    setState(() {});
    _trackSoon();
  }

  @override
  void dispose() {
    L10n.changed.removeListener(_relang);
    live.removeListener(_maybeUpdate);
    navTarget.removeListener(_sendTarget);
    for (final l in [goals, live, live.pos]) {
      l.removeListener(_trackSoon);
    }
    _trackTimer?.cancel();
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
        content: Text(
          tr('Game data updated from your PC ({built})', {
            'built': fresh.built,
          }),
        ),
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
        title: 'Enshroud Buddy',
        debugShowCheckedModeBanner: false,
        locale: L10n.lang.locale,
        supportedLocales: [for (final l in languages) l.locale],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: buildTheme(),
        home: FutureBuilder<GameDb>(
          future: db,
          builder: (context, snap) {
            if (snap.hasError) {
              return Scaffold(
                body: Center(
                  child: Text(
                    tr('Could not load game data\n{error}', {
                      'error': snap.error,
                    }),
                  ),
                ),
              );
            }
            if (!snap.hasData) return const _Splash();
            // a new key when the data changes, so every screen starts over with it
            return Home(
              key: ValueKey('${snap.data!.built} ${L10n.lang.code}'),
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
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.local_fire_department,
            size: 56,
            color: Palette.flame,
          ),
          const SizedBox(height: 16),
          Text(
            tr('Kindling the Flame…'),
            style: const TextStyle(
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
            NavigationDestination(
              icon: const Icon(Icons.home_outlined),
              selectedIcon: const Icon(Icons.home),
              label: tr('Home'),
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
              label: tr('Plan'),
            ),
            NavigationDestination(
              icon: const Icon(Icons.map_outlined),
              selectedIcon: const Icon(Icons.map),
              label: tr('Map'),
            ),
            NavigationDestination(
              icon: const Icon(Icons.shield_outlined),
              selectedIcon: const Icon(Icons.shield),
              label: tr('Character'),
            ),
            NavigationDestination(
              icon: const Icon(Icons.auto_stories_outlined),
              selectedIcon: const Icon(Icons.auto_stories),
              label: tr('Codex'),
            ),
          ],
        ),
      ),
    );
  }
}
