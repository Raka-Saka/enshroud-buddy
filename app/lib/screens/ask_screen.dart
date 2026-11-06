import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/game_db.dart';
import '../data/guide.dart';
import '../data/item_icons.dart';
import '../data/live_state.dart';
import '../data/mentions.dart';
import '../data/voice.dart';
import '../data/where.dart';
import '../l10n.dart';
import '../labels.dart';
import '../theme.dart';
import 'item_screen.dart';
import 'items_screen.dart' show categoryLabel;
import 'map_screen.dart';
import 'plans_screen.dart';
import 'skill_tree_screen.dart';
import 'widgets.dart';

/// One turn of the conversation.
class AskTurn {
  AskTurn(this.question, {this.answer, this.error});
  final String question;
  String? answer, error;

  /// While it's being written: the text so far and what Claude is doing ("Searching the web").
  String partial = '';
  String? status;

  Map<String, dynamic> toJson() => {'q': question, 'a': answer, 'e': error};
  static AskTurn fromJson(Map<String, dynamic> j) =>
      AskTurn(j['q'], answer: j['a'], error: j['e']);
}

/// The conversation, kept outside the screen so an answer still being written survives leaving Ask.
class AskChat extends ChangeNotifier {
  final turns = <AskTurn>[];
  String? session;
  bool busy = false;
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('ask_chat');
      if (raw == null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      session = j['session'];
      turns.addAll([
        for (final t in j['turns'] as List)
          AskTurn.fromJson(t as Map<String, dynamic>),
      ]);
      // a question still open when the app closed won't be answered now: offer a retry
      for (final t in turns) {
        if (t.answer == null && t.error == null) t.error = 'interrupted';
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      final keep = turns.length > 30 ? turns.sublist(turns.length - 30) : turns;
      await p.setString(
        'ask_chat',
        jsonEncode({
          'session': session,
          'turns': [for (final t in keep) t.toJson()],
        }),
      );
    } catch (_) {}
  }

  /// [spoken]: asked by voice, so the answer is read aloud.
  Future<void> send(
    Live live,
    String q, {
    String? context,
    bool spoken = false,
  }) async {
    q = q.trim();
    if (q.isEmpty || busy) return;
    final turn = AskTurn(q)..status = 'Sending';
    turns.add(turn);
    busy = true;
    notifyListeners();
    try {
      await for (final ev in live.askStream(
        q,
        session: session,
        context: context,
      )) {
        if (ev['status'] != null) turn.status = ev['status'];
        if (ev['reset'] == true) turn.partial = '';
        if (ev['delta'] != null) turn.partial += ev['delta'] as String;
        if (ev['done'] == true) {
          turn.answer = ev['answer'] as String;
          session = ev['session'] as String? ?? session;
        }
        notifyListeners();
      }
    } catch (e) {
      turn.error = '$e'.replaceFirst('Bad state: ', '');
    }
    if (turn.answer == null && turn.error == null) turn.error = 'no answer';
    busy = false;
    notifyListeners();
    _save();
    if (spoken && turn.answer != null) Voice.speak(turn.answer!);
  }

  void retry(Live live, AskTurn t, {String? context}) {
    turns.remove(t);
    send(live, t.question, context: context);
  }

  void clear() {
    turns.clear();
    session = null;
    notifyListeners();
    _save();
  }
}

final askChat = AskChat();

/// "Ask about this" from an item, skill or place: Ask with questions about it to offer.
void askAbout(
  BuildContext context,
  GameDb db,
  String topic,
  List<String> prompts,
) => Navigator.push(
  context,
  MaterialPageRoute(
    builder: (_) => AskScreen(db: db, topic: topic, prompts: prompts),
  ),
);

/// The questions offered in the chosen language, by the English question that is sent (Claude gets the
/// English one; it answers in the chosen language).
final _shownQuestions = <String, String>{};

/// A question to offer: [en] is sent, [shown] is what the chip and the bubble say.
String _question(String en, String shown) {
  _shownQuestions[en] = shown;
  return en;
}

/// An offered question as the player sees it.
String shownQuestion(String en) => _shownQuestions[en] ?? en;

