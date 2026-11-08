import 'package:flutter/material.dart';

/// RAVI ships **not connected** to any backend — point this at your own
/// RAVI-compatible server (REST + Socket.IO), e.g. 'http://localhost:5000'.
const String kBaseUrl = '<your-backend-url>';

/// ------------------------------------------------------------------
/// Runtime accent color (Settings → Accent color).
/// A ValueNotifier key that every palette read resolves through, so the
/// whole app (Material theme + custom palette) recolors instantly.
/// ------------------------------------------------------------------
class AccentStore {
  AccentStore._();

  /// Currently selected accent key — persisted via AppState prefs.
  static final ValueNotifier<String> key = ValueNotifier<String>('blue');

  static const Map<String, List<Color>> palettes = {
    'blue': [Color(0xFF198FD5), Color(0xFF58B9EF)], // default
    'purple': [Color(0xFF7C3AED), Color(0xFFA78BFA)],
    'green': [Color(0xFF16A34A), Color(0xFF4ADE80)],
    'orange': [Color(0xFFEA580C), Color(0xFFFB923C)],
    'pink': [Color(0xFFDB2777), Color(0xFFF472B6)],
    'red': [Color(0xFFDC2626), Color(0xFFF87171)],
    'teal': [Color(0xFF0D9488), Color(0xFF2DD4BF)],
    'indigo': [Color(0xFF4F46E5), Color(0xFF818CF8)],
  };

  static const List<String> keys = [
    'blue', 'purple', 'indigo', 'teal', 'green', 'orange', 'pink', 'red'
  ];

  static String label(String key, bool fa) => switch (key) {
        'blue' => fa ? 'آبی (پیش‌فرض)' : 'Blue (default)',
        'purple' => fa ? 'بنفش' : 'Purple',
        'green' => fa ? 'سبز' : 'Green',
        'orange' => fa ? 'نارنجی' : 'Orange',
        'pink' => fa ? 'صورتی' : 'Pink',
        'red' => fa ? 'قرمز' : 'Red',
        'teal' => fa ? 'فیروزه‌ای' : 'Teal',
        'indigo' => fa ? 'نیلی' : 'Indigo',
        _ => key,
      };

  static Color of(Brightness b) {
    final pair = palettes[key.value] ?? palettes['blue']!;
    return b == Brightness.dark ? pair[1] : pair[0];
  }
}

const String kAppName = 'Ravi';
const String kBrandText = 'RAVI';

/// Design tokens taken 1:1 from the RAVI web index (CSS variables).
class C {
  // ---- Light theme (from :root) ----
  static const Color bgL = Color(0xFFFFFFFF);
  static const Color bgSoftL = Color(0xFFF4F6F7);
  static const Color bgCardL = Color(0xFFFFFFFF);
  static const Color bgElevL = Color(0xFFFFFFFF);
  static const Color borderL = Color(0xFFECEFF3);
  static const Color borderSoftL = Color(0xFFE7EBEF);
  static const Color textL = Color(0xFF252B32);
  static const Color text2L = Color(0xFF8C9298);
  static const Color text3L = Color(0xFFA2A8AD);
  static const Color accentL = Color(0xFF198FD5);
  static const Color accentSoftL = Color(0xFFE8F5FC);
  static const Color navBgL = Color(0xFAFFFFFF); // rgba(255,255,255,.98)
  static const Color overlayL = Color(0x40141C24); // rgba(20,28,36,.25)

