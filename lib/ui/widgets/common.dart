import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../core/api_service.dart';
import '../../core/app_state.dart';
import '../../core/constants.dart';
import 'premium_logo.dart';

/// v1.1.0 — first-strong bidi detection (Telegram behaviour): a paragraph
/// follows the first strong directional character. Fixes Persian text with a
/// trailing emoji / English word rendering on the wrong side.
TextDirection bidiDirectionOf(String text, {TextDirection? fallback}) {
  for (final r in text.runes) {
    // Hebrew + Arabic (incl. supplements & presentation forms)
    if ((r >= 0x0590 && r <= 0x08FF) ||
        (r >= 0xFB1D && r <= 0xFDFD) ||
        (r >= 0xFE70 && r <= 0xFEFC)) {
      return TextDirection.rtl;
    }
    // Latin / Latin-1 letters / Latin extended
    if ((r >= 0x0041 && r <= 0x005A) ||
        (r >= 0x0061 && r <= 0x007A) ||
        (r >= 0x00C0 && r <= 0x024F)) {
      return TextDirection.ltr;
    }
  }
  return fallback ?? TextDirection.ltr;
}

/// v1.0.8 — avatar with the animated Pro frame, EXACTLY like index.html:
/// the frame PNG is painted at **200% of the avatar size** centered on it
/// (.pp-frame{width:200%;height:200%;transform:translate(-50%,-50%)}),
/// with a blurred glowing copy behind (.pp-frame-glow).
///
/// v1.0.8 THE REAL FIX: a Stack hands its children LOOSENED versions of its
/// own tight constraints — the old 2× SizedBox was silently clamped back to
/// 1× avatar size, so the frame artwork (which keeps transparent padding in
/// the outer ~21% of the image) collapsed INSIDE the photo and looked like a
/// misplaced blob. OverflowBox lets the frame paint its true 2× box while
/// the layout footprint stays exactly `size × size`.
class FrameAvatar extends StatelessWidget {
  final String avatarPath; // avatar file (may be empty → gradient initial)
  final String frameUrl; // /static/frames/frame_x.png ('' → no frame)
  final String name; // for gradient + initial
  final double size; // avatar diameter
  final bool glow;

  const FrameAvatar({
    super.key,
    required this.name,
    this.avatarPath = '',
    this.frameUrl = '',
    this.size = 120,
    this.glow = true,
  });

  bool get _hasFrame =>
      frameUrl.isNotEmpty && frameUrl != 'None' && frameUrl != 'null';

  @override
  Widget build(BuildContext context) {
    final hasImg = avatarPath.isNotEmpty &&
        !avatarPath.contains('default.png') &&
        avatarPath != 'None';

    final avatar = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF2A3240),
        border: Border.all(
          color: Theme.of(context).scaffoldBackgroundColor,
          width: size > 60 ? 3 : 2,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0x2414283C),
            blurRadius: size * .12,
            offset: Offset(0, size * .05),
          ),
        ],
      ),
      child: ClipOval(
        child: hasImg
            ? CachedNetworkImage(
                imageUrl: ApiService.I.avatarUrl(avatarPath),
                fit: BoxFit.cover,
                memCacheWidth: (size * 2).toInt(),
                httpHeaders: {'Cookie': ApiService.I.cookieHeader},
                errorWidget: (_, __, ___) => _letter(),
              )
            : _letter(),
      ),
    );

    if (!_hasFrame) {
      return SizedBox(width: size, height: size, child: avatar);
    }

    final frame = ApiService.I.absoluteUrl(frameUrl);
    // 200% of the avatar — the web contract (.pp-frame width:200%).
    final frameSize = size * 2;

    Widget framedImage({required bool blur}) {
      final img = SizedBox(
        width: frameSize,
        height: frameSize,
        child: CachedNetworkImage(
          imageUrl: frame,
          fit: BoxFit.contain,
          memCacheWidth: (frameSize * 1.4).toInt(),
          httpHeaders: {'Cookie': ApiService.I.cookieHeader},
          fadeInDuration: const Duration(milliseconds: 160),
          errorWidget: (_, __, ___) => const SizedBox.shrink(),
        ),
      );
      if (!blur) return img;
      return ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: 7, sigmaY: 7),
        child: Opacity(opacity: .5, child: img),
      );
    }

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          avatar,
          // glow copy behind (pp-frame-glow) — 2× and truly unclamped
          if (glow)
            IgnorePointer(
              child: OverflowBox(
                minWidth: 0, maxWidth: frameSize,
                minHeight: 0, maxHeight: frameSize,
                alignment: Alignment.center,
                child: framedImage(blur: true),
              ),
            ),
          // crisp frame on top — 2× and truly unclamped
          IgnorePointer(
            child: OverflowBox(
              minWidth: 0, maxWidth: frameSize,
              minHeight: 0, maxHeight: frameSize,
              alignment: Alignment.center,
              child: framedImage(blur: false),
            ),
          ),
        ],
      ),
    );
  }

  Widget _letter() {
    final n = name.trim();
    final initial = n.isEmpty
        ? 'R'
        : String.fromCharCode(n.runes.first).toUpperCase();
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: C.crAvatarGrad,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(initial,
            style: TextStyle(
              color: Colors.white,
              fontSize: size * .38,
              fontWeight: FontWeight.w800,
              height: 1,
            )),
      ),
    );
  }
}

