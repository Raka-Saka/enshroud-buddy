import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'buddy_auth.dart';
import 'game_db.dart';
import 'history.dart';

/// One item stack from the save.
class Owned {
  Owned(Map<String, dynamic> j)
    : slot = j['slot'],
      itemId = j['item'],
      count = j['count'],
      level = j['level'],
      durability = (j['durability'] as List?)?.cast<int>(),
      tier = (j['tier'] as List?)?.cast<int>(),
      cosmetic = j['cosmetic'] == true;
  final int slot, count;

  /// In a cosmetic (look) slot: shown, but its stats don't count (tools/state.py, mark_cosmetics).
  final bool cosmetic;
  final String itemId;
  final int? level;
  final List<int>? durability;

  /// [upgrades allowed, upgrades applied]; each upgrade adds a level (checked: Trailblazer Boots, a level-30
  /// item, read level 33 with [3, 3]; a level-30 ring 34 with [4, 4]).
  final List<int>? tier;

  int get upgradesLeft => tier == null ? 0 : (tier![0] - tier![1]).clamp(0, 99);

  /// The level it reaches with every upgrade left applied.
  int? get topLevel => level == null ? null : level! + upgradesLeft;
}

class StoredIn {
  StoredIn(this.label, this.count, {this.base});
  final String label;
  final int count;

  /// The base it's in, when known.
  final String? base;
}

class Storage {
  Storage(Map<String, dynamic> j, this.index)
    : kind = j['kind'],
      baseId = j['base'],
      items = [for (final r in j['items']) Owned(r)];
  final int index;

  /// The base it stands in (decoded position inside a Flame Altar's build box), when known.
  final String? baseId;

  /// Item id of the chest, rack or feeder; null for animals, crops and other holders.
  final String? kind;
  final List<Owned> items;
}

class Base {
  Base(Map<String, dynamic> j)
    : id = j['id'],
      name = j['name'],
      altarLevel = j['altar_level'] ?? 0,
      mapX = (j['map'][0] as num).toDouble(),
      mapY = (j['map'][1] as num).toDouble(),
      size = [
        for (var k = 0; k < 3; k++)
          ((j['max']?[k] ?? 0) as num).toDouble() -
              ((j['min']?[k] ?? 0) as num).toDouble(),
      ],
      pieces = [for (final p in j['pieces'] ?? const []) Piece(p as List)],
      placed = Map<String, int>.from(j['placed'] ?? const {});
  final String id;
  final String? name;
  final int altarLevel;

  /// Position on the 1280 px fog-map grid.
  final double mapX, mapY;

  /// Build box size (half-metres = voxels) and the snapped building pieces inside it.
  final List<double> size;
  final List<Piece> pieces;

  /// Objects placed in this base by item id (stations, chests, decorations) and how many.
  final Map<String, int> placed;
  String get label => name ?? 'Unnamed base (${id.substring(4)})';

  /// Side of the cubic build zone, from the box in the save ("120 m").
  String get zone => '${(size[0] / 2).round()} m';
}

/// A snapped building piece in a base: position from the build box corner and size, in voxels (0.5 m);
/// the material and shape are item ids ("Rough Wood Block", "Wide Wall").
class Piece {
  Piece(List j)
    : x = (j[0] as num).toDouble(),
      y = (j[1] as num).toDouble(),
      z = (j[2] as num).toDouble(),
      sx = (j[3] as num).toDouble(),
      sy = (j[4] as num).toDouble(),
      sz = (j[5] as num).toDouble(),
      rotation = j[6] as int,
      material = j[7] as String,
      shape = j.length > 8 ? j[8] as String : '';
  final double x, y, z, sx, sy, sz;
  final int rotation;
  final String material, shape;
}

