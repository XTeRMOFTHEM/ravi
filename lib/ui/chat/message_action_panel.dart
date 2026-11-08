import 'dart:math' as math;
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../core/api_service.dart';
import '../../core/app_state.dart';
import '../../core/constants.dart';
import '../../core/models.dart';
import '../widgets/ravi_alerts.dart';

/// v1.0.7 — Telegram-style floating action panel, anchored to the pressed
/// bubble: glass reaction strip on top + VERTICAL action items underneath
/// (Reply / Edit / Copy / Forward / Save GIF / Delete).
///
/// v1.0.7 fixes:
///  • the rows used a bare InkWell inside the ROOT overlay — no Material
///    ancestor → exception → transparent ErrorWidget → the menu items were
///    INVISIBLE. Everything now lives inside Material(transparency).
///  • the old gray/yellow divider lines are gone — clean glass spacing.
///  • opens right next to the tapped message and stays glassy enough for the
///    blurred wallpaper to read through.
class MessageActionPanel {
  MessageActionPanel._();

  static const List<String> reactions = [
    '👍', '❤️', '😂', '😮', '😢', '🙏', '🔥', '🎉'
  ];

  // v1.0.8 — single-entry registry so long-pressing the SAME message again
  // CLOSES the panel (toggle), and long-pressing another message replaces it.
  static OverlayEntry? _current;
  static _PanelEntry? _currentAnim;
  static int? _currentMsgId;
  static bool Function()? _closingGuard;

  /// Returns true when a panel was open and got closed (toggle consumed).
  static bool toggleFor(int msgId) {
    if (_current != null && _currentMsgId == msgId) {
      closeCurrent();
      return true;
    }
    if (_current != null) closeCurrent(); // replace, not stack
    return false;
  }

  static void closeCurrent() {
    final e = _current;
    _current = null;
    _currentAnim = null;
    _currentMsgId = null;
    try {
      e?.remove();
    } catch (_) {}
  }

