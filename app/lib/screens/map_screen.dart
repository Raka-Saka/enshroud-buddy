import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../data/game_db.dart';
import '../data/clusters.dart';
import '../data/guide.dart';
import '../data/hall_check.dart';
import '../data/hall_plan.dart';
import '../data/item_icons.dart';
import '../data/screen_on.dart';
import '../data/live_state.dart';
import '../data/pins.dart';
import '../data/planner.dart';
import '../data/route.dart';
import '../data/shroud.dart';
import '../data/where.dart';
import 'plans_screen.dart';
import '../l10n.dart';
import '../nav.dart';
import '../theme.dart';
import 'ask_screen.dart';
import 'gear_screen.dart';
import 'item_screen.dart';
import 'lore_screen.dart';
import '../data/background.dart';

/// Map grid (World.mapPx, as in the save) to map coordinates: CrsSimple spans 0..1.
LatLng gridToLatLng(double x, double y) =>
    LatLng(-y / World.mapPx, x / World.mapPx);
(double, double) latLngToGrid(LatLng p) => (
  p.longitude * World.mapPx,
  -p.latitude * World.mapPx,
);

final _bounds = LatLngBounds(const LatLng(-1, 0), const LatLng(0, 1));

/// Set by other screens ("Show on map"); Home switches to the Map tab and the map centres on it.
final mapFocus = ValueNotifier<Poi?>(null);

/// The Shopping layer: the best places for everything on the shopping list.
final showShopping = ValueNotifier<bool>(false);

/// A layer another screen wants on ('water', 'shroud'); the map turns it on and shows itself.
final mapShow = ValueNotifier<String?>(null);

IconData pinIcon(String kind) => switch (kind) {
  'resource' => Icons.diamond_outlined,
  'chest' => Icons.inventory_2_outlined,
  'danger' => Icons.warning_amber_rounded,
  'todo' => Icons.flag_outlined,
  _ => Icons.push_pin_outlined,
};

/// A pin kind's name on screen (Pin.kinds keeps the English one, which a pin stores as its default title).
String _pinKindLabel(String key, String en) => switch (key) {
  'note' => tr('Note'),
  'resource' => tr('Resource'),
  'chest' => tr('Chest / loot'),
  'danger' => tr('Danger'),
  'todo' => tr('To do'),
  _ => en,
};

/// A place kind's name on screen: the game's, or "Other" for places without one.
String _kindLabel(String k) => k == 'Other' ? tr('Other') : gt(k);

/// A loot group's name on screen (GameDb.lootGroups keeps the English one).
String _lootGroupLabel(String g) => switch (g) {
  'Clothes' => tr('Clothes'),
  'Weapons' => tr('Weapons'),
  'Armor & rings' => tr('Armor & rings'),
  'Other' => tr('Other'),
  _ => g,
};

/// Icon and colour for a map point.
(IconData, Color) poiStyle(Poi p) =>
    p.isUnique
        ? (Icons.star, Palette.gold)
        : switch (p.cat) {
          'lore' => (Icons.menu_book, Palette.parchment),
          'shroud' => (Icons.hourglass_bottom, Palette.flame),
          'spot' => (Icons.shopping_basket, Palette.spring),
          'water' => (Icons.bubble_chart, const Color(0xFF6EC6FF)),
          'fish' => (Icons.phishing, const Color(0xFF6EC6FF)),
          'updraft' => (Icons.air, Palette.spring),
          'chest' => (
            Icons.inventory_2,
            switch (p.kind) {
              'Gold' => const Color(0xFFE8B931),
              'Silver' => const Color(0xFFC9D1D6),
              _ => const Color(0xFFB0834F),
            },
          ),
          _ => switch (p.kind) {
            'Flame Shrine' => (Icons.local_fire_department, Palette.flame),
            'Ancient Spire' => (Icons.cell_tower, Palette.spring),
            'Return Beacon' => (Icons.wb_twilight, Palette.spring),
            'Elixir Well' => (Icons.water_drop, Palette.veil),
            'Boss' => (Icons.whatshot, Palette.ember),
            'Enemy Camp' => (Icons.flag, Palette.ember),
            'Dungeon' => (Icons.castle, const Color(0xFFB58DE0)),
            'Shroud Root' => (Icons.coronavirus_outlined, Palette.veil),
            'Shroud Lair' => (Icons.bug_report_outlined, Palette.ember),
            'Gem Forge' => (Icons.diamond, Palette.spring),
            'Mine' => (Icons.hardware, Palette.ash),
            'Cave' => (Icons.terrain, Palette.ash),
            _ => (Icons.place, Palette.bone),
          },
        };

