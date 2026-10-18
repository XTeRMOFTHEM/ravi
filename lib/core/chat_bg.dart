import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';
import 'constants.dart';

/// Chat background setting — Telegram-style wallpapers:
///  • preset gradients with a subtle doodle pattern (drawn, no assets)
///  • v1.0.9 — bundled PACK backgrounds (assets/backgrounds/*.jpg), one of
///    them auto-selected as the very first default (messenger look)
///  • v1.0.9 — the user's own wallpapers: a persistent gallery of uploaded
///    photos (server URLs) that can be selected / removed from the panel
///  • v1.0.9 — bubble color presets for MY bubbles (persisted, previewed)
class ChatBgSetting {
  final String presetKey; // '' => default surface; 'asset:x' / 'url:...' / gradient key
  const ChatBgSetting({this.presetKey = ''});

  bool get isDefault => presetKey.isEmpty;
  bool get isCustomUrl => presetKey.startsWith('url:');
  bool get isAsset => presetKey.startsWith('asset:');
  String? get serverUrl => isCustomUrl ? presetKey.substring(4) : null;
  String? get assetPath => isAsset ? 'assets/backgrounds/${presetKey.substring(6)}' : null;

  static const List<(String, List<Color>, bool)> presets = [
    ('grape', [Color(0xFFB9A7F5), Color(0xFF8D7BE8), Color(0xFF6C5CD6)], false),
    ('ocean', [Color(0xFF9CCFF0), Color(0xFF5FA8E0), Color(0xFF3B7FC4)], false),
    ('forest', [Color(0xFFA8D5B0), Color(0xFF6FAE84), Color(0xFF437D5C)], false),
    ('dawn', [Color(0xFFF6C6A8), Color(0xFFE89898), Color(0xFFC4708B)], false),
    ('sand', [Color(0xFFF0E3C2), Color(0xFFDEC694), Color(0xFFB99E6B)], false),
    ('night', [Color(0xFF1B2240), Color(0xFF111735), Color(0xFF0A0F26)], true),
    ('charcoal', [Color(0xFF2A2A33), Color(0xFF1C1C24), Color(0xFF121218)], true),
    ('wine', [Color(0xFF4A1D33), Color(0xFF33121F), Color(0xFF200A14)], true),
  ];

  /// v1.0.9 — the bundled background pack (from the user's zip).
  static const List<(String, String)> pack = [
    ('bg_pack_1.jpg', 'Doodle'),
    ('bg_pack_2.jpg', 'Sky'),
    ('bg_pack_3.jpg', 'Pattern'),
    ('bg_pack_4.jpg', 'Tech'),
    ('bg_pack_5.jpg', 'Leafy'),
  ];

  /// The DEFAULT wallpaper chosen on first launch — the most
  /// messenger-like of the pack (soft doodle pattern).
  static const String defaultFirstRun = 'asset:bg_pack_3.jpg';

  static List<Color>? colorsFor(String key) {
    for (final p in presets) {
      if (p.$1 == key) return p.$2;
    }
    return null;
  }

  static bool isDarkPreset(String key) {
    if (key.startsWith('asset:')) return false;
    for (final p in presets) {
      if (p.$1 == key) return p.$3;
    }
    return false;
  }
}

/// v1.0.9 — bubble color presets for the user's own bubbles.
class BubbleColorStore {
  BubbleColorStore._();
  static final BubbleColorStore I = BubbleColorStore._();

  static const List<(String, Color, Color)> presets = [
    ('classic', Color(0xFF7C3AED), Color(0xFF5B21B6)), // Ravi purple
    ('ocean', Color(0xFF0EA5E9), Color(0xFF0369A1)),
    ('emerald', Color(0xFF10B981), Color(0xFF047857)),
    ('sunset', Color(0xFFF97316), Color(0xFFC2410C)),
    ('rose', Color(0xFFF43F5E), Color(0xFFBE123C)),
    ('slate', Color(0xFF475569), Color(0xFF1E293B)),
    ('violet', Color(0xFF8B5CF6), Color(0xFF6D28D9)),
    ('cyan', Color(0xFF06B6D4), Color(0xFF0E7490)),
  ];

  final ValueNotifier<String> key = ValueNotifier('classic');

  Color get c1 => presets
      .firstWhere((p) => p.$1 == key.value, orElse: () => presets.first)
      .$2;
  Color get c2 => presets
      .firstWhere((p) => p.$1 == key.value, orElse: () => presets.first)
      .$3;

  LinearGradient get gradient =>
      LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [c1, c2]);

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      key.value = p.getString('bg.bubble') ?? 'classic';
    } catch (_) {}
  }

  Future<void> set(String k) async {
    key.value = k;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('bg.bubble', k);
    } catch (_) {}
  }
}

/// Global chat background store — loads from prefs, notifies listeners.
class ChatBgStore {
  ChatBgStore._();
  static final ChatBgStore I = ChatBgStore._();

  final ValueNotifier<ChatBgSetting> current =
      ValueNotifier(const ChatBgSetting());