  static void show(
    BuildContext context, {
    required Message msg,
    required Rect anchorRect, // bubble rect (global coords)
    required VoidCallback onReply,
    required VoidCallback onCopy,
    VoidCallback? onEdit,
    VoidCallback? onSaveGif,
    VoidCallback? onForward,
    VoidCallback? onDelete,
    VoidCallback? onSelect,
    VoidCallback? onPin,
    required ValueChanged<String> onReact,
  }) {
    HapticFeedback.mediumImpact();
    // v1.0.8: any open panel is replaced cleanly (no stacking).
    closeCurrent();
    final overlay = Overlay.of(context, rootOverlay: true);
    late final OverlayEntry entry;
    final anim = _PanelEntry();
    final me = AppState.I.me.value.username;

    entry = OverlayEntry(
      builder: (ctx) {
      final dark = Theme.of(context).brightness == Brightness.dark;
      final s = AppState.I.str;
      final size = MediaQuery.of(context).size;
      const panelWidth = 218.0;
      // vertical placement: prefer above the bubble, else below
      final itemCount = 3 + (onEdit != null ? 1 : 0) + (onForward != null ? 1 : 0) + (onSaveGif != null ? 1 : 0) + (onPin != null ? 1 : 0) + (onDelete != null ? 1 : 0);
      final panelHeight = 62 + itemCount * 42.0;
      final top = anchorRect.top - panelHeight - 10 > MediaQuery.of(context).padding.top
          ? anchorRect.top - panelHeight - 8
          : math.min(anchorRect.bottom + 8, size.height - panelHeight - 20);
      // horizontal: clamp inside the screen, align toward the bubble side
      final isOwn = msg.isMe;
      double left = isOwn
          ? anchorRect.right - panelWidth
          : anchorRect.left;
      left = left.clamp(12.0, size.width - panelWidth - 12);

      final items = <_PanelItem>[
        _PanelItem(Icons.reply_rounded, s.reply, const Color(0xFF8B5CF6), onReply),
        if (onEdit != null)
          _PanelItem(Icons.edit_rounded, s.edit, const Color(0xFF38BDF8), onEdit!),
        if (msg.text.isNotEmpty)
          _PanelItem(Icons.copy_rounded, s.copy, dark ? Colors.white : const Color(0xFF334155), onCopy),
        if (onForward != null)
          _PanelItem(Icons.shortcut_rounded, s.forward, const Color(0xFF38BDF8), onForward!),
        // v1.1.0 — Telegram-style pin
        if (onPin != null)
          _PanelItem(Icons.push_pin_rounded, s.pinMessage, const Color(0xFFF59E0B), onPin!),
        if (onSaveGif != null)
          _PanelItem(Icons.save_alt_rounded, s.saveGif, const Color(0xFF38BDF8), onSaveGif!),
        // v1.0.9 — multi-select entry point (Telegram)
        if (onSelect != null)
          _PanelItem(Icons.checklist_rounded, s.selectMessages, const Color(0xFF22C55E), onSelect!),
        if (onDelete != null)
          _PanelItem(Icons.delete_outline_rounded, s.delete, const Color(0xFFEF4444), onDelete!),
      ];

      return AnimatedBuilder(
        animation: anim.c,
        builder: (context, _) {
          final t = Curves.easeOutCubic.transform(anim.c.value.clamp(0.0, 1.0));
          return Stack(children: [
            // dim + tap-away
            Positioned.fill(
              child: GestureDetector(
                onTap: () => _close(entry),
                behavior: HitTestBehavior.opaque,
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: .28 * t),
                ),
              ),
            ),
            Positioned(
              top: top.clamp(40.0, size.height - 120),
              left: left,
              child: IgnorePointer(
                ignoring: t < 0.9,
                child: Transform.translate(
                  offset: Offset(0, 14 * (1 - t)),
          child: Opacity(
                    opacity: t,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
                        child: Material(
                          type: MaterialType.transparency,
                          child: Container(
                            width: panelWidth,
                            padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
                            decoration: BoxDecoration(
                              color: dark
                                  ? const Color(0xD9151B23)
                                  : const Color(0xE8FFFFFF),
                              borderRadius: BorderRadius.circular(22),
                              border: Border.all(
                                color: dark
                                    ? Colors.white.withValues(alpha: .12)
                                    : Colors.white.withValues(alpha: .55),
                              ),
                              boxShadow: const [
                                BoxShadow(
                                    color: Color(0x52000000),
                                    blurRadius: 34,
                                    offset: Offset(0, 16)),
                              ],
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // ---- reaction strip ----
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    for (var i = 0; i < reactions.length; i++)
                                      _ReactionBtn(
                                        emoji: reactions[i],
                                        mine: msg.reactions.any((r) =>
                                            r.emoji == reactions[i] &&
                                            r.usernames.contains(me)),
                                        delay: i * 26,
                                        anim: anim,
                                        onTap: () {
                                          _close(entry);
                                          onReact(reactions[i]);
                                        },
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 7),
                                // ---- vertical items ----
                                for (final it in items)
                                  _PanelRow(
                                    item: it,
                                    dark: dark,
                                    anim: anim,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ]);
        },
      );
    });
    // v1.0.8 — register AFTER the entry object exists.
    _current = entry;
    _currentAnim = anim;
    _currentMsgId = msg.id;
    overlay.insert(entry);
    anim.forward();
  }

  static void _close(OverlayEntry entry) {
    if (_current == entry) {
      _current = null;
      _currentAnim = null;
      _currentMsgId = null;
    }
    try {
      entry.remove();
    } catch (_) {}
  }
}

class _PanelItem {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _PanelItem(this.icon, this.label, this.color, this.onTap);
}

class _PanelEntry {
  late final AnimationController c = AnimationController(
      vsync: _Ticker(), duration: const Duration(milliseconds: 250));
  void forward() => c.forward();
}

class _Ticker extends TickerProvider {
  @override
  Ticker createTicker(TickerCallback onTick) => Ticker(onTick);
}

class _ReactionBtn extends StatelessWidget {
  final String emoji;
  final bool mine;
  final int delay; // ms — staggered pop-in
  final _PanelEntry anim;
  final VoidCallback onTap;

  const _ReactionBtn({
    required this.emoji,
    required this.mine,
    required this.delay,
    required this.anim,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedBuilder(
        animation: anim.c,
        builder: (context, child) {
          // staggered elastic pop-in
          final raw = (anim.c.value - delay / 1000 * 0.8).clamp(0.0, 1.0);
          final t = Curves.elasticOut.transform(raw);
          return Transform.scale(
            scale: 0.3 + 0.7 * t,
            child: Opacity(
              opacity: raw.clamp(0.0, 1.0),
              child: child,
            ),
          );
        },
        child: Container(
          padding: const EdgeInsets.all(3.5),
          decoration: BoxDecoration(
            color: mine
                ? const Color(0xFF8B5CF6).withValues(alpha: .2)
                : Colors.transparent,
            shape: BoxShape.circle,
          ),
          child: Text(emoji,
              style: TextStyle(
                  fontSize: mine ? 26 : 24,
                  height: 1,
                  shadows: mine
                      ? [Shadow(color: const Color(0x668B5CF6), blurRadius: 12)]
                      : null)),
        ),
      ),
    );
  }
}

class _PanelRow extends StatelessWidget {
  final _PanelItem item;
  final bool dark;
  final _PanelEntry anim;
  const _PanelRow({required this.item, required this.dark, required this.anim});

  @override
  Widget build(BuildContext context) {
    // v1.0.9 — any action CLOSES the panel (Telegram behaviour): the user
    // complained "after e.g. copy the panel must close, it's infuriating".
    return InkWell(
      onTap: () {
        MessageActionPanel.closeCurrent();
        item.onTap();
      },
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 10.5),
        child: Row(children: [
          Icon(item.icon, size: 17, color: item.color),
          const SizedBox(width: 11),
          Text(item.label,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: item.color)),
        ]),
      ),
    );
  }
}

/// v1.0.7 — reaction chips under a bubble: mini AVATAR STACK of the first
/// two reactors + emoji + count.
/// v1.0.9 — `hideAvatars` (CHANNELS): Telegram channels show only the number
/// next to the emoji — no mini profile stack.
class ReactionChips extends StatelessWidget {
  final List<ReactionSummary> reactions;
  final ValueChanged<String> onTap;
  final bool hideAvatars;

  const ReactionChips({
    super.key,
    required this.reactions,
    required this.onTap,
    this.hideAvatars = false,
  });

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty) return const SizedBox.shrink();
    final me = AppState.I.me.value.username;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 5,
        runSpacing: 4,
        children: [
          for (final r in reactions)
            GestureDetector(
              onTap: () => onTap(r.emoji),
              child: _PopChip(
                key: ValueKey('rx-${r.emoji}-${r.count}'),
                mine: r.usernames.contains(me),
                reaction: r,
                hideAvatars: hideAvatars,
                onTap: () => onTap(r.emoji),
              ),
            ),
        ],
      ),
    );
  }
}