  // chat surface (light) — v1.4.0: warm WhatsApp-ish paper for the chat bg
  static const Color chatFallbackL = Color(0xFFECE3D8);
  static const Color chatHeadBgL = Color(0xF2FFFFFF); // rgba(255,255,255,.95)
  static const Color chatHeadBorderL = Color(0x12000000); // rgba(0,0,0,.07)
  static const Color chatTextL = Color(0xFF1B2026);
  static const Color chatText2L = Color(0xFF6D7681);
  static const Color chatText3L = Color(0xFF9AA3AC);
  static const Color bubOtherL = Color(0xFFFFFFFF);
  static const Color bubOtherBorderL = Color(0x2114283C); // rgba(20,40,60,.13)
  static const Color bubOwn1 = Color(0xFF7C3AED); // purple gradient start
  static const Color bubOwn2 = Color(0xFF5B21B6); // purple gradient end
  static const Color chatInputBgL = Color(0xA8FFFFFF); // rgba(255,255,255,.66)
  static const Color chatInputTextL = Color(0xFF1B2026);
  static const Color chatInputPhL = Color(0x6B0F1E2D); // rgba(15,30,45,.42)

  // profile (light)
  static const Color pfNameL = Color(0xFF1A2028);
  static const Color pfHandleL = Color(0xFF7C5CF0);
  static const Color pfSubL = Color(0xFF6B7280);
  static const Color pfMetaL = Color(0xFF8A929C);
  static const Color pfCardL = Color(0xFFF6F7F9);
  static const Color pfCardBorderL = Color(0x0F14283C);
  static const Color pfBgL = Color(0xFFFFFFFF);
  static const Color pfDividerL = Color(0x1414283C);

  // ---- Dark theme (from body.dark) ----
  static const Color bgD = Color(0xFF101418);
  static const Color bgSoftD = Color(0xFF1B2127);
  static const Color bgCardD = Color(0xFF141A1F);
  static const Color bgElevD = Color(0xFF16161F);
  static const Color borderD = Color(0xFF242A30);
  static const Color borderSoftD = Color(0xFF252C32);
  static const Color textD = Color(0xFFEEF2F5);
  static const Color text2D = Color(0xFF87919A);
  static const Color text3D = Color(0xFF5C656E);
  static const Color accentD = Color(0xFF58B9EF);
  static const Color accentSoftD = Color(0xFF15384A);
  static const Color navBgD = Color(0xF5141A1F); // rgba(20,26,31,.96)
  static const Color overlayD = Color(0x59000000); // rgba(0,0,0,.35)

  // chat surface (dark)
  static const Color chatFallbackD = Color(0xFF0A0A12);
  static const Color chatHeadBgD = Color(0x9E0A0A12); // rgba(10,10,18,.62)
  static const Color chatHeadBorderD = Color(0x12FFFFFF);
  static const Color chatTextD = Color(0xFFF0F0F5);
  static const Color chatText2D = Color(0xFF8B8B9C);
  static const Color chatText3D = Color(0xFF555566);
  static const Color bubOtherD = Color(0xFF1E1E2A);
  static const Color bubOtherBorderD = Color(0x0FFFFFFF);
  static const Color chatInputBgD = Color(0x12FFFFFF); // rgba(255,255,255,.07)
  static const Color chatInputTextD = Color(0xFFFFFFFF);
  static const Color chatInputPhD = Color(0x52FFFFFF); // rgba(255,255,255,.32)

  // profile (dark)
  static const Color pfBgD = Color(0xFF0A0A0F);
  static const Color pfNameD = Color(0xFFFFFFFF);
  static const Color pfHandleD = Color(0xFFA78BFA);
  static const Color pfSubD = Color(0xFFB8BACB);
  static const Color pfMetaD = Color(0xFF6B6F84);
  static const Color pfCardD = Color(0xFF111118);
  static const Color pfCardBorderD = Color(0x0DFFFFFF);
  static const Color pfDividerD = Color(0x14FFFFFF);

  // misc
  static const Color badgeGrayL = Color(0xFFCBD1D7);
  static const Color badgeGrayD = Color(0xFF39424B);
  static const Color onlinePurple = Color(0xFFA855F7);
  static const Color recordRed = Color(0xFFEF4444);
  static const Color recordRedText = Color(0xFFF87171);

