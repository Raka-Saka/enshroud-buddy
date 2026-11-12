import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:ensh_companion/data/hunt.dart';
import 'package:ensh_companion/data/buddy_auth.dart';
import 'package:ensh_companion/data/build.dart';
import 'package:ensh_companion/data/clusters.dart';
import 'package:ensh_companion/data/db_store.dart';
import 'package:ensh_companion/data/game_db.dart';
import 'package:ensh_companion/data/guide.dart';
import 'package:ensh_companion/data/hall_check.dart';
import 'package:ensh_companion/data/hall_plan.dart';
import 'package:ensh_companion/data/item_icons.dart';
import 'package:ensh_companion/data/live_state.dart';
import 'package:ensh_companion/data/tracker.dart';
import 'package:ensh_companion/data/updates.dart';
import 'package:ensh_companion/data/mentions.dart';
import 'package:ensh_companion/data/news.dart';
import 'package:ensh_companion/data/planner.dart';
import 'package:ensh_companion/data/projection.dart';
import 'package:ensh_companion/data/route.dart';
import 'package:ensh_companion/data/shroud.dart';
import 'package:ensh_companion/data/tasks.dart';
import 'package:ensh_companion/data/where.dart';
import 'package:ensh_companion/l10n.dart';
import 'package:ensh_companion/screens/items_screen.dart';
import 'package:ensh_companion/screens/survival_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final db = GameDb.fromJson(
    jsonDecode(File('assets/game.json').readAsStringSync()),
  );

  test('search ranks prefix matches first', () {
    expect(db.search('iron arrow').first.name, 'Iron Arrow');
    // every item, not a first page (the Locked filter runs on the whole list)
    expect(db.search('').length, db.items.length);
  });

  test('recipes link workshops and inputs', () {
    final arrow = db.search('iron arrow').first;
    final r = db.madeBy[arrow.id]!.first;
    expect(db.workshops[r.workshopId]!.name, 'Hunter');
    expect(
      r.inputs.map((i) => db.nameOf(i.ref)),
      containsAll(['Twigs', 'Iron Bars', 'Feather']),
    );
  });

  test('unlock trees evaluate against knowledge flags', () {
    final u = Unlock({
      'op': 'AND',
      'c': [
        {'t': 'Rescue the Farmer', 'k': 'aaaa0001'},
        {
          'op': 'OR',
          'c': [
            {'t': 'Pick up Clay', 'k': 'aaaa0002'},
            {'t': 'Raise the Flame to level 3'},
          ],
        },
      ],
    });
    expect(u.met({'aaaa0001', 'aaaa0002'}), isTrue);
    expect(u.met({'aaaa0002'}), isFalse);
    expect(u.met({'aaaa0001'}), isNull);
    expect(u.leaves.length, 3);
  });

  test('most recipes explain how they unlock', () {
    expect(db.recipes.where((r) => r.unlock != null).length, greaterThan(1500));
  });

  test('planner expands a craft into gather totals', () {
    final arrow = db.search('iron arrow').first;
    final planner = Planner(db, null);
    final step = planner.planAll([Goal(arrow.id, 100)]).single;
    expect(step.batches, 2); // 50 per craft
    final gathered = planner.toGather.keys.map(db.nameOf).toSet();
    expect(
      gathered,
      contains('Iron Ore'),
    ); // Iron Bars and Twigs are crafted down to ore and wood
    expect(gathered, contains('Feather'));
    expect(
      gathered.contains('Iron Bars'),
      isFalse,
    ); // smelted, so planned as a craft
  });

  test('map points cover spires, shrines, lore and chests', () {
    final kinds = db.poi.map((p) => p.kind).toSet();
    expect(
      kinds,
      containsAll(['Ancient Spire', 'Flame Shrine', 'Elixir Well']),
    );
    expect(db.poi.where((p) => p.cat == 'lore').length, greaterThan(500));
    expect(db.poi.where((p) => p.cat == 'chest').length, greaterThan(3000));
    // every Shroud Root is done once its first-time skill point is claimed
    final roots = db.poi.where((p) => p.kind == 'Shroud Root').toList();
    expect(roots.length, greaterThan(50));
    expect(roots.every((p) => p.done?.leaves.single.knowledge != null), isTrue);
    for (final p in db.poi) {
      expect(p.x, inInclusiveRange(0, 1280));
      expect(p.y, inInclusiveRange(0, 1280));
    }
  });

  test('shroud time inputs', () {
    expect(statSeconds('1 min'), 60);
    expect(statSeconds('30 s'), 30);
    expect(statSeconds('-4 min'), -240);
    final b = db.balancing!;
    expect(b.fogBase, 240);
    expect(b.fogPerFlame, 60);
    expect(
      (b.fogBase + b.fogPerFlame * 6) * 1.5,
      900,
    ); // the test world: Flame 6, Shroud time x1.5
    expect(b.altarsAt(6), greaterThanOrEqualTo(8));
  });

  test('png encoder writes a valid header', () {
    final png = encodePng(Uint8List(4 * 4 * 4), 4, 4);
    expect(png.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    expect(String.fromCharCodes(png.sublist(12, 16)), 'IHDR');
  });

  test('skill paths walk linked nodes from a Spark', () {
    final target = db.skills.firstWhere((k) => k.name == 'Multi Shot');
    final path = pathTo(db, {}, target.id);
    expect(path.last.id, target.id);
    for (var i = 1; i < path.length; i++) {
      expect(path[i].links, contains(path[i - 1].id));
    }
    expect(
      db.skillById[path.first.id]!.links.any(
        (l) => db.skillById[l]!.type == 'Root',
      ),
      isTrue,
    );
    expect(
      db.skills.map((k) => k.archetype).toSet().length,
      13,
    ); // 12 archetypes + the centre
    expect(db.skills.where((k) => k.archetype == 'Centre').length, 19);
  });

  test('sets and lore are present', () {
    expect(db.sets.length, greaterThan(100));
    expect(db.lore.length, greaterThan(200));
  });

  test('an archer build favours bows and archer gear', () {
    Skill named(String n) => db.skills.firstWhere((k) => k.name == n);
    final learned = {
      for (final n in [
        'Dexterity',
        'Marksman',
        'Sniper',
        'Bow Specialization',
        'Ranger',
        'Endurance',
      ])
        named(n).id: 1,
    };
    final state = LiveState({
      'character': {
        'name': 'Test',
        'skills': [],
        'recipes_unlocked': [],
        'level': 45,
      },
      'world': {'name': 'Test', 'bases': [], 'containers': []},
    });
    final target = BuildTarget(db, learned, [named('Multi Shot')]);
    expect(target.topWeapons.first, 'Bow');
    expect(target.classes.keys.first, 'Ranger');
    final advisor = GearAdvisor(db, state, target);
    Item item(String n) => db.items.values.firstWhere((it) => it.name == n);
    final archer = advisor.rate(item("Vorgoth's Soulbound Chest"));
    expect(archer.$2, contains('Ranger'));
    final mageChest = db.items.values.firstWhere(
      (it) =>
          it.stats?.slot == 'Armour_UpperBody' &&
          it.stats?.alignment == 'Mage' &&
          it.stats?.levels?[1] == 45,
    );
    expect(archer.$1, greaterThan(advisor.rate(mageChest).$1));
    expect(
      advisor
          .targets('RangeWeapon')
          .every((g) => g.item.stats!.weaponType == 'Bow'),
      isTrue,
    );
    expect(advisor.foodSlots, 3);
  });

  test('gear starts from what is worn; nothing below it, nothing looted', () {
    Skill named(String n) => db.skills.firstWhere((k) => k.name == n);
    Item item(String n) => db.items.values.firstWhere((it) => it.name == n);
    final worn = item('Trailblazer Boots'), low = item('Marksman Boots');
    final unique = item("Dragon's Wing");
    Map<String, dynamic> rec(Item it, int level) => {
      'slot': 0,
      'item': it.id,
      'count': 1,
      'level': level,
    };
    final s = LiveState({
      'character': {
        'name': 'Test',
        'level': 39,
        'skills': [],
        'recipes_unlocked': [],
        'equipment': [rec(worn, 33)],
        'bag': [rec(unique, 37)],
      },
      'world': {
        'name': 'Test',
        'bases': [],
        'containers': [
          {
            'kind': null,
            'items': [rec(low, 10)],
          },
        ],
      },
    });
    expect(
      SkillPoints(db, s).fromLevel,
      38 * db.balancing!.skillPointsPerLevel,
    );
    final learned = {
      for (final n in ['Dexterity', 'Marksman', 'Bow Specialization', 'Ranger'])
        named(n).id: 1,
    };
    final advisor = GearAdvisor(db, s, BuildTarget(db, learned, const []));
    final owned = advisor.owned();
    expect(owned['Armour_Feet']!.first.item.id, worn.id);
    expect(owned['Armour_Feet']!.first.current, isTrue);
    expect(owned['Armour_Feet']!.any((g) => g.item.id == low.id), isFalse);
    expect(
      advisor.upgrades('Armour_Feet', owned).every((t) => t.level! >= 33),
      isTrue,
    );
    expect(owned['RangeWeapon']!.first.item.id, unique.id);
    expect(
      advisor
          .upgrades('RangeWeapon', owned, count: 99)
          .any((t) => t.item.id == unique.id),
      isFalse,
    );
  });

  test('skills carry their numbers and projections follow the tree', () {
    final marksman = db.skills.firstWhere((k) => k.name == 'Marksman');
    expect(marksman.description, contains('5/10/15%'));
    expect(marksman.axes, ['damage']);
    expect(marksman.weapons, ['Bow']);
    expect(
      db.skills.where((k) => (k.description ?? '').contains('%k')),
      isEmpty,
    );
    final p = Projection(
      db,
      const {},
      Projection.goals.first,
      30,
      flameLevel: 6,
    );
    expect(p.spent, lessThanOrEqualTo(30));
    expect(p.steps.map((s) => s.skill.name), contains('Marksman'));
    final taken = {
      for (final k in db.skills)
        if (k.type == 'Root') k.id,
    };
    for (final st in p.steps) {
      expect(
        st.skill.links.any(taken.contains) || taken.contains(st.skill.id),
        isTrue,
        reason: st.skill.name,
      );
      taken.add(st.skill.id);
    }
    expect(p.share('damage'), greaterThan(p.share('damage', projected: false)));
  });

  test('gather spots and chests rank by distance and risk', () {
    String id(String n) => db.items.values.firstWhere((i) => i.name == n).id;
    expect(db.gather[id('Iron Ore')], isNotEmpty);
    final state = LiveState({
      'character': {
        'name': 'Test',
        'skills': [],
        'recipes_unlocked': [],
        'level': 30,
      },
      'world': {
        'name': 'Test',
        'flame_level': 6,
        'containers': [],
        'bases': [
          {
            'id': 'base00',
            'name': 'Home',
            'altar_level': 3,
            'min': [0, 0, 0],
            'max': [1, 1, 1],
            'map': [640, 640],
          },
        ],
      },
    });
    final w = WhereToGet(db, state, null);
    final best = w.best(id('Iron Ore'), count: 5);
    expect(best, isNotEmpty);
    for (var i = 1; i < best.length; i++) {
      expect(best[i].score, greaterThanOrEqualTo(best[i - 1].score));
    }
    expect(best.first.base, 'Home');
    final bow = w.best(id('Firefeather Bow'));
    expect(bow.first.spot.kind, 'chest');
    expect(bow.first.odds, greaterThan(0));
    // standing on a spot, live from the game: it counts from you
    final s = best.first.spot;
    final here = PlayerPos({
      'map': [s.x + 1, s.y],
      'heading': 90,
      'y': 100,
    });
    final near = WhereToGet(db, state, null, here: here).rank(s);
    expect(near.base, 'you');
    expect(near.distanceM, closeTo(8, 0.01));
    expect(near.describe(), startsWith('10 m from you')); // 8 m, to 5 m
  });

  test('next up puts what you can do where you stand first', () {
    String id(String n) => db.items.values.firstWhere((i) => i.name == n).id;
    final ore = id('Iron Ore');
    final state = LiveState({
      'character': {
        'name': 'Test',
        'skills': [],
        'recipes_unlocked': [],
        'level': 30,
      },
      'world': {
        'name': 'Test',
        'flame_level': 6,
        'containers': [
          {
            'kind': null,
            'base': 'base00',
            'items': [
              {'slot': 0, 'item': ore, 'count': 200},
            ],
          },
        ],
        'bases': [
          {
            'id': 'base00',
            'name': 'Home',
            'altar_level': 3,
            'min': [0, 0, 0],
            'max': [240, 240, 240],
            'map': [640, 640],
          },
        ],
      },
    });
    final plan = TaskPlan(db, state, [
      Goal(id('Iron Bars'), 10),
    ], WhereToGet(db, state, null));
    final far = nextUp(
      plan,
      PlayerPos({
        'map': [100, 100],
        'heading': 0,
        'y': 100,
      }),
    );
    expect(far.where((n) => n.here), isEmpty);
    final home = nextUp(
      plan,
      PlayerPos({
        'map': [641, 641],
        'heading': 0,
        'y': 100,
      }),
    );
    expect(home.first.task.kind, TaskKind.fetch);
    expect(home.first.note, startsWith('Here: '));
    expect(home.length, far.length);
  });

  test('the guide turns, climbs and checks the glide over the ground', () {
    const n = 1280; // the map grid
    final flat = Uint8List(n * n)
      ..fillRange(0, n * n, 50); // 100 m everywhere (2 m a step)
    final hm = HeightMap.test(flat, 2, 0);
    final g = Glider(
      name: 'Test',
      speed: 25,
      drain: 5,
      saving: 0.24,
      ratio: 7.5,
      measured: false,
    );
    // on a 200 m tower, facing north; the target is 1 km east
    final p = PlayerPos({
      'map': [500, 500],
      'heading': 0,
      'y': 303,
    });
    const t = NavTarget('East', 625, 500);
    final guide = Guide(p, t, hm, g);
    expect(guide.distanceM, closeTo(1000, 0.1));
    expect(guide.turnText, 'turn right');
    expect(guide.heightText, '200 m below you');
    final glide = guide.glide!;
    expect(glide.reaches, isTrue);
    expect(glide.seconds, closeTo(40, 0.1));
    expect(glide.stamina, closeTo(40 * 5 * 0.76, 0.1));
    expect(glide.describe(), startsWith('Glide all the way: 40 s'));
    // a 280 m ridge halfway blocks it: land before it, and say how much higher would clear it
    final ridge = Uint8List.fromList(flat);
    for (var y = 0; y < n; y++) {
      for (var x = 560; x < 566; x++) {
        ridge[y * n + x] = 140;
      }
    }
    final blocked = Guide(p, t, HeightMap.test(ridge, 2, 0), g).glide!;
    expect(blocked.reaches, isFalse);
    expect(
      blocked.carriesM,
      inInclusiveRange(470, 500),
    ); // the ridge starts 484 m out
    expect(blocked.climbFirst, greaterThan(0));
    expect(blocked.describe(), contains('then walk'));
  });

  test(
    'in the air the guide steers by your course and shows where you come down',
    () {
      const n = 1280; // the map grid
      final hm = HeightMap.test(
        Uint8List(n * n)..fillRange(0, n * n, 50),
        2,
        0,
      ); // 100 m
      final g = Glider(
        name: 'Test',
        speed: 25,
        drain: 5,
        saving: 0,
        ratio: 7.5,
        measured: true,
      );
      // 200 m up, flying east at 20 m/s while the camera looks north; the target is due north
      final p = PlayerPos({
        'map': [500, 500],
        'heading': 0,
        'y': 303,
        'mode': 'air',
        'speed': 20,
        'course': 90,
        'above': 200,
      });
      expect(p.airborne, isTrue);
      expect(p.travel, 90);
      final guide = Guide(
        p,
        const NavTarget('North', 500, 380),
        hm,
        g,
      ); // 960 m
      expect(guide.turnText, 'turn left');
      expect(guide.modeText, 'Gliding');
      expect(guide.glideText, startsWith('Head straight there: you make it'));
      final land = guide.landing!;
      expect(land.distanceM, closeTo(200 * 7.5 * 0.85, 8)); // 1275 m east
      expect(land.x, closeTo(500 + 1275 / 8, 1));
      expect(land.y, closeTo(500, 0.01));
      final fall = PlayerPos({
        'map': [500, 500],
        'heading': 0,
        'y': 303,
        'mode': 'fall',
      });
      expect(
        Guide(fall, const NavTarget('North', 500, 300), hm, g).glideText,
        'Falling: open the glider',
      );
      // an older agent sends no mode: on foot, by the camera
      final old = PlayerPos({
        'map': [500, 500],
        'heading': 0,
        'y': 303,
      });
      expect(old.mode, isNull);
      expect(old.travel, 0);
    },
  );

  test(
    'on foot the guide finds higher ground to glide from when that is quicker',
    () {
      const n = 1280; // the map grid
      final v = Uint8List(n * n)..fillRange(0, n * n, 50); // lowland at 100 m
      // a 400 m plateau 480 m wide, with the player in a 300 m dip in it; the target is 1.8 km east
      for (var y = 440; y < 560; y++) {
        for (var x = 470; x < 530; x++) {
          final d = (x - 500) * (x - 500) + (y - 500) * (y - 500);
          v[y * n + x] = d <= 64 ? 150 : 200;
        }
      }
      final hm = HeightMap.test(v, 2, 0);
      final g = Glider(
        name: 'Test',
        speed: 25,
        drain: 5,
        saving: 0,
        ratio: 7.5,
        measured: true,
      );
      final p = PlayerPos({
        'map': [500, 500],
        'heading': 90,
        'y': 303,
        'mode': 'foot',
      });
      const t = NavTarget('East', 725, 500);
      expect(
        GlideCheck.of(p, t, hm, g)!.reaches,
        isFalse,
      ); // the dip's rim is in the way
      final plan = LaunchPlan.of(p, t, hm, g)!;
      expect(plan.x, inInclusiveRange(520, 530)); // the plateau's east edge
      expect(plan.climbM, closeTo(100, 1));
      expect(plan.glide.reaches, isTrue);
      expect(plan.savedS, greaterThan(30));
      expect(plan.describe(p), startsWith('Climb 100 m to high ground'));
      expect(plan.describe(p), contains('east, then glide 1.'));
      // on top of a tower the glide from here already reaches: no plan
      final tower = PlayerPos({
        'map': [700, 500],
        'heading': 90,
        'y': 303,
        'mode': 'foot',
      });
      expect(
        LaunchPlan.of(tower, const NavTarget('Near', 760, 500), hm, g),
        isNull,
      );
      // nor in the air
      final aloft = PlayerPos({
        'map': [500, 500],
        'heading': 90,
        'y': 303,
        'mode': 'air',
      });
      expect(LaunchPlan.of(aloft, t, hm, g), isNull);
    },
  );

  test('game data from the network must carry a real, past build time', () {
    expect(DbStore.plausible('2026-10-27T06:22:11'), isTrue);
    expect(
      DbStore.plausible('9999-01-01T00:00:00'),
      isFalse,
    ); // would win over every app update
    expect(DbStore.plausible('not a date'), isFalse);
    expect(DbStore.plausible(null), isFalse);
  });

  test('cosmetic pieces are listed but don\'t count as worn', () {
    final s = LiveState({
      'character': {
        'name': 'Hero',
        'equipment': [
          {'slot': 0, 'item': 'aaaa0001', 'count': 1, 'cosmetic': true},
          {'slot': 1, 'item': 'aaaa0002', 'count': 1},
        ],
        'skills': const [],
        'recipes_unlocked': const [],
      },
      'world': {
        'name': 'Test World',
        'bases': const [],
        'containers': const [],
      },
    });
    expect(s.equipment.map((o) => o.itemId), ['aaaa0002']);
    expect(s.cosmetics.map((o) => o.itemId), ['aaaa0001']);
    expect(s.whereIs('aaaa0001', (id) => id).map((w) => w.label), ['Cosmetic']);
  });

  test(
    'the setup lists save folders, worlds and characters from the agent',
    () {
      final list = SaveList({
        'folders': [
          {
            'folder': r'c:\steam\userdata\1\1203620\remote',
            'label': 'Steam account 1',
            'worlds': [
              {
                'slot': 1,
                'name': 'Home World',
                'saved_at': '2026-10-26T23:37:02',
              },
              {
                'slot': 0,
                'name': 'Test World',
                'saved_at': '2026-10-16T09:02:52',
              },
            ],
            'characters': [
              {'slot': 0, 'name': 'Hero', 'saved_at': '2026-10-16T09:22:51'},
            ],
          },
        ],
        'current': {
          'folder': r'c:\steam\userdata\1\1203620\remote',
          'world': 1,
          'character': 0,
        },
      });
      expect(list.folders.single.label, 'Steam account 1');
      expect(list.folders.single.worlds.map((w) => w.name), [
        'Home World',
        'Test World',
      ]);
      expect(list.folders.single.characters.single.slot, 0);
      expect(list.current.world, 1);
      expect(
        SaveList(const {}).folders,
        isEmpty,
      ); // an older agent without /saves content
    },
  );

  test('a task plan crafts intermediates before the goal', () {
    String id(String n) => db.items.values.firstWhere((i) => i.name == n).id;
    final goal = id("Vorgoth's Soulbound Chest");
    final plan = TaskPlan(db, null, [
      Goal(goal, 1),
    ], WhereToGet(db, null, null));
    final crafts = plan.of(TaskKind.craft).toList();
    expect(crafts.length, greaterThan(1));
    expect(crafts.last.itemId, goal);
    expect(
      plan.of(TaskKind.station),
      isNotEmpty,
    ); // nothing is built without a save
    final kinds = plan.tasks.map((t) => t.kind.index).toList();
    expect(kinds, orderedEquals([...kinds]..sort()));
    expect(db.items[id('Twigs')]!.isCommon, isTrue);
  });

  test('regions, zone pins and hazards from hints', () {
    String id(String n) => db.items.values.firstWhere((i) => i.name == n).id;
    expect(db.regionNames, contains("Cinder's Cradle"));
    final copper = db.items[id('Copper Ore')]!;
    expect(copper.regions, ['Revelwood']);
    final w = WhereToGet(db, null, null);
    final spots = w.best(copper.id);
    expect(spots, isNotEmpty);
    expect(spots.first.spot.kind, 'zone');
    expect(db.items[id('Pearl')]!.underwater, isTrue);
    expect(db.items[id('Salt')]!.inShroud, isTrue);
    expect(w.best(id('Pearl')).first.underwater, isTrue);
  });

  test('number unlock conditions keep their operator', () {
    Unlock? find(Unlock u, String op) {
      if (u.runtime?.$1 == 'flame' && u.runtime?.$2 == op) return u;
      for (final c in u.children) {
        final f = find(c, op);
        if (f != null) return f;
      }
      return null;
    }

    Unlock? more, less;
    for (final r in db.recipes) {
      if (r.unlock == null) continue;
      more ??= find(r.unlock!, '>');
      less ??= find(r.unlock!, '<');
    }
    const ctx = UnlockContext(flame: 6, level: 33, altar: 4, altars: 8);
    // "> v" reads as "strength v+1" and holds from v+1 up
    final v = more!.runtime!.$3;
    expect(more.text, 'Raise the Flame to strength ${v + 1}');
    expect(more.met(const {}, ctx), 6 > v);
    expect(less!.text, startsWith('Flame strength below'));
    expect(less.met(const {}, ctx), 6 < less.runtime!.$3);
    expect(
      more.met(const {}),
      isNull,
    ); // without a save, a number condition is unknown
  });

  test(
    'game data carries its build time near the start, for updates from the PC',
    () {
      final raw = File('assets/game.json').readAsStringSync();
      final built = DbStore.builtOf(raw);
      expect(built, isNotNull);
      expect(db.built, built);
      expect(
        DbStore.builtOf(
          '{"version":1,"built":"2026-10-26T08:00:00","items":{}}',
        ),
        '2026-10-26T08:00:00',
      );
    },
  );

  test(
    'answers link game names: longest first, plurals, skills and named places',
    () {
      final found = Mentions.of(db).find(
        'Craft Iron Arrows at the Hunter with Copper Ore and Twigs, then learn Sniper. '
        'Ask about stone walls. Eat Salt-cured meat.',
      );
      final names = [for (final m in found) m.name];
      expect(names, containsAll(['Iron Arrow', 'Copper Ore', 'Twigs']));
      expect(
        found.firstWhere((m) => m.name == 'Iron Arrow').end,
        'Craft Iron Arrows'.length,
      );
      expect(
        found.where((m) => m.kind == MentionKind.skill).map((m) => m.name),
        contains('Sniper'),
      );
      // lowercase words in a sentence are not names
      expect(
        names.where((n) => n.toLowerCase() == 'stone' || n == 'Salt'),
        isEmpty,
      );
    },
  );

  testWidgets('map markers follow the kind, then a phrase of the title', (
    t,
  ) async {
    await MapIcons.load();
    Poi label(String kind, String title) =>
        Poi({'x': 0, 'y': 0, 'c': 'label', 'k': kind, 't': title});
    expect(
      MapIcons.asset(label('Enemy Camp', 'Caravan Camp')),
      endsWith('/enemy_camp.png'),
    );
    expect(
      MapIcons.asset(label('Place', 'Little Rock Goat Farm')),
      endsWith('/farm.png'),
    );
    expect(
      MapIcons.asset(label('Dungeon', 'Hidden Hollow Tomb')),
      endsWith('/tomb.png'),
    );
    expect(
      MapIcons.asset(label('Boss', 'Balefire Garrison "Rimerock"')),
      endsWith('/balefire.png'),
    );
    expect(
      MapIcons.asset(Poi({'x': 0, 'y': 0, 'c': 'lore', 't': 'A note'})),
      endsWith('/lore.png'),
    );
    expect(MapIcons.asset(label('Return Beacon', 'Return Beacon')), isNull);
    expect(MapIcons.asset(label('Place', 'Mineral Springs')), isNull);
  });

  test('groups: same kind in one square merges, three or more', () {
    final pts = [
      ('chest', 1.0, 1.0),
      ('chest', 2.0, 2.0),
      ('chest', 3.0, 3.0), // one group
      ('lore', 1.5, 1.5), // another kind stays apart
      ('chest', 50.0, 50.0), ('chest', 51.0, 51.0), // two: stay single
    ];
    final g = clusterPoints(
      pts,
      x: (p) => p.$2,
      y: (p) => p.$3,
      group: (p) => p.$1,
      cell: 10,
    );
    expect(g.where((c) => c.items.length == 3).single.x, 2.0);
    expect(g.where((c) => c.items.length == 1).length, 3);
  });

  test('fishing spots carry their fish, the halls their layout', () {
    final spots = db.poi.where((p) => p.cat == 'fish').toList();
    expect(spots, isNotEmpty);
    for (final s in spots) {
      final t = db.fish[s.fishTable]!;
      expect(t.fish, isNotEmpty);
      expect(
        t.fish.map((f) => f.share).reduce((a, b) => a + b),
        closeTo(100, 1),
      );
      expect(db.items[t.fish.first.id], isNotNull);
    }
    final h = db.halls!;
    expect(h.points.length % h.stride, 0);
    final inside = db.poi.where((p) => p.inside).toList();
    expect(inside.where((p) => p.cat == 'chest'), isNotEmpty);
    for (final p in inside) {
      expect(h.contains(p.x, p.y), isTrue);
      expect(p.height, isNotNull);
    }
    expect(db.poi.any((p) => p.inside && p.kind == 'Save Point'), isTrue);
    // each world Hall leads to its own inside, and every point inside belongs to one
    final entrances = db.poi.where(
      (p) => p.title == 'Hollow Halls' && !p.inside,
    );
    expect(h.halls.length, entrances.length);
    expect(
      {for (final e in entrances) h.entranceAt(e.x, e.y)}.length,
      h.halls.length,
    );
    for (final p in inside) {
      expect(p.hall, inInclusiveRange(0, h.halls.length - 1));
      final b = h.halls[p.hall!];
      expect(p.x >= b.x0 - 8 && p.x <= b.x1 + 8, isTrue, reason: p.title);
    }
    expect(db.poi.where((p) => p.cat == 'updraft'), isNotEmpty);
  });

  test('a farming route visits fishing spots for fish, each stop once', () {
    String id(String name) =>
        db.items.values.firstWhere((i) => i.name == name).id;
    final fish = id('Shimmerfin');
    final need = {fish: 3, id('Copper Ore'): 10, id('Flax'): 5};
    final where = WhereToGet(db, null, null);
    final r = FarmRoute.plan(where, need, fromX: 640, fromY: 640);
    final got = {for (final s in r.stops) ...s.items.keys};
    expect(got.union(r.skipped.toSet()), need.keys.toSet());
    expect(
      r.stops.firstWhere((s) => s.items.containsKey(fish)).spot.spot.kind,
      'fish',
    );
    // reversing the order never walks less than what was planned
    final there = r.lengthFrom(640, 640);
    final back = FarmRoute(r.stops.reversed.toList(), const []);
    expect(there, lessThanOrEqualTo(back.lengthFrom(640, 640) + 1e-6));
  });
  test('before a Hollow Hall: level, gear under it, hook, damage, healing', () {
    final halls = db.halls!;
    final top = halls.halls.reduce((a, b) => a.level > b.level ? a : b);
    expect(top.contents['hollow'], greaterThan(0));
    Item item(String n, {String? slot}) => db.items.values.firstWhere(
      (i) => i.name == n && (slot == null || i.stats?.slot == slot),
    );
    Map<String, dynamic> rec(Item it, {int? level, int count = 1}) => {
      'slot': 0,
      'item': it.id,
      'count': count,
      'level': level,
    };
    final helmet = db.items.values.firstWhere(
      (i) => i.stats?.slot == 'Armour_Head' && i.stats?.levels != null,
    );
    final axe = item('Batwing Axe');
    final s = LiveState({
      'character': {
        'name': 'Test',
        'level': top.level - 6,
        'skills': [],
        'recipes_unlocked': [],
        'equipment': [
          rec(helmet, level: top.level - 12),
          rec(item('Improved Grappling Hook')),
        ],
        'bag': [
          rec(axe, level: top.level + 1),
          rec(item('Greater Health Potion'), count: 7),
        ],
      },
      'world': {'name': 'Test', 'bases': [], 'containers': []},
    });
    final lines = {for (final l in HallCheck(db, top, s).lines()) l.id: l};
    expect(lines['Level']!.mark, CheckMark.warn);
    expect(lines['Gear']!.mark, CheckMark.warn);
    expect(lines['Gear']!.detail, contains(helmet.name));
    expect(lines['Gear']!.detail, isNot(contains(axe.name)));
    expect(lines['Healing']!.mark, CheckMark.ok);
    expect(lines['Healing']!.detail, contains('×7'));
    if ((top.contents['hook'] ?? 0) > 0) {
      expect(lines['Grappling hook']!.mark, CheckMark.ok);
    }
    // the axe cuts: it neither hits a weakness nor counts as blunt
    final dmg = halls.damage!;
    expect(dmg.weak, isNot(contains('physicalCut')));
    expect(lines['Damage']!.mark, CheckMark.warn);
    // without a save: the level and what's inside, nothing about gear
    final bare = HallCheck(db, top, null).lines().map((l) => l.id);
    expect(bare, contains('Level'));
    expect(bare, isNot(contains('Gear')));
  });
  test('a hall floor plan fills rooms; on a floor only it is bright', () {
    final l = db.halls!;
    final k = 3;
    final h = l.halls[k];
    final box = [h.x0, h.y0, h.x1, h.y1];
    final watch = Stopwatch()..start();
    final all = HallPlan.build(
      l.points,
      k,
      box,
      null,
      color: 0xFFE8A33D,
      ground: 0xFF13222A,
      on: 0xFFE6E1D6,
      near: 0xFFE8D9B5,
      far: 0xFF9AA5A8,
    );
    final ms = watch.elapsedMilliseconds;
    // print('plan of hall $k: ${all.png.length} bytes in $ms ms');
    expect(ms, lessThan(3000));
    expect(all.png.sublist(1, 4), 'PNG'.codeUnits);
    expect(all.x0, lessThan(h.x0));
    expect(all.x1, greaterThan(h.x1));
    // a floor where the hall has points
    final z =
        l
            .points[[
                  for (var i = 0; i + 3 < l.points.length; i += 4)
                    if (l.points[i + 3] == k) i,
                ].first +
                2]
            .toDouble();
    final on = HallPlan.build(
      l.points,
      k,
      box,
      z,
      color: 0xFFE8A33D,
      ground: 0xFF13222A,
      on: 0xFFE6E1D6,
      near: 0xFFE8D9B5,
      far: 0xFF9AA5A8,
    );
    expect(on.png, isNot(equals(all.png)));
  });

  test('a hall\'s finds: pages and fixed loot, had by name or recipe', () {
    final halls = db.halls!;
    // a hall whose chests always hold something
    final k =
        [
          for (var i = 0; i < halls.halls.length; i++)
            if (db.poi.any(
              (p) => p.inside && p.hall == i && p.fixed.isNotEmpty,
            ))
              i,
        ].first;
    LiveState state(List<String> ids, Set<String> knowledge) => LiveState({
      'character': {
        'name': 'Test',
        'level': 30,
        'skills': [],
        'recipes_unlocked': [],
        'knowledge': knowledge.toList(),
        'equipment': [],
        'bag': [
          for (final id in ids) {'slot': 0, 'item': id, 'count': 1, 'level': 1},
        ],
      },
      'world': {'name': 'Test', 'bases': [], 'containers': []},
    });
    expect(HallFinds(db, null).of(k).every((f) => f.have == null), isTrue);
    expect(HallFinds(db, null).missing(k), isNull);
    final none = HallFinds(db, state([], {}));
    final finds = none.of(k);
    expect(finds, isNotEmpty);
    expect(finds.where((f) => !f.lore).every((f) => f.have == false), isTrue);
    expect(
      none.missing(k),
      finds.length - finds.where((f) => f.have == true).length,
    );
    // owning one chest's loot (any id of the same name) marks that chest had
    final chest = db.poi.firstWhere(
      (p) => p.inside && p.hall == k && p.fixed.isNotEmpty,
    );
    final names = chest.fixed.map((id) => db.items[id]!.name).toSet();
    final other = [
      for (final n in names) db.items.values.lastWhere((i) => i.name == n).id,
    ];
    final mine = HallFinds(db, state(other, {}));
    expect(mine.had(chest), isTrue);
    expect(
      mine.of(k).where((f) => names.contains(f.name)).every((f) => f.have!),
      isTrue,
    );
    expect(mine.missing(k), lessThan(none.missing(k)!));
    // a page counts once the save knows it
    final page = db.poi.where((p) => p.inside && p.lore != null).firstOrNull;
    if (page != null) {
      expect(none.had(page), isFalse);
      final done = db.lore[page.lore![0]].pages[page.lore![1]].done;
      if (done?.knowledge case final key?) {
        expect(HallFinds(db, state([], {key})).had(page), isTrue);
      }
    }
  });
  test('an artisan is sheltered once a station of theirs is placed', () {
    final q = db.quests.firstWhere((q) => q.name == 'Collector Needs Shelter');
    final leaf = q.pages.last.done!.leaves.firstWhere((l) => l.sheltered);
    expect(leaf.npc, isNotNull);
    expect(leaf.placed, isNotEmpty);
    UnlockContext ctx(Map<String, int> placed) =>
        UnlockContext(flame: 1, level: 1, altar: 1, altars: 1, placed: placed);
    final u = q.pages.last.done!;
    // not rescued: not done, whatever is placed
    expect(u.met({}, ctx({leaf.placed.first: 1})), isFalse);
    // rescued, no station out: the save can't tell
    expect(u.met({leaf.npc!}, ctx({})), isNull);
    // rescued and their station placed: lives in a base
    expect(u.met({leaf.npc!}, ctx({leaf.placed.first: 1})), isTrue);
  });
  testWidgets('gear by the skill or stat it gives, strongest first', (t) async {
    // perks lose their "×n" and merge with a value of the same name
    final st = ItemStats({
      'pk': ['Health ×2', 'Fatal Precision'],
      'v': [
        ['Item Level', '30'],
        ['Health', '20'],
        ['Comfort - Trophy', '1'],
      ],
    });
    expect(st.effects, {'Health': '×2 · 20', 'Fatal Precision': ''});
    expect(st.strength('Health'), (2, 20.0));
    expect(st.strength('Fatal Precision'), (1, 0.0));
    expect(db.skillNames, contains('Fatal Precision'));
    final gear = db.byEffect['Fatal Precision']!;
    expect(gear.length, greaterThan(5));

    await t.pumpWidget(
      MaterialApp(
        home: LiveScope(
          live: Live(),
          child: Scaffold(
            body: ItemsScreen(
              db: db,
              effect: 'Fatal Precision',
              embedded: true,
            ),
          ),
        ),
      ),
    );
    // strongest first, then the highest level; copies with the same card show once, each row with its
    // slot, level and the effect
    int top(Item i) => i.stats!.levels?.last ?? 0;
    final first =
        (gear.toList()..sort((a, b) {
              final (ta, _) = a.stats!.strength('Fatal Precision');
              final (tb, _) = b.stats!.strength('Fatal Precision');
              return ta != tb ? tb - ta : top(b) - top(a);
            }))
            .first;
    expect(find.text(first.name), findsOneWidget);
    expect(
      find.textContaining(
        RegExp('level ([0-9]+–)?${top(first)} · Fatal Precision'),
      ),
      findsWidgets,
    );
    // clearing the effect and typing part of it offers the effect as a chip
    await t.tap(find.byTooltip('Delete'));
    await t.pump();
    await t.enterText(find.byType(TextField), 'fatal');
    await t.pump();
    expect(find.textContaining('Fatal Precision · '), findsOneWidget);
  });
  test('unique loot: where each piece lies, cosmetics by their sets', () {
    // a chest's fixed loot and a special point's item are both "loot"
    final special = db.poi.firstWhere((p) => p.cat == 'special');
    expect(special.loot, [special.itemId]);
    final chest = db.poi.firstWhere((p) => p.fixed.isNotEmpty);
    expect(chest.loot, chest.fixed);
    expect(db.placesOf[special.itemId], contains(special));
    // cosmetic pieces are the Clothes sets' items; most lie somewhere on the map
    final farmer = db.sets.firstWhere((s) => s.name == 'Farmer Set');
    expect(db.clothes, containsAll(farmer.entries.map((e) => e.itemId)));
    expect(
      db.clothes.where(db.placesOf.containsKey).length / db.clothes.length,
      greaterThan(0.8),
    );
    expect(db.lootGroup(farmer.entries.first.itemId), 'Clothes');
    // a special point counts as had once its item is (null without a save)
    expect(HallFinds.collectible(special), isTrue);
    expect(HallFinds(db, null).had(special), isNull);
    LiveState holding(List<String> ids) => LiveState({
      'character': {
        'name': 'Test',
        'level': 30,
        'skills': [],
        'recipes_unlocked': [],
        'knowledge': [],
        'equipment': [],
        'bag': [
          for (final id in ids) {'slot': 0, 'item': id, 'count': 1, 'level': 1},
        ],
      },
      'world': {'name': 'Test', 'bases': [], 'containers': []},
    });
    expect(HallFinds(db, holding([])).had(special), isFalse);
    expect(HallFinds(db, holding([special.itemId!])).had(special), isTrue);
  });

  test('chest heights: caves and islands the map alone does not show', () {
    // every chest has its height; Cinder's Cradle's span more than a kilometre
    final chests = db.poi.where((p) => p.cat == 'chest').toList();
    expect(chests.every((p) => p.height != null), isTrue);
    final hs = chests.map((p) => p.height!).toList()..sort();
    expect(hs.last - hs.first, greaterThan(1000));
    expect(heightNote(568, 633, null), '568 m up · 65 m under the surface');
    expect(heightNote(1808, 1800, null), '1808 m up');
    expect(heightNote(700, 650, null), '700 m up · 50 m above the ground');
    final me = PlayerPos({
      'map': [0, 0],
      'heading': 0,
      'y': 611, // the camera, 3 m above the feet
    });
    expect(heightNote(568, null, me), '568 m up · 40 m below you');
    expect(heightNote(610, null, me), '610 m up · level with you');
  });

  test('pairing QR code and update versions', () {
    final p =
        Live.parsePairing(
          'enshroudbuddy:pair?a=192.168.1.20:4750,10.0.0.5:4750&k=ABCDEFGH',
        )!;
    expect(p.hosts, ['192.168.1.20:4750', '10.0.0.5:4750']);
    expect(p.key, 'ABCDEFGH');
    expect(Live.parsePairing('https://example.com/pair?a=x&k=y'), isNull);
    expect(Live.parsePairing('enshroudbuddy:pair?a=&k=ABCD'), isNull);
    expect(Updates.newer('0.35.0', '0.34.5'), isTrue);
    expect(Updates.newer('0.34.10', '0.34.9'), isTrue);
    expect(Updates.newer('0.34.5', '0.34.5+48'), isFalse);
    expect(Updates.newer('0.34.4', '0.34.5'), isFalse);
  });

  test('signed requests match the agent (agent.py sign)', () {
    final nonce = '00' * 16;
    expect(
      BuddyAuth.sign('ABCDEFGH', ['GET', '/health', 1700000000, nonce]),
      '4fe868bb30d88461cdd0946453bb927c8beb2c6f72492c0afe3a9169cb842ca2',
    );
    expect(
      BuddyAuth.sign('ABCDEFGH', [
        nonce,
        '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',
      ]),
      '94aebefdb7722f6743ce03a646443a4503dbc73b6cebfea47b8ba68147201beb',
    );
    // a signed body (POST /target), as agent.py set_target checks it
    expect(
      BuddyAuth.bodySig('ABCD1234', 'n0nce', utf8.encode('{"x":1}')),
      '2187b3790a2dbf0797daf753537493f87d9fb1e90f38253865fa4a961c87018c',
    );
  });

  test('overlay tracker: next tasks, completion, nearest missing', () {
    final s = LiveState({
      'character': {
        'name': 'Test',
        'level': 30,
        'skills': [],
        'recipes_unlocked': [],
        'knowledge': [],
        'equipment': [],
        'bag': [],
      },
      'world': {'name': 'Test', 'bases': [], 'containers': []},
    });
    expect(trackerOf(db, null, const [], null, null), isNull);
    final spot = db.poi.firstWhere((p) => !p.inside && p.loot.isNotEmpty);
    final here = PlayerPos({
      'map': [spot.x + 0.5, spot.y],
      'heading': 0,
      'y': 100,
    });
    final idle = trackerOf(db, s, const [], null, here)!;
    expect(idle['lines'], isEmpty);
    final done = (idle['done'] as List).cast<Map>();
    expect(done.map((c) => c['label']), ['Lore', 'Unique loot']);
    expect(done.every((c) => c['have'] == 0 && (c['of'] as int) > 100), isTrue);
    // nothing had yet: the nearest missing place is the one we stand by
    final t = idle['target'] as Map;
    expect((t['x'] as double) - spot.x, closeTo(0, 3));
    final arrow = db.search('iron arrow').first;
    final plan = trackerOf(db, s, [Goal(arrow.id, 20)], null, here)!;
    expect(plan['title'], arrow.name);
    expect((plan['lines'] as List).length, inInclusiveRange(1, 5));
    expect(plan['open'], greaterThanOrEqualTo((plan['lines'] as List).length));
    expect(plan['target'], isNotNull);
  });

  test('hunt: leads to the nearest missing, moves on after a visit', () {
    SharedPreferences.setMockInitialValues({});
    final s = LiveState({
      'character': {
        'name': 'Test',
        'level': 30,
        'skills': [],
        'recipes_unlocked': [],
        'knowledge': [],
        'equipment': [],
        'bag': [],
      },
      'world': {'name': 'Test', 'bases': [], 'containers': []},
    });
    PlayerPos at(double x, double y) => PlayerPos({
      'map': [x, y],
      'heading': 0,
      'y': 100,
    });
    final page = db.poi.firstWhere(
      (p) => !p.inside && p.cat == 'lore' && p.lore != null,
    );
    final h = Hunt()..start(HuntKind.lore, db, s, at(page.x + 0.5, page.y));
    expect(hunt.on, isFalse);
    expect(h.current, same(page));
    expect(navTarget.value?.x, page.x);
    final all = h.left;
    expect(all, greaterThan(100));
    h.update(db, s, at(page.x + 0.5, page.y)); // there
    expect(h.current, same(page));
    // walked on from it: the next nearest takes over, one fewer left
    h.update(db, s, at(page.x + 10, page.y));
    expect(h.current, isNot(same(page)));
    expect(h.left, all - 1);
    expect(h.current!.cat, 'lore');
    // skipping also moves on; picking another target by hand ends the hunt
    final second = h.current;
    h.skip(db, s, at(page.x + 10, page.y));
    expect(h.current, isNot(same(second)));
    navTarget.addListener(h.targetChanged);
    navTarget.value = NavTarget('elsewhere', 0, 0);
    navTarget.removeListener(h.targetChanged);
    expect(h.on, isFalse);
    navTarget.value = null;
  });

  test('hunt: hands the places to the PC and follows what it picked', () {
    SharedPreferences.setMockInitialValues({});
    final s = LiveState({
      'character': {
        'name': 'Test',
        'level': 30,
        'skills': [],
        'recipes_unlocked': [],
        'knowledge': [],
        'equipment': [],
        'bag': [],
      },
      'world': {'name': 'Test', 'bases': [], 'containers': []},
    });
    final sent = <Map<String, Object?>?>[];
    final h = Hunt()..send = sent.add;
    h.start(HuntKind.lore, db, s, null);
    expect(sent.single!['new'], isTrue);
    final places = sent.single!['places'] as List;
    expect(places.length, h.left);
    // the PC visited the first place and leads to the second
    final a = places[0] as List, b = places[1] as List;
    h.update(
      db,
      s,
      null,
      pc: {
        'cur': [b[0], b[1]],
        'passed': [
          [a[0], a[1]],
        ],
      },
    );
    expect(h.current?.x, b[0]);
    expect(h.left, places.length - 1);
    expect(sent.length, 2); // the shorter list went back
    expect(sent.last!.containsKey('new'), isFalse);
    h.stop();
    expect(sent.last, isNull);
    navTarget.value = null;
  });

  test('news: newest first, only the newest three unread the first time', () async {
    SharedPreferences.setMockInitialValues({});
    final n = KeenNews();
    final posts = [
      for (var i = 0; i < 6; i++)
        {
          'id': 'p$i',
          'date': 1700000000 + i * 86400,
          'title': 'Changelog for Hotfix #$i',
          'kind': i == 5 ? 'test' : 'patch',
          'url': '',
          'text': '# Changelog\n- Fixed the Iron Bars recipe.',
        },
    ];
    await n.update((_) async => jsonEncode({'at': 1, 'posts': posts}));
    expect(n.posts.first.id, 'p5');
    expect(n.posts.first.ahead, isTrue);
    expect(n.unread, 3);
    n.read(n.posts.first);
    expect(n.unread, 2);
    final m = Mentions.of(db).find(n.posts.first.text);
    expect(m.map((x) => x.name), contains('Iron Bars'));
  });

  test('trophy bosses: named as their head, done once it is had', () {
    final bosses = db.poi.where((p) => p.head != null).toList();
    expect(bosses.map((p) => p.title).toSet().length, greaterThan(10));
    for (final p in bosses) {
      expect(p.kind, 'Boss');
      expect(db.items[p.head]!.name, startsWith('${p.title} '));
      expect(db.poiDone(p, {}), isFalse);
      expect(db.poiDone(p, {p.head!}), isTrue);
    }
    final head = bosses.first.head!;
    final spots = WhereToGet(db, null, null).spots(head);
    expect(spots.where((s) => s.kind == 'boss'), isNotEmpty);
    expect(Hunt.wanted(HuntKind.trophies, bosses.first), isTrue);
  });

  test(
    'hunt: Shroud Roots in a region, shrines remembered once visited',
    () async {
      SharedPreferences.setMockInitialValues({});
      final s = LiveState({
        'character': {
          'name': 'Test',
          'level': 30,
          'skills': [],
          'recipes_unlocked': [],
          'knowledge': [],
          'equipment': [],
          'bag': [],
        },
        'world': {'name': 'Hunt test', 'bases': [], 'containers': []},
      });
      PlayerPos at(double x, double y) => PlayerPos({
        'map': [x, y],
        'heading': 0,
        'y': 100,
      });
      final root = db.poi.firstWhere(
        (p) => Hunt.wanted(HuntKind.roots, p) && db.regionAt(p.x, p.y) != null,
      );
      final region = db.regionAt(root.x, root.y)!;
      final h = Hunt();
      final all = h.count(db, s, HuntKind.roots, null);
      final there = h.count(db, s, HuntKind.roots, region);
      expect(all, greaterThan(40));
      expect(there, inInclusiveRange(1, all - 1));
      h.start(HuntKind.roots, db, s, at(root.x, root.y), region: region);
      expect(h.left, there);
      expect(db.regionAt(h.current!.x, h.current!.y), region);
      h.stop();
      // a shrine: the save can't tell, so having been there is what counts, and it's kept for the next hunt
      final shrine = db.poi.firstWhere(
        (p) => !p.inside && Hunt.wanted(HuntKind.shrines, p),
      );
      expect(Hunt.tracked(shrine), isFalse);
      final shrines = h.count(db, s, HuntKind.shrines, null);
      h.start(HuntKind.shrines, db, s, at(shrine.x + 0.5, shrine.y));
      expect(h.current, same(shrine));
      h.update(db, s, at(shrine.x + 0.5, shrine.y));
      h.update(db, s, at(shrine.x + 10, shrine.y));
      h.stop();
      expect(h.count(db, s, HuntKind.shrines, null), shrines - 1);
      expect(h.visitedCount, 1);
      await Future<void>.delayed(Duration.zero);
      final kept = (await SharedPreferences.getInstance()).getStringList(
        'hunt_visited:Hunt test',
      );
      expect(kept, hasLength(1));
      h.forgetVisited();
      expect(h.count(db, s, HuntKind.shrines, null), shrines);
      navTarget.value = null;
    },
  );

  test(
    'languages: every file has every text, placeholders and plural forms',
    () {
      final keys =
          jsonDecode(File('../tools/i18n/ui_keys.json').readAsStringSync())
              as Map<String, dynamic>;
      final slots = RegExp(r'\{(\w+)\}');
      Set<String> of(String s) => {for (final m in slots.allMatches(s)) m[1]!};
      for (final l in languages.skip(1)) {
        final ui =
            jsonDecode(File('assets/i18n/ui/${l.code}.json').readAsStringSync())
                as Map<String, dynamic>;
        for (final k in keys.keys) {
          final v = ui[k];
          expect(v, isNotNull, reason: '${l.code}: $k');
          for (final form in v is Map ? v.values : [v]) {
            expect(of(form as String), of(k), reason: '${l.code}: $k');
          }
        }
        final game = File('assets/i18n/game/${l.code}.json');
        expect(game.existsSync(), isTrue, reason: l.code);
      }
      L10n.use(
        languages.firstWhere((l) => l.code == 'Ru_Ru'),
        ui: {
          '{n} items': {
            'one': '{n} предмет',
            'few': '{n} предмета',
            'many': '{n} предметов',
          },
          'Hello {name}': 'Привет, {name}',
        },
        game: {'Iron Bar': 'Железный слиток'},
      );
      expect(trn(1, '{n} item', '{n} items'), '1 предмет');
      expect(trn(3, '{n} item', '{n} items'), '3 предмета');
      expect(trn(11, '{n} item', '{n} items'), '11 предметов');
      expect(trn(22, '{n} item', '{n} items'), '22 предмета');
      expect(tr('Hello {name}', {'name': 'Ann'}), 'Привет, Ann');
      expect(tr('Untranslated'), 'Untranslated');
      expect(gt('Iron Bar'), 'Железный слиток');
      L10n.use(languages.first);
      expect(trn(1, '{n} item', '{n} items'), '1 item');
      expect(gt('Iron Bar'), 'Iron Bar');
    },
  );
}