/// Circle avatar with the web app's gradient palette (a1..a4 by name hash)
/// or the server image when available. Repaint-friendly: pure decoration.
class RaviAvatar extends StatelessWidget {
  final String avatarPath;
  final String name;
  final double size;
  final bool globe;
  final bool chatHeader;
  // v1.4.0 — سیو مسیج: بوکمارک طلایی به‌جای آواتار (مثل تلگرام)
  final bool bookmark;

  static final Map<String, int> _hashCache = {};

  const RaviAvatar({
    super.key,
    required this.name,
    this.avatarPath = '',
    this.size = 57,
    this.globe = false,
    this.chatHeader = false,
    this.bookmark = false,
  });

  int _gradientIndex() {
    if (globe) return 0;
    final key = name.isEmpty ? '?' : name.toLowerCase();
    return _hashCache.putIfAbsent(key, () {
      var h = 0;
      for (final cu in key.codeUnits) {
        h = (h * 31 + cu) & 0x7fffffff;
      }
      return h % C.avatarGradients.length;
    });
  }

  String get _initial {
    final n = name.trim();
    if (n.isEmpty) return 'R';
    return String.fromCharCode(n.runes.first).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    // v1.4.0 — سیو مسیج: بوکمارک طلایی (مثل تلگرام)
    if (bookmark) {
      return SizedBox(
        width: size,
        height: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFF7B733), Color(0xFFE88D1A)],
            ),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Icon(Icons.bookmark_rounded,
                size: size * 0.46, color: Colors.white),
          ),
        ),
      );
    }
    final hasImg = avatarPath.isNotEmpty &&
        !avatarPath.contains('default.png') &&
        avatarPath != 'None';
    final grad = C.avatarGradients[_gradientIndex()];

    Widget inner;
    if (hasImg) {
      inner = CachedNetworkImage(
        imageUrl: ApiService.I.avatarUrl(avatarPath),
        memCacheWidth: (size * 2).toInt(),
        fadeInDuration: const Duration(milliseconds: 120),
        placeholder: (_, __) => _gradientBox(grad),
        errorWidget: (_, __, ___) => _gradientBox(grad),
        imageBuilder: (context, provider) => Container(
          width: size, height: size,
          decoration: BoxDecoration(
            shape: globe ? BoxShape.rectangle : BoxShape.circle,
            borderRadius: globe ? BorderRadius.circular(size / 2) : null,
            image: DecorationImage(image: provider, fit: BoxFit.cover),
          ),
        ),
      );
    } else {
      inner = _gradientBox(grad);
    }

    return SizedBox(width: size, height: size, child: inner);
  }

  Widget _gradientBox(List<Color> grad) {
    if (globe) {
      // Globe avatar from the web index: blue gradient + globe SVG strokes.
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: C.globeGrad,
          shape: BoxShape.circle,
        ),
        child: Center(
          child: SizedBox(
            width: size * 0.52,
            height: size * 0.52,
            child: CustomPaint(painter: _GlobePainter()),
          ),
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: grad,
        ),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          _initial,
          style: TextStyle(
            color: Colors.white,
            fontSize: size * 0.37,
            fontWeight: FontWeight.w700,
            height: 1,
          ),
        ),
      ),
    );
  }
}