/// A map point's marker: the game's own when the wiki has it (MapIcons), else a glyph in a ring.
/// Done points fade, with a tick.
class PoiIcon extends StatelessWidget {
  const PoiIcon(this.p, {super.key, this.done = false});
  final Poi p;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = poiStyle(p);
    final path = p.isUnique ? null : MapIcons.asset(p);
    final glyph = Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Palette.night.withValues(alpha: 0.8),
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 1.5),
      ),
      child: Icon(done ? Icons.check : icon, size: 13, color: color),
    );
    // lore notes are many and small in the game too
    final size = p.cat == 'lore' ? 20.0 : 28.0;
    final mark =
        path == null
            ? glyph
            : Image.asset(
              path,
              width: size,
              height: size,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) => glyph,
            );
    if (!done) return mark;
    if (path == null) return Opacity(opacity: 0.45, child: mark);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Opacity(opacity: 0.45, child: mark),
        const Positioned(
          right: -3,
          bottom: -3,
          child: Icon(Icons.check_circle, size: 13, color: Palette.spring),
        ),
      ],
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key, required this.db, required this.pins});
  final GameDb db;
  final Pins pins;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final controller = MapController();
  bool showUnique = true, showShroud = true, showWater = false;
  bool showFish = true, showUpdrafts = false;

  /// "Unique loot only": every other point off (bases stay). [lootItems] narrows it to what a search picked
  /// (an item or a set, [lootTitle]), [lootMissing] to what the character lacks, [lootGroup] to one kind.
  bool lootOnly = false, lootMissing = false;
  Set<String>? lootItems;
  String? lootTitle, lootGroup;

  void _lootHunt(bool on, {bool missing = false}) {
    lootOnly = on;
    lootItems = null;
    lootTitle = null;
    lootGroup = null;
    lootMissing = on && missing;
    if (on) hideDone = false;
  }

  /// Whether a point stays in the loot hunt: some of its unique loot passes the filters.
  bool _lootKeeps(Poi p, HallFinds finds) => p.loot.any(
    (id) =>
        (lootItems?.contains(id) ?? true) &&
        (lootGroup == null || widget.db.lootGroup(id) == lootGroup) &&
        (!lootMissing || finds.hasItem(id) == false),
  );

  /// The player's height, to 2 m, while inside the Hollow Halls (null outside): that floor shows bright.
  double? _floor;

  /// The hall the player is in, and the one opened with "See inside" (HallLayout.halls): only that hall's
  /// rooms and points show in the corner.
  int? _hall, _browseHall;

  static const _hallColors = [
    Palette.ember,
    Palette.flame,
    Palette.spring,
    Color(0xFF6EC6FF),
    Palette.veil,
    Palette.bone,
  ];

  /// "Springlands Hollow Halls": the region its entrance stands in.
  String hallName(Hall h) {
    final region = h.region ?? widget.db.regionAt(h.x, h.y);
    return region == null || region.isEmpty
        ? gt('Hollow Halls')
        : tr('{region} Hollow Halls', {'region': gt(region)});
  }

  /// Floor plans per hall and floor (4 m steps; "all" for the whole hall), built once in the background.
  final _plans = <String, HallPlan>{};
  final _planning = <String>{};

  HallPlan? _floorPlan(int k, double? floor) {
    final l = widget.db.halls!;
    final f = floor == null ? null : (floor / 4).round() * 4.0;
    final key = '$k|${f ?? 'all'}';
    final done = _plans[key];
    if (done != null || !_planning.add(key)) return done;
    final h = l.halls[k];
    final pts = l.points;
    final box = [h.x0, h.y0, h.x1, h.y1];
    final color = _hallColors[k % _hallColors.length].toARGB32();
    final ground = Palette.shroud.toARGB32(), on = Palette.bone.toARGB32();
    final near = Palette.parchment.toARGB32(), far = Palette.ash.toARGB32();
    background(
      () => HallPlan.build(
        pts,
        k,
        box,
        f,
        color: color,
        ground: ground,
        on: on,
        near: near,
        far: far,
      ),
    ).then((plan) {
      if (!mounted) return;
      setState(() {
        // floors passed through long ago go first
        if (_plans.length > 24) _plans.remove(_plans.keys.first);
        _plans[key] = plan;
      });
    });
    return null;
  }

  /// Show a hall's find: open the hall, centre on it, and its sheet.
  void goFind(int k, Poi p) {
    setState(() => _browseHall = k);
    controller.move(gridToLatLng(p.x, p.y), 6.5);
    final s = LiveScope.of(context).state;
    showPoi(p, HallFinds(widget.db, s).had(p) ?? false);
  }

  void openHall(int k) {
    final h = widget.db.halls!.halls[k];
    setState(() => _browseHall = k);
    controller.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds(
          gridToLatLng(h.x0, h.y0),
          gridToLatLng(h.x1, h.y1),
        ),
        padding: const EdgeInsets.fromLTRB(24, 140, 24, 90),
      ),
    );
  }

  /// A farming run for the shopping list, and the stop the guide leads to.
  FarmRoute? route;
  int routeAt = 0;

  /// Plan the run from where you are (or the main base) and lead to its first stop.
  void _planRoute(WhereToGet where, LiveState? s, (double, double) from) {
    final planner = Planner(widget.db, s)..planAll(GoalsScope.of(context).all);
    final need = {
      for (final e in planner.toGather.entries)
        if (!e.key.startsWith('cat:')) e.key: e.value,
    };
    final r = FarmRoute.plan(where, need, fromX: from.$1, fromY: from.$2);
    HapticFeedback.selectionClick();
    setState(() {
      route = r.stops.isEmpty ? null : r;
      routeAt = 0;
    });
    final msg = [
      if (r.stops.isEmpty) tr('Nothing on the shopping list to fetch.'),
      if (r.stops.isNotEmpty)
        trn(
          r.stops.length,
          '{n} stop, {distance} as the crow flies.',
          '{n} stops, {distance} as the crow flies.',
          {'distance': distanceText(r.lengthFrom(from.$1, from.$2))},
        ),
      if (r.skipped.isNotEmpty)
        tr('Not reachable yet: {items}.', {
          'items': r.skipped.map((id) => widget.db.shownName(id)).join(', '),
        }),
    ].join(' ');
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
    _guideStop();
  }

  void _guideStop() {
    final r = route;
    if (r == null) return;
    if (routeAt >= r.stops.length) {
      setState(() => route = null);
      navTarget.value = null;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(tr('Route done.'))));
      return;
    }
    final stop = r.stops[routeAt];
    navigateTo(
      NavTarget(
        stop.items.keys.map(widget.db.nameOf).join(', '),
        stop.x,
        stop.y,
      ),
    );
  }

  bool showCold = false;
  ShroudMap? shroud;
  Terrain? terrain;
  MemoryImage? coldImage;

  /// A place shown from the shopping list or an item page that isn't a map point itself.
  Poi? focusSpot;
  int? overlayFor;
  MemoryImage? shroudImage;
  bool showFog = true,
      showBases = true,
      showPins = true,
      showLore = false,
      showChests = false,
      hideDone = false;
  late Set<String> kinds = {
    for (final p in widget.db.poi)
      if (p.cat == 'label') p.kind ?? 'Other',
  };
  late final Set<String> allKinds = {...kinds};
  double zoom = 3;

  /// Keep the player in the middle as they move (until the map is dragged).
  bool following = false;
  HeightMap? heights;

  /// The guide's launch plan, worked out again (in the background) after 16 m of walking.
  LaunchPlan? _plan;
  String? _planKey, _planTarget;

  LaunchPlan? _launchPlan(PlayerPos p, NavTarget t, Glider? g) {
    final hm = heights;
    if (hm == null || g == null || p.airborne) return null;
    final target = '${t.x},${t.y}';
    final key =
        '${(p.x / 2).round()},${(p.y / 2).round()},$target,${g.ratio},${p.walkSpeed}';
    if (key != _planKey) {
      _planKey = key;
      LaunchPlan.later(p, t, hm, g).then((plan) {
        if (mounted && _planKey == key) {
          setState(() {
            _plan = plan;
            _planTarget = target;
          });
        }
      }, onError: (_) {});
    }
    return _planTarget == target ? _plan : null;
  }

  /// Buzzed once on reaching the guide's target.
  bool _arrivedBuzzed = false;
  Live? _live;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    widget.pins.addListener(_changed);
    mapFocus.addListener(_focus);
    showShopping.addListener(_changed);
    mapShow.addListener(_showLayer);
    appTab.addListener(_watchPos);
    _lifecycle = AppLifecycleListener(onStateChange: (_) => _watchPos());
    navTarget.addListener(_navChanged);
    HeightMap.instance.then((h) {
      if (mounted) setState(() => heights = h);
    });
    Terrain.instance.then(
      (t) => setState(() {
        terrain = t;
        shroud = t.shroud;
      }),
    );
  }

  /// Recolour the Shroud overlay when the passage level changes.
  MemoryImage? _shroudOverlay(int passage) {
    final m = shroud;
    if (m == null) return null;
    if (overlayFor != passage) {
      overlayFor = passage;
      shroudImage = MemoryImage(m.overlay(passage));
    }
    return shroudImage;
  }

  /// What a tap on the map says about that spot (Shroud level, cold), shown there for a few seconds.
  ({LatLng at, String text})? _note;
  Timer? _noteTimer;

  void _say(LatLng at, String? text) {
    _noteTimer?.cancel();
    setState(() => _note = text == null ? null : (at: at, text: text));
    if (text != null) {
      _noteTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _note = null);
      });
    }
  }

  void _tapInfo(LatLng at, int passage) {
    // a tap on the map also lets go of a place shown from another screen
    if (focusSpot != null) setState(() => focusSpot = null);
    final (x, y) = latLngToGrid(at);
    final lv = shroud?.levelAt(x, y);
    if (lv == null) {
      _say(
        at,
        (terrain?.cold.isCold(x, y) ?? false)
            ? tr(
              'Cold zone: frost resistance from gear or food, or a high enough Flame',
            )
            : null,
      );
      return;
    }
    _say(
      at,
      lv > passage
          ? tr(
            'Shroud level {level} (estimated): above your passage level {passage}',
            {'level': lv, 'passage': passage},
          )
          : tr(
            'Shroud level {level} (estimated): you can enter (passage level {passage})',
            {'level': lv, 'passage': passage},
          ),
    );
  }

  void _focus() {
    final p = mapFocus.value;
    if (p == null) return;
    setState(() {
      if (lootOnly) _lootHunt(false);
      if (p.isUnique) showUnique = true;
      if (p.cat == 'spot') {
        if (p.kind?.startsWith('Altar ') ?? false) {
          showBases = true;
        } else {
          focusSpot = p;
        }
      }
    });
    final t = navTarget.value;
    final guiding = t != null && t.title == p.title && t.x == p.x && t.y == p.y;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (guiding) {
        navigateTo(t);
        return;
      }
      controller.move(gridToLatLng(p.x, p.y), 5);
      showPoi(p, false);
    });
    mapFocus.value = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final live = LiveScope.of(context);
    if (live != _live) {
      _live?.pos.removeListener(_moved);
      _live = live..pos.addListener(_moved);
      _watchPos();
    }
  }

  /// Read the live position once a second while the map is the tab on screen.
  void _watchPos() {
    _live?.followPos(_shown);
    _screenOn();
  }

  bool get _shown =>
      appTab.value == Tabs.map &&
      (WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed) ==
          AppLifecycleState.resumed;

  /// The screen stays on while the map shows a live position, so the trail and the guide don't vanish
  /// mid-game; with the game closed or another tab open it sleeps as usual.
  void _screenOn() => ScreenOn.set(_shown && _live?.pos.value != null);

  void _moved() {
    _screenOn();
    final p = _live?.pos.value;
    if (p == null) {
      if (following || _floor != null) {
        setState(() {
          following = false;
          _floor = null;
        });
      }
      return;
    }
    if (following)
      controller.move(gridToLatLng(p.x, p.y), controller.camera.zoom);
    final inHalls = widget.db.halls?.contains(p.x, p.y) ?? false;
    final floor = inHalls ? (p.height / 2).round() * 2.0 : null;
    final hall = inHalls ? widget.db.halls!.hallAt(p.x, p.y, p.height) : null;
    if (floor != _floor || hall != _hall) {
      setState(() {
        _floor = floor;
        _hall = hall;
      });
    }
    final t = navTarget.value;
    if (t != null && !_arrivedBuzzed) {
      final d =
          math.sqrt(math.pow(t.x - p.x, 2) + math.pow(t.y - p.y, 2)) *
          World.mPerPx;
      if (d < 15) {
        _arrivedBuzzed = true;
        HapticFeedback.heavyImpact();
      }
    }
  }

  void _navChanged() {
    _arrivedBuzzed = false;
    if (mounted) setState(() {});
  }

  /// Lead the way to a place: the line and the guide card follow the live position.
  void navigateTo(NavTarget t) {
    navTarget.value = t;
    if (_live?.pos.value != null) {
      _followMe();
    } else {
      controller.move(
        gridToLatLng(t.x, t.y),
        math.max(controller.camera.zoom, 4.2),
      );
    }
  }

  void _followMe() {
    final p = _live?.pos.value;
    if (p == null) return;
    HapticFeedback.selectionClick();
    setState(() => following = true);
    controller.move(
      gridToLatLng(p.x, p.y),
      math.max(controller.camera.zoom, 4.5),
    );
  }

  @override
  void dispose() {
    widget.pins.removeListener(_changed);
    mapFocus.removeListener(_focus);
    showShopping.removeListener(_changed);
    mapShow.removeListener(_showLayer);
    appTab.removeListener(_watchPos);
    navTarget.removeListener(_navChanged);
    _lifecycle.dispose();
    _noteTimer?.cancel();
    _live?.pos.removeListener(_moved);
    _live?.followPos(false);
    ScreenOn.set(false);
    super.dispose();
  }

  void _changed() => setState(() {});

  void _showLayer() {
    final layer = mapShow.value;
    if (layer == null) return;
    setState(() {
      if (layer == 'water') showWater = true;
      if (layer == 'shroud') showShroud = true;
    });
    mapShow.value = null;
  }

  Future<void> editPin({Pin? pin, LatLng? at}) async {
    final title = TextEditingController(text: pin?.title ?? '');
    final note = TextEditingController(text: pin?.note ?? '');
    var kind = pin?.kind ?? 'note';
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Palette.shroud,
      builder:
          (ctx) => StatefulBuilder(
            builder:
                (ctx, setSheet) => Padding(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    16,
                    16,
                    MediaQuery.of(ctx).viewInsets.bottom + 16,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          pin == null ? tr('New pin') : tr('Edit pin'),
                          style: Theme.of(ctx).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: title,
                          autofocus: pin == null,
                          decoration: InputDecoration(hintText: tr('Title')),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: note,
                          maxLines: 3,
                          decoration: InputDecoration(hintText: tr('Note')),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          children: [
                            for (final e in Pin.kinds.entries)
                              ChoiceChip(
                                avatar: Icon(pinIcon(e.key), size: 16),
                                label: Text(_pinKindLabel(e.key, e.value)),
                                selected: kind == e.key,
                                onSelected: (_) => setSheet(() => kind = e.key),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            if (pin != null)
                              IconButton(
                                tooltip: tr('Delete'),
                                icon: const Icon(
                                  Icons.delete_outline,
                                  color: Palette.ember,
                                ),
                                onPressed: () => Navigator.pop(ctx, 'delete'),
                              ),
                            if (pin != null)
                              IconButton(
                                tooltip: tr('Navigate'),
                                icon: const Icon(
                                  Icons.near_me,
                                  color: Palette.flame,
                                ),
                                onPressed: () => Navigator.pop(ctx, 'navigate'),
                              ),
                            const Spacer(),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: Text(tr('Cancel')),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(ctx, 'save'),
                              child: Text(tr('Save')),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
          ),
    );
    if (result == 'delete' && pin != null) {
      await widget.pins.remove(pin);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(tr('Pin "{title}" deleted', {'title': pin.title})),
            action: SnackBarAction(
              label: tr('Undo'),
              onPressed: () => widget.pins.add(pin),
            ),
          ),
        );
    } else if (result == 'navigate' && pin != null) {
      navigateTo(NavTarget(pin.title, pin.x, pin.y));
    } else if (result == 'save') {
      final t =
          title.text.trim().isEmpty ? Pin.kinds[kind]! : title.text.trim();
      if (pin == null) {
        final (x, y) = latLngToGrid(at!);
        await widget.pins.add(
          Pin(x: x, y: y, title: t, note: note.text.trim(), kind: kind),
        );
      } else {
        pin
          ..title = t
          ..note = note.text.trim()
          ..kind = kind;
        await widget.pins.update();
      }
    }
  }

  void showPoi(Poi p, bool done) {
    final db = widget.db;
    final setting = p.lootSetting == null ? null : db.loot[p.lootSetting];
    void openItem(String id) {
      final it = db.items[id];
      if (it != null)
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ItemScreen(db: db, item: it)),
        );
    }

    Widget heightLine(PlayerPos? me) => Text(
      heightNote(p.height!, heights?.at(p.x, p.y), me),
      style: const TextStyle(color: Palette.ash),
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Palette.shroud,
      builder:
          (ctx) => DraggableScrollableSheet(
            expand: false,
            initialChildSize:
                p.cat == 'chest' || p.cat == 'fish' || p.title == 'Hollow Halls'
                    ? 0.5
                    : 0.3,
            maxChildSize: 0.9,
            builder:
                (ctx, scroll) => ListView(
                  controller: scroll,
                  padding: const EdgeInsets.all(16),
                  children: [
                    Row(
                      children: [
                        PoiIcon(p),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            gt(p.title),
                            style: Theme.of(ctx).textTheme.titleLarge,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      [
                        switch (p.cat) {
                          'lore' => tr('Lore note'),
                          'chest' => tr('Loot chest'),
                          'special' => tr('Unique loot'),
                          _ => gtn(p.kind) ?? '',
                        },
                        if (p.inside && p.height != null)
                          tr('inside the Hollow Halls, {height} m up', {
                            'height': p.height!.round(),
                          }),
                        if (done)
                          p.cat == 'lore' ? tr('found') : tr('completed'),
                      ].join(' · '),
                      style: TextStyle(
                        color: done ? Palette.spring : Palette.ash,
                      ),
                    ),
                    if (!p.inside && p.height != null)
                      _live == null
                          ? heightLine(null)
                          : ValueListenableBuilder(
                            valueListenable: _live!.pos,
                            builder: (_, me, _) => heightLine(me),
                          ),
                    Wrap(
                      spacing: 4,
                      children: [
                        TextButton.icon(
                          icon: const Icon(Icons.near_me, size: 18),
                          label: Text(tr('Navigate')),
                          onPressed: () {
                            Navigator.pop(ctx);
                            navigateTo(NavTarget.poi(p));
                          },
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.auto_awesome, size: 18),
                          label: Text(tr('Ask about this place')),
                          onPressed: () {
                            Navigator.pop(ctx);
                            askAbout(context, db, p.title, placePrompts(p));
                          },
                        ),
                      ],
                    ),
                    if (p.cat == 'spot' && p.itemId != null) ...[
                      const SizedBox(height: 8),
                      ActionChip(
                        avatar: const Icon(Icons.shopping_basket, size: 16),
                        label: Text(tr('Item page')),
                        onPressed: () => openItem(p.itemId!),
                      ),
                    ],
                    if (p.cat == 'special') ...[
                      const SizedBox(height: 10),
                      Text(
                        p.candidates > 1
                            ? tr('In one of {n} chests around here.', {
                              'n': p.candidates,
                            })
                            : tr('In a chest right here.'),
                      ),
                      const SizedBox(height: 8),
                      ActionChip(
                        avatar: const Icon(
                          Icons.star,
                          size: 16,
                          color: Palette.gold,
                        ),
                        label: Text(gt(p.title)),
                        onPressed: () => openItem(p.itemId!),
                      ),
                    ],
                    if (p.fixed.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        tr('Always holds'),
                        style: TextStyle(
                          color: Palette.gold,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final id in p.fixed)
                            ActionChip(
                              avatar: switch (HallFinds(
                                db,
                                LiveScope.of(context).state,
                              ).hasItem(id)) {
                                true => const Icon(
                                  Icons.check_circle,
                                  size: 16,
                                  color: Palette.spring,
                                ),
                                _ => const Icon(
                                  Icons.star,
                                  size: 16,
                                  color: Palette.gold,
                                ),
                              },
                              label: Text(db.shownName(id)),
                              onPressed: () => openItem(id),
                            ),
                        ],
                      ),
                      if (HallFinds(db, LiveScope.of(context).state).had(p)
                          case final had?)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            had
                                ? tr(
                                  'You have it (in gear, bag, a chest, or its recipe).',
                                )
                                : tr(
                                  'Not found yet: not in your gear, bag or chests.',
                                ),
                            style: TextStyle(
                              color: had ? Palette.spring : Palette.flame,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                    if (setting != null) ...[
                      const SizedBox(height: 14),
                      Text(
                        tr('Random loot · rarity odds'),
                        style: TextStyle(
                          color: Palette.flame,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      for (var r = 0; r < 5; r++)
                        if (setting.odds[r] > 0)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 90,
                                  child: Text(
                                    gt(LootSetting.rarities[r]),
                                    style: TextStyle(
                                      color: Palette.rarity(
                                        LootSetting.rarities[r],
                                      ),
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: LinearProgressIndicator(
                                    value: setting.odds[r] / 100,
                                    color: Palette.rarity(
                                      LootSetting.rarities[r],
                                    ),
                                    backgroundColor: Palette.shroudHigh,
                                  ),
                                ),
                                SizedBox(
                                  width: 48,
                                  child: Text(
                                    '${setting.odds[r].toStringAsFixed(0)}%',
                                    textAlign: TextAlign.right,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      const SizedBox(height: 10),
                      Text(
                        tr('Can contain {n} items: {kinds}', {
                          'n': setting.poolSize,
                          'kinds': (setting.categories.entries.toList()
                                ..sort((a, b) => b.value.compareTo(a.value)))
                              .map(
                                (e) => '${e.value} ${gt(e.key).toLowerCase()}',
                              )
                              .join(', '),
                        }),
                        style: const TextStyle(color: Palette.ash),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final id in _examplesFor(setting, p.areaLevel))
                            ActionChip(
                              label: Text(db.shownName(id)),
                              onPressed: () => openItem(id),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        p.areaLevel > 0
                            ? tr(
                              'Area level {level}: loot drops at about level {level}. Examples above fit that level. Every {chest} shares this pool and these odds; the area sets the level. Chests refill over time.',
                              {
                                'level': p.areaLevel,
                                'chest':
                                    gt(
                                      p.title,
                                    ).split(' · ').first.toLowerCase(),
                              },
                            )
                            : tr(
                              'Loot level scales with you here. Chests refill over time.',
                            ),
                        style: const TextStyle(
                          color: Palette.ash,
                          fontSize: 12,
                        ),
                      ),
                    ],
                    if (p.cat == 'label' && p.title == 'Hollow Halls')
                      if (db.halls?.entranceAt(p.x, p.y) case final k?) ...[
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          icon: const Icon(Icons.account_tree_outlined),
                          label: Text(tr('See inside')),
                          onPressed: () {
                            Navigator.pop(ctx);
                            openHall(k);
                          },
                        ),
                        const SizedBox(height: 6),
                        Text(
                          tr(
                            '{hall}, level {level}. The game keeps every hall\'s inside in one far corner of the world; the map shows this one there with its chests, notes and save points. Inside, it follows you: your floor bright, the others faint.',
                            {
                              'hall': hallName(db.halls!.halls[k]),
                              'level': db.halls!.halls[k].level,
                            },
                          ),
                          style: const TextStyle(
                            color: Palette.ash,
                            fontSize: 12,
                          ),
                        ),
                        _HallCheckView(
                          check: HallCheck(
                            db,
                            db.halls!.halls[k],
                            LiveScope.of(context).state,
                          ),
                          onGear: () {
                            Navigator.pop(ctx);
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => GearScreen(db: db),
                              ),
                            );
                          },
                        ),
                        _FindsView(
                          finds: HallFinds(
                            db,
                            LiveScope.of(context).state,
                          ).of(k),
                          onTap: (f) {
                            Navigator.pop(ctx);
                            goFind(k, f.poi);
                          },
                        ),
                        _HallQuestsView(
                          quests: HallFinds(
                            db,
                            LiveScope.of(context).state,
                          ).quests(db.halls!.halls[k]),
                        ),
                      ],
                    if (db.fish[p.fishTable] case final ft?) ...[
                      const SizedBox(height: 12),
                      Text(
                        tr('Bites here · share of fish'),
                        style: TextStyle(
                          color: Palette.flame,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      for (final f in ft.fish)
                        if (db.items[f.id] case final it?)
                          InkWell(
                            onTap: () => openItem(f.id),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 3),
                              child: Row(
                                children: [
                                  ItemIcon(it, size: 26),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      f.time.isEmpty
                                          ? gt(it.name)
                                          : tr('{fish} · {time} only', {
                                            'fish': gt(it.name),
                                            'time': gt(f.time).toLowerCase(),
                                          }),
                                    ),
                                  ),
                                  Text('${f.share.toStringAsFixed(1)}%'),
                                ],
                              ),
                            ),
                          ),
                      const SizedBox(height: 8),
                      Text(
                        [
                          if (ft.trash > 0)
                            tr(
                              '{percent}% of casts land treasure or trash (your bait decides which)',
                              {'percent': ft.trash.toStringAsFixed(0)},
                            ),
                          if (ft.boot > 0)
                            tr('{percent}% a wet boot', {
                              'percent': ft.boot.toStringAsFixed(0),
                            }),
                          if (p.areaLevel > 0)
                            tr('area level {level}', {'level': p.areaLevel}),
                        ].join(' · '),
                        style: const TextStyle(
                          color: Palette.ash,
                          fontSize: 12,
                        ),
                      ),
                    ],
                    if (p.lore != null) ...[
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        icon: const Icon(Icons.auto_stories_outlined),
                        label: Text(tr('Open in Codex')),

                        onPressed: () {
                          Navigator.pop(ctx);
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder:
                                  (_) => DocScreen(
                                    db: db,
                                    doc: db.lore[p.lore![0]],
                                  ),
                            ),
                          );
                        },
                      ),
                    ],
                  ],
                ),
          ),
    );
  }

  /// Pool items that drop at this area level, best rarity first, then closest level range.
  List<String> _examplesFor(LootSetting setting, int level) {
    if (level <= 0 || setting.pool.isEmpty) return setting.examples;
    final top = setting.odds.indexOf(setting.odds.reduce(math.max));
    final fits = [
      for (final id in setting.pool)
        if (widget.db.items[id] case final it?)
          if (it.stats?.levels == null ||
              (it.stats!.levels![0] <= level && level <= it.stats!.levels![1]))
            it,
    ]..sort((a, b) {
      final ra = (Rarity.rank(a.rarity)) == top ? 0 : 1,
          rb = (Rarity.rank(b.rarity)) == top ? 0 : 1;
      if (ra != rb) return ra.compareTo(rb);
      int gap(Item i) =>
          i.stats?.levels == null ? 99 : (i.stats!.levels![0] - level).abs();
      return gap(a).compareTo(gap(b));
    });
    return [for (final it in fits.take(10)) it.id];
  }

  Future<void> search() async {
    final db = widget.db;
    final finds = HallFinds(db, LiveScope.of(context).state);
    final labels = [
      for (final p in db.poi)
        if (p.cat != 'chest' && p.cat != 'special') p,
    ];
    // loot: each item placed in the world (copies by name once), and each set with a piece placed
    final byName = <String, Set<String>>{};
    for (final id in db.placesOf.keys) {
      if (db.items[id] case final it?) (byName[it.name] ??= {}).add(id);
    }
    _Loot loot(String name, Set<String> ids, {ItemSet? set}) {
      final places = {for (final id in ids) ...?db.placesOf[id]};
      final pieces = {for (final id in ids) db.items[id]?.name ?? id};
      final had = {
        for (final id in ids)
          if (finds.hasItem(id) ?? false) db.items[id]?.name ?? id,
      };
      return _Loot(
        name,
        ids,
        places.toList(),
        set: set,
        item: set == null ? db.items[ids.first] : null,
        pieces: pieces.length,
        had: finds.state == null ? null : had.length,
      );
    }

    final loots = [
      for (final MapEntry(key: n, value: ids) in byName.entries) loot(n, ids),
      for (final set in db.sets)
        if ({
              for (final e in set.entries)
                if (db.placesOf.containsKey(e.itemId)) e.itemId,
            }
            case final ids when ids.isNotEmpty)
          loot(set.name, ids, set: set),
    ];
    final pick = await showSearch<_Pick?>(
      context: context,
      delegate: _PoiSearch(labels, loots),
    );
    if (!mounted || pick == null) return;
    if (pick.items case final ids?) {
      _showLoot(pick.title!, ids);
      return;
    }
    final picked = pick.poi;
    if (picked != null) {
      final s = LiveScope.of(context).state;
      setState(() {
        // a place: the full map again
        if (lootOnly) _lootHunt(false);
        if (picked.isUnique) showUnique = true;
        switch (picked.cat) {
          case 'lore':
            showLore = true;
          case 'water':
            showWater = true;
          case 'fish':
            showFish = true;
          case 'updraft':
            showUpdrafts = true;
          case 'label':
            kinds.add(picked.kind ?? 'Other');
        }
        if (picked.inside && picked.hall != null) _browseHall = picked.hall;
        hideDone = false;
      });
      controller.move(gridToLatLng(picked.x, picked.y), 5);
      showPoi(picked, s != null && widget.db.poiDone(picked, s.knowledge));
    }
  }

  /// A search's item or set: only its places on the map, framed, with the had ones marked.
  void _showLoot(String title, Set<String> ids) {
    final places = [
      for (final p in widget.db.poi)
        if (p.loot.any(ids.contains)) p,
    ];
    setState(() {
      _lootHunt(true);
      lootItems = ids;
      lootTitle = title;
      _browseHall = null;
    });
    if (places.isEmpty) return;
    if (places.length == 1) {
      final p = places.single;
      if (p.inside && p.hall != null) setState(() => _browseHall = p.hall);
      controller.move(gridToLatLng(p.x, p.y), 5.5);
      return;
    }
    controller.fitCamera(
      CameraFit.coordinates(
        coordinates: [for (final p in places) gridToLatLng(p.x, p.y)],
        padding: const EdgeInsets.fromLTRB(40, 230, 40, 90),
        maxZoom: 5.5,
      ),
    );
  }

  /// Every layer in one sheet: overlays, points, place kinds.
  Future<void> openLayers() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder:
          (ctx) => StatefulBuilder(
            builder: (ctx, setSheet) {
              void flip(void Function() f) {
                HapticFeedback.selectionClick();
                setSheet(f);
                setState(() {});
              }

              Widget chip(
                String label,
                IconData icon,
                bool on,
                void Function(bool) set,
              ) => FilterChip(
                avatar: Icon(icon, size: 18),
                label: Text(label),
                selected: on,
                onSelected: (v) => flip(() => set(v)),
              );
              Widget group(String title, List<Widget> chips) => Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title.toUpperCase(),
                      style: const TextStyle(
                        fontFamily: 'Cinzel',
                        fontSize: 12,
                        letterSpacing: 1.3,
                        color: Palette.flame,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 8, children: chips),
                  ],
                ),
              );
              return DraggableScrollableSheet(
                expand: false,
                initialChildSize: 0.62,
                maxChildSize: 0.92,
                builder:
                    (ctx, scroll) => ListView(
                      controller: scroll,
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                      children: [
                        group(tr('Overlays'), [
                          chip(
                            tr('Explored'),
                            Icons.visibility_outlined,
                            showFog,
                            (v) => showFog = v,
                          ),
                          chip(
                            tr('Shroud'),
                            Icons.cloud_outlined,
                            showShroud,
                            (v) => showShroud = v,
                          ),
                          chip(
                            tr('Cold'),
                            Icons.ac_unit,
                            showCold,
                            (v) => showCold = v,
                          ),
                        ]),
                        group(tr('Mine'), [
                          chip(
                            tr('Bases'),
                            Icons.local_fire_department,
                            showBases,
                            (v) => showBases = v,
                          ),
                          chip(
                            tr('My pins · {n}', {'n': widget.pins.all.length}),
                            Icons.push_pin_outlined,
                            showPins,
                            (v) => showPins = v,
                          ),
                          chip(
                            tr('Shopping'),
                            Icons.shopping_basket_outlined,
                            showShopping.value,
                            (v) => showShopping.value = v,
                          ),
                        ]),
                        group(tr('Loot and lore'), [
                          chip(
                            tr('Unique loot only'),
                            Icons.star,
                            lootOnly,
                            (v) => _lootHunt(
                              v,
                              missing: LiveScope.of(context).state != null,
                            ),
                          ),
                          chip(
                            tr('Unique loot'),
                            Icons.star_outline,
                            showUnique,
                            (v) => showUnique = v,
                          ),
                          chip(
                            tr('Chests'),
                            Icons.inventory_2_outlined,
                            showChests,
                            (v) => showChests = v,
                          ),
                          chip(
                            tr('Lore'),
                            Icons.menu_book_outlined,
                            showLore,
                            (v) => showLore = v,
                          ),
                          chip(
                            tr('Air bubbles'),
                            Icons.bubble_chart_outlined,
                            showWater,
                            (v) => showWater = v,
                          ),
                          chip(
                            tr('Fishing spots'),
                            Icons.phishing,
                            showFish,
                            (v) => showFish = v,
                          ),
                          chip(
                            tr('Updrafts'),
                            Icons.air,
                            showUpdrafts,
                            (v) => showUpdrafts = v,
                          ),
                        ]),
                        group(
                          tr('Places · {shown} of {all}', {
                            'shown': kinds.length,
                            'all': allKinds.length,
                          }),
                          [
                            for (final k in allKinds.toList()..sort())
                              FilterChip(
                                label: Text(_kindLabel(k)),
                                selected: kinds.contains(k),
                                onSelected:
                                    (v) => flip(
                                      () => v ? kinds.add(k) : kinds.remove(k),
                                    ),
                              ),
                          ],
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(tr('Hide completed places')),
                          subtitle: Text(
                            tr(
                              'Cleared camps, claimed Shroud Roots, found lore',
                            ),
                          ),
                          value: hideDone,
                          onChanged: (v) => flip(() => hideDone = v),
                        ),
                        Text(
                          tr(
                            'Tip: tap the map for the Shroud level or cold there; long-press to drop a pin.',
                          ),
                          style: const TextStyle(
                            color: Palette.ash,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
              );
            },
          ),
    );
  }

  /// Place kinds shown at every zoom; the rest appear from zoom 3.6.
  static const _major = {
    'Ancient Spire',
    'Flame Shrine',
    'Boss',
    'Dungeon',
    'Elixir Well',
    'Return Beacon',
    'Shroud Root',
    'Shroud Lair',
    'Gem Forge',
  };

  /// Zoom levels where markers appear, labels show or groups split (every half step).
  static const _zoomSteps = [
    1.5, 2, 2.5, 3, 3.5, 4, 4.2, 4.5, 5, 5.5, 6, 7, //
  ];

  /// How many layers differ from how the map starts, for the Layers badge (none: no badge).
  int get _activeLayers =>
      [
        (showFog, true),
        (showShroud, true),
        (showCold, false),
        (showBases, true),
        (showPins, true),
        (showShopping.value, false),
        (showUnique, true),
        (lootOnly, false),
        (showChests, false),
        (showLore, false),
        (showWater, false),
        (showFish, true),
        (showUpdrafts, false),
        (hideDone, false),
      ].where((l) => l.$1 != l.$2).length;

  @override
  Widget build(BuildContext context) {
    final live = LiveScope.of(context);
    final s = live.state;
    final known = s?.knowledge ?? const <String>{};
    final home =
        s?.bases.isEmpty ?? true
            ? const LatLng(-0.75, 0.5)
            : () {
              final b = s!.bases.reduce(
                (a, b) => a.altarLevel >= b.altarLevel ? a : b,
              );
              return gridToLatLng(b.mapX, b.mapY);
            }();
    final shroudImg = showShroud ? _shroudOverlay(s?.flameLevel ?? 0) : null;
    if (showCold && coldImage == null && terrain != null) {
      coldImage = MemoryImage(terrain!.cold.overlay());
    }
    final shopping = <(String, RankedSpot)>[];
    final where = WhereToGet(widget.db, s, terrain, here: live.pos.value);
    if (showShopping.value && !lootOnly) {
      final planner = Planner(widget.db, s)
        ..planAll(GoalsScope.of(context).all);
      for (final id in planner.toGather.keys) {
        if (id.startsWith('cat:')) continue;
        for (final r in where.best(id, count: 2)) {
          shopping.add((id, r));
        }
      }
    }
    final showLabels = zoom >= 4.2;
    final points = <Marker>[];
    final floor = _floor;
    final active = _hall ?? _browseHall;
    final finds = HallFinds(widget.db, s);
    // the halls' floor plans in view: the open one (on your floor when you're in it), or all of them
    final plans = <int, HallPlan>{
      if (widget.db.halls case final h? when zoom >= 2.5)
        for (var k = 0; k < h.halls.length; k++)
          if (active == null || active == k)
            if (_floorPlan(k, active == k && _hall != null ? floor : null)
                case final p?)
              k: p,
    };
    final shown = <({Poi p, bool done, bool faint, bool missing})>[];
    // the hunt's count: places shown, and pieces of loot there still missing
    final lootMissingIds = <String>{};
    for (final p in widget.db.poi) {
      if (lootOnly && !_lootKeeps(p, finds)) continue;
      // with a hall open (or you in it), the other halls' points stay off
      if (p.inside && active != null && p.hall != null && p.hall != active) {
        continue;
      }
      // its finds, save points and updrafts are on the map whatever the layers say (plain chests and plaques
      // follow theirs); with you inside, other floors faint
      final mine = p.inside && active != null && p.hall == active;
      final keep =
          mine &&
          switch (p.cat) {
            'chest' => p.fixed.isNotEmpty || showChests,
            'lore' => p.lore != null || showLore,
            _ => true,
          };
      final faint =
          mine &&
          _hall != null &&
          floor != null &&
          p.height != null &&
          (p.height! - floor).abs() > 12;
      // majors at every zoom; the rest from 2.5, gathered into groups until zoomed in
      final visible =
          lootOnly ||
          keep ||
          (!mine && p.isUnique
              ? showUnique && zoom >= 2.5
              : switch (p.cat) {
                'lore' => showLore && zoom >= 2.5,
                'shroud' => showShroud,
                'water' => showWater,
                'chest' => showChests && zoom >= 2.5,
                'fish' => showFish,
                'updraft' => showUpdrafts && zoom >= 2.5,
                _ =>
                  !mine &&
                      kinds.contains(p.kind ?? 'Other') &&
                      (_major.contains(p.kind) || zoom >= 2.5),
              });
      if (!visible) continue;
      // a page read, or loot the character has anywhere, is done; in the open hall, what's missing stands out
      final had = finds.had(p);
      final done = had ?? (s != null && widget.db.poiDone(p, known));
      if (done && hideDone) continue;
      // in the open hall, and for a searched item or set, what's missing carries its name
      final missing = (mine || lootItems != null) && had == false;
      if (lootOnly) {
        lootMissingIds.addAll([
          for (final id in p.loot)
            if ((lootItems?.contains(id) ?? true) && finds.hasItem(id) == false)
              widget.db.items[id]?.name ?? id,
        ]);
      }
      shown.add((p: p, done: done, faint: faint && !missing, missing: missing));
    }
    // points of one kind closer than about 52 dp share a marker with their count, until zoom 5.5
    final groups =
        zoom >= 5.5
            ? [
              for (final v in shown) Cluster([v], v.p.x, v.p.y),
            ]
            : clusterPoints(
              shown,
              x: (v) => v.p.x,
              y: (v) => v.p.y,
              // same kind, and inside the halls the same brightness
              group:
                  (v) =>
                      v.missing
                          ? 'find ${v.p.x} ${v.p.y}'
                          : '${v.p.isUnique
                                  ? 'unique'
                                  : v.p.cat == 'label'
                                  ? 'k:${v.p.kind}'
                                  : v.p.cat}'
                              '${v.faint ? '~' : ''}',
              // 52 dp in map pixels: a 256 px tile spans the whole map at zoom 0
              cell: 52 * World.mapPx / 256 / math.pow(2, zoom),
            );
    for (final g in groups) {
      final v = g.items.first;
      final p = v.p;
      if (g.items.length > 1) {
        points.add(
          Marker(
            point: gridToLatLng(g.x, g.y),
            width: 44,
            height: 44,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap:
                  () => controller.move(
                    gridToLatLng(g.x, g.y),
                    math.min(zoom + 1.5, 8),
                  ),
              child: Opacity(
                opacity: v.faint ? 0.35 : 1,
                child: _GroupMark(
                  icon: PoiIcon(p, done: g.items.every((v) => v.done)),
                  count: g.items.length,
                ),
              ),
            ),
          ),
        );
        continue;
      }
      if (v.missing) {
        final dh =
            _hall != null && floor != null && p.height != null
                ? p.height! - floor
                : 0.0;
        points.add(
          Marker(
            point: gridToLatLng(p.x, p.y),
            width: 150,
            height: 70,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => showPoi(p, false),
              child: _FindMark(
                icon: PoiIcon(p),
                text:
                    p.cat == 'lore'
                        ? gt(p.title)
                        : p.loot
                            .map((id) => widget.db.shownName(id))
                            .toSet()
                            .join(', '),
                // another floor: which way, and how far
                note:
                    dh.abs() <= 6
                        ? null
                        : dh > 0
                        ? tr('{m} m up', {'m': dh.abs().round()})
                        : tr('{m} m down', {'m': dh.abs().round()}),
              ),
            ),
          ),
        );
        continue;
      }
      points.add(
        Marker(
          point: gridToLatLng(p.x, p.y),
          // a 40 dp hit box around the 26 dp marker; labels get room for their pill
          width: showLabels && p.cat == 'label' ? 120 : 40,
          height: showLabels && p.cat == 'label' ? 48 : 40,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => showPoi(p, v.done),
            child: Opacity(
              opacity: v.faint ? 0.35 : 1,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  PoiIcon(p, done: v.done),
                  if (showLabels && p.cat == 'label')
                    // on a dark pill: bone text alone is hard to read on the parchment map
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        color: Palette.night.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        gt(p.title),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: controller,
            options: MapOptions(
              crs: const CrsSimple(),
              initialCenter: home,
              initialZoom: 3,
              minZoom: 1,
              // past the tiles' own detail (4): the map blurs, but markers, pins and the halls' rooms stay sharp
              maxZoom: 8,
              backgroundColor: Palette.night,
              // north stays up: a pinch zooms and pans but never turns the map
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              cameraConstraint: CameraConstraint.containCenter(bounds: _bounds),
              onLongPress: (_, p) => editPin(at: p),
              onTap: (_, p) => _tapInfo(p, s?.flameLevel ?? 0),
              onPositionChanged: (camera, gesture) {
                if (gesture && following) setState(() => following = false);
                final z = camera.zoom;
                int band(double v) => _zoomSteps.where((t) => v >= t).length;
                if (band(z) != band(zoom)) {
                  setState(() => zoom = z);
                }
                zoom = z;
                if (_browseHall != null) {
                  final (cx, cy) = latLngToGrid(camera.center);
                  if (!(widget.db.halls?.contains(cx, cy) ?? false)) {
                    setState(() => _browseHall = null);
                  }
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'assets/map/{z}_{x}_{y}.jpg',
                tileProvider: AssetTileProvider(),
                maxNativeZoom: 4,
                tileBounds: _bounds,
              ),
              if (shroudImg != null)
                OverlayImageLayer(
                  overlayImages: [
                    OverlayImage(bounds: _bounds, imageProvider: shroudImg),
                  ],
                ),
              if (showCold && coldImage != null)
                OverlayImageLayer(
                  overlayImages: [
                    OverlayImage(bounds: _bounds, imageProvider: coldImage!),
                  ],
                ),
              // the last fog stays up through saves and dropped requests (Live.fogOverlay)
              if (showFog)
                ValueListenableBuilder<Uint8List?>(
                  valueListenable: live.fogOverlay,
                  builder:
                      (context, fog, _) =>
                          fog == null
                              ? const SizedBox.shrink()
                              : OverlayImageLayer(
                                overlayImages: [
                                  OverlayImage(
                                    bounds: _bounds,
                                    imageProvider: MemoryImage(fog),
                                    gaplessPlayback: true,
                                  ),
                                ],
                              ),
                ),
              if (widget.db.halls case final h? when zoom >= 2.5) ...[
                _HallsLayer(
                  layout: h,
                  floor: _hall == null ? null : _floor,
                  hall: active,
                  colors: _hallColors,
                  planned: plans.keys.toSet(),
                ),
                if (plans.isNotEmpty)
                  OverlayImageLayer(
                    overlayImages: [
                      for (final p in plans.values)
                        OverlayImage(
                          bounds: LatLngBounds(
                            gridToLatLng(p.x0, p.y0),
                            gridToLatLng(p.x1, p.y1),
                          ),
                          imageProvider: MemoryImage(p.png),
                          gaplessPlayback: true,
                        ),
                    ],
                  ),
              ],
              if (widget.db.halls case final h? when zoom >= 2.5)
                MarkerLayer(
                  markers: [
                    for (var k = 0; k < h.halls.length; k++)
                      if ((_hall ?? _browseHall) == null ||
                          (_hall ?? _browseHall) == k)
                        Marker(
                          point: gridToLatLng(h.halls[k].x0, h.halls[k].y0),
                          width: 240,
                          height: 52,
                          alignment: Alignment.bottomRight,
                          child: GestureDetector(
                            onTap:
                                () =>
                                    _browseHall == k && _hall == null
                                        ? setState(() => _browseHall = null)
                                        : openHall(k),
                            child: _Label(
                              // the open hall's label closes it: every hall shows again
                              icon:
                                  _browseHall == k && _hall == null
                                      ? Icons.close
                                      : Icons.account_tree_outlined,
                              color: _hallColors[k % _hallColors.length],
                              text:
                                  '${gtn(h.halls[k].region) ?? hallName(h.halls[k])} · ${tr('L{n}', {'n': h.halls[k].level})}'
                                  '${switch (finds.missing(k)) {
                                    null => '',
                                    0 => ' · ${tr('all found')}',
                                    final n => ' · ${tr('{n} to find', {'n': n})}',
                                  }}',
                            ),
                          ),
                        ),
                  ],
                ),
              MarkerLayer(markers: points),
              if (route case final r?) ...[
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: [
                        for (final st in r.stops.skip(routeAt))
                          gridToLatLng(st.x, st.y),
                      ],
                      color: Palette.amber.withValues(alpha: 0.8),
                      strokeWidth: 3,
                      pattern: StrokePattern.dashed(segments: const [8, 6]),
                    ),
                  ],
                ),
                MarkerLayer(
                  markers: [
                    for (var i = 0; i < r.stops.length; i++)
                      Marker(
                        point: gridToLatLng(r.stops[i].x, r.stops[i].y),
                        width: 30,
                        height: 30,
                        child: _StopMark(
                          n: i + 1,
                          done: i < routeAt,
                          next: i == routeAt,
                        ),
                      ),
                  ],
                ),
              ],
              if (_note case final n?)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: n.at,
                      width: 240,
                      height: 64,
                      // above the finger, its tail on the spot
                      alignment: Alignment.topCenter,
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Palette.night.withValues(alpha: 0.92),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Palette.veil),
                          ),
                          child: Text(
                            n.text,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              if (shopping.isNotEmpty || focusSpot != null)
                MarkerLayer(
                  markers: [
                    for (final (id, r) in shopping)
                      Marker(
                        point: gridToLatLng(r.spot.x, r.spot.y),
                        width: 140,
                        height: 52,
                        child: GestureDetector(
                          onTap: () => showPoi(where.asPoi(id, r), false),
                          child: _Label(
                            icon: Icons.shopping_basket,
                            color: Palette.risk(r.risk),
                            text: widget.db.shownName(id),
                          ),
                        ),
                      ),
                    if (focusSpot case final f?)
                      Marker(
                        point: gridToLatLng(f.x, f.y),
                        width: 140,
                        height: 52,
                        child: GestureDetector(
                          onTap: () => showPoi(f, false),
                          child: _Label(
                            icon: Icons.shopping_basket,
                            color: Palette.flame,
                            text: gt(f.title),
                          ),
                        ),
                      ),
                  ],
                ),
              if (showBases && s != null)
                MarkerLayer(
                  markers: [
                    for (final b in s.bases)
                      Marker(
                        point: gridToLatLng(b.mapX, b.mapY),
                        width: 140,
                        height: 52,
                        child: _Label(
                          icon: Icons.local_fire_department,
                          color: Palette.flame,
                          text: b.label,
                        ),
                      ),
                  ],
                ),
              if (showPins && !lootOnly)
                MarkerLayer(
                  markers: [
                    for (final p in widget.pins.all)
                      Marker(
                        point: gridToLatLng(p.x, p.y),
                        width: 140,
                        height: 52,
                        child: GestureDetector(
                          onTap: () => editPin(pin: p),
                          child: _Label(
                            icon: pinIcon(p.kind),
                            color: Palette.spring,
                            text: p.title,
                          ),
                        ),
                      ),
                  ],
                ),
              if (navTarget.value case final t?)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: gridToLatLng(t.x, t.y),
                      width: 40,
                      height: 40,
                      child: const _Goal(),
                    ),
                  ],
                ),
              ValueListenableBuilder<PlayerPos?>(
                valueListenable: live.pos,
                builder: (context, p, _) {
                  final t = navTarget.value;
                  final g = p == null ? null : Glider.of(widget.db, s, p);
                  final plan =
                      p == null || t == null ? null : _launchPlan(p, t, g);
                  final hm = heights;
                  final landing =
                      p == null || hm == null || g == null
                          ? null
                          : Landing.of(p, hm, g);
                  Polyline leg(
                    double x0,
                    double y0,
                    double x1,
                    double y1,
                    Color c, {
                    bool dots = false,
                  }) => Polyline(
                    points: [gridToLatLng(x0, y0), gridToLatLng(x1, y1)],
                    color: c,
                    strokeWidth: 3,
                    pattern:
                        dots
                            ? const StrokePattern.dotted(spacingFactor: 1.6)
                            : StrokePattern.dashed(segments: const [10, 7]),
                  );
                  return Stack(
                    children: [
                      if (p != null && (t != null || landing != null))
                        PolylineLayer(
                          polylines: [
                            if (t != null && plan != null) ...[
                              leg(p.x, p.y, plan.x, plan.y, Palette.bone),
                              leg(
                                plan.x,
                                plan.y,
                                t.x,
                                t.y,
                                Palette.spring,
                                dots: true,
                              ),
                            ] else if (t != null)
                              leg(p.x, p.y, t.x, t.y, Palette.flame),
                            if (landing != null)
                              leg(
                                p.x,
                                p.y,
                                landing.x,
                                landing.y,
                                Palette.amber,
                                dots: true,
                              ),
                          ],
                        ),
                      MarkerLayer(
                        markers: [
                          if (t != null && plan != null)
                            Marker(
                              point: gridToLatLng(plan.x, plan.y),
                              width: 28,
                              height: 28,
                              child: const _Waypoint(
                                icon: Icons.landscape,
                                color: Palette.spring,
                              ),
                            ),
                          if (landing != null)
                            Marker(
                              point: gridToLatLng(landing.x, landing.y),
                              width: 28,
                              height: 28,
                              child: const _Waypoint(
                                icon: Icons.paragliding,
                                color: Palette.amber,
                              ),
                            ),
                          if (p != null)
                            Marker(
                              point: gridToLatLng(p.x, p.y),
                              width: 34,
                              height: 34,
                              child: _You(
                                heading: p.travel,
                                airborne: p.airborne,
                              ),
                            ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Material(
                          color: Palette.shroud.withValues(alpha: 0.94),
                          elevation: 3,
                          shadowColor: Colors.black54,
                          shape: const StadiumBorder(),
                          child: InkWell(
                            customBorder: const StadiumBorder(),
                            onTap: search,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 14,
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.search,
                                    color: Palette.flame,
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    tr('Search places and loot'),
                                    style: const TextStyle(color: Palette.ash),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Badge(
                        isLabelVisible: _activeLayers > 0,
                        label: Text('$_activeLayers'),
                        child: IconButton.filledTonal(
                          tooltip: tr('Layers'),
                          style: IconButton.styleFrom(
                            backgroundColor: Palette.shroud.withValues(
                              alpha: 0.94,
                            ),
                            padding: const EdgeInsets.all(14),
                          ),
                          icon: const Icon(
                            Icons.layers_outlined,
                            color: Palette.flame,
                          ),
                          onPressed: openLayers,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final (label, icon, value, set) in [
                          (
                            tr('Unique loot only'),
                            Icons.star_outline,
                            lootOnly,
                            (bool v) => _lootHunt(v, missing: s != null),
                          ),
                          (
                            tr('Shopping'),
                            Icons.shopping_basket_outlined,
                            showShopping.value,
                            (bool v) => showShopping.value = v,
                          ),
                          (
                            tr('Shroud'),
                            Icons.cloud_outlined,
                            showShroud,
                            (bool v) => showShroud = v,
                          ),
                          (
                            tr('Chests'),
                            Icons.inventory_2_outlined,
                            showChests,
                            (bool v) => showChests = v,
                          ),
                          (
                            tr('Lore'),
                            Icons.menu_book_outlined,
                            showLore,
                            (bool v) => showLore = v,
                          ),
                          (
                            tr('Cold'),
                            Icons.ac_unit,
                            showCold,
                            (bool v) => showCold = v,
                          ),
                        ]) ...[
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: FilterChip(
                              avatar: Icon(icon, size: 16),
                              label: Text(label),
                              selected: value,
                              backgroundColor: Palette.shroud.withValues(
                                alpha: 0.9,
                              ),
                              onSelected: (v) {
                                HapticFeedback.selectionClick();
                                setState(() => set(v));
                              },
                            ),
                          ),
                          if (icon == Icons.shopping_basket_outlined &&
                              showShopping.value)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: ActionChip(
                                avatar: const Icon(Icons.route, size: 16),
                                label: Text(
                                  route == null ? tr('Route') : tr('New route'),
                                ),
                                backgroundColor: Palette.shroud.withValues(
                                  alpha: 0.9,
                                ),
                                onPressed: () {
                                  final at = live.pos.value;
                                  _planRoute(
                                    where,
                                    s,
                                    at != null
                                        ? (at.x, at.y)
                                        : latLngToGrid(home),
                                  );
                                },
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                  if (lootOnly) ...[
                    const SizedBox(height: 8),
                    _LootBar(
                      title:
                          lootTitle == null
                              ? tr('Unique loot')
                              : gt(lootTitle!),
                      places: shown.length,
                      missing: s == null ? null : lootMissingIds.length,
                      missingOnly: lootMissing,
                      group: lootItems == null ? lootGroup : null,
                      onMissing:
                          s == null
                              ? null
                              : (v) => setState(() => lootMissing = v),
                      onGroup:
                          lootItems == null
                              ? (g) => setState(() => lootGroup = g)
                              : null,
                      onClose: () => setState(() => _lootHunt(false)),
                    ),
                  ],
                  if (route case final r? when routeAt < r.stops.length) ...[
                    const SizedBox(height: 8),
                    _RouteBar(
                      db: widget.db,
                      route: r,
                      at: routeAt,
                      onDone: () {
                        HapticFeedback.selectionClick();
                        setState(() => routeAt++);
                        _guideStop();
                      },
                      onClose: () {
                        setState(() => route = null);
                        navTarget.value = null;
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),
          ValueListenableBuilder<PlayerPos?>(
            valueListenable: live.pos,
            builder: (context, p, _) {
              final target = navTarget.value;
              if (target != null) {
                return Positioned(
                  left: 12,
                  right: 84,
                  bottom: 12,
                  child: _GuideCard(
                    target: target,
                    pos: p,
                    plan:
                        p == null
                            ? null
                            : _launchPlan(
                              p,
                              target,
                              Glider.of(widget.db, s, p),
                            ),
                    guide:
                        p == null
                            ? null
                            : Guide(
                              p,
                              target,
                              heights,
                              Glider.of(widget.db, s, p),
                            ),
                    onTap: _followMe,
                    onClose: () => navTarget.value = null,
                  ),
                );
              }
              if (p == null) return const SizedBox.shrink();
              final w = Whereabouts(widget.db, s, p);
              return Positioned(
                left: 12,
                right: 84,
                bottom: 12,
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Material(
                    color: Palette.shroud.withValues(alpha: 0.94),
                    elevation: 3,
                    shadowColor: Colors.black54,
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: _followMe,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 9, 14, 9),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Transform.rotate(
                              angle: p.heading * math.pi / 180,
                              child: const Icon(
                                Icons.navigation,
                                size: 18,
                                color: Palette.flame,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    w.text,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    w.height,
                                    style: const TextStyle(
                                      color: Palette.ash,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          Positioned(
            right: 12,
            bottom: 12,
            child: Column(
              children: [
                ValueListenableBuilder<PlayerPos?>(
                  valueListenable: live.pos,
                  builder:
                      (context, p, _) =>
                          p == null
                              ? const SizedBox.shrink()
                              : Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: FloatingActionButton(
                                  heroTag: 'me',
                                  shape: const CircleBorder(),
                                  tooltip: tr('Follow me (live from the game)'),
                                  backgroundColor:
                                      following
                                          ? Palette.flame
                                          : Palette.shroud,
                                  foregroundColor:
                                      following ? Palette.night : Palette.flame,
                                  onPressed: _followMe,
                                  child: const Icon(Icons.navigation),
                                ),
                              ),
                ),
                FloatingActionButton(
                  heroTag: 'home',
                  shape: const CircleBorder(),
                  tooltip: tr('Centre on my main base'),
                  backgroundColor: Palette.shroud,
                  foregroundColor: Palette.flame,
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    controller.move(home, 3.5);
                  },
                  child: const Icon(Icons.home_outlined),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A search pick: a place, or loot (an item's or a set's ids) to show where it lies.
class _Pick {
  const _Pick.place(Poi this.poi) : title = null, items = null;
  const _Pick.loot(String this.title, Set<String> this.items) : poi = null;
  final Poi? poi;
  final String? title;
  final Set<String>? items;
}

/// An item or set the map can find: its ids, the places holding them, and how many pieces are had.
class _Loot {
  _Loot(
    this.name,
    this.ids,
    this.places, {
    this.set,
    this.item,
    required this.pieces,
    this.had,
  });
  final String name;
  final Set<String> ids;
  final List<Poi> places;
  final ItemSet? set;
  final Item? item;
  final int pieces;

  /// Pieces the character has (null without a save).
  final int? had;

  String get where {
    if (set != null) {
      return trn(
        pieces,
        '{category} · {n} piece on the map',
        '{category} · {n} pieces on the map',
        {'category': gt(set!.category)},
      );
    }
    final p = places.first;
    if (places.length == 1 && p.cat == 'special') {
      return p.candidates > 1
          ? tr('In one of {n} chests around there', {'n': p.candidates})
          : tr('In a chest');
    }
    return places.length == 1
        ? tr('In a chest')
        : tr('In {n} places', {'n': places.length});
  }
}

class _PoiSearch extends SearchDelegate<_Pick?> {
  _PoiSearch(this.all, this.loot);
  final List<Poi> all;
  final List<_Loot> loot;

  @override
  String get searchFieldLabel => tr('Places, items in chests, sets');

  @override
  ThemeData appBarTheme(BuildContext context) => Theme.of(context);

  @override
  List<Widget> buildActions(BuildContext context) => [
    IconButton(icon: const Icon(Icons.clear), onPressed: () => query = ''),
  ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
    icon: const Icon(Icons.arrow_back),
    onPressed: () => close(context, null),
  );

  @override
  Widget buildResults(BuildContext context) => buildSuggestions(context);

  @override
  Widget buildSuggestions(BuildContext context) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          tr(
            'A place, a piece of unique loot ("{garb}"), or a whole set ("{set}"): the map then shows only where it lies.',
            {'garb': gt('Farmer Garb'), 'set': gt('Farmer Set')},
          ),
          style: const TextStyle(color: Palette.ash, height: 1.4),
        ),
      );
    }
    // the English name and the shown one both match
    bool hit(String name) =>
        name.toLowerCase().contains(q) || gt(name).toLowerCase().contains(q);
    // names starting with the query first; sets before their pieces
    int rank(String name) =>
        name.toLowerCase().startsWith(q) || gt(name).toLowerCase().startsWith(q)
            ? 0
            : 1;
    final items = [
      for (final l in loot)
        if (hit(l.name)) l,
    ]..sort(
      (a, b) =>
          rank(a.name) != rank(b.name)
              ? rank(a.name) - rank(b.name)
              : (a.set == null) != (b.set == null)
              ? (a.set == null ? 1 : -1)
              : gt(a.name).compareTo(gt(b.name)),
    );
    final places = all.where((p) => hit(p.title)).take(40).toList();
    Widget head(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        t,
        style: const TextStyle(
          color: Palette.flame,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    return ListView(
      children: [
        if (items.isNotEmpty) head(tr('Unique loot')),
        for (final l in items.take(40))
          ListTile(
            leading: SizedBox(
              width: 32,
              child: Center(
                child:
                    l.item != null
                        ? ItemIcon(l.item!, size: 28)
                        : Icon(
                          l.set!.category.startsWith('Clothes')
                              ? Icons.checkroom
                              : Icons.collections_bookmark_outlined,
                          color: Palette.gold,
                        ),
              ),
            ),
            title: Text(gt(l.name)),
            subtitle: Text(l.where, style: const TextStyle(color: Palette.ash)),
            trailing: switch (l.had) {
              null => null,
              final h when l.set != null => Text(
                tr('{had} of {all}', {'had': h, 'all': l.pieces}),
                style: TextStyle(
                  color: h == l.pieces ? Palette.spring : Palette.ash,
                ),
              ),
              final h =>
                h > 0
                    ? const Icon(Icons.check, color: Palette.spring, size: 18)
                    : const Icon(Icons.star, color: Palette.gold, size: 18),
            },
            onTap: () => close(context, _Pick.loot(l.name, l.ids)),
          ),
        if (places.isNotEmpty) head(tr('Places')),
        for (final p in places)
          ListTile(
            leading: SizedBox(width: 32, child: Center(child: PoiIcon(p))),
            title: Text(gt(p.title)),
            subtitle: Text(
              p.cat == 'lore' ? tr('Lore note') : gtn(p.kind) ?? '',
              style: const TextStyle(color: Palette.ash),
            ),
            onTap: () => close(context, _Pick.place(p)),
          ),
        if (items.isEmpty && places.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              tr(
                'Nothing by that name on the map. Loot that only drops at random from a kind of chest has no place: its item page says which chests.',
              ),
              style: const TextStyle(color: Palette.ash, height: 1.4),
            ),
          ),
      ],
    );
  }
}

/// The loot hunt's bar: what is shown, how much is still missing, and its filters.
class _LootBar extends StatelessWidget {
  const _LootBar({
    required this.title,
    required this.places,
    required this.missing,
    required this.missingOnly,
    required this.group,
    required this.onMissing,
    required this.onGroup,
    required this.onClose,
  });
  final String title;
  final int places;

  /// Pieces shown still missing (null without a save).
  final int? missing;
  final bool missingOnly;
  final String? group;
  final ValueChanged<bool>? onMissing;

  /// Null for a search's item or set: no kinds to pick from.
  final ValueChanged<String?>? onGroup;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    Widget chip(String label, bool on, ValueChanged<bool> set) => Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(label),
        selected: on,
        visualDensity: VisualDensity.compact,
        onSelected: (v) {
          HapticFeedback.selectionClick();
          set(v);
        },
      ),
    );
    return Material(
      color: Palette.shroud.withValues(alpha: 0.95),
      elevation: 3,
      shadowColor: Colors.black54,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.star, color: Palette.gold, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: title,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        TextSpan(
                          text: [
                            '',
                            places == 0
                                ? tr('nothing here')
                                : trn(places, '{n} place', '{n} places'),
                            if (missing != null)
                              missing == 0
                                  ? tr('all found')
                                  : tr('{n} to find', {'n': missing}),
                          ].join(' · '),
                          style: const TextStyle(color: Palette.ash),
                        ),
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: tr('Back to the full map'),
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: onClose,
                ),
              ],
            ),
            if (onMissing != null || onGroup != null)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    if (onMissing case final set?)
                      chip(tr('Still missing'), missingOnly, set),
                    if (onGroup case final set?)
                      for (final g in GameDb.lootGroups)
                        chip(
                          _lootGroupLabel(g),
                          group == g,
                          (v) => set(v ? g : null),
                        ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The guide's target on the map.
class _Goal extends StatelessWidget {
  const _Goal();

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: Palette.flame.withValues(alpha: 0.18),
      border: Border.all(color: Palette.flame, width: 2.5),
    ),
    child: const Icon(Icons.flag, size: 20, color: Palette.flame),
  );
}

/// Where the guide leads and how to get there: distance and turn, height, the glide check.
class _GuideCard extends StatelessWidget {
  const _GuideCard({
    required this.target,
    required this.pos,
    required this.plan,
    required this.guide,
    required this.onTap,
    required this.onClose,
  });
  final NavTarget target;
  final PlayerPos? pos;
  final LaunchPlan? plan;
  final Guide? guide;
  final VoidCallback onTap, onClose;

  @override
  Widget build(BuildContext context) {
    final g = guide;
    final glide = g?.glide;
    final glideText = g?.glideText;
    final falling = g?.mode == Motion.fall;
    final mode = g?.modeText;
    return Material(
      color: Palette.shroud.withValues(alpha: 0.96),
      elevation: 4,
      shadowColor: Colors.black54,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.flag, size: 16, color: Palette.flame),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      gt(target.title),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Palette.flame,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (mode != null)
                    Container(
                      margin: const EdgeInsets.only(left: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: (g!.airborne ? Palette.amber : Palette.ash)
                            .withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            switch (g.mode) {
                              Motion.air => Icons.paragliding,
                              Motion.fall => Icons.south,
                              _ => Icons.directions_walk,
                            },
                            size: 12,
                            color: g.airborne ? Palette.amber : Palette.ash,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            mode,
                            style: TextStyle(
                              fontSize: 11,
                              color: g.airborne ? Palette.amber : Palette.ash,
                            ),
                          ),
                        ],
                      ),
                    ),
                  IconButton(
                    tooltip: tr('Stop guiding'),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: onClose,
                  ),
                ],
              ),
              if (g == null)
                Text(
                  tr('Waiting for your position from the game'),
                  style: const TextStyle(color: Palette.ash, fontSize: 12),
                )
              else ...[
                Row(
                  children: [
                    Transform.rotate(
                      angle: g.arrived ? 0 : g.turn * math.pi / 180,
                      child: Icon(
                        g.arrived ? Icons.check_circle : Icons.navigation,
                        size: 26,
                        color: g.arrived ? Palette.spring : Palette.bone,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            g.headline,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            g.heightText,
                            style: const TextStyle(
                              color: Palette.ash,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (glideText != null && !g.arrived) ...[
                  const SizedBox(height: 6),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        falling ? Icons.warning_amber : Icons.paragliding,
                        size: 16,
                        color:
                            !falling && (glide?.reaches ?? false)
                                ? Palette.spring
                                : Palette.amber,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          glideText,
                          style: const TextStyle(fontSize: 12, height: 1.3),
                        ),
                      ),
                    ],
                  ),
                ],
                if (plan != null &&
                    pos != null &&
                    !g.arrived &&
                    !g.airborne) ...[
                  const SizedBox(height: 6),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.landscape,
                        size: 16,
                        color: Palette.spring,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          plan!.describe(pos!),
                          style: const TextStyle(fontSize: 12, height: 1.3),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The player on the map: an arrow turned the way the camera looks.
/// A stop on the guide's route: the launch spot, or where the glide comes down.
class _Waypoint extends StatelessWidget {
  const _Waypoint({required this.icon, required this.color});
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Palette.night.withValues(alpha: 0.85),
      shape: BoxShape.circle,
      border: Border.all(color: color, width: 2),
    ),
    child: Icon(icon, size: 15, color: color),
  );
}

class _You extends StatelessWidget {
  const _You({required this.heading, this.airborne = false});
  final double heading;
  final bool airborne;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Palette.night.withValues(alpha: 0.85),
      shape: BoxShape.circle,
      // in the air the ring turns amber and the arrow points where you fly
      border: Border.all(
        color: airborne ? Palette.amber : Colors.white,
        width: 2,
      ),
      boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 6)],
    ),
    child: Transform.rotate(
      angle: heading * math.pi / 180,
      child: const Icon(Icons.navigation, size: 20, color: Palette.flame),
    ),
  );
}

class _Label extends StatelessWidget {
  const _Label({required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Palette.night.withValues(alpha: 0.85),
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 2),
        ),
        child: Icon(icon, size: 16, color: color),
      ),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: Palette.night.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        ),
      ),
    ],
  );
}

/// A group of map points of one kind: its marker with how many it stands for.
class _GroupMark extends StatelessWidget {
  const _GroupMark({required this.icon, required this.count});
  final Widget icon;
  final int count;

  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.center,
    clipBehavior: Clip.none,
    children: [
      icon,
      Positioned(
        right: 0,
        top: 0,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(
            color: Palette.night,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Palette.flame, width: 1),
          ),
          child: Text(
            count > 99 ? '99+' : '$count',
            style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700),
          ),
        ),
      ),
    ],
  );
}

