import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/live_state.dart';
import '../l10n.dart';
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
            tr('Couldn\'t scan: {error}. Type the details below.', {
              'error': e.message,
            }),
          ),
        ),
      );
      return;
    }
    if (code == null) return; // cancelled
    if (Live.parsePairing(code) == null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            tr(
              'That isn\'t the agent\'s code: on the PC, right-click the tray icon, Pair a phone.',
            ),
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
              ? tr('Paired with your PC')
              : tr(
                'The PC didn\'t answer. Is the phone on the same Wi-Fi as the PC? On the PC, allow Enshroud Buddy on private networks if Windows asked.',
              ),
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
        SnackBar(
          content: Text(
            tr('Reading {character} in {world}; it shows in a few seconds', {
              'character': c,
              'world': w,
            }),
          ),
        ),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(tr('Couldn\'t switch: {error}', {'error': e}))),
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final live = LiveScope.of(context);
    // rebuilt when another language is picked (the app's locale changes once its texts are loaded)
    Localizations.localeOf(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Setup'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          SectionTitle(tr('PC agent')),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: FilledButton.icon(
              onPressed: busy ? null : () => _scan(live),
              icon: const Icon(Icons.qr_code_scanner),
              label: Text(tr('Scan the PC\'s code')),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              tr(
                'On the PC: right-click the Enshroud Buddy icon in the tray, Pair a phone. Or type the details:',
              ),
              style: const TextStyle(color: Palette.ash, fontSize: 12),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: host,
                    decoration: InputDecoration(
                      hintText: '192.168.1.20:4750',
                      helperText: tr(
                        'Shown in the agent\'s tray menu on the PC: "Phone address"',
                      ),
                    ),
                    onSubmitted: (_) => _saveHost(live),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: () => _saveHost(live),
                  child: Text(tr('Connect')),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: pairing,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                hintText: 'ABCD-EFGH',
                helperText: tr(
                  'Pairing code, also in the tray menu: keeps other devices out',
                ),
              ),
              onSubmitted: (_) => _saveHost(live),
            ),
          ),
          _language(),
          SectionTitle(tr('Game save')),
          FutureBuilder<SaveList>(
            future: saves,
            builder: (context, snap) {
              if (snap.hasError) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    tr(
                      'The agent didn\'t answer, or it is older than this app. Check the address above.',
                    ),
                    style: const TextStyle(color: Palette.ash),
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
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    tr(
                      'No Enshrouded saves on that PC yet: play once, then come back.',
                    ),
                    style: const TextStyle(color: Palette.ash),
                  ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final f in list.folders) _folder(live, list, f),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text(
                      tr(
                        'Playing in a friend\'s world? The world is saved on the host\'s PC, so only your character is on yours: pick a world you host to see bases and chests.',
                      ),
                      style: const TextStyle(
                        color: Palette.ash,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          SectionTitle(tr('About')),
          ListTile(
            leading: const Icon(Icons.gavel_outlined),
            title: Text(tr('Licenses and credits')),
            subtitle: Text(
              tr(
                'Unofficial fan project. Not affiliated with or endorsed by Keen Games.',
              ),
              style: const TextStyle(color: Palette.ash, fontSize: 12),
            ),
            onTap:
                () => showLicensePage(
                  context: context,
                  applicationName: 'Enshroud Buddy',
                  applicationLegalese: tr(
                    'Unofficial fan project. Not affiliated with or endorsed by Keen Games. Enshrouded and its content are the property of Keen Games GmbH. App code: MIT license.',
                  ),
                ),
          ),
        ],
      ),
    );
  }

  /// The language picked here (null: the phone's), shown on the Language tile.
  late Future<String?> _chosen = L10n.chosen();

  Widget _language() => FutureBuilder<String?>(
    future: _chosen,
    builder: (context, snap) {
      final pick = languages.where((l) => l.code == snap.data).firstOrNull;
      return ListTile(
        leading: const Icon(Icons.translate),
        title: Text(tr('Language')),
        subtitle: Text(
          pick?.name ??
              tr('Phone language ({lang})', {'lang': L10n.ofDevice().name}),
          style: const TextStyle(color: Palette.ash, fontSize: 12),
        ),
        onTap:
            snap.connectionState == ConnectionState.done
                ? () => _pickLanguage(pick?.code)
                : null,
      );
    },
  );

  Future<void> _pickLanguage(String? current) async {
    // '' stands for the phone's language; null is a dismissed dialog
    final now = current ?? '';
    final code = await showDialog<String>(
      context: context,
      builder:
          (context) => SimpleDialog(
            title: Text(tr('Language')),
            children: [
              for (final (c, name) in [
                ('', tr('Phone language')),
                for (final l in languages) (l.code, l.name),
              ])
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, c),
                  child: Row(
                    children: [
                      Icon(
                        c == now
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        size: 20,
                        color: c == now ? Palette.flame : Palette.ash,
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(name)),
                    ],
                  ),
                ),
            ],
          ),
    );
    if (code == null || code == now) return;
    await L10n.choose(code.isEmpty ? null : code);
    if (mounted) setState(() => _chosen = L10n.chosen());
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
          title: Text(
            e.name.isEmpty
                ? tr('{kind} {slot}', {'kind': kind, 'slot': e.slot})
                : e.name,
          ),
          subtitle: Text(
            tr('Slot {slot} · saved {time}', {
              'slot': e.slot,
              'time': e.savedAt.replaceFirst('T', ' '),
            }),
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
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                tr('World'),
                style: const TextStyle(color: Palette.ash),
              ),
            ),
            for (final e in f.worlds)
              pick(
                tr('World'),
                e,
                here && world == e.slot,
                () => setState(() {
                  // another account's folder: start from its newest character
                  if (!here) character = f.characters.firstOrNull?.slot;
                  folder = f.folder;
                  world = e.slot;
                }),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                tr('Character'),
                style: const TextStyle(color: Palette.ash),
              ),
            ),
            for (final e in f.characters)
              pick(
                tr('Character'),
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
                    isCurrent ? tr('Reading this save') : tr('Read this save'),
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
