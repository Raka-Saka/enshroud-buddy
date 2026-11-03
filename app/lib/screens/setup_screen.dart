import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/live_state.dart';
import '../theme.dart';
import 'widgets.dart';

/// The PC agent's address, and which world and character it reads: every save folder on that PC
/// (one per Steam account), with the names the game shows.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late final host = TextEditingController(text: LiveScope.of(context).host);
  late final pairing = TextEditingController(text: LiveScope.of(context).key);
  Future<SaveList>? saves;
  String? folder;
  int? world, character;
  bool busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    saves ??= _load();
  }

  Future<SaveList> _load() async {
    final list = await LiveScope.of(context).saves();
    setState(() {
      folder = list.current.folder;
      world = list.current.world;
      character = list.current.character;
    });
    return list;
  }

  Future<void> _saveHost(Live live) async {
    await live.setHost(host.text, pairing: pairing.text);
    if (mounted) setState(() => saves = _load());
  }

  static const _scanner = MethodChannel('ensh/scan');

  /// Google's code scanner (no camera permission: Play services shows its own camera screen), then pairing.
  Future<void> _scan(Live live) async {
    final messenger = ScaffoldMessenger.of(context);
    String? code;
    try {
      code = await _scanner.invokeMethod<String>('qr');
    } on PlatformException catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Couldn\'t scan: ${e.message}. Type the details below.',
          ),
        ),
      );
      return;
    }
    if (code == null) return; // cancelled
    if (Live.parsePairing(code) == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'That isn\'t the agent\'s code: on the PC, right-click the tray icon, Pair a phone.',
          ),
        ),
      );
      return;
    }
    setState(() => busy = true);
    final h = await live.pair(code);
    if (!mounted) return;
    setState(() {
      busy = false;
      if (h != null) {
        host.text = h;
        pairing.text = live.key;
        saves = _load();
      }
    });
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          h != null
              ? 'Paired with your PC'
              : 'The PC didn\'t answer. Is the phone on the same Wi-Fi as the PC? On the PC, allow '
                  'Enshroud Buddy on private networks if Windows asked.',
        ),
      ),
    );
  }

  Future<void> _use(Live live, SaveFolder f) async {
    setState(() => busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await live.select(f.folder, world!, character!);
      final w = f.worlds.firstWhere((e) => e.slot == world).name;
      final c = f.characters.firstWhere((e) => e.slot == character).name;
      messenger.showSnackBar(
        SnackBar(content: Text('Reading $c in $w; it shows in a few seconds')),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Couldn\'t switch: $e')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final live = LiveScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Setup')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const SectionTitle('PC agent'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: FilledButton.icon(
              onPressed: busy ? null : () => _scan(live),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan the PC\'s code'),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              'On the PC: right-click the Enshroud Buddy icon in the tray, Pair a phone. Or type the details:',
              style: TextStyle(color: Palette.ash, fontSize: 12),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: host,
                    decoration: const InputDecoration(
                      hintText: '192.168.1.20:4750',
                      helperText:
                          'Shown in the agent\'s tray menu on the PC: "Phone address"',
                    ),
                    onSubmitted: (_) => _saveHost(live),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: () => _saveHost(live),
                  child: const Text('Connect'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: pairing,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                hintText: 'ABCD-EFGH',
                helperText:
                    'Pairing code, also in the tray menu: keeps other devices out',
              ),
              onSubmitted: (_) => _saveHost(live),
            ),
          ),
          const SectionTitle('Game save'),
          FutureBuilder<SaveList>(
            future: saves,
            builder: (context, snap) {
              if (snap.hasError) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'The agent didn\'t answer, or it is older than this app. Check the address above.',
                    style: TextStyle(color: Palette.ash),
                  ),
                );
              }
              final list = snap.data;
              if (list == null) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (list.folders.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'No Enshrouded saves on that PC yet: play once, then come back.',
                    style: TextStyle(color: Palette.ash),
                  ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final f in list.folders) _folder(live, list, f),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text(
                      'Playing in a friend\'s world? The world is saved on the host\'s PC, so only your '
                      'character is on yours: pick a world you host to see bases and chests.',
                      style: TextStyle(color: Palette.ash, fontSize: 12.5),
                    ),
                  ),
                ],
              );
            },
          ),
          const SectionTitle('About'),
          ListTile(
            leading: const Icon(Icons.gavel_outlined),
            title: const Text('Licenses and credits'),
            subtitle: const Text(
              'Unofficial fan project. Not affiliated with or endorsed by Keen Games.',
              style: TextStyle(color: Palette.ash, fontSize: 12),
            ),
            onTap:
                () => showLicensePage(
                  context: context,
                  applicationName: 'Enshroud Buddy',
                  applicationLegalese:
                      'Unofficial fan project. Not affiliated with or endorsed by Keen Games. '
                      'Enshrouded and its content are the property of Keen Games GmbH. App code: MIT license.',
                ),
          ),
        ],
      ),
    );
  }

  Widget _folder(Live live, SaveList list, SaveFolder f) {
    final here = folder == f.folder;
    final isCurrent =
        list.current.folder == f.folder &&
        list.current.world == world &&
        list.current.character == character;
    Widget pick(String kind, SaveSlot e, bool selected, VoidCallback onTap) =>
        ListTile(
          dense: true,
          leading: Icon(
            selected ? Icons.radio_button_checked : Icons.radio_button_off,
            color: selected ? Palette.flame : Palette.ash,
          ),
          title: Text(e.name.isEmpty ? '$kind ${e.slot}' : e.name),
          subtitle: Text(
            'Slot ${e.slot} · saved ${e.savedAt.replaceFirst('T', ' ')}',
            style: const TextStyle(color: Palette.ash, fontSize: 12),
          ),
          onTap: onTap,
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Text(
                f.label,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text('World', style: TextStyle(color: Palette.ash)),
            ),
            for (final e in f.worlds)
              pick(
                'World',
                e,
                here && world == e.slot,
                () => setState(() {
                  // another account's folder: start from its newest character
                  if (!here) character = f.characters.firstOrNull?.slot;
                  folder = f.folder;
                  world = e.slot;
                }),
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text('Character', style: TextStyle(color: Palette.ash)),
            ),
            for (final e in f.characters)
              pick(
                'Character',
                e,
                here && character == e.slot,
                () => setState(() {
                  if (!here) world = f.worlds.firstOrNull?.slot;
                  folder = f.folder;
                  character = e.slot;
                }),
              ),
            if (here)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: FilledButton.icon(
                  icon: Icon(isCurrent ? Icons.check : Icons.swap_horiz),
                  label: Text(
                    isCurrent ? 'Reading this save' : 'Read this save',
                  ),
                  onPressed:
                      isCurrent ||
                              busy ||
                              world == null ||
                              character == null ||
                              !f.worlds.any((e) => e.slot == world) ||
                              !f.characters.any((e) => e.slot == character)
                          ? null
                          : () => _use(live, f),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