/// The Hollow Halls' rooms and corridors, drawn from the objects placed in them on a dark ground that
/// hides the map's terrain there. With a hall open only it shows; with the player inside, their floor is
/// bright and the others faint. Otherwise each hall has its colour.
class _HallsLayer extends StatelessWidget {
  const _HallsLayer({
    required this.layout,
    required this.floor,
    required this.hall,
    required this.colors,
    this.planned = const {},
  });
  final HallLayout layout;
  final double? floor;
  final int? hall;
  final List<Color> colors;

  /// Halls drawn as floor plans already (HallPlan): no dots for them.
  final Set<int> planned;

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final o = camera.getOffsetFromOrigin(gridToLatLng(0, 0));
    final far = camera.getOffsetFromOrigin(
      gridToLatLng(World.mapPx, World.mapPx),
    );
    return MobileLayerTransformer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _HallsPainter(
          layout,
          floor,
          hall,
          colors,
          planned,
          o,
          (far.dx - o.dx) / World.mapPx,
        ),
      ),
    );
  }
}

class _HallsPainter extends CustomPainter {
  _HallsPainter(
    this.layout,
    this.floor,
    this.hall,
    this.colors,
    this.planned,
    this.origin,
    this.scale,
  );
  final HallLayout layout;
  final double? floor;
  final int? hall;
  final List<Color> colors;
  final Set<int> planned;
  final Offset origin;

