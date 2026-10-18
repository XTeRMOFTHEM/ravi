import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// v1.0.9 — Swipe-to-reply, THIRD and final pass. Root causes of the
/// "message jumps somewhere and gets stuck" bug found & killed:
///
///  1. easeOutBack OVERSHOOT: the settle curve reaches t≈1.1, so
///     `dx = _dx * (1 - t)` went NEGATIVE and the row visibly flung to the
///     opposite side ("پیام می‌پره"). → replaced with easeOutCubic (0→1,
///     monotonic, never overshoots).
///  2. Transform.scale with a dynamic alignment flipped mid-drag → tiny
///     visual teleport. → scale is GONE, only translate remains.
///  3. Raw Listener v1.0.7 fought the scroll arena (jam). GestureDetector
///     v1.0.8 was better but only caught the bubble (deferToChild), so a
///     swipe starting on the padding/avatar did nothing and felt "stuck".
///     → HitTestBehavior.translucent + full-row usage from the chat screen.
///
/// Extra Telegram-feel: rubber-band follow, rotating arrow with armed color
/// flip, haptics on arm/fire, velocity-aware flick, always settles home.
class SwipeToReply extends StatefulWidget {
  final Widget child;
  final VoidCallback onSwipeReply;
  final bool enabled;

  const SwipeToReply({
    super.key,
    required this.child,
    required this.onSwipeReply,
    this.enabled = true,
  });

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply>
    with SingleTickerProviderStateMixin {
  late final AnimationController _settle = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 300));

  double _dx = 0; // current painted offset
  double _dragDx = 0; // accumulated raw drag
  bool _armed = false;

  static const double _threshold = 58;

  bool _animating = false;

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  void _onDragStart(DragStartDetails d) {
    _settle.stop();
    _animating = false;
    _dx = 0;
    _dragDx = 0;
    _armed = false;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    _dragDx += d.delta.dx;
    final target = _dragDx * 0.55;
    _dx = _rubberBand(target, 92);
    final crossed = _dx.abs() > _threshold;
    if (crossed != _armed) {
      _armed = crossed;
      crossed ? HapticFeedback.mediumImpact() : HapticFeedback.selectionClick();
    }
    setState(() {});
  }

  static double _rubberBand(double x, double softCap) {
    final sign = x.sign;
    final v = x.abs();
    if (v <= softCap) return x;
    return sign * (softCap + (v - softCap) * 0.15);
  }

  void _onDragEnd(DragEndDetails d) {
    final velocity = d.velocity.pixelsPerSecond.dx;
    final flick = velocity.abs() > 850 && _dx.abs() > _threshold * .5;
    final fire = _armed || flick;
    _armed = false;
    _settleTo(fire);
    if (fire) {
      HapticFeedback.lightImpact();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onSwipeReply();
      });
    }
  }

  void _onDragCancel() {
    _armed = false;
    _settleTo(false);
  }

  /// Always animates the painted offset to exactly 0 with a monotonic curve.
  void _settleTo(bool fire) {
    setState(() => _animating = true);
    _settle.forward(from: 0).whenComplete(() {
      if (!mounted) return;
      setState(() {
        _dx = 0;
        _dragDx = 0;
        _animating = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    return GestureDetector(
      // translucent: taps/clicks fall through to the bubble, but the drag
      // starts ANYWHERE on the row (bubble, avatar, empty padding) — Telegram.
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: _onDragStart,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      onHorizontalDragCancel: _onDragCancel,
      child: AnimatedBuilder(
        animation: _settle,
        builder: (context, child) {
          double dx = _dx;
          if (_animating) {
            // monotonic 1→0, NEVER overshoots below zero (the old jump bug)
            final t = Curves.easeOutCubic.transform(_settle.value);
            dx = _dx * (1 - t);
          }
          final reveal = (dx.abs() / _threshold).clamp(0.0, 1.0);
          final rtl = Directionality.of(context) == TextDirection.rtl;
          final revealAtEnd = (dx < 0) != rtl;
          return Stack(
            children: [
              Positioned.fill(
                child: Align(
                  alignment: revealAtEnd
                      ? AlignmentDirectional.centerEnd
                      : AlignmentDirectional.centerStart,
                  child: Opacity(
                    opacity: reveal.clamp(0.0, 1.0),
                    child: Transform.rotate(
                      angle: (0.55 - 0.35 * reveal) *
                          (revealAtEnd ? -1 : 1) *
                          reveal,
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 10),
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: const Color(0xFF8B5CF6)
                              .withValues(alpha: .14 + .16 * reveal),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.reply_rounded,
                          size: 19,
                          color: _armed
                              ? const Color(0xFF8B5CF6)
                              : const Color(0xFF9F7BF5),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Transform.translate(
                offset: Offset(dx, 0),
                child: child,
              ),
            ],
          );
        },
        child: widget.child,
      ),
    );
  }
}

/// Tiny helper used by the composer's voice recorder progress arc.
class RecordArcPainter extends CustomPainter {
  final double progress;
  RecordArcPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 2;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFFEF4444);
    canvas.drawArc(Rect.fromCircle(center: c, radius: r),
        -math.pi / 2, 2 * math.pi * progress.clamp(0, 1), false, paint);
  }

  @override
  bool shouldRepaint(covariant RecordArcPainter old) => old.progress != progress;
}