class LiveState {
  LiveState(Map<String, dynamic> j) {
    final c = j['character'] as Map<String, dynamic>;
    final w = j['world'] as Map<String, dynamic>;
    character = c['name'];
    world = w['name'];
    savedAt = DateTime.tryParse(c['saved_at'] ?? '');
    final worn = [for (final r in c['equipment'] ?? const []) Owned(r)];
    equipment = [
      for (final o in worn)
        if (!o.cosmetic) o,
    ];
    cosmetics = [
      for (final o in worn)
        if (o.cosmetic) o,
    ];
    bag = [for (final r in c['bag'] ?? const []) Owned(r)];
    pouch = [for (final r in c['pouch'] ?? const []) Owned(r)];
    skills = {
      for (final s in c['skills']) s['node'] as String: s['level'] as int,
    };
    level = c['level'] ?? 0;
    xp = c['xp'] ?? 0;
    recipesUnlocked = Set<String>.from(c['recipes_unlocked']);
    bases = [for (final b in w['bases']) Base(b)];
    var i = 0;
    containers = [for (final x in w['containers']) Storage(x, i++)];
    placed = Map<String, int>.from(w['placed'] ?? const {});
    settings = {
      for (final e
          in (w['settings'] as Map<String, dynamic>? ?? const {}).entries)
        e.key: (e.value as num).toDouble(),
    };
    flameLevel = w['flame_level'] ?? 0;
    warnings = List<String>.from(j['warnings'] ?? const []);
    knowledge = {
      ...List<String>.from(c['knowledge'] ?? const []),
      ...List<String>.from(w['knowledge'] ?? const []),
    };
    itemsKnown = Set<String>.from(c['items_known'] ?? const []);
  }

  /// Knowledge flags of the character and the world, for unlock checks.
  late final Set<String> knowledge;

  /// Every item the character has ever had: the game's own collection (sets, blocks).
  late final Set<String> itemsKnown;

  late final String character, world;
  late final DateTime? savedAt;

  /// Worn gear (what counts for stats); the cosmetic slots' pieces are in [cosmetics].
  late final List<Owned> equipment, bag, pouch;
  late final List<Owned> cosmetics;
  late final Map<String, int> skills;

  /// Character level and experience, from the save.
  late final int level, xp;
  late final Set<String> recipesUnlocked;
  late final List<Base> bases;
  late final List<Storage> containers;

  /// Placed objects by item id (stations, chests, decorations) and how many.
  late final Map<String, int> placed;

  /// World settings factors (shroud_time, diving_time, food_buff_duration, ...).
  late final Map<String, double> settings;

  /// Flame level, read from the world's logic block.
  late final int flameLevel;

  /// What the PC's save reader met but couldn't read (tools/state.py), e.g. item data from a game update:
  /// something may be missing until the reader learns it.
  late final List<String> warnings;

  Iterable<Owned> get carried => [...bag, ...pouch];

  /// What number unlock conditions compare against.
  late final UnlockContext unlockContext = UnlockContext(
    flame: flameLevel,
    level: level,
    altar: bases.fold(0, (a, b) => b.altarLevel > a ? b.altarLevel : a),
    altars: bases.length,
    placed: placed,
  );

  /// Total owned per item id: carried + every container (equipment excluded).
  late final Map<String, int> totals = () {
    final t = <String, int>{};
    for (final o in [...carried, for (final c in containers) ...c.items]) {
      t[o.itemId] = (t[o.itemId] ?? 0) + o.count;
    }
    return t;
  }();

  int owned(String itemId) => totals[itemId] ?? 0;

  List<String>? _labels;

  /// "Large Magic Chest #3": numbered per container type, in save order.
  List<String> labels(String Function(String) name) {
    if (_labels != null) return _labels!;
    final seen = <String, int>{};
    return _labels = [
      for (final c in containers)
        () {
          final kind = c.kind == null ? 'Other storage' : name(c.kind!);
          seen[kind] = (seen[kind] ?? 0) + 1;
          return '$kind #${seen[kind]}';
        }(),
    ];
  }