  /// Screen pixels per map pixel.
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    Offset at(double x, double y) =>
        Offset(origin.dx + x * scale, origin.dy + y * scale);
    final l = layout;
    canvas.drawRect(
      Rect.fromPoints(at(l.x0 - 3, l.y0 - 3), at(l.x1 + 3, l.y1 + 3)),
      Paint()..color = Palette.night.withValues(alpha: 0.94),
    );
    final pts = l.points;
    final n = l.stride;
    final byHall = n == 4 && floor == null;
    // one colour per bucket: the hall (by hall), or the floor (bright, near, faint)
    final buckets = <int, List<double>>{};
    final view = Offset.zero & size;
    for (var i = 0; i + n - 1 < pts.length; i += n) {
      final k = n == 4 ? pts[i + 3] : 0;
      if ((hall != null && k != hall) || planned.contains(k)) continue;
      final p = at(pts[i] / 10, pts[i + 1] / 10);
      if (!view.contains(p)) continue;
      final b =
          floor != null
              ? switch ((pts[i + 2] - floor!).abs()) {
                <= 6 => 0,
                <= 16 => 1,
                _ => 2,
              }
              : byHall
              ? k
              : 0;
      (buckets[b] ??= [])
        ..add(p.dx)
        ..add(p.dy);
    }
    // about 2 m across, never under a pixel and a half
    final w = math.max(1.5, scale / 4);
    for (final MapEntry(key: b, value: list) in buckets.entries) {
      final color =
          floor != null
              ? [
                Palette.bone,
                Palette.parchment.withValues(alpha: 0.45),
                Palette.ash.withValues(alpha: 0.16),
              ][b]
              : b < 0
              ? Palette.ash
              : colors[b % colors.length];
      canvas.drawRawPoints(
        ui.PointMode.points,
        Float32List.fromList(list),
        Paint()
          ..color = color
          ..strokeWidth = w
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_HallsPainter old) =>
      old.floor != floor ||
      old.hall != hall ||
      old.planned.length != planned.length ||
      old.origin != origin ||
      old.scale != scale;
}

/// A numbered stop of the farming run: amber for the next, faint once done.
class _StopMark extends StatelessWidget {
  const _StopMark({required this.n, required this.done, required this.next});
  final int n;
  final bool done, next;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: done ? 0.4 : 1,
    child: Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: next ? Palette.amber : Palette.night.withValues(alpha: 0.85),
        shape: BoxShape.circle,
        border: Border.all(color: Palette.amber, width: 2),
      ),
      child: Text(
        '$n',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          color: next ? Palette.night : Palette.amber,
        ),
      ),
    ),
  );
}

