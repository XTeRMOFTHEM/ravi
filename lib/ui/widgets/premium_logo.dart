// PremiumLogo: animated logo + premium star effect (no dependencies).
// Usage:  const PremiumLogo(size: 48)
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';

class PremiumLogo extends StatefulWidget {
  const PremiumLogo({
    super.key,
    this.size = 120,
    this.logoColor = const Color(0xFF0A0A0A),
    this.accentA = 0x8F7BFF, // violet (RGB, no alpha)
    this.accentB = 0x7AA7FF, // blue   (RGB, no alpha)
    this.duration = const Duration(seconds: 5),
  });

  final double size;
  final Color logoColor;
  final int accentA;
  final int accentB;
  final Duration duration;

  @override
  State<PremiumLogo> createState() => _PremiumLogoState();
}

class _PremiumLogoState extends State<PremiumLogo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: widget.duration);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Respect "reduce motion": show the static logo only.
    if (MediaQuery.of(context).disableAnimations) {
      _c.stop();
      _c.value = 0;
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: CustomPaint(
          painter: _LogoPainter(
            _c,
            widget.logoColor,
            widget.accentA,
            widget.accentB,
          ),
        ),
      ),
    );
  }
}

// ---------- keyframe helpers ----------
double _kf(double t, List<double> ts, List<double> vs, [List<Curve>? cv]) {
  if (t <= ts.first) return vs.first;
  for (var i = 0; i < ts.length - 1; i++) {
    if (t < ts[i + 1]) {
      final p = (t - ts[i]) / (ts[i + 1] - ts[i]);
      final c = cv != null ? cv[i] : Curves.linear;
      return vs[i] + (vs[i + 1] - vs[i]) * c.transform(p);
    }
  }
  return vs.last;
}