class _GlobePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width / 16
      ..color = Colors.white;
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;
    canvas.drawCircle(c, r, paint);
    // vertical ellipse
    canvas.drawOval(
        Rect.fromCenter(center: c, width: r * 0.9, height: r * 2), paint);
    // horizontal lines
    canvas.drawLine(Offset(c.dx - r, c.dy), Offset(c.dx + r, c.dy), paint);
    canvas.drawLine(
        Offset(c.dx - r * 0.83, c.dy - r * 0.55), Offset(c.dx + r * 0.83, c.dy - r * 0.55),
        paint);
    canvas.drawLine(
        Offset(c.dx - r * 0.83, c.dy + r * 0.55), Offset(c.dx + r * 0.83, c.dy + r * 0.55),
        paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Small verified check (admin) badge — drawn, zero image cost.
class VerifiedBadge extends StatelessWidget {
  final double size;
  const VerifiedBadge({super.key, this.size = 15});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size.square(size), painter: _VerifiedPainter());
  }
}

/// v1.0.8 — the Index animated PRO star (gold star PNG asset) replacing the
/// old "PRO" text chip everywhere: own profile, other profiles, chat author
/// rows and member lists. Two synchronized animations, exactly like the web:
///  • profileProPulse  — scale 1 → 1.14 with a warm glow (2.6s, ease-in-out)
///  • proStarShine      — a light sweep masked to the star shape (3s)
class ProStarBadge extends StatefulWidget {
  final double size;
  final bool animate; // small list rows use a static glyph (list performance)
  // v1.3.2 — Telegram-inspired one-shot ENTRANCE: the badge pops in with a
  // springy overshoot + halo flash, then settles into the ambient pulse.
  final bool entrance;
  // v1.5.0 — profile taps open the animated premium tag + feature list.
  final VoidCallback? onTap;

  const ProStarBadge(
      {super.key,
      this.size = 20,
      this.animate = true,
      this.entrance = false,
      this.onTap});

  @override
  State<ProStarBadge> createState() => _ProStarBadgeState();
}

/// v1.5.0 — PREMIUM LOGO badge (the animated dart logo the user provided):
/// • همه‌جا همان لوگوی انیمیشنی رسم می‌شود (aura + glint + ستاره چرخان)
/// • ردیف‌های لیست: نسخه‌ی ثابت (بدون هیچ کنترلری — پرفورمنس موبایل ضعیف)
/// • پروفایل‌ها/هدر: PremiumLogo با چرخه‌ی ۸ ثانیه‌ای + ورود فنری تلگرامی
class _ProStarBadgeState extends State<ProStarBadge>
    with TickerProviderStateMixin {
  late final AnimationController _enter = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 650));
  late final AnimationController _burst = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 700));

  @override
  void initState() {
    super.initState();
    if (widget.entrance) {
      _enter.forward();
      _burst.forward();
    } else {
      _enter.value = 1.0;
    }
  }

  @override
  void dispose() {
    _enter.dispose();
    _burst.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // v1.5.0 — لوگوی انیمیشنی Premium (فایل dart داده‌شده) همه‌جا:
    //  • ردیف‌های لیست: نقاشی ثابت (بدون کنترلر — پرفورمنس لیست)
    //  • پروفایل/هدر چت: PremiumLogo کامل با انیمیشن aura+glint+ستاره،
    //    در پروفایل‌ها چرخه‌ی ۸ ثانیه‌ای
    final dark = Theme.of(context).brightness == Brightness.dark;
    final logoColor = dark ? const Color(0xFFE8ECF3) : const Color(0xFF14161B);

    final Widget badge;
    if (!widget.animate) {
      // static glyph — zero controllers, safe for long scrolling lists
      badge = PremiumLogoStatic(
        size: widget.size,
        logoColor: logoColor,
      );
    } else {
      badge = PremiumLogo(
        size: widget.size,
        logoColor: logoColor,
        accentA: kPremiumAccentA,
        accentB: kPremiumAccentB,
        // پروفایل‌ها و هدرها: تکرار هر ۸ ثانیه (طبق درخواست)
        duration: const Duration(seconds: 8),
      );
    }

    final Widget out = RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: widget.entrance
            ? AnimatedBuilder(
                animation: Listenable.merge([_enter, _burst]),
                builder: (context, _) {
                  final e = _enter.value;
                  final back = Curves.easeOutBack.transform(e);
                  final enterScale = (0.2 + 0.8 * back).clamp(0.0, 1.3);
                  final burstT = Curves.easeOutCubic.transform(_burst.value);
                  return Stack(
                    fit: StackFit.expand,
                    clipBehavior: Clip.none,
                    alignment: Alignment.center,
                    children: [
                      if (burstT < 1.0)
                        CustomPaint(
                          painter: _StarBurstPainter(
                              progress: burstT,
                              color: const Color(0xFF9FCBFF)),
                        ),
                      Transform.scale(
                        scale: enterScale,
                        child: badge,
                      ),
                    ],
                  );
                },
              )
            : badge,
      ),
    );

    if (widget.onTap == null) return out;
    return GestureDetector(onTap: widget.onTap, child: out);
  }
}