/// The farming run's next stop: what to get there, how many stops are left, done and close.
class _RouteBar extends StatelessWidget {
  const _RouteBar({
    required this.db,
    required this.route,
    required this.at,
    required this.onDone,
    required this.onClose,
  });
  final GameDb db;
  final FarmRoute route;
  final int at;
  final VoidCallback onDone, onClose;

  @override
  Widget build(BuildContext context) {
    final stop = route.stops[at];
    return Material(
      color: Palette.shroud.withValues(alpha: 0.95),
      elevation: 3,
      shadowColor: Colors.black54,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        child: Row(
          children: [
            const Icon(Icons.route, color: Palette.amber, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr('Stop {at} of {all}', {
                      'at': at + 1,
                      'all': route.stops.length,
                    }),
                    style: const TextStyle(color: Palette.ash, fontSize: 11),
                  ),
                  Text(
                    stop.items.entries
                        .map((e) => '${db.shownName(e.key)} ×${e.value}')
                        .join(', '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    stop.spot.describe(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Palette.ash, fontSize: 11),
                  ),
                ],
              ),
            ),
            TextButton(onPressed: onDone, child: Text(tr('Done'))),
            IconButton(
              tooltip: tr('End the route'),
              icon: const Icon(Icons.close, size: 18),
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

/// "Before you go" for a Hollow Hall: what is inside, then each check with a mark.
class _HallCheckView extends StatelessWidget {
  const _HallCheckView({required this.check, required this.onGear});
  final HallCheck check;
  final VoidCallback onGear;

  @override
  Widget build(BuildContext context) {
    final lines = check.lines();
    final gearLow = lines.any(
      (l) => l.id == 'Gear' && l.mark == CheckMark.warn,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 14),
        Text(
          tr('Before you go'),
          style: const TextStyle(
            color: Palette.flame,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (check.contents.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            tr('Inside: {contents}', {'contents': check.contents}),
            style: const TextStyle(color: Palette.ash, fontSize: 12),
          ),
        ],
        const SizedBox(height: 6),
        for (final l in lines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  switch (l.mark) {
                    CheckMark.ok => Icons.check_circle_outline,
                    CheckMark.warn => Icons.error_outline,
                    CheckMark.info => Icons.info_outline,
                  },
                  size: 18,
                  color: switch (l.mark) {
                    CheckMark.ok => Palette.spring,
                    CheckMark.warn => Palette.ember,
                    CheckMark.info => Palette.ash,
                  },
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${l.title}  ',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        TextSpan(
                          text: l.detail,
                          style: const TextStyle(color: Palette.parchment),
                        ),
                      ],
                    ),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        if (gearLow)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.shield_outlined, size: 18),
              label: Text(tr('My gear by slot')),
              onPressed: onGear,
            ),
          ),
      ],
    );
  }
}