  /// Where an item is: "Bag 12", "Large Magic Chest #3 40", ...
  List<StoredIn> whereIs(String itemId, String Function(String) name) {
    final out = <StoredIn>[];
    final carried = this.carried
        .where((o) => o.itemId == itemId)
        .fold(0, (a, o) => a + o.count);
    if (carried > 0) out.add(StoredIn('Bag', carried));
    final worn = equipment.where((o) => o.itemId == itemId).length;
    if (worn > 0) out.add(StoredIn('Equipped', worn));
    final look = cosmetics.where((o) => o.itemId == itemId).length;
    if (look > 0) out.add(StoredIn('Cosmetic', look));
    final l = labels(name);
    for (final c in containers) {
      final n = c.items
          .where((o) => o.itemId == itemId)
          .fold(0, (a, o) => a + o.count);
      if (n > 0) out.add(StoredIn(l[c.index], n, base: baseName(c.baseId)));
    }
    return out;
  }

  /// A base's name from its id ("base07" -> "Lakeside Keep").
  String? baseName(String? id) {
    if (id == null) return null;
    for (final b in bases) {
      if (b.id == id) return b.label;
    }
    return null;
  }

  /// Bases where a station (or any placeable) stands.
  List<Base> basesWith(String itemId) => [
    for (final b in bases)
      if ((b.placed[itemId] ?? 0) > 0) b,
  ];
}

/// Gives every screen access to the live state.
class LiveScope extends InheritedNotifier<Live> {
  const LiveScope({super.key, required Live live, required super.child})
    : super(notifier: live);

  static Live of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LiveScope>()!.notifier!;
}

/// Where the player is right now, read from the running game by the agent (GET /pos).
class PlayerPos {
  PlayerPos(Map<String, dynamic> j)
    : x = ((j['map'] as List)[0] as num).toDouble(),
      y = ((j['map'] as List)[1] as num).toDouble(),
      heading = (j['heading'] as num).toDouble(),
      height = (j['y'] as num).toDouble(),
      glide = switch (j['glide']) {
        {'ratio': final num r, 'speed': final num s} => (
          ratio: r.toDouble(),
          speed: s.toDouble(),
        ),
        _ => null,
      },
      mode = switch (j['mode']) {
        'air' => Motion.air,
        'fall' => Motion.fall,
        'foot' => Motion.foot,
        _ => null,
      },
      speed = (j['speed'] as num?)?.toDouble() ?? 0,
      course = (j['course'] as num?)?.toDouble(),
      above = (j['above'] as num?)?.toDouble(),
      walkSpeed = switch (j['walk']) {
        {'speed': final num s} => s.toDouble(),
        _ => null,
      };

  /// On the 1280 px map (8 m a pixel, y grows south).
  final double x, y;

  /// Where the camera looks, in degrees: 0 north, 90 east.
  final double heading;
  final double height;

  /// The equipped glider as measured from the player's own glides (tools/glide.py): metres across per
  /// metre of height, and metres a second. Null until a few glides are in.
  final ({double ratio, double speed})? glide;

  /// On foot, in the air or falling, from the last few readings (tools/motion.py); null from an older
  /// agent.
  final Motion? mode;

  /// Metres a second across the ground, and the direction of travel (degrees, 0 north) when moving.
  final double speed;
  final double? course;

  /// Metres the feet are above the map's ground (a few metres off; more on ridges).
  final double? above;

  /// The player's own walking speed, metres a second, once a minute of walking is measured.
  final double? walkSpeed;

  bool get airborne => mode == Motion.air || mode == Motion.fall;

  /// The way the guide steers by: where you're flying in the air, where the camera looks on foot.
  double get travel =>
      airborne && course != null && speed >= 3 ? course! : heading;
}

enum Motion { foot, air, fall }