/// v1.5.0 — تگ انیمیشنی پرمیوم: لمسِ لوگو در پروفایل → یک تگ «PREMIUM» با
/// انیمیشن از بالای لوگو بالا می‌آید و پایینِ آن توضیح قابلیت‌ها باز می‌شود.
class ProStarTag extends StatefulWidget {
  final double size;
  const ProStarTag({super.key, this.size = 20});

  @override
  State<ProStarTag> createState() => _ProStarTagState();
}

class _ProStarTagState extends State<ProStarTag>
    with SingleTickerProviderStateMixin {
  bool _open = false;
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 380));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() => _open = !_open);
    _open ? _c.forward() : _c.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;
    final curved = CurvedAnimation(parent: _c, curve: Curves.easeOutBack);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        // ---- the animated tag above the logo ----
        ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: _open ? 1.0 : 0.0,
            child: ScaleTransition(
              scale: Tween(begin: 0.6, end: 1.0).animate(curved),
              alignment: Alignment.bottomCenter,
              child: FadeTransition(
                opacity: curved,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      gradient: const LinearGradient(
                        colors: [Color(0xFF8F7BFF), Color(0xFF7AA7FF)],
                      ),
                      boxShadow: const [
                        BoxShadow(
                            color: Color(0x558F7BFF),
                            blurRadius: 14,
                            offset: Offset(0, 3)),
                      ],
                    ),
                    child: Text(
                      s.premiumTagTitle,
                      textDirection: TextDirection.ltr,
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.4,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        // ---- the animated logo itself ----
        GestureDetector(
          onTap: _toggle,
          child: ProStarBadge(size: widget.size, animate: true),
        ),
        // ---- the feature description below ----
        AnimatedSize(
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _open
              ? Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: p.bgSoft,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: p.borderSoft),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.premiumTagDesc,
                          style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                              color: p.text)),
                      const SizedBox(height: 6),
                      for (final f in s.premiumFeatures)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.auto_awesome_rounded,
                                  size: 11, color: Color(0xFF8F7BFF)),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(f,
                                    style: TextStyle(
                                        fontSize: 10.5,
                                        height: 1.4,
                                        color: p.text2)),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// باریکه‌ی ورود تلگرامی: ۶ پرتو کوتاه از مرکز که باز و محو می‌شوند
class _StarBurstPainter extends CustomPainter {
  final double progress; // 0..1
  final Color color;
  _StarBurstPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width * 0.5;
    final t = progress;
    final len = r * (0.55 + 0.75 * t);
    final alpha = (1.0 - t) * 0.85;
    final paint = Paint()
      ..color = color.withValues(alpha: alpha.clamp(0.0, 1.0))
      ..strokeWidth = math.max(0.9, r * 0.10 * (1.0 - 0.5 * t))
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 6; i++) {
      final ang = -math.pi / 2 + i * math.pi / 3;
      final from = Offset(c.dx + r * 0.55 * math.cos(ang),
          c.dy + r * 0.55 * math.sin(ang));
      final to = Offset(c.dx + len * math.cos(ang), c.dy + len * math.sin(ang));
      canvas.drawLine(from, to, paint);
    }
  }

  @override
  bool shouldRepaint(_StarBurstPainter old) => old.progress != progress;
}

class RingProgress extends StatelessWidget {
  final double progress; // 0..1 (<=0 → indeterminate spin)
  final double size;
  final double strokeWidth;
  final Color color;
  final Color track;
  final Widget? child;