List<String> itemPrompts(GameDb db, Item it) {
  final item = {'item': gt(it.name)};
  return [
    if (db.madeBy[it.id]?.isNotEmpty ?? false)
      _question('How do I make ${it.name}?', tr('How do I make {item}?', item))
    else
      _question(
        'Where do I find ${it.name}?',
        tr('Where do I find {item}?', item),
      ),
    if (it.stats?.slot != null)
      _question(
        'Is ${it.name} good for my build?',
        tr('Is {item} good for my build?', item),
      ),
    _question(
      'What is ${it.name} good for?',
      tr('What is {item} good for?', item),
    ),
    if (db.madeBy[it.id]?.isNotEmpty ?? false)
      _question(
        'Where do I find ${it.name}?',
        tr('Where do I find {item}?', item),
      ),
  ];
}

List<String> skillPrompts(Skill k) {
  final skill = {'skill': gt(k.name)};
  return [
    _question(
      'Is ${k.name} worth it for my build?',
      tr('Is {skill} worth it for my build?', skill),
    ),
    _question(
      'What does ${k.name} do at each rank?',
      tr('What does {skill} do at each rank?', skill),
    ),
    _question(
      'Which skills go well with ${k.name}?',
      tr('Which skills go well with {skill}?', skill),
    ),
  ];
}

List<String> placePrompts(Poi p) {
  final at = '${p.title} at x ${p.x.round()}, y ${p.y.round()}';
  final place = {'place': gt(p.title), 'x': p.x.round(), 'y': p.y.round()};
  return [
    _question(
      'What is at the $at?',
      tr('What is at the {place} at x {x}, y {y}?', place),
    ),
    _question(
      'Am I ready for the $at?',
      tr('Am I ready for the {place} at x {x}, y {y}?', place),
    ),
    _question(
      'What should I bring to the $at?',
      tr('What should I bring to the {place} at x {x}, y {y}?', place),
    ),
  ];
}

/// Ask the companion: Claude Code on the PC answers from the live save, the game data and the web,
/// using the player's own plan (no API key). Follow-ups keep the conversation.
class AskScreen extends StatefulWidget {
  const AskScreen({super.key, required this.db, this.topic, this.prompts});
  final GameDb db;

  /// Opened from a page ("Ask about this"): what it's about, and questions to offer.
  final String? topic;
  final List<String>? prompts;

  @override
  State<AskScreen> createState() => _AskScreenState();
}

class _AskScreenState extends State<AskScreen> {
  final input = TextEditingController();
  final scroll = ScrollController();
  var _shown = '';

  static List<String> get suggestions => [
    _question('What should I do next?', tr('What should I do next?')),
    _question(
      'Where do I find Copper Ore?',
      tr('Where do I find {item}?', {'item': gt('Copper Ore')}),
    ),
    _question(
      'What is the best food for my build?',
      tr('What is the best food for my build?'),
    ),
    _question(
      'What can I craft with what I have?',
      tr('What can I craft with what I have?'),
    ),
    _question(
      'Am I ready for the Shroud in Kindlewastes?',
      tr('Am I ready for the Shroud in {region}?', {
        'region': gt('Kindlewastes'),
      }),
    ),
    _question(
      'Which skills should I take next?',
      tr('Which skills should I take next?'),
    ),
  ];

  /// The page's questions stay offered until one is asked.
  var _offer = true;

  @override
  void initState() {
    super.initState();
    input.addListener(_typed);
    askChat.addListener(_changed);
    askChat.load();
    _toEnd(jump: true);
  }

