import 'package:flutter/material.dart';

/// Mirrors the backend's PROFILE_THEMES / AVATAR_FRAMES / CARD_BG_THEMES
/// (app.py) so the customize-profile sheet renders the exact same choices.
class ProPresets {
  ProPresets._();

  static const Map<String, List<Color>> profileThemes = {
    'default': [Color(0xFF7C3AED), Color(0xFF6D28D9), Color(0xFF4C1D95)],
    'steel': [Color(0xFF475569), Color(0xFF1E293B), Color(0xFF0F172A)],
    'gold': [Color(0xFFF59E0B), Color(0xFFB45309), Color(0xFF78350F)],
    'sky': [Color(0xFF38BDF8), Color(0xFF0284C7), Color(0xFF075985)],
    'crimson': [Color(0xFFFB7185), Color(0xFFBE123C), Color(0xFF4C0519)],
    'emerald': [Color(0xFF34D399), Color(0xFF059669), Color(0xFF064E3B)],
    'midnight': [Color(0xFF1E1B3A), Color(0xFF0D0D16), Color(0xFF000000)],
    'sunset': [Color(0xFFFB923C), Color(0xFFDB2777), Color(0xFF701A75)],
    'rosegold': [Color(0xFFFECDD3), Color(0xFFFB7185), Color(0xFF9D174D)],
    'obsidian': [Color(0xFF18181B), Color(0xFF09090B), Color(0xFF000000)],
    'icy': [Color(0xFFE0F2FE), Color(0xFF7DD3FC), Color(0xFF38BDF8)],
    'fire': [Color(0xFFFDE047), Color(0xFFF97316), Color(0xFFDC2626)],
    'aurora': [Color(0xFF22D3EE), Color(0xFF818CF8), Color(0xFFF472B6)],
  };

  /// Reverse lookup: backend cover_theme_css → theme key (for rendering
  /// other people's profiles without parsing CSS gradients).
  static const Map<String, String> cssToKey = {
    'radial-gradient(circle at 25% 15%, rgba(196,181,253,0.35) 0%, transparent 45%), linear-gradient(135deg, #7c3aed 0%, #6d28d9 55%, #4c1d95 100%)': 'default',
    'radial-gradient(circle at 75% 20%, rgba(148,163,184,0.30) 0%, transparent 45%), linear-gradient(135deg, #475569 0%, #1e293b 60%, #0f172a 100%)': 'steel',
    'radial-gradient(circle at 25% 20%, rgba(253,224,71,0.35) 0%, transparent 45%), linear-gradient(135deg, #f59e0b 0%, #b45309 55%, #78350f 100%)': 'gold',
    'radial-gradient(circle at 70% 15%, rgba(224,242,254,0.40) 0%, transparent 45%), linear-gradient(135deg, #38bdf8 0%, #0284c7 55%, #075985 100%)': 'sky',
    'radial-gradient(circle at 30% 20%, rgba(254,205,211,0.30) 0%, transparent 45%), linear-gradient(135deg, #fb7185 0%, #be123c 55%, #4c0519 100%)': 'crimson',
    'radial-gradient(circle at 70% 20%, rgba(167,243,208,0.35) 0%, transparent 45%), linear-gradient(135deg, #34d399 0%, #059669 55%, #064e3b 100%)': 'emerald',
    'radial-gradient(circle at 50% 10%, rgba(99,102,241,0.20) 0%, transparent 50%), linear-gradient(135deg, #1e1b3a 0%, #0d0d16 60%, #000000 100%)': 'midnight',
    'radial-gradient(circle at 25% 20%, rgba(253,186,116,0.35) 0%, transparent 45%), linear-gradient(135deg, #fb923c 0%, #db2777 55%, #701a75 100%)': 'sunset',
    'radial-gradient(circle at 30% 15%, rgba(255,228,230,0.40) 0%, transparent 45%), linear-gradient(135deg, #fecdd3 0%, #fb7185 45%, #9d174d 100%)': 'rosegold',
    'radial-gradient(circle at 60% 15%, rgba(56,189,248,0.18) 0%, transparent 50%), linear-gradient(135deg, #18181b 0%, #09090b 60%, #000000 100%)': 'obsidian',
  };

  static const List<(String, String)> avatarFrames = [
    ('dragon', 'Dragon'),
    ('moon', 'Moonlight'),
    ('gaming', 'Gamer'),
    ('sakura', 'Sakura'),
    ('forest', 'Forest'),
    ('sun', 'Sun'),
    ('ocean', 'Ocean'),
    ('void', 'Void'),
    ('frost', 'Frost'),
    ('grove', 'Grove'),
    ('lava', 'Lava'),
    ('bushido', 'Bushido'),
    ('celestial', 'Celestial'),
    ('crimson', 'Crimson'),
  ];

  static const Map<String, Color> cardBgThemes = {
    'default': Color(0xFF0A0A0F),
    'charcoal': Color(0xFF1C1C22),
    'slate': Color(0xFF1A2230),
    'graphite': Color(0xFF232323),
    'navy': Color(0xFF141B2E),
    'plum': Color(0xFF241A2E),
    'maroon': Color(0xFF2A1418),
    'forest': Color(0xFF132119),
    'espresso': Color(0xFF211A14),
    'ink': Color(0xFF12131C),
  };

  static String frameUrl(String key) => '/static/frames/frame_$key.png';

  static String themeLabel(String key, bool fa) => switch (key) {
        'default' => fa ? 'پیش‌فرض' : 'Default',
        'steel' => fa ? 'فولادی' : 'Steel',
        'gold' => fa ? 'طلایی' : 'Gold',
        'sky' => fa ? 'آسمانی' : 'Sky',
        'crimson' => fa ? 'سرخ' : 'Crimson',
        'emerald' => fa ? 'زمردی' : 'Emerald',
        'midnight' => fa ? 'نیمه‌شب' : 'Midnight',
        'sunset' => fa ? 'غروب' : 'Sunset',
        'rosegold' => fa ? 'رزگلد' : 'Rose gold',
        'obsidian' => fa ? ' ابسیدین' : 'Obsidian',
        'icy' => fa ? 'یخی' : 'Icy',
        'fire' => fa ? 'آتش' : 'Fire',
        'aurora' => fa ? 'شفق' : 'Aurora',
        _ => key,
      };
}