/// A find still missing in the open hall: its marker in a glowing ring, what it is, and which way when it's
/// on another floor.
class _FindMark extends StatelessWidget {
  const _FindMark({required this.icon, required this.text, this.note});
  final Widget icon;
  final String text;
  final String? note;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Palette.flame, width: 2),
          boxShadow: [
            BoxShadow(
              color: Palette.flame.withValues(alpha: 0.7),
              blurRadius: 10,
              spreadRadius: 1,
            ),
          ],
        ),
        child: icon,
      ),
      const SizedBox(height: 2),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: Palette.night.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: Palette.flame.withValues(alpha: 0.6)),
        ),
        child: Text(
          note == null ? text : '$text · $note',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        ),
      ),
    ],
  );
}

/// A hall's journal pages and fixed loot, missing first: a tap shows it on the map.
class _FindsView extends StatelessWidget {
  const _FindsView({required this.finds, required this.onTap});
  final List<Find> finds;
  final void Function(Find) onTap;

  @override
  Widget build(BuildContext context) {
    if (finds.isEmpty) return const SizedBox.shrink();
    final known = finds.any((f) => f.have != null);
    final left = finds.where((f) => f.have == false).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 14),
        Text(
          known
              ? left == 0
                  ? tr('To find · all {n} found', {'n': finds.length})
                  : tr('To find · {left} of {all} missing', {
                    'left': left,
                    'all': finds.length,
                  })
              : tr('To find'),
          style: const TextStyle(
            color: Palette.flame,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          known
              ? tr(
                'Journal pages you haven\'t read, and loot these chests always hold that isn\'t in your gear, bag or chests. Missing ones glow on the map.',
              )
              : tr(
                'Journal pages and loot these chests always hold. Connect the PC agent to see what you have.',
              ),
          style: const TextStyle(color: Palette.ash, fontSize: 12),
        ),
        for (final f in finds)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            leading: Icon(
              f.lore ? Icons.menu_book_outlined : Icons.star_outline,
              color:
                  f.have == true
                      ? Palette.ash
                      : f.lore
                      ? Palette.parchment
                      : Palette.gold,
            ),
            title: Text(
              gt(f.name),
              style: TextStyle(
                color: f.have == true ? Palette.ash : null,
                fontWeight: f.have == false ? FontWeight.w600 : null,
              ),
            ),
            subtitle:
                f.places > 1
                    ? Text(tr('in {n} chests', {'n': f.places}))
                    : null,
            trailing: switch (f.have) {
              true => const Icon(Icons.check, color: Palette.spring),
              false => Text(
                tr('missing'),
                style: const TextStyle(color: Palette.flame, fontSize: 12),
              ),
              null => null,
            },
            onTap: () => onTap(f),
          ),
      ],
    );
  }
}

/// The quests that lead into a hall, done or still open (from the save; an artisan counts as living in a
/// base once one of their stations is placed).
class _HallQuestsView extends StatelessWidget {
  const _HallQuestsView({required this.quests});
  final List<(Doc, bool?)> quests;

  @override
  Widget build(BuildContext context) {
    if (quests.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 14),
        Text(
          tr('Quests'),
          style: const TextStyle(
            color: Palette.flame,
            fontWeight: FontWeight.w700,
          ),
        ),
        for (final (q, done) in quests)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            leading: Icon(
              Icons.flag_outlined,
              color: done == true ? Palette.ash : Palette.parchment,
            ),
            title: Text(
              gt(q.name),
              style: TextStyle(color: done == true ? Palette.ash : null),
            ),
            trailing: switch (done) {
              true => const Icon(Icons.check, color: Palette.spring),
              false => Text(
                tr('open'),
                style: const TextStyle(color: Palette.flame, fontSize: 12),
              ),

              null => null,
            },
          ),
      ],
    );
  }
}