  @override
  void dispose() {
    askChat.removeListener(_changed);
    input.removeListener(_typed);
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  var _empty = true;
  void _typed() {
    if (input.text.trim().isEmpty != _empty) {
      setState(() => _empty = input.text.trim().isEmpty);
    }
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    // follow the answer as it's written, unless the player scrolled up to read
    final last = askChat.turns.isEmpty ? '' : askChat.turns.last.partial;
    if (last != _shown) {
      _shown = last;
      if (!scroll.hasClients ||
          scroll.position.maxScrollExtent - scroll.offset < 120) {
        _toEnd(jump: true);
      }
    }
  }

  /// What the phone knows that the PC doesn't: the plan.
  String? _context() {
    final goals = GoalsScope.of(context).all;
    if (goals.isEmpty) return null;
    return 'my plan: ${goals.map((g) => '${g.count} x ${widget.db.nameOf(g.itemId)}').join(', ')}';
  }

  void send(String q, {bool spoken = false}) {
    if (q.trim().isEmpty || askChat.busy) return;
    HapticFeedback.selectionClick();
    input.clear();
    _offer = false;
    Voice.stop();
    askChat.send(LiveScope.of(context), q, context: _context(), spoken: spoken);
    _toEnd();
  }

  /// Ask by voice: the phone's recognizer, then straight away; the answer is read aloud.
  Future<void> _listen() async {
    try {
      final q = await Voice.listen();
      if (q != null && q.trim().isNotEmpty && mounted) send(q, spoken: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'.replaceFirst('Bad state: ', ''))),
      );
    }
  }

  void _toEnd({bool jump = false}) =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!scroll.hasClients) return;
        final end = scroll.position.maxScrollExtent;
        if (jump) {
          scroll.jumpTo(end);
        } else {
          scroll.animateTo(
            end,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        }
      });

  @override
  Widget build(BuildContext context) {
    final turns = askChat.turns, busy = askChat.busy;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Ask')),
        actions: [
          if (turns.isNotEmpty)
            IconButton(
              tooltip: tr('New conversation'),
              icon: const Icon(Icons.add_comment_outlined),
              onPressed: busy ? null : askChat.clear,
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child:
                turns.isEmpty
                    ? ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        EmptyState(
                          icon: Icons.auto_awesome,
                          title:
                              widget.topic == null
                                  ? tr('Ask about your game')
                                  : tr('Ask about {topic}', {
                                    'topic': gt(widget.topic!),
                                  }),
                          message: tr(
                            'Claude Code on your PC answers from your latest save, the game data and the wiki. It uses your Claude plan, and your question with what it needs from your save goes to Anthropic. Tap a name in an answer to open it, plan it or find it on the map. Or tap the mic and ask out loud: the answer is read back.',
                          ),
                        ),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          alignment: WrapAlignment.center,
                          children: [
                            for (final s in widget.prompts ?? suggestions)
                              ActionChip(
                                label: Text(shownQuestion(s)),
                                onPressed: () => send(s),
                              ),
                          ],
                        ),
                      ],
                    )
                    : ListView(
                      controller: scroll,
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                      children: [
                        for (final t in turns) ...[
                          _Bubble(text: shownQuestion(t.question), mine: true),
                          if (t.answer != null)
                            _Answer(db: widget.db, text: t.answer!)
                          else if (t.error != null)
                            _Bubble(
                              text: tr('Couldn\'t answer: {error}', {
                                'error': switch (t.error) {
                                  'interrupted' => tr('interrupted'),
                                  'no answer' => tr('no answer'),
                                  final e => e,
                                },
                              }),
                              mine: false,
                              color: const Color(0xFF3A1E16),
                              action: TextButton(
                                onPressed:
                                    busy
                                        ? null
                                        : () => askChat.retry(
                                          LiveScope.of(context),
                                          t,
                                          context: _context(),
                                        ),
                                child: Text(tr('Retry')),
                              ),
                            )
                          else if (t.partial.isNotEmpty)
                            _Answer(
                              db: widget.db,
                              text: t.partial,
                              writing: true,
                            )
                          else
                            _Thinking(status: t.status),
                        ],
                      ],
                    ),
          ),
          if (turns.isNotEmpty && _offer && widget.prompts != null)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final s in widget.prompts!)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ActionChip(
                        label: Text(shownQuestion(s)),
                        onPressed: busy ? null : () => send(s),
                      ),
                    ),
                ],
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: input,
                      enabled: !busy,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: send,
                      decoration: InputDecoration(
                        hintText:
                            widget.topic != null && _offer
                                ? tr('Ask about {topic}', {
                                  'topic': gt(widget.topic!),
                                })
                                : turns.isEmpty
                                ? tr('Ask anything')
                                : tr('Ask a follow-up'),
                        prefixIcon: const Icon(
                          Icons.auto_awesome,
                          color: Palette.flame,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // the web app has no speech (it lives in the Android app's MainActivity)
                  if (_empty && !kIsWeb)
                    IconButton.filled(
                      tooltip: tr('Ask out loud'),
                      onPressed: busy ? null : _listen,
                      icon: const Icon(Icons.mic),
                    )
                  else
                    IconButton.filled(
                      tooltip: tr('Send'),
                      onPressed: busy ? null : () => send(input.text),
                      icon: const Icon(Icons.arrow_upward),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.text,
    required this.mine,
    this.color,
    this.action,
  });
  final String text;
  final bool mine;
  final Color? color;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Align(
    alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
    child: Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * 0.82,
      ),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: color ?? (mine ? const Color(0xFF4A3414) : Palette.shroud),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(mine ? 18 : 4),
          bottomRight: Radius.circular(mine ? 4 : 18),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectableText(text, style: const TextStyle(height: 1.35)),
          if (action != null) action!,
        ],
      ),
    ),
  );
}