/// The saves on the agent's PC (GET /saves) and the one it reads.
class SaveList {
  SaveList(Map<String, dynamic> j)
    : folders = [
        for (final f in j['folders'] ?? const [])
          SaveFolder(f as Map<String, dynamic>),
      ],
      current = (
        folder: (j['current']?['folder'] ?? '') as String,
        world: (j['current']?['world'] ?? 0) as int,
        character: (j['current']?['character'] ?? 0) as int,
      );
  final List<SaveFolder> folders;
  final ({String folder, int world, int character}) current;
}

/// One save folder (a Steam account, or Saved Games) with its worlds and characters, newest first.
class SaveFolder {
  SaveFolder(Map<String, dynamic> j)
    : folder = j['folder'],
      label = j['label'] ?? j['folder'],
      worlds = [for (final e in j['worlds'] ?? const []) SaveSlot(e)],
      characters = [for (final e in j['characters'] ?? const []) SaveSlot(e)];
  final String folder, label;
  final List<SaveSlot> worlds, characters;
}

class SaveSlot {
  SaveSlot(Map<String, dynamic> j)
    : slot = j['slot'],
      name = j['name'] ?? '',
      savedAt = j['saved_at'] ?? '';
  final int slot;
  final String name, savedAt;
}

/// Talks to the PC agent (agent/agent.py) over the LAN.
class Live extends ChangeNotifier {
  /// The PC agent's address when Setup hasn't set one: empty unless the build says
  /// (flutter build apk --dart-define=AGENT_HOST=192.168.1.20:4750).
  static const defaultHost = String.fromEnvironment('AGENT_HOST');

  /// The agent's pairing code (its tray menu), sent with every request; a build can carry one too
  /// (--dart-define=AGENT_KEY=ABCDEFGH).
  static const defaultKey = String.fromEnvironment('AGENT_KEY');
  String key = defaultKey;

  /// Signs a request (BuddyAuth); returns its nonce.
  String _auth(HttpClientRequest req) => BuddyAuth.apply(req, key);
  String host = defaultHost;
  LiveState? state;
  String? error;
  String? _builtAt;

  /// The PC agent's version (GET /health), null for agents older than 0.36.
  String? agentVersion;

  /// Progress snapshots, oldest first (GET /history).
  List<Snapshot> history = const [];

  /// Changes whenever the agent rebuilds; used to refresh the fog overlay.
  String? get builtAt => _builtAt;
  bool loading = false;
  Timer? _timer;

  /// The player's live position; null while the game isn't running (or the agent is older).
  final pos = ValueNotifier<PlayerPos?>(null);

  /// The explored-map veil (GET /fog_overlay.png). A new one replaces it only once fully downloaded, and
  /// the last one is kept through dropped requests and between app starts, so the fog never blinks out
  /// when the game saves (every 30 s or so) or the Wi-Fi hiccups.
  final fogOverlay = ValueNotifier<Uint8List?>(null);
  String? _fogFor;

  Future<void> _fetchFog() async {
    final at = _builtAt;
    if (at == null || at == _fogFor) return;
    try {
      final bytes = await _getBytes('/fog_overlay.png');
      _fogFor = at;
      fogOverlay.value = bytes;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_fog', base64Encode(bytes));
    } catch (_) {} // keep the one we have; the next save tries again
  }

  /// When the last live position came in: a missed reading keeps it for [posGrace].
  DateTime? _posSeen;
  static const posGrace = Duration(seconds: 10);

  /// A request failed or the agent had no camera this second: drop the position only once it has been
  /// gone for [posGrace], so a slow request doesn't blink the arrow, the trail and the guide away.
  void _posLost() {
    final seen = _posSeen;
    if (pos.value != null &&
        seen != null &&
        DateTime.now().difference(seen) < posGrace) {
      return;
    }
    _setPos(null);
  }

  Timer? _posTimer;
  bool _posBusy = false;

  /// Follow the player once a second (while the map is on screen); otherwise it is read with each refresh.
  void followPos(bool on) {
    if (on == (_posTimer != null)) return;
    _posTimer?.cancel();
    _posTimer =
        on
            ? Timer.periodic(const Duration(seconds: 1), (_) => _pollPos())
            : null;
    if (on) _pollPos();
  }