  // avatar gradients (a1..a4 like index)
  static const List<List<Color>> avatarGradients = [
    [Color(0xFF53B5ED), Color(0xFF1786C6)], // a1 blue
    [Color(0xFF9C7CF2), Color(0xFF6650C9)], // a2 purple
    [Color(0xFF55C59B), Color(0xFF269A75)], // a3 green
    [Color(0xFFFFB45C), Color(0xFFEF7D31)], // a4 orange
  ];

  static const LinearGradient ownBubbleGrad = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [bubOwn1, bubOwn2],
  );

  static const LinearGradient globeGrad = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF38BDF8), Color(0xFF2563EB)],
  );

  static const LinearGradient crAvatarGrad = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF8B5CF6), Color(0xFF6D28D9)],
  );
}

/// Full semantic palette resolved for the active brightness.
/// NOTE: `accent`/`accentSoft` are getters resolved through [AccentStore]
/// so that Settings → Accent color recolors the entire app at runtime.
@immutable
class Palette {
  final Brightness brightness;
  final Color bg, bgSoft, bgCard, bgElev, border, borderSoft;
  final Color text, text2, text3, navBg, overlay;

  Color get accent => AccentStore.of(brightness);
  Color get accentSoft => brightness == Brightness.light
      ? const Color(0xFFE8F5FC)
      : const Color(0xFF15384A);
  final Color chatFallback, chatHeadBg, chatHeadBorder;
  final Color chatText, chatText2, chatText3;
  final Color bubOther, bubOtherBorder, chatInputBg, chatInputText, chatInputPh;
  final Color pfBg, pfName, pfHandle, pfSub, pfMeta, pfCard, pfCardBorder, pfDivider;
  final Color badgeGray;

  const Palette.light()
      : brightness = Brightness.light,
        bg = C.bgL, bgSoft = C.bgSoftL, bgCard = C.bgCardL, bgElev = C.bgElevL,
        border = C.borderL, borderSoft = C.borderSoftL,
        text = C.textL, text2 = C.text2L, text3 = C.text3L,
        navBg = C.navBgL, overlay = C.overlayL,
        chatFallback = C.chatFallbackL, chatHeadBg = C.chatHeadBgL,
        chatHeadBorder = C.chatHeadBorderL,
        chatText = C.chatTextL, chatText2 = C.chatText2L, chatText3 = C.chatText3L,
        bubOther = C.bubOtherL, bubOtherBorder = C.bubOtherBorderL,
        chatInputBg = C.chatInputBgL, chatInputText = C.chatInputTextL,
        chatInputPh = C.chatInputPhL,
        pfBg = C.pfBgL, pfName = C.pfNameL, pfHandle = C.pfHandleL,
        pfSub = C.pfSubL, pfMeta = C.pfMetaL, pfCard = C.pfCardL,
        pfCardBorder = C.pfCardBorderL, pfDivider = C.pfDividerL,
        badgeGray = C.badgeGrayL;

  const Palette.dark()
      : brightness = Brightness.dark,
        bg = C.bgD, bgSoft = C.bgSoftD, bgCard = C.bgCardD, bgElev = C.bgElevD,
        border = C.borderD, borderSoft = C.borderSoftD,
        text = C.textD, text2 = C.text2D, text3 = C.text3D,
        navBg = C.navBgD, overlay = C.overlayD,
        chatFallback = C.chatFallbackD, chatHeadBg = C.chatHeadBgD,
        chatHeadBorder = C.chatHeadBorderD,
        chatText = C.chatTextD, chatText2 = C.chatText2D, chatText3 = C.chatText3D,
        bubOther = C.bubOtherD, bubOtherBorder = C.bubOtherBorderD,
        chatInputBg = C.chatInputBgD, chatInputText = C.chatInputTextD,
        chatInputPh = C.chatInputPhD,
        pfBg = C.pfBgD, pfName = C.pfNameD, pfHandle = C.pfHandleD,
        pfSub = C.pfSubD, pfMeta = C.pfMetaD, pfCard = C.pfCardD,
        pfCardBorder = C.pfCardBorderD, pfDivider = C.pfDividerD,
        badgeGray = C.badgeGrayD;
}