  const RingProgress({
    super.key,
    required this.progress,
    this.size = 38,
    this.strokeWidth = 2.4,
    this.color = Colors.white,
    this.track = const Color(0x33FFFFFF),
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (child != null) child!,
          CustomPaint(
            painter: _RingPainter(
              progress: progress,
              strokeWidth: strokeWidth,
              color: color,
              track: track,
            ),
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double progress;
  final double strokeWidth;
  final Color color;
  final Color track;
  _RingPainter({
    required this.progress,
    required this.strokeWidth,
    required this.color,
    required this.track,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (progress < 0) return; // hidden
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - strokeWidth;
    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = track;
    canvas.drawCircle(c, r, trackPaint);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = color;
    if (progress == 0) {
      // indeterminate arc — 90° sweep starting at the top
      canvas.drawArc(Rect.fromCircle(center: c, radius: r), 0, math.pi / 2,
          false, paint);
    } else {
      canvas.drawArc(Rect.fromCircle(center: c, radius: r), -math.pi / 2,
          2 * math.pi * progress.clamp(0.0, 1.0), false, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.progress != progress || old.color != color;
}

class _VerifiedPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final path = Path()..addOval(Rect.fromLTWH(0, 0, s, s));
    final paint = Paint()..color = const Color(0xFF198FD5);
    canvas.drawPath(path, paint);
    final check = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.16
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final p = Path()
      ..moveTo(s * 0.30, s * 0.52)
      ..lineTo(s * 0.45, s * 0.66)
      ..lineTo(s * 0.71, s * 0.37);
    canvas.drawPath(p, check);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Unread pill (accent circle) — identical metrics to the web badge.
class UnreadPill extends StatelessWidget {
  final int count;
  const UnreadPill({super.key, required this.count});

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    return Container(
      constraints: const BoxConstraints(minWidth: 21),
      height: 21,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.light
            ? C.accentL
            : C.accentD,
        shape: count.toString().length > 1 ? BoxShape.rectangle : BoxShape.circle,
        borderRadius: count.toString().length > 1 ? BorderRadius.circular(11) : null,
        boxShadow: [
          BoxShadow(
            color: (Theme.of(context).brightness == Brightness.light
                    ? C.accentL
                    : C.accentD)
                .withValues(alpha: 0.38),
            blurRadius: 7,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: const TextStyle(
            color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w700,
            height: 1),
      ),
    );
  }
}

/// Category badge next to a chip.
class CatBadge extends StatelessWidget {
  final int count;
  final bool active;
  const CatBadge({super.key, required this.count, required this.active});

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      constraints: const BoxConstraints(minWidth: 21),
      height: 21,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: active
            ? (dark ? C.accentD : C.accentL)
            : (dark ? C.badgeGrayD : C.badgeGrayL),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Text(
        '$count',
        style: const TextStyle(color: Colors.white, fontSize: 10.5,
            fontWeight: FontWeight.w600, height: 1),
      ),
    );
  }
}

/// Toast pill (like .app-toast in the web app).
void showRaviToast(BuildContext context, String msg, {IconData icon = Icons.check_circle_outline_rounded}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  final overlay = Overlay.of(context, rootOverlay: true);
  final entry = OverlayEntry(
    builder: (_) => Positioned(
      bottom: 92 + MediaQuery.of(context).padding.bottom,
      left: 0, right: 0,
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              color: dark ? C.bgElevD : Colors.white,
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: dark ? C.borderD : C.borderL),
              boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 30)],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: dark ? C.accentD : C.accentL),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(msg,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: dark ? C.textD : C.textL)),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  Future.delayed(const Duration(milliseconds: 1900), () => entry.remove());
}

/// Settings section card (.section-card).
class SectionCard extends StatelessWidget {
  final List<Widget> children;
  const SectionCard({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(top: 10, left: 2, right: 2),
      decoration: BoxDecoration(
        color: dark ? C.bgCardD : C.bgCardL,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: dark ? C.borderSoftD : C.borderSoftL),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

/// Settings row (.list-row) — icon tile, title, subtitle, trailing.
class ListRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String sub;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool danger;

  const ListRow({
    super.key,
    required this.icon,
    required this.title,
    required this.sub,
    this.trailing,
    this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          constraints: const BoxConstraints(minHeight: 54),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: p.border, width: 1)),
          ),
          child: Row(
            textDirection: TextDirection.ltr,
            children: [
              Container(
                width: 31, height: 31,
                decoration: BoxDecoration(
                  color: danger
                      ? const Color(0xFFEF4444).withValues(alpha: .12)
                      : p.accentSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon,
                    size: 18,
                    color: danger ? const Color(0xFFEF4444) : p.accent),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(title,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.w700,
                            color: p.text)),
                    const SizedBox(height: 3),
                    Text(sub,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 9.5, color: p.text2)),
                  ],
                ),
              ),
              trailing ??
                  Icon(Icons.chevron_right_rounded, size: 17, color: p.text3),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// v1.0.8 — Telegram-style FLOATING glass menu (⋮ menus, user menus…)
// ============================================================================

class MenuItem {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const MenuItem(this.icon, this.label, this.color, this.onTap);
}

/// A small glass card pinned under the tapped button (Telegram ⋮ menu):
/// spring scale-in from the anchor, tap-away to close, soft blur backdrop.
void showFloatingMenu(
  BuildContext context, {
  required List<MenuItem> items,
  bool dark = false,
  bool alignEnd = false,
  Offset? anchor, // global position of the tapped button (optional)
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final size = MediaQuery.of(context).size;
  final width = 208.0;
  final height = items.length * 44.0 + 14.0;
  double left;
  if (anchor != null) {
    left = anchor.dx - (alignEnd ? width : 0);
  } else {
    left = alignEnd ? size.width - width - 10 : 10;
  }
  left = left.clamp(10.0, size.width - width - 10);
  final top = (anchor?.dy ?? 64.0) + 4.0;
  late final OverlayEntry entry;
  final controller = _FloatMenuAnim();

  entry = OverlayEntry(
    builder: (_) => AnimatedBuilder(
      animation: controller.c,
      builder: (context, _) {
        final t = Curves.easeOutBack.transform(controller.c.value.clamp(0.0, 1.0));
        final op = controller.c.value.clamp(0.0, 1.0);
        return Stack(children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => _removeMenu(entry, controller),
              behavior: HitTestBehavior.opaque,
              child: ColoredBox(
                  color: Colors.black.withValues(alpha: .18 * op)),
            ),
          ),
          Positioned(
            top: top.clamp(50.0, size.height - height - 16),
            left: left,
            child: IgnorePointer(
              ignoring: op < .9,
              child: Transform.scale(
                scale: 0.82 + 0.18 * t,
                alignment: alignEnd ? Alignment.topRight : Alignment.topLeft,
                child: Opacity(
                  opacity: op,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                      child: Material(
                        type: MaterialType.transparency,
                        child: Container(
                          width: width,
                          padding: const EdgeInsets.all(7),
                          decoration: BoxDecoration(
                            color: dark
                                ? const Color(0xE6161C24)
                                : const Color(0xF2FFFFFF),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: dark
                                  ? Colors.white.withValues(alpha: .10)
                                  : Colors.white.withValues(alpha: .55),
                            ),
                            boxShadow: const [
                              BoxShadow(
                                  color: Color(0x47000000),
                                  blurRadius: 30,
                                  offset: Offset(0, 12)),
                            ],
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final it in items)
                                InkWell(
                                  onTap: () {
                                    _removeMenu(entry, controller);
                                    it.onTap();
                                  },
                                  borderRadius: BorderRadius.circular(12),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 11),
                                    child: Row(children: [
                                      Icon(it.icon,
                                          size: 18, color: it.color),
                                      const SizedBox(width: 11),
                                      Expanded(
                                        child: Text(it.label,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w700,
                                                color: it.color == const Color(0xFFEF4444)
                                                    ? it.color
                                                    : (dark
                                                        ? Colors.white
                                                        : C.textL))),
                                      ),
                                    ]),
                                  ),
                                ),
                            ]),
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
    ),
  );
  overlay.insert(entry);
  controller.c.forward();
}

void _removeMenu(OverlayEntry entry, _FloatMenuAnim controller) {
  try {
    entry.remove();
  } catch (_) {}
  try {
    controller.c.dispose();
  } catch (_) {}
}

class _FloatMenuAnim {
  final AnimationController c = AnimationController(
      vsync: _MenuTicker(), duration: const Duration(milliseconds: 240));
}

class _MenuTicker extends TickerProvider {
  @override
  Ticker createTicker(TickerCallback onTick) => Ticker(onTick);
}

/// v1.5.0 — لوگوی پرمیومِ پروفایل با «تگِ بازشو»:
/// لمس لوگو → یک تگ PREMIUM با انیمیشن از بالای لوگو بالا می‌آید و زیر آن
/// لیستِ قابلیت‌ها باز می‌شود (Overlay مستقل — چیدمان پروفایل نمی‌شکند).
/// انیمیشن لوگو با چرخه‌ی ۸ ثانیه‌ای تکرار می‌شود.
class PremiumProfileBadge extends StatefulWidget {
  final double size;
  const PremiumProfileBadge({super.key, this.size = 20});

  @override
  State<PremiumProfileBadge> createState() => _PremiumProfileBadgeState();
}

class _PremiumProfileBadgeState extends State<PremiumProfileBadge> {
  final GlobalKey _anchorKey = GlobalKey();
  OverlayEntry? _entry;

  void _toggle() {
    HapticFeedback.selectionClick();
    if (_entry != null) {
      _remove();
      return;
    }
    _entry = OverlayEntry(
      builder: (ctx) => _PremiumTagOverlay(
        anchorKey: _anchorKey,
        onDismiss: _remove,
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_entry!);
  }

  void _remove() {
    try {
      _entry?.remove();
    } catch (_) {}
    _entry = null;
  }

  @override
  void dispose() {
    _remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: _anchorKey,
      onTap: _toggle,
      child: ProStarBadge(size: widget.size, animate: true),
    );
  }
}

class _PremiumTagOverlay extends StatefulWidget {
  final GlobalKey anchorKey;
  final VoidCallback onDismiss;
  const _PremiumTagOverlay({required this.anchorKey, required this.onDismiss});

  @override
  State<_PremiumTagOverlay> createState() => _PremiumTagOverlayState();
}

class _PremiumTagOverlayState extends State<_PremiumTagOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 420))
    ..forward();