  /// v1.0.9 — the user's own wallpapers (server-relative URLs).
  final ValueNotifier<List<String>> customs = ValueNotifier([]);

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      // FIRST RUN: default to the messenger-like pack background.
      final saved = p.getString('pref.chatBg');
      if (saved == null) {
        current.value = ChatBgSetting(presetKey: ChatBgSetting.defaultFirstRun);
        await p.setString('pref.chatBg', ChatBgSetting.defaultFirstRun);
      } else {
        current.value = ChatBgSetting(presetKey: saved);
      }
      customs.value = p.getStringList('bg.customs') ?? <String>[];
    } catch (_) {}
  }

  Future<void> set(ChatBgSetting s) async {
    current.value = s;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('pref.chatBg', s.presetKey);
    } catch (_) {}
  }

  /// v1.0.9 — add a just-uploaded photo to "Your wallpapers" and select it.
  Future<void> addCustom(String serverUrl, {bool select = true}) async {
    final list = List<String>.from(customs.value);
    if (!list.contains(serverUrl)) list.insert(0, serverUrl);
    customs.value = list;
    if (select) await set(ChatBgSetting(presetKey: 'url:$serverUrl'));
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList('bg.customs', list);
    } catch (_) {}
  }

  /// v1.0.9 — remove from the gallery; fall back to default if it was active.
  Future<void> removeCustom(String serverUrl) async {
    final list = List<String>.from(customs.value)..remove(serverUrl);
    customs.value = list;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList('bg.customs', list);
    } catch (_) {}
    if (current.value.presetKey == 'url:$serverUrl') {
      await set(const ChatBgSetting());
    }
  }

  /// Background widget for the chat area (behind the blur-free list).
  static Widget buildBackground(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ValueListenableBuilder<ChatBgSetting>(
      valueListenable: I.current,
      builder: (context, bg, _) {
        final presetColors = ChatBgSetting.colorsFor(bg.presetKey);
        if (bg.assetPath != null) {
          // v1.0.9 — bundled pack photo
          return Stack(
            fit: StackFit.expand,
            children: [
              Image.asset(
                bg.assetPath!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => DecoratedBox(
                  decoration: BoxDecoration(
                    color: dark ? C.chatFallbackD : C.chatFallbackL,
                  ),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: dark ? const Color(0x59000000) : const Color(0x14FFFFFF),
                ),
              ),
            ],
          );
        }
        if (bg.serverUrl != null) {
          // Custom photo from the server (+ dark scrim for readability).
          return Stack(
            fit: StackFit.expand,
            children: [
              CachedNetworkImage(
                imageUrl: ApiService.I.absoluteUrl(bg.serverUrl!),
                fit: BoxFit.cover,
                httpHeaders: {'Cookie': ApiService.I.cookieHeader},
                fadeInDuration: const Duration(milliseconds: 180),
                errorWidget: (_, __, ___) => DecoratedBox(
                  decoration: BoxDecoration(
                    color: dark ? C.chatFallbackD : C.chatFallbackL,
                  ),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: dark ? const Color(0x66000000) : const Color(0x24FFFFFF),
                ),
              ),
            ],
          );
        }
        if (presetColors != null) {
          return Stack(
            fit: StackFit.expand,
            children: [
              _gradientBox(presetColors),
              CustomPaint(
                painter: _DoodlePattern(
                  color: ChatBgSetting.isDarkPreset(bg.presetKey)
                      ? Colors.white.withValues(alpha: .05)
                      : Colors.white.withValues(alpha: .13),
                ),
              ),
            ],
          );
        }
        // default: brand surface + very subtle pattern
        return Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(
                color: dark ? C.chatFallbackD : C.chatFallbackL),
            CustomPaint(
              painter: _DoodlePattern(
                color: dark
                    ? Colors.white.withValues(alpha: .022)
                    : const Color(0x06000000),
              ),
            ),
          ],
        );
      },
    );
  }

  static Widget _gradientBox(List<Color> colors) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
      ),
    );
  }
}

/// Telegram-like faint doodle pattern: hearts / stars / circles drawn on a
/// deterministic grid — zero assets, GPU cheap (paints once per size).
class _DoodlePattern extends CustomPainter {
  final Color color;
  _DoodlePattern({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..color = color;
    final fill = Paint()..color = color.withValues(alpha: color.a);
    final rnd = math.Random(7); // deterministic
    const cell = 96.0;
    for (double y = cell / 2; y < size.height + cell; y += cell) {
      for (double x = cell / 2; x < size.width + cell; x += cell) {
        final dx = x + rnd.nextDouble() * 34 - 17;
        final dy = y + rnd.nextDouble() * 34 - 17;
        final kind = rnd.nextInt(3);
        final s = 9.0 + rnd.nextDouble() * 7;
        canvas.save();
        canvas.translate(dx, dy);
        canvas.rotate(rnd.nextDouble() * 0.9 - 0.45);
        switch (kind) {
          case 0: // circle
            canvas.drawCircle(Offset.zero, s * 0.5, paint);
            break;
          case 1: // star (5 lines)
            for (int i = 0; i < 5; i++) {
              final a = i * 2 * math.pi / 5 - math.pi / 2;
              final b = a + math.pi;
              canvas.drawLine(
                Offset(math.cos(a) * s * 0.5, math.sin(a) * s * 0.5),
                Offset(math.cos(b) * s * 0.5, math.sin(b) * s * 0.5),
                paint,
              );
            }
            break;
          default: // heart
            final path = Path()
              ..moveTo(0, s * 0.32)
              ..cubicTo(-s * 0.5, -s * 0.14, -s * 0.24, -s * 0.5, 0, -s * 0.2)
              ..cubicTo(s * 0.24, -s * 0.5, s * 0.5, -s * 0.14, 0, s * 0.32);
            canvas.drawPath(path, fill);
        }
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DoodlePattern old) => old.color != color;
}
