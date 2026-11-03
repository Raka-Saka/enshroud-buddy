import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/live_state.dart';
import '../theme.dart';

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 20, 16, 6),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text.toUpperCase(),
            style: const TextStyle(
              fontFamily: 'Cinzel',
              fontSize: 12.5,
              letterSpacing: 1.4,
              color: Palette.flame,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    ),
  );
}

class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.color = Palette.ash, this.icon});
  final String text;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withValues(alpha: 0.45)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
        ],
        Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

/// A dashboard card: header (icon, title, optional action), then content.
class DashCard extends StatelessWidget {
  const DashCard({
    super.key,
    required this.title,
    required this.child,
    this.icon,
    this.color = Palette.flame,
    this.action,
    this.onAction,
  });
  final String title;
  final IconData? icon;
  final Color color;
  final String? action;
  final VoidCallback? onAction;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 20, color: color),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontFamily: 'Cinzel',
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (action != null)
                TextButton(
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    onAction?.call();
                  },
                  child: Text(action!),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Padding(padding: const EdgeInsets.only(right: 8), child: child),
        ],
      ),
    ),
  );
}

/// A glanceable number: big value, small label.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.value,
    required this.label,
    this.icon,
    this.color = Palette.flame,
    this.onTap,
  });
  final String value, label;
  final IconData? icon;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Palette.shroudHigh,
    borderRadius: BorderRadius.circular(Radii.tile),
    child: InkWell(
      borderRadius: BorderRadius.circular(Radii.tile),
      onTap:
          onTap == null
              ? null
              : () {
                HapticFeedback.selectionClick();
                onTap!();
              },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) Icon(icon, size: 18, color: color),
            const SizedBox(height: 4),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Palette.ash, fontSize: 11.5),
            ),
          ],
        ),
      ),
    ),
  );
}

/// A labelled progress bar with "done / total".
class ProgressLine extends StatelessWidget {
  const ProgressLine({
    super.key,
    required this.label,
    required this.done,
    required this.total,
    this.icon,
    this.onTap,
  });
  final String label;
  final int done, total;
  final IconData? icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(Radii.tile),
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: Palette.veil),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(label)),
                    Text(
                      '$done / $total',
                      style: const TextStyle(color: Palette.ash, fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: total == 0 ? 0 : done / total,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(3),
                ),
              ],
            ),
          ),
          if (onTap != null)
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Icon(Icons.chevron_right, size: 18, color: Palette.ash),
            ),
        ],
      ),
    ),
  );
}

/// Nothing here yet: an icon, a line of why, and what to do.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actions = const [],
  });
  final IconData icon;
  final String title;
  final String? message;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 40, color: Palette.flame.withValues(alpha: 0.8)),
        const SizedBox(height: 10),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        ),
        if (message != null) ...[
          const SizedBox(height: 4),
          Text(
            message!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Palette.ash),
          ),
        ],
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: actions,
          ),
        ],
      ],
    ),
  );
}

/// Connection to the PC agent: live, offline with the last state, or waiting.
class LiveBadge extends StatelessWidget {
  const LiveBadge({super.key, required this.live});
  final Live live;

  static String ago(DateTime? t) {
    if (t == null) return 'never';
    final d = DateTime.now().difference(t);
    return d.inMinutes < 1
        ? 'just now'
        : d.inHours < 1
        ? '${d.inMinutes} min ago'
        : d.inDays < 1
        ? '${d.inHours} h ago'
        : '${d.inDays} d ago';
  }

  @override
  Widget build(BuildContext context) {
    final s = live.state;
    final ok = live.error == null && s != null;
    final color =
        ok ? Palette.spring : (s == null ? Palette.ash : Palette.amber);
    final text =
        s == null
            ? (live.loading ? 'Connecting…' : 'No data from the PC agent')
            : '${ok ? 'Live' : 'Offline'} · saved ${ago(s.savedAt)}';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color, fontSize: 12.5),
          ),
        ),
      ],
    );
  }
}

/// Lore text on parchment.
class Parchment extends StatelessWidget {
  const Parchment({super.key, this.title, required this.text});
  final String? title;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: Palette.parchment,
      borderRadius: BorderRadius.circular(Radii.tile),
      boxShadow: const [
        BoxShadow(color: Colors.black54, blurRadius: 10, offset: Offset(0, 4)),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              title!,
              style: const TextStyle(
                fontFamily: 'Cinzel',
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Palette.ink,
              ),
            ),
          ),
        Text(
          text,
          style: const TextStyle(
            color: Palette.ink,
            fontSize: 15,
            height: 1.5,
            fontStyle: FontStyle.italic,
          ),
        ),
      ],
    ),
  );
}