class _PopChip extends StatefulWidget {
  final bool mine;
  final ReactionSummary reaction;
  final bool hideAvatars;
  final VoidCallback onTap;
  const _PopChip({
    super.key,
    required this.mine,
    required this.reaction,
    this.hideAvatars = false,
    required this.onTap,
  });

  @override
  State<_PopChip> createState() => _PopChipState();
}

class _PopChipState extends State<_PopChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 340));

  @override
  void initState() {
    super.initState();
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Widget _miniAvatar(ReactionUser u) {
    final url = ApiService.I.avatarUrl(u.avatar);
    return Container(
      width: 15,
      height: 15,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF7C5CE0),
        border: Border.all(
          color: widget.mine
              ? const Color(0xFF8B5CF6)
              : (Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xFF2A313A)
                  : Colors.white),
          width: 1.1,
        ),
      ),
      child: ClipOval(
        child: url.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                memCacheWidth: 40,
                httpHeaders: {'Cookie': ApiService.I.cookieHeader},
                errorWidget: (_, __, ___) => Center(
                  child: Text(
                    u.username.isNotEmpty ? u.username[0].toUpperCase() : '?',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 7.5,
                        fontWeight: FontWeight.w800,
                        height: 1),
                  ),
                ),
              )
            : Center(
                child: Text(
                  u.username.isNotEmpty ? u.username[0].toUpperCase() : '?',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 7.5,
                      fontWeight: FontWeight.w800,
                      height: 1),
                ),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final r = widget.reaction;
    final avatars = r.reactors.take(2).toList();
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        // elastic bounce on (re)entry — fires when the count changes too,
        // because the widget is re-keyed by the parent.
        final t = Curves.elasticOut.transform(_c.value);
        return Transform.scale(scale: 0.7 + 0.3 * t, child: child);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
        decoration: BoxDecoration(
          color: widget.mine
              ? const Color(0xFF8B5CF6).withValues(alpha: .22)
              : (dark
                  ? Colors.white.withValues(alpha: .09)
                  : Colors.black.withValues(alpha: .05)),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: widget.mine
                ? const Color(0xFF8B5CF6)
                : Colors.transparent,
            width: 1.2,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // avatar stack: first two reactors (HIDDEN in channels — Telegram
            // channels show the emoji + count only)
            if (!widget.hideAvatars && avatars.isNotEmpty)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 3),
                child: SizedBox(
                  width: avatars.length == 1 ? 15 : 25,
                  height: 15,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      PositionedDirectional(
                        start: 0,
                        child: _miniAvatar(avatars[0]),
                      ),
                      if (avatars.length > 1)
                        PositionedDirectional(
                          start: 10,
                          child: _miniAvatar(avatars[1]),
                        ),
                    ],
                  ),
                ),
              ),
            Text(r.emoji, style: const TextStyle(fontSize: 12.5, height: 1)),
            const SizedBox(width: 3),
            Text('${r.count}',
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    color: widget.mine
                        ? const Color(0xFF8B5CF6)
                        : (dark ? C.text2D : C.text2L))),
          ],
        ),
      ),
    );
  }
}