  Future<void> _pollPos() async {
    if (_posBusy) return;
    _posBusy = true;
    try {
      final j = jsonDecode(await _get('/pos')) as Map<String, dynamic>;
      if (j['live'] == true) {
        _posSeen = DateTime.now();
        _setPos(PlayerPos(j));
      } else {
        _posLost();
      }
    } catch (_) {
      _posLost();
    } finally {
      _posBusy = false;
    }
  }

  PlayerPos? _posShown;

  /// Every reading goes to [pos] (the map's arrow); the screens that rank tasks and spots by where you
  /// are rebuild only when you've moved 40 m or more, or the game started or stopped.
  void _setPos(PlayerPos? p) {
    pos.value = p;
    final last = _posShown;
    final moved =
        (p == null) != (last == null) ||
        (p != null &&
            last != null &&
            (p.x - last.x) * (p.x - last.x) + (p.y - last.y) * (p.y - last.y) >=
                25);
    if (moved) {
      _posShown = p;
      notifyListeners();
    }
  }

  Future<void> start() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      host = prefs.getString('agent_host') ?? defaultHost;
      key = prefs.getString('agent_key') ?? defaultKey;
      if (prefs.getString('agent_key') == null && key.isNotEmpty) {
        await prefs.setString('agent_key', key);
      }
      // a build's address is kept, so later builds without one still find the agent
      if (prefs.getString('agent_host') == null && host.isNotEmpty) {
        await prefs.setString('agent_host', host);
      }
      final cached = prefs.getString('last_state');
      if (cached != null) state = LiveState(jsonDecode(cached));
      final fog = prefs.getString('last_fog');
      if (fog != null) fogOverlay.value = base64Decode(fog);
      final hist = prefs.getString('last_history');
      if (hist != null) history = _history(hist);
    } catch (_) {}
    notifyListeners();
    await refresh();
    _poll(true);
    // the game saves about every 30 s: check every 5 s while the app is open, not in the background
    _lifecycle = AppLifecycleListener(
      onResume: () {
        refresh(onlyIfNew: true);
        _poll(true);
      },
      onPause: () => _poll(false),
    );
  }

  AppLifecycleListener? _lifecycle;

  void _poll(bool on) {
    _timer?.cancel();
    _timer =
        on
            ? Timer.periodic(
              const Duration(seconds: 5),
              (_) => refresh(onlyIfNew: true),
            )
            : null;
  }

  /// A private (home network) IPv4 address with a port, the only kind the agent listens for: a code
  /// pointing anywhere else is ignored.
  static bool _homeAddress(String h) {
    final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)\.(\d+):(\d+)$').firstMatch(h);
    if (m == null) return false;
    final a = int.parse(m[1]!), b = int.parse(m[2]!);
    return a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168);
  }

  /// The addresses and pairing code in the agent's QR code ("enshroudbuddy:pair?a=IP:PORT,IP:PORT&k=CODE",
  /// tray menu "Pair a phone"), or null for any other text.
  static ({List<String> hosts, String key})? parsePairing(String text) {
    final uri = Uri.tryParse(text.trim());
    if (uri == null || uri.scheme != 'enshroudbuddy' || uri.path != 'pair') {
      return null;
    }
    final hosts =
        (uri.queryParameters['a'] ?? '')
            .split(',')
            .where((h) => h.isNotEmpty && _homeAddress(h))
            .toList();
    final key = uri.queryParameters['k'] ?? '';
    return hosts.isEmpty || key.isEmpty ? null : (hosts: hosts, key: key);
  }

  /// Pairs with the agent from its QR code: a PC can have several addresses, and only the one on the
  /// phone's network answers, so each is tried in turn and the first that knows the code is kept. Returns
  /// that address, or null when none answered.
  Future<String?> pair(String code) async {
    final p = parsePairing(code);
    if (p == null) throw const FormatException('not an Enshroud Buddy code');
    for (final h in p.hosts) {
      final client =
          HttpClient()..connectionTimeout = const Duration(seconds: 2);
      try {
        for (var attempt = 0; attempt < 2; attempt++) {
          final req = await client.getUrl(Uri.parse('http://$h/health'));
          final nonce = BuddyAuth.apply(req, p.key);
          final res = await req.close().timeout(const Duration(seconds: 4));
          if (res.statusCode == 401 && await BuddyAuth.learnClock(res))
            continue;
          final body = await res.fold<List<int>>([], (a, c) => a..addAll(c));
          if (res.statusCode == 200 &&
              BuddyAuth.replyOk(p.key, nonce, res, body)) {
            await setHost(h, pairing: p.key);
            return h;
          }
          break;
        }
      } catch (_) {
        // not reachable from this network: try the next
      } finally {
        client.close(force: true);
      }
    }
    return null;
  }

  Future<void> setHost(String h, {String? pairing}) async {
    host = h.trim();
    if (pairing != null) {
      key = pairing.replaceAll('-', '').replaceAll(' ', '').toUpperCase();
    }
    _builtAt = null;
    _fogFor = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('agent_host', host);
    await prefs.setString('agent_key', key);
    await refresh();
  }

  /// Ask the companion (POST /ask): headless Claude Code on the PC answers from the save and the game
  /// data. Returns (answer, session id for follow-ups); throws with a short reason.
  /// Every save on the agent's PC, and the one it reads.
  Future<SaveList> saves() async =>
      SaveList(jsonDecode(await _get('/saves')) as Map<String, dynamic>);

  /// Have the agent read another world and character; the state follows within seconds.
  Future<void> select(String folder, int world, int character) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await client.postUrl(Uri.parse('http://$host/select'));
      _auth(req);
      req.headers.contentType = ContentType.json;
      final payload = utf8.encode(
        jsonEncode({'folder': folder, 'world': world, 'character': character}),
      );
      req.contentLength = payload.length;
      req.add(payload);
      final res = await req.close().timeout(const Duration(seconds: 10));
      final body =
          jsonDecode(await res.transform(utf8.decoder).join())
              as Map<String, dynamic>;
      if (body['ok'] != true) throw StateError(body['error'] ?? 'refused');
    } finally {
      client.close(force: true);
    }
    // the agent rebuilds in a few seconds: look then, and again a little later
    _builtAt = null;
    _fogFor = null;
    for (final wait in const [4, 10]) {
      Future.delayed(Duration(seconds: wait), refresh);
    }
  }

  Future<(String, String?)> ask(
    String question, {
    String? session,
    String? context,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await client.postUrl(Uri.parse('http://$host/ask'));
      _auth(req);
      req.headers.contentType = ContentType.json;
      final payload = utf8.encode(
        jsonEncode({
          'q': question,
          if (session != null) 'session': session,
          if (context != null) 'context': context,
        }),
      );
      req.contentLength = payload.length; // a sized body, not chunked
      req.add(payload);
      final res = await req.close().timeout(const Duration(seconds: 260));
      final body =
          jsonDecode(await res.transform(utf8.decoder).join())
              as Map<String, dynamic>;
      if (body['error'] != null) throw StateError(body['error']);
      return (body['answer'] as String, body['session'] as String?);
    } finally {
      client.close(force: true);
    }
  }

  /// The same as [ask], answered as it is written (POST /ask/stream): events {"status"}, {"reset"},
  /// {"delta"}, then {"done", "answer", "session"}; throws with a short reason. Falls back to the
  /// whole answer at once on an agent without streaming.
  Stream<Map<String, dynamic>> askStream(
    String question, {
    String? session,
    String? context,
  }) async* {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await client.postUrl(Uri.parse('http://$host/ask/stream'));
      _auth(req);
      req.headers.contentType = ContentType.json;
      final payload = utf8.encode(
        jsonEncode({
          'q': question,
          if (session != null) 'session': session,
          if (context != null) 'context': context,
        }),
      );
      req.contentLength = payload.length;
      req.add(payload);
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode == 404) {
        await res.drain<void>();
        final (a, s) = await ask(question, session: session, context: context);
        yield {'done': true, 'answer': a, 'session': s};
        return;
      }
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final lines = res
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(const Duration(seconds: 150));
      await for (final line in lines) {
        if (line.trim().isEmpty) continue;
        final ev = jsonDecode(line) as Map<String, dynamic>;
        if (ev['error'] != null) throw StateError(ev['error']);
        yield ev;
        if (ev['done'] == true) return;
      }
      throw StateError('the PC stopped answering');
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _get(String path) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await client.getUrl(Uri.parse('http://$host$path'));
      final nonce = _auth(req);
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode == 401) {
        if (await BuddyAuth.learnClock(res)) {
          throw StateError(
            'the phone\'s clock is off from the PC\'s; trying again',
          );
        }
        throw StateError(
          'the pairing code is missing or wrong: Setup, then scan the agent\'s code',
        );
      }
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final body = await res.fold<List<int>>([], (a, c) => a..addAll(c));
      if (!BuddyAuth.replyOk(key, nonce, res, body)) {
        throw StateError(
          'the reply didn\'t come from your agent (or it is older than this app)',
        );
      }
      return utf8.decode(body);
    } finally {
      client.close(force: true);
    }
  }

  int _failures = 0;

  Future<Uint8List> _getBytes(String path) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await client.getUrl(Uri.parse('http://$host$path'));
      final nonce = _auth(req);
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode == 401) await BuddyAuth.learnClock(res);
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final b = BytesBuilder(copy: false);
      await for (final chunk in res) {
        b.add(chunk);
      }
      final body = b.takeBytes();
      if (!BuddyAuth.replyOk(key, nonce, res, body)) {
        throw StateError('the reply didn\'t come from your agent');
      }
      return body;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> refresh({bool onlyIfNew = false}) async {
    if (loading) return;
    loading = true;
    if (!onlyIfNew) notifyListeners();
    final stateBefore = state, errorBefore = error;
    try {
      final health = jsonDecode(await _get('/health')) as Map<String, dynamic>;
      agentVersion = health['version'] as String?;
      if (health['ok'] != true)
        throw StateError(health['error'] ?? 'agent not ready');
      if (!onlyIfNew || health['built_at'] != _builtAt || state == null) {
        final raw = await _get('/state');
        state = LiveState(
          await compute(jsonDecode, raw) as Map<String, dynamic>,
        );
        _builtAt = health['built_at'];
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('last_state', raw);
        try {
          final hist = await _get('/history');
          history = _history(hist);
          await prefs.setString('last_history', hist);
        } catch (_) {} // an older agent without /history
      }
      error = null;
      _failures = 0;
      _fetchFog();
      if (_posTimer == null) _pollPos();
    } catch (e) {
      // one missed 5 s check on a busy Wi-Fi isn't news: say so from the second in a row
      if (++_failures >= 2 || state == null || !onlyIfNew) {
        error = 'Agent unreachable at $host ($e)';
      }
      _posLost();
    } finally {
      loading = false;
      // a quiet check (every 5 s) only rebuilds the screens when the save or the link changed
      if (!onlyIfNew ||
          !identical(state, stateBefore) ||
          error != errorBefore) {
        notifyListeners();
      }
    }
  }

  static List<Snapshot> _history(String raw) => [
    for (final j in jsonDecode(raw) as List)
      Snapshot(j as Map<String, dynamic>),
  ];

  @override
  void dispose() {
    _timer?.cancel();
    _posTimer?.cancel();
    _lifecycle?.dispose();
    pos.dispose();
    fogOverlay.dispose();
    super.dispose();
  }
}