/// A map position written in an answer ("x 123, y 456") and the place named just before it.
class _Spot {
  _Spot(this.label, this.x, this.y);
  final String label;
  final double x, y;
}

/// An answer: plain text with "- " bullets. Game names are links (open, plan, show on map) and get a
/// chip each when the answer is complete, with one for every map position it gives.
class _Answer extends StatefulWidget {
  const _Answer({required this.db, required this.text, this.writing = false});
  final GameDb db;
  final String text;

  /// Still being written: no chips yet, a small progress mark at the end.
  final bool writing;

  @override
  State<_Answer> createState() => _AnswerState();
}

class _AnswerState extends State<_Answer> {
  static final _pos = RegExp(r'x\s*(\d{1,4})\s*,\s*y\s*(\d{1,4})');
  final _taps = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _clearTaps();
    super.dispose();
  }

  void _clearTaps() {
    for (final t in _taps) {
      t.dispose();
    }
    _taps.clear();
  }

  List<_Spot> _spots(String text) => [
    for (final m in _pos.allMatches(text))
      if (double.parse(m.group(1)!) <= World.mapPx &&
          double.parse(m.group(2)!) <= World.mapPx)
        () {
          final line = text
              .substring(0, m.start)
              .split('\n')
              .last
              .replaceAll(RegExp(r'^[-•\s]+'), '');
          final label = line.split(RegExp(r'[(:,]')).first.trim();
          return _Spot(
            label.isEmpty ? tr('Place') : label,
            double.parse(m.group(1)!),
            double.parse(m.group(2)!),
          );
        }(),
  ];

  List<InlineSpan> _spans(String text, List<Mention> mentions) {
    _clearTaps();
    final out = <InlineSpan>[];
    var at = 0;
    for (final m in mentions) {
      if (m.start > at) out.add(TextSpan(text: text.substring(at, m.start)));
      final tap = TapGestureRecognizer()..onTap = () => _open(m);
      _taps.add(tap);
      out.add(
        TextSpan(
          text: text.substring(m.start, m.end),
          recognizer: tap,
          style: TextStyle(
            color: switch (m.kind) {
              MentionKind.item => Palette.flame,
              MentionKind.skill => const Color(0xFFC6A8F0),
              MentionKind.place => Palette.spring,
            },
            fontWeight: FontWeight.w600,
            decoration: TextDecoration.underline,
            decorationStyle: TextDecorationStyle.dotted,
            decorationColor: Palette.ash,
          ),
        ),
      );
      at = m.end;
    }
    if (at < text.length) out.add(TextSpan(text: text.substring(at)));
    return out;
  }

  void _open(Mention m) {
    HapticFeedback.selectionClick();
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => _MentionSheet(db: widget.db, m: m, outer: context),
    );
  }

  @override
  Widget build(BuildContext context) {
    var clean =
        widget.text
            .replaceAll('**', '')
            .replaceAll(RegExp(r'^#+\s*', multiLine: true), '')
            .trimRight();
    // "Source: Enshrouded Wiki" on its own line, set apart
    String? source;
    final cut = clean.lastIndexOf('\n');
    final lastLine = clean.substring(cut + 1).trim();
    if (!widget.writing && lastLine.startsWith('Source:')) {
      source = lastLine.substring(7).trim();
      clean = cut < 0 ? '' : clean.substring(0, cut).trimRight();
    }
    final mentions = Mentions.of(widget.db).find(clean);
    final chips = <Mention>[];
    if (!widget.writing) {
      final seen = <String>{};
      for (final m in mentions) {
        if (seen.add(m.key)) chips.add(m);
      }
    }
    // a named place with its position written next to it gets one chip, the place's own
    final named = {
      for (final m in chips)
        if (m.kind == MentionKind.place) m.name,
    };
    final spots = [
      if (!widget.writing)
        for (final s in _spots(clean))
          if (!named.any(s.label.contains)) s,
    ];
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.9,
        ),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: const BoxDecoration(
          color: Palette.shroud,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(18),
            bottomRight: Radius.circular(18),
            bottomLeft: Radius.circular(4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectionArea(
              child: Text.rich(
                TextSpan(children: _spans(clean, mentions)),
                style: const TextStyle(height: 1.4),
              ),
            ),
            if (widget.writing)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                ),
              ),
            if (spots.isNotEmpty || chips.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final s in spots.take(6))
                    ActionChip(
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      avatar: const Icon(
                        Icons.place,
                        size: 16,
                        color: Palette.spring,
                      ),
                      label: Text(_short(s.label)),
                      onPressed:
                          () =>
                              mapFocus.value = Poi({
                                'c': 'spot',
                                'k': tr('From the companion'),
                                't': s.label,
                                'x': s.x,
                                'y': s.y,
                              }),
                    ),
                  for (final m in chips.take(8))
                    ActionChip(
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      avatar: Icon(
                        _icon(m.kind),
                        size: 16,
                        color: _tint(m.kind),
                      ),
                      label: Text(_short(gt(m.name))),
                      onPressed: () => _open(m),
                    ),
                ],
              ),
            ],
            // where it came from, and read aloud
            if (!widget.writing)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    if (source != null) ...[
                      const Icon(Icons.public, size: 14, color: Palette.ash),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          source,
                          style: const TextStyle(
                            color: Palette.ash,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ] else
                      const Spacer(),
                    if (!kIsWeb)
                      ValueListenableBuilder<String?>(
                        valueListenable: Voice.speaking,
                        builder: (context, now, _) {
                          final on = now == widget.text;
                          return IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: on ? tr('Stop reading') : tr('Read aloud'),
                            icon: Icon(
                              on
                                  ? Icons.stop_circle_outlined
                                  : Icons.volume_up_outlined,
                              size: 20,
                              color: on ? Palette.flame : Palette.ash,
                            ),
                            onPressed:
                                () =>
                                    on
                                        ? Voice.stop()
                                        : Voice.speak(widget.text),
                          );
                        },
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

String _short(String s) => s.length > 28 ? '${s.substring(0, 28)}…' : s;

IconData _icon(MentionKind k) => switch (k) {
  MentionKind.item => Icons.inventory_2_outlined,
  MentionKind.skill => Icons.auto_awesome,
  MentionKind.place => Icons.place_outlined,
};

Color _tint(MentionKind k) => switch (k) {
  MentionKind.item => Palette.flame,
  MentionKind.skill => const Color(0xFFC6A8F0),
  MentionKind.place => Palette.spring,
};

/// What can be done with a name from an answer: open it, add it to the plan, find it on the map.
class _MentionSheet extends StatelessWidget {
  const _MentionSheet({required this.db, required this.m, required this.outer});
  final GameDb db;
  final Mention m;

  /// The Ask screen's context, for what happens after the sheet closes.
  final BuildContext outer;

  void _then(BuildContext context, void Function() action) {
    Navigator.pop(context);
    action();
  }

  @override
  Widget build(BuildContext context) {
    final s = LiveScope.of(context).state;
    final text = Theme.of(context).textTheme;
    final (subtitle, detail, actions) = switch (m.kind) {
      MentionKind.item => _item(context, s),
      MentionKind.skill => _skill(context, s),
      MentionKind.place => _place(context, s),
    };
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (m.kind == MentionKind.item && m.item != null)
                  ItemIcon(m.item, size: 44)
                else
                  Icon(_icon(m.kind), color: _tint(m.kind)),
                const SizedBox(width: 10),
                Expanded(child: Text(gt(m.name), style: text.titleLarge)),
              ],
            ),
            if (subtitle.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  subtitle,
                  style: const TextStyle(color: Palette.ash),
                ),
              ),
            if (detail != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(detail, style: const TextStyle(height: 1.4)),
              ),
            const SizedBox(height: 16),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
        ),
      ),
    );
  }

  (String, String?, List<Widget>) _item(BuildContext context, LiveState? s) {
    final it = m.item!;
    final have = s?.owned(it.id) ?? 0;
    final where = s?.whereIs(it.id, db.nameOf) ?? const <StoredIn>[];
    final detail =
        s == null
            ? null
            : have == 0
            ? tr('You have none.')
            : tr('You have {n}: {where}', {
              'n': have,
              'where': where
                  .take(3)
                  .map(
                    (w) =>
                        '${w.base != null ? '${w.base}, ' : ''}${shownLabel(w.label)} ${w.count}',
                  )
                  .join(' · '),
            });
    final findable =
        db.gather.containsKey(it.id) ||
        it.fixedPlacements > 0 ||
        it.chestKinds.isNotEmpty;
    return (
      [
        categoryLabel(it.category),
        if (it.rarity.isNotEmpty) gt(it.rarity),
      ].join(' · '),
      detail,
      [
        FilledButton.tonalIcon(
          icon: const Icon(Icons.menu_book_outlined),
          label: Text(tr('Open')),
          onPressed:
              () => _then(
                context,
                () => Navigator.push(
                  outer,
                  MaterialPageRoute(
                    builder: (_) => ItemScreen(db: db, item: it),
                  ),
                ),
              ),
        ),
        FilledButton.tonalIcon(
          icon: const Icon(Icons.playlist_add),
          label: Text(tr('Add to plan')),
          onPressed: () => _then(context, () => addGoal(outer, it, 1)),
        ),
        if (findable)
          FilledButton.tonalIcon(
            icon: const Icon(Icons.map_outlined),
            label: Text(tr('Show on map')),
            onPressed:
                () => _then(context, () async {
                  final here = LiveScope.of(context).pos.value;
                  final terrain = await Terrain.instance;
                  final w = WhereToGet(db, s, terrain, here: here);
                  final best = w.best(it.id, count: 1);
                  if (best.isNotEmpty) {
                    mapFocus.value = w.asPoi(it.id, best.first);
                  }
                }),
          ),
      ],
    );
  }

  (String, String?, List<Widget>) _skill(BuildContext context, LiveState? s) {
    final k = m.skill!;
    final rank = s?.skills[k.id];
    return (
      [
        gt(k.archetype),
        if (k.cls != 'Neutral') classLabel(k.cls),
        trn(k.cost, '{n} point per rank', '{n} points per rank'),
        if (s != null)
          rank == null
              ? tr('not learned')
              : tr('rank {rank} of {max}', {'rank': rank, 'max': k.maxLevel}),
      ].join(' · '),
      gtn(k.description),
      [
        FilledButton.tonalIcon(
          icon: const Icon(Icons.account_tree_outlined),
          label: Text(tr('Open in skill tree')),
          onPressed:
              () => _then(
                context,
                () => Navigator.push(
                  outer,
                  MaterialPageRoute(
                    builder: (_) => SkillTreeScreen(db: db, focus: k),
                  ),
                ),
              ),
        ),
      ],
    );
  }

  (String, String?, List<Widget>) _place(BuildContext context, LiveState? s) {
    final p = m.place!;
    final region = db.regionAt(p.x, p.y);
    final done = s == null ? null : db.poiDone(p, s.knowledge);
    return (
      [
        if (p.kind != null) gt(p.kind!),
        if (region != null) gt(region),
        if (done == true) tr('done'),
      ].join(' · '),
      null,
      [
        FilledButton.tonalIcon(
          icon: const Icon(Icons.map_outlined),
          label: Text(tr('Show on map')),
          onPressed: () => _then(context, () => mapFocus.value = p),
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.near_me),
          label: Text(tr('Navigate')),
          onPressed:
              () => _then(context, () {
                navTarget.value = NavTarget.poi(p);
                mapFocus.value = p;
              }),
        ),
      ],
    );
  }
}

class _Thinking extends StatelessWidget {
  const _Thinking({this.status});
  final String? status;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
      decoration: BoxDecoration(
        color: Palette.shroud,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Text(
              switch (status) {
                null => tr('Thinking…'),
                'Sending' => tr('Sending…'),
                final s => '$s…',
              },
              key: ValueKey(status),
              style: const TextStyle(color: Palette.ash),
            ),
          ),
        ],
      ),
    ),
  );
}