Color _rgba(int rgb, double a) => Color.fromRGBO(
    (rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255, a.clamp(0.0, 1.0));

int _mix(int a, int b, double t) {
  int ch(int s) {
    final x = (a >> s) & 255, y = (b >> s) & 255;
    return (x + (y - x) * t).round();
  }

  return (ch(16) << 16) | (ch(8) << 8) | ch(0);
}

const _lin = Curves.linear;
const _eRing = Cubic(0.1, 0.6, 0.3, 1);

class _LogoPainter extends CustomPainter {
  _LogoPainter(this.anim, this.logoColor, this.accentA, this.accentB)
      : super(repaint: anim);

  final Animation<double> anim;
  final Color logoColor;
  final int accentA, accentB;

  static final Path _logo = _buildLogo()..fillType = PathFillType.evenOdd;
  static final Path _star = _buildStar();
  static final Rect _starBounds = _star.getBounds();
  static final Path _glintBand = Path()
    ..addRect(const Rect.fromLTWH(-26, -230, 52, 460));
  static final Float64List _skew = _skewMatrix();

  static Float64List _skewMatrix() {
    final m = Matrix4.identity();
    m.setEntry(0, 1, math.tan(-22 * math.pi / 180));
    return m.storage;
  }

  final Paint _p = Paint()..isAntiAlias = true;

  Shader _radial(double r, List<Color> cs, List<double> st) =>
      RadialGradient(colors: cs, stops: st)
          .createShader(Rect.fromCircle(center: Offset.zero, radius: r));

  void _disc(Canvas c, double r, Shader s, double scale) {
    c.save();
    c.scale(scale);
    _p
      ..shader = s
      ..style = PaintingStyle.fill;
    c.drawCircle(Offset.zero, r, _p);
    c.restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final t = anim.value;
    const white = 0xFFFFFF;
    final tint = _mix(white, accentA, 0.45);

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(size.shortestSide / 420);

    // 1) aura behind the logo
    final auraO = _kf(t, [0, .02, .40, .64, .90, 1], [0, 0, .8, 1, 0, 0]);
    if (auraO > 0.001) {
      final auraS = _kf(t, [0, .40, .64, .90, 1], [.6, 1, 1.12, .8, .8]);
      _disc(
        canvas,
        175,
        _radial(175, [
          _rgba(accentA, .55 * auraO),
          _rgba(accentB, .22 * auraO),
          _rgba(accentB, 0),
        ], [0, .55, 1]),
        auraS,
      );
    }

    // 2) logo (slight pulse near the flash)
    final logoS = _kf(t, [0, .56, .66, .80, 1], [1, 1, 1.03, 1, 1]);
    canvas.save();
    canvas.scale(logoS);
    _p
      ..shader = null
      ..style = PaintingStyle.fill
      ..color = logoColor;
    canvas.drawPath(_logo, _p);
    canvas.restore();

    // 3) glint sweeping across the logo
    if (t > .54 && t < .76) {
      final gx = _kf(t, [0, .54, .76, 1], [-280, -280, 280, 280],
          [_lin, const Cubic(.5, 0, .3, 1), _lin]);
      canvas.save();
      canvas.clipPath(_logo);
      canvas.translate(gx, 0);
      canvas.transform(_skew);
      _p
        ..style = PaintingStyle.fill
        ..shader = LinearGradient(colors: [
          _rgba(white, 0),
          _rgba(white, .7),
          _rgba(white, 0),
        ]).createShader(const Rect.fromLTWH(-26, -230, 52, 460));
      canvas.drawPath(_glintBand, _p);
      canvas.restore();
    }

    // 4) soft core glow over the logo
    final coreO = _kf(t, [0, .04, .40, .64, .88, 1], [0, 0, .55, .8, 0, 0]);
    final coreShader = (double o) => _radial(120, [
          _rgba(white, .85 * o),
          _rgba(tint, .45 * o),
          _rgba(accentA, 0),
        ], [0, .35, 1]);
    if (coreO > 0.001) _disc(canvas, 120, coreShader(coreO), 1);

    // 5) two halo rings (second one rides the flash)
    void ring(double s, double o) {
      if (o <= 0.001) return;
      _disc(
        canvas,
        80,
        _radial(80, [
          _rgba(accentA, 0),
          _rgba(tint, .95 * o),
          _rgba(accentB, 0),
        ], [.62, .86, 1]),
        s,
      );
    }

    ring(
      _kf(t, [0, .12, .46, 1], [.35, .35, 2.5, 2.5], [_lin, _eRing, _lin]),
      _kf(t, [0, .12, .20, .46, 1], [0, 0, .95, 0, 0]),
    );
    ring(
      _kf(t, [0, .56, .84, 1], [.5, .5, 2.5, 2.5], [_lin, _eRing, _lin]),
      _kf(t, [0, .56, .62, .84, 1], [0, 0, .9, 0, 0]),
    );

    // 6) the star: grows, spins fast, spins in place, shrinks and fades
    final starO = _kf(t, [0, .08, .76, .90, 1], [0, 1, 1, 0, 0]);
    if (starO > 0.001) {
      const ts = [0.0, .08, .40, .64, .90, 1.0];
      const cv = <Curve>[
        _lin,
        Cubic(.4, 0, .15, 1),
        Cubic(.25, .4, .45, 1),
        Cubic(.5, 0, .3, 1),
        _lin,
      ];
      final rot = _kf(t, ts, [0, 0, 900, 1440, 1620, 1620], cv);
      final sc = _kf(t, ts, [1, 1, 2.0, 2.1, 1, 1], cv);
      final shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          _rgba(white, starO),
          _rgba(_mix(white, accentA, .3), starO),
          _rgba(accentB, starO),
        ],
        stops: const [0, .5, 1],
      ).createShader(_starBounds);
      canvas.save();
      canvas.rotate(rot * math.pi / 180);
      canvas.scale(sc);
      _p
        ..shader = shader
        ..style = PaintingStyle.fill;
      canvas.drawPath(_star, _p);
      _p
        ..style = PaintingStyle.stroke
        ..strokeWidth = .8;
      canvas.drawPath(_star, _p);
      canvas.restore();
    }

    // 7) flash of light
    final flO = _kf(t, [0, .56, .64, .76, 1], [0, 0, .85, 0, 0]);
    if (flO > 0.001) {
      final flS = _kf(t, [0, .56, .76, 1], [.45, .45, 1.25, 1.25]);
      _disc(
        canvas,
        160,
        _radial(160, [
          _rgba(white, .85 * flO),
          _rgba(tint, .45 * flO),
          _rgba(accentA, 0),
        ], [0, .35, 1]),
        flS,
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LogoPainter old) =>
      old.logoColor != logoColor ||
      old.accentA != accentA ||
      old.accentB != accentB;
}

// ---------- traced paths (centered at 0,0; logo spans about +-155) ----------
Path _buildLogo() => Path()
    ..moveTo(73.67, 155.12)
    ..cubicTo(52.07, 152.25, 29.73, 132.32, 14.76, 102.58)
    ..cubicTo(13.24, 99.56, 12.10, 97.67, 11.79, 97.67)
    ..cubicTo(11.52, 97.67, 9.47, 98.66, 7.23, 99.87)
    ..cubicTo(-3.49, 105.66, -15.64, 111.24, -26.93, 115.53)
    ..cubicTo(-66.00, 130.41, -102.16, 132.21, -126.83, 120.52)
    ..cubicTo(-150.17, 109.46, -159.94, 88.47, -152.61, 65.18)
    ..cubicTo(-146.67, 46.31, -127.80, 27.60, -101.30, 14.32)
    ..cubicTo(-97.29, 12.31, -96.61, 11.60, -97.62, 10.48)
    ..cubicTo(-98.06, 10.00, -101.46, 3.51, -104.69, -3.00)
    ..cubicTo(-130.17, -54.35, -134.85, -103.14, -117.10, -132.45)
    ..cubicTo(-99.36, -161.75, -65.03, -162.65, -37.17, -134.54)
    ..cubicTo(-28.09, -125.38, -17.88, -110.53, -12.83, -99.13)
    ..cubicTo(-12.41, -98.19, -11.91, -97.32, -11.71, -97.19)
    ..cubicTo(-11.51, -97.07, -9.09, -98.18, -6.34, -99.67)
    ..cubicTo(40.03, -124.76, 85.54, -133.60, 117.65, -123.77)
    ..cubicTo(136.87, -117.89, 149.95, -105.71, 154.26, -89.70)
    ..cubicTo(155.39, -85.49, 155.57, -74.53, 154.57, -70.33)
    ..cubicTo(149.31, -48.15, 131.24, -28.84, 101.75, -13.90)
    ..cubicTo(99.49, -12.76, 97.67, -11.63, 97.67, -11.37)
    ..cubicTo(97.67, -11.12, 98.58, -9.19, 99.69, -7.09)
    ..cubicTo(115.00, 21.75, 123.55, 46.39, 127.03, 71.67)
    ..cubicTo(127.93, 78.20, 128.29, 93.57, 127.68, 99.56)
    ..cubicTo(124.77, 128.18, 111.80, 147.60, 91.44, 153.86)
    ..cubicTo(87.58, 155.05, 87.37, 155.07, 81.17, 155.17)
    ..cubicTo(77.68, 155.23, 74.31, 155.20, 73.67, 155.12)
    ..close()
    ..moveTo(51.69, 118.32)
    ..cubicTo(57.41, 115.41, 60.94, 108.20, 62.49, 96.23)
    ..cubicTo(63.52, 88.33, 62.85, 76.60, 60.81, 66.75)
    ..cubicTo(60.60, 65.74, 59.84, 65.81, 58.38, 66.95)
    ..cubicTo(50.30, 73.27, 33.21, 84.74, 21.50, 91.71)
    ..cubicTo(18.20, 93.67, 15.14, 95.56, 14.71, 95.90)
    ..lineTo(13.92, 96.53)
    ..lineTo(15.69, 98.67)
    ..cubicTo(21.06, 105.11, 29.66, 112.40, 36.11, 115.97)
    ..cubicTo(42.04, 119.25, 48.08, 120.16, 51.69, 118.32)
    ..close()
    ..moveTo(-75.99, 62.35)
    ..cubicTo(-71.48, 61.78, -69.59, 61.48, -66.42, 60.81)
    ..cubicTo(-65.18, 60.55, -65.53, 59.69, -68.53, 55.67)
    ..cubicTo(-76.67, 44.77, -85.51, 31.43, -93.05, 18.67)
    ..cubicTo(-95.02, 15.32, -95.65, 14.50, -96.25, 14.50)
    ..cubicTo(-96.74, 14.50, -98.38, 15.81, -101.05, 18.33)
    ..cubicTo(-114.99, 31.47, -121.51, 44.38, -117.90, 51.73)
    ..cubicTo(-113.66, 60.37, -95.93, 64.86, -75.99, 62.35)
    ..close()
    ..moveTo(-48.51, 55.80)
    ..cubicTo(-36.50, 51.38, -27.90, 47.46, -17.21, 41.53)
    ..cubicTo(-8.03, 36.44, 4.01, 28.65, 13.27, 21.79)
    ..lineTo(18.38, 18.01)
    ..lineTo(19.61, 18.68)
    ..cubicTo(29.03, 23.82, 42.57, 35.74, 52.35, 47.49)
    ..cubicTo(54.86, 50.51, 56.53, 52.27, 56.60, 51.96)
    ..cubicTo(56.80, 50.90, 51.56, 37.69, 47.71, 29.57)
    ..cubicTo(41.37, 16.20, 30.93, -0.71, 20.26, -14.89)
    ..lineTo(17.96, -17.95)
    ..lineTo(18.53, -19.06)
    ..cubicTo(23.35, -28.40, 38.77, -45.56, 49.75, -53.80)
    ..cubicTo(52.02, -55.50, 52.71, -56.59, 51.25, -56.16)
    ..cubicTo(40.99, -53.15, 20.96, -43.57, 7.83, -35.40)
    ..cubicTo(0.34, -30.73, -13.29, -21.35, -16.78, -18.45)
    ..cubicTo(-18.10, -17.35, -18.06, -17.34, -23.03, -20.60)
    ..cubicTo(-33.45, -27.45, -47.03, -40.12, -53.71, -49.24)
    ..cubicTo(-55.21, -51.28, -55.65, -51.71, -56.04, -51.47)
    ..cubicTo(-56.44, -51.23, -55.54, -48.56, -52.42, -40.67)
    ..cubicTo(-45.99, -24.43, -34.00, -3.54, -21.51, 13.17)
    ..cubicTo(-17.34, 18.75, -17.55, 18.30, -18.38, 19.83)
    ..cubicTo(-23.66, 29.69, -38.34, 45.83, -50.45, 55.10)
    ..cubicTo(-52.71, 56.83, -52.00, 57.09, -48.51, 55.80)
    ..close()
    ..moveTo(100.30, -16.83)
    ..cubicTo(113.13, -28.72, 120.06, -40.14, 119.19, -48.00)
    ..cubicTo(117.88, -59.82, 96.20, -65.57, 70.23, -60.98)
    ..cubicTo(66.44, -60.31, 66.00, -60.17, 66.00, -59.62)
    ..cubicTo(66.00, -59.44, 67.38, -57.38, 69.07, -55.06)
    ..cubicTo(79.13, -41.20, 86.06, -30.73, 93.17, -18.67)
    ..cubicTo(95.42, -14.84, 96.24, -13.67, 96.66, -13.67)
    ..cubicTo(96.78, -13.67, 98.42, -15.09, 100.30, -16.83)
    ..close()
    ..moveTo(-55.49, -68.36)
    ..cubicTo(-42.64, -77.83, -22.41, -91.10, -15.46, -94.61)
    ..cubicTo(-13.36, -95.67, -13.40, -96.03, -15.96, -98.92)
    ..cubicTo(-22.06, -105.84, -30.12, -112.57, -35.93, -115.59)
    ..cubicTo(-46.66, -121.16, -53.30, -119.70, -57.93, -110.74)
    ..cubicTo(-62.43, -102.04, -63.87, -86.80, -61.51, -72.83)
    ..cubicTo(-61.26, -71.37, -60.97, -69.54, -60.86, -68.77)
    ..cubicTo(-60.59, -66.86, -60.10, -65.67, -59.58, -65.67)
    ..cubicTo(-59.35, -65.67, -57.51, -66.88, -55.49, -68.36)
    ..close();

Path _buildStar() => Path()
    ..moveTo(-51.67, 56.35)
    ..cubicTo(-51.67, 56.17, -51.12, 55.61, -50.45, 55.10)
    ..cubicTo(-38.34, 45.83, -23.66, 29.69, -18.38, 19.83)
    ..cubicTo(-17.55, 18.30, -17.34, 18.75, -21.51, 13.17)
    ..cubicTo(-34.00, -3.54, -45.99, -24.43, -52.42, -40.67)
    ..cubicTo(-55.54, -48.56, -56.44, -51.23, -56.04, -51.47)
    ..cubicTo(-55.65, -51.71, -55.21, -51.28, -53.71, -49.24)
    ..cubicTo(-47.03, -40.12, -33.45, -27.45, -23.03, -20.60)
    ..cubicTo(-18.06, -17.34, -18.10, -17.35, -16.78, -18.45)
    ..cubicTo(-13.29, -21.35, 0.34, -30.73, 7.83, -35.40)
    ..cubicTo(20.96, -43.57, 40.99, -53.15, 51.25, -56.16)
    ..cubicTo(52.71, -56.59, 52.02, -55.50, 49.75, -53.80)
    ..cubicTo(38.77, -45.56, 23.35, -28.40, 18.53, -19.06)
    ..lineTo(17.96, -17.95)
    ..lineTo(20.26, -14.89)
    ..cubicTo(30.93, -0.71, 41.37, 16.20, 47.71, 29.57)
    ..cubicTo(51.56, 37.69, 56.80, 50.90, 56.60, 51.96)
    ..cubicTo(56.53, 52.27, 54.86, 50.51, 52.35, 47.49)
    ..cubicTo(42.57, 35.74, 29.03, 23.82, 19.61, 18.68)
    ..lineTo(18.38, 18.01)
    ..lineTo(13.27, 21.79)
    ..cubicTo(-5.15, 35.42, -25.97, 47.27, -42.67, 53.61)
    ..cubicTo(-51.12, 56.83, -51.67, 56.99, -51.67, 56.35)
    ..close();


// ================= RAVI v1.5.0 integration helpers =================

/// Accent palette of the premium logo (RGB ints, no alpha) — shared with
/// ProStarBadge so badges and the profile tag look identical.
const int kPremiumAccentA = 0x8F7BFF; // violet
const int kPremiumAccentB = 0x7AA7FF; // blue

/// Static (non-animated) paint of the premium glyph — used in long scrolling
/// lists where dozens of live controllers would kill weak phones.
class PremiumLogoStatic extends StatelessWidget {
  const PremiumLogoStatic({
    super.key,
    required this.size,
    this.logoColor = const Color(0xFF0A0A0A),
  });

  final double size;
  final Color logoColor;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _LogoPainter(
              const AlwaysStoppedAnimation(0.0), logoColor, kPremiumAccentA,
              kPremiumAccentB),
        ),
      ),
    );
  }
}