  Rect _anchorRect(BuildContext ctx) {
    final box =
        widget.anchorKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(ctx, rootOverlay: true).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null || !box.attached) {
      return const Rect.fromLTWH(0, 0, 1, 1);
    }
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.I.str;
    final mq = MediaQuery.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final p =
        dark ? const Palette.dark() : const Palette.light();
    final rect = _anchorRect(context);
    const cardW = 268.0;
    final left = (rect.center.dx - cardW / 2)
        .clamp(10.0, mq.size.width - cardW - 10.0);
    final top = (rect.bottom + 8)
        .clamp(10.0, mq.size.height - 240.0);
    final curved = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);

    return Stack(
      children: [
        // بستن با لمس بیرون
        Positioned.fill(
          child: GestureDetector(onTap: widget.onDismiss),
        ),
        Positioned(
          left: left,
          top: top,
          child: FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween(begin: const Offset(0, -0.12), end: Offset.zero)
                  .animate(curved),
              child: Material(
                color: Colors.transparent,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // ---- تگ PREMIUM ----
                    ScaleTransition(
                      scale: Tween(begin: 0.5, end: 1.0)
                          .animate(CurvedAnimation(
                              parent: _c, curve: Curves.easeOutBack)),
                      alignment: Alignment.bottomCenter,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 5),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          gradient: const LinearGradient(
                            colors: [Color(0xFF8F7BFF), Color(0xFF7AA7FF)],
                          ),
                          boxShadow: const [
                            BoxShadow(
                                color: Color(0x558F7BFF),
                                blurRadius: 16,
                                offset: Offset(0, 4)),
                          ],
                        ),
                        child: Text(s.premiumTagTitle,
                            textDirection: TextDirection.ltr,
                            style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 1.6,
                                color: Colors.white)),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // ---- توضیح قابلیت‌ها ----
                    Container(
                      width: cardW,
                      padding: const EdgeInsets.all(13),
                      decoration: BoxDecoration(
                        color: p.navBg,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: p.borderSoft),
                        boxShadow: const [
                          BoxShadow(
                              color: Color(0x3D122A46),
                              blurRadius: 30,
                              offset: Offset(0, 14)),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.premiumTagDesc,
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  color: p.text)),
                          const SizedBox(height: 7),
                          for (final f in s.premiumFeatures)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2.5),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Icon(Icons.auto_awesome_rounded,
                                      size: 12, color: Color(0xFF8F7BFF)),
                                  const SizedBox(width: 7),
                                  Expanded(
                                    child: Text(f,
                                        style: TextStyle(
                                            fontSize: 11,
                                            height: 1.4,
                                            color: p.text2)),
                                  ),
                                ],
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
      ],
    );
  }
}