/// Animated pending clock (Telegram-like sweeping timer) for optimistic
/// messages; failed shows a red warning.
class PendingClock extends StatefulWidget {
  final bool failed;
  const PendingClock({super.key, required this.failed});

  @override
  State<PendingClock> createState() => _PendingClockState();
}

class _PendingClockState extends State<PendingClock>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1600))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.failed) {
      return const Icon(Icons.error_outline_rounded,
          size: 12, color: Color(0xFFFFB4AB));
    }
    return SizedBox(
      width: 12, height: 12,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => CustomPaint(
          painter: _ClockPainter(progress: _c.value),
        ),
      ),
    );
  }
}

class _ClockPainter extends CustomPainter {
  final double progress;
  _ClockPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final c = Offset(s / 2, s / 2);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.11
      ..color = Colors.white.withValues(alpha: .55)
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(c, s * 0.4, stroke);
    // sweeping hand
    final a = -math.pi / 2 + 2 * math.pi * progress;
    final hand = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.12
      ..color = Colors.white.withValues(alpha: .9)
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
        c, Offset(c.dx + s * 0.28 * math.cos(a), c.dy + s * 0.28 * math.sin(a)), hand);
  }

  @override
  bool shouldRepaint(covariant _ClockPainter old) => old.progress != progress;
}
