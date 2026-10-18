import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart' as image_picker;

import '../../core/api_service.dart';
import '../../core/app_state.dart';
import '../../core/chat_bg.dart';
import '../../core/constants.dart';
import '../../core/i18n.dart';
import '../../core/socket_service.dart';
import '../auth/auth_screen.dart';
import '../widgets/common.dart';
import '../widgets/ravi_alerts.dart';
import 'contacts_page.dart';

/// Settings page — 1:1 with index.html `page-settings`:
/// Appearance / Account / Notifications & Sound / Privacy / About groups.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  bool _themeMenuOpen = false;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;

    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 110),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 18, 10, 8),
          child: Text(s.settingsTitle,
              style: TextStyle(
                  fontSize: 20, fontWeight: FontWeight.w800, color: p.text)),
        ),

        // ---------------- Appearance ----------------
        _groupLabel(p, s.grpAppearance),
        SectionCard(children: [
          ListRow(
            icon: Icons.brightness_6_outlined,
            title: s.displayMode,
            sub: _themeSub(s),
            trailing: AnimatedRotation(
              turns: _themeMenuOpen ? 0.25 : 0,
              duration: const Duration(milliseconds: 200),
              child: Icon(Icons.chevron_right_rounded, size: 17, color: p.text3),
            ),
            onTap: () => setState(() => _themeMenuOpen = !_themeMenuOpen),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 200),
            crossFadeState: _themeMenuOpen
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Container(
              margin: const EdgeInsets.fromLTRB(2, 6, 2, 2),
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: p.bgSoft,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: p.border),
              ),
              child: Row(
                children: [
                  _themeChoice(p, Icons.brightness_5_outlined, s.themeLight,
                      ThemeModePref.light),
                  _themeChoice(p, Icons.dark_mode_outlined, s.themeDark,
                      ThemeModePref.dark),
                  _themeChoice(p, Icons.devices_outlined, s.themeSystem,
                      ThemeModePref.system),
                ],
              ),
            ),
          ),
          ListRow(
            icon: Icons.colorize_outlined,
            title: s.accentTitle,
            sub: s.accentSub,
            trailing: ValueListenableBuilder<String>(
              valueListenable: AccentStore.key,
              builder: (context, key, _) => Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: AccentStore.of(Theme.of(context).brightness),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            onTap: _openAccentSheet,
          ),
          ListRow(
            icon: Icons.wallpaper_outlined,
            title: s.chatBg,
            sub: _wallpaperSub(),
            onTap: _openWallpaperSheet,
          ),
          ListRow(
            icon: Icons.language_outlined,
            title: s.language,
            sub: AppState.I.lang.value.label,
            trailing: _langSeg(p),
          ),
          ListRow(
            icon: Icons.format_size_rounded,
            title: s.textSize,
            sub: s.textSizeStandard,
            onTap: _openTextSizeSheet,
          ),
        ]),

        // ---------------- Account ----------------
        _groupLabel(p, s.grpAccount),
        SectionCard(children: [
          ListRow(
            icon: Icons.person_outline_rounded,
            title: s.myAccount,
            sub: _accountSub(),
            onTap: () => AppState.I.pageIndex.value = 3,
          ),
          ListRow(
            icon: Icons.contacts_outlined,
            title: s.contactsTitle,
            sub: s.contactsSub,
            onTap: _openContacts,
          ),
          ListRow(
            icon: Icons.call_outlined,
            title: s.callsTitle,
            sub: s.callsEmptySub,
            onTap: _openCalls,
          ),
          ListRow(
            icon: Icons.phone_outlined,
            title: s.phone,
            sub: s.phoneSub,
          ),
        ]),

        // ---------------- Notifications ----------------
        _groupLabel(p, s.grpNotify),
        SectionCard(children: [
          ValueListenableBuilder<bool>(
            valueListenable: AppState.I.notificationsOn,
            builder: (_, v, __) => ListRow(
              icon: Icons.notifications_none_rounded,
              title: s.notifications,
              sub: s.notifSub,
              trailing: _toggle(p, v, AppState.I.setNotifications),
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: AppState.I.soundsOn,
            builder: (_, v, __) => ListRow(
              icon: Icons.volume_up_outlined,
              title: s.sounds,
              sub: s.soundsSub,
              trailing: _toggle(p, v, AppState.I.setSounds),
            ),
          ),
        ]),

        // ---------------- Privacy ----------------
        _groupLabel(p, s.grpPrivacy),
        SectionCard(children: [
          ListRow(
              icon: Icons.lock_outline_rounded,
              title: s.privacy,
              sub: s.privacySub,
              onTap: _openPrivacy),
          ListRow(
              icon: Icons.devices_outlined,
              title: s.sessionsTitle,
              sub: s.sessionsSub,
              onTap: _openSessions),
          ListRow(
              icon: Icons.shield_outlined,
              title: s.passwordLogin,
              sub: s.passwordSub,
              onTap: _openPrivacy),
        ]),

        // ---------------- About ----------------
        _groupLabel(p, s.grpAbout),
        SectionCard(children: [
          ListRow(icon: Icons.info_outline_rounded, title: s.aboutRavi, sub: s.aboutSub),
        ]),
      ],
    );
  }

  String _themeSub(S s) => switch (AppState.I.themePref.value) {
        ThemeModePref.light => s.themeLight,
        ThemeModePref.dark => s.themeDark,
        ThemeModePref.system => s.themeSystem,
      };

  // v1.0.8 — Contacts / Calls sub-pages
  void _openContacts() {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
      builder: (_) => _SubPageScaffold(
          title: s.contactsTitle, palette: p, child: const ContactsPage()),
    ));
  }

  // ---------- v1.0.9 — privacy & security (real backend logic) ----------
  void _openPrivacy() {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
      builder: (_) => PrivacyScreen(p: p),
    ));
  }

  // ---------- v1.0.9 — active sessions (real backend logic) ----------
  void _openSessions() {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
      builder: (_) => SessionsScreen(p: p),
    ));
  }

  void _openCalls() {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
      builder: (_) => _SubPageScaffold(
          title: s.callsTitle, palette: p, child: const CallsPage()),
    ));
  }

  String _wallpaperSub() {
    final bg = ChatBgStore.I.current.value;
    final fa = AppState.I.lang.value.isFa;
    if (bg.isDefault) return AppState.I.str.chatBgDefault;
    if (bg.serverUrl != null) return fa ? 'عکس اختصاصی' : 'Custom photo';
    return switch (bg.presetKey) {
      'grape' => fa ? 'انگوری' : 'Grape',
      'ocean' => fa ? 'اقیانوسی' : 'Ocean',
      'forest' => fa ? 'جنگلی' : 'Forest',
      'dawn' => fa ? 'سپیده' : 'Dawn',
      'sand' => fa ? 'شن‌زار' : 'Sand',
      'night' => fa ? 'شب' : 'Night',
      'charcoal' => fa ? 'ذغالی' : 'Charcoal',
      'wine' => fa ? 'شرابی' : 'Wine',
      _ => bg.presetKey,
    };
  }

  // ---------------- accent picker ----------------
  void _openAccentSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? C.bgElevD
          : Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        final dark = Theme.of(ctx).brightness == Brightness.dark;
        final s = AppState.I.str;
        final fa = AppState.I.lang.value.isFa;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(s.accentPickTitle,
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w800,
                        color: dark ? C.textD : C.textL)),
                const SizedBox(height: 18),
                ValueListenableBuilder<String>(
                  valueListenable: AccentStore.key,
                  builder: (context, sel, _) => Wrap(
                    spacing: 14,
                    runSpacing: 14,
                    alignment: WrapAlignment.center,
                    children: [
                      for (final key in AccentStore.keys)
                        GestureDetector(
                          onTap: () {
                            AppState.I.setAccent(key);
                            Future.delayed(
                                const Duration(milliseconds: 220),
                                () => Navigator.pop(ctx));
                          },
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 46,
                                height: 46,
                                decoration: BoxDecoration(
                                  color: AccentStore.palettes[key]![
                                      dark ? 1 : 0],
                                  shape: BoxShape.circle,
                                  border: sel == key
                                      ? Border.all(
                                          color: dark
                                              ? Colors.white
                                              : Colors.black87,
                                          width: 3)
                                      : null,
                                  boxShadow: [
                                    BoxShadow(
                                      color: AccentStore.palettes[key]![
                                              dark ? 1 : 0]
                                          .withValues(alpha: .4),
                                      blurRadius: 10,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: sel == key
                                    ? const Icon(Icons.check_rounded,
                                        color: Colors.white, size: 20)
                                    : null,
                              ),
                              const SizedBox(height: 6),
                              Text(AccentStore.label(key, fa),
                                  style: TextStyle(
                                      fontSize: 9.5,
                                      color: dark ? C.text2D : C.text2L)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---------------- chat wallpaper picker (with live preview) ----------------
  void _openWallpaperSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const _WallpaperSheet(),
    );
  }

  String _accountSub() {
    final me = ApiService.I.me();
    final name = me.name.isEmpty ? me.username : me.name;
    return '$name · @${me.username}';
  }

  Widget _groupLabel(Palette p, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 11, 10, 4),
      child: Text(label,
          style: TextStyle(fontSize: 10, color: p.text3,
              fontWeight: FontWeight.w600)),
    );
  }

  Widget _themeChoice(Palette p, IconData icon, String label, ThemeModePref mode) {
    final active = AppState.I.themePref.value == mode;
    return Expanded(
      child: GestureDetector(
        onTap: () => AppState.I.setThemePref(mode),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 9),
          decoration: BoxDecoration(
            color: active ? p.accentSoft : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 15, color: active ? p.accent : p.text2),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                      color: active ? p.accent : p.text2)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _langSeg(Palette p) {
    return Container(
      height: 30,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: p.bgSoft,
        borderRadius: BorderRadius.circular(15),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _langBtn(p, 'English', const Lang('en')),
          _langBtn(p, 'فارسی', const Lang('fa')),
        ],
      ),
    );
  }

  Widget _langBtn(Palette p, String label, Lang lang) {
    final active = AppState.I.lang.value.code == lang.code;
    return GestureDetector(
      onTap: () => AppState.I.setLang(lang),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? p.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 10.5,
                fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                color: active ? Colors.white : p.text2)),
      ),
    );
  }

  Widget _toggle(Palette p, bool on, ValueChanged<bool> onChange) {
    return GestureDetector(
      onTap: () => onChange(!on),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 38,
        height: 22,
        padding: const EdgeInsets.all(3),
        alignment: on ? Alignment.centerRight : Alignment.centerLeft,
        decoration: BoxDecoration(
          color: on
              ? p.accent
              : (Theme.of(context).brightness == Brightness.light
                  ? const Color(0xFFDCE1E5)
                  : const Color(0xFF39424B)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Container(
          width: 16,
          height: 16,
          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
        ),
      ),
    );
  }

  void _openTextSizeSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? C.bgElevD
          : Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        final p = Theme.of(ctx).brightness == Brightness.dark
            ? const Palette.dark()
            : const Palette.light();
        final s = AppState.I.str;
        final fa = AppState.I.lang.value.isFa;
        // v1.0.9 — REAL labels (Small/Standard/Large/Extra — the old sheet
        // showed "Standard" for every row) + a live chat preview bubble that
        // scales with the choice.
        final choices = <(double, String)>[
          (0.9, fa ? 'کوچک' : 'Small'),
          (1.0, s.textSizeStandard),
          (1.15, fa ? 'بزرگ' : 'Large'),
          (1.3, fa ? 'خیلی بزرگ' : 'Extra large'),
        ];
        return SafeArea(
          child: StatefulBuilder(builder: (ctx2, setSt) {
            final scale = AppState.I.textScale.value;
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(s.textSize,
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w800, color: p.text)),
                  Text(s.textSizeSub,
                      style: TextStyle(fontSize: 11.5, color: p.text2)),
                  const SizedBox(height: 14),
                  // ---- live preview ----
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: p.bgSoft,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(children: [
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: p.bgCard,
                            borderRadius: BorderRadius.circular(13),
                            border: Border.all(color: p.border),
                          ),
                          child: Text(
                            fa ? 'صبحه؟' : 'Morning?',
                            style: TextStyle(
                                fontSize: 13 * scale,
                                color: p.text,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(colors: [
                              Color(0xFF7C3AED),
                              Color(0xFF5B21B6)
                            ]),
                            borderRadius: BorderRadius.circular(13),
                          ),
                          child: Text(
                            fa ? 'نه توی توکیو اینجا شبه' : 'Nope, it\'s night in Tokyo',
                            style: TextStyle(
                                fontSize: 13 * scale, color: Colors.white,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 14),
                  ...choices.map((c) {
                    final active = (scale - c.$1).abs() < 0.01;
                    return ListTile(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      tileColor: active ? p.accentSoft : null,
                      leading: active
                          ? Icon(Icons.check_circle_rounded,
                              color: p.accent, size: 20)
                          : Icon(Icons.circle_outlined,
                              color: p.text3, size: 20),
                      title: Text(c.$2,
                          style: TextStyle(
                              fontSize: 13.5 * (c.$1 > 1.0 ? 1.06 : 1.0),
                              color: active ? p.accent : p.text,
                              fontWeight:
                                  active ? FontWeight.w700 : FontWeight.w500)),
                      onTap: () {
                        AppState.I.setTextScale(c.$1);
                        setSt(() {});
                      },
                    );
                  }),
                ],
              ),
            );
          }),
        );
      },
    );
  }
}

/// Logout helper (used by profile page too).
Future<void> confirmLogout(BuildContext context) async {
  final s = AppState.I.str;
  final dark = Theme.of(context).brightness == Brightness.dark;
  final ok = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: dark ? C.bgElevD : Colors.white,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(s.logout,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(s.logoutSub,
                style: TextStyle(fontSize: 13,
                    color: dark ? C.text2D : C.text2L)),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(15))),
                    child: Text(s.cancel),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFEF4444),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(15))),
                    child: Text(s.logout),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  if (ok == true && context.mounted) {
    await ApiService.I.logout();
    SocketService.I.configure(cookie: '');
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true)
          .pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const AuthScreen()),
              (r) => false);
    }
  }
}

// ==================== wallpaper picker sheet (live preview) ====================

class _WallpaperSheet extends StatefulWidget {
  const _WallpaperSheet();

  @override
  State<_WallpaperSheet> createState() => _WallpaperSheetState();
}

class _WallpaperSheetState extends State<_WallpaperSheet> {
  String _selected = ChatBgStore.I.current.value.presetKey;
  bool _uploading = false;

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;
    final h = MediaQuery.of(context).size.height;

    return Container(
      height: h * 0.82,
      decoration: BoxDecoration(
        color: p.bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 12),
          Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                  color: p.border, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 10),
          Text(s.wallpaperTitle,
              style: TextStyle(
                  fontSize: 16.5, fontWeight: FontWeight.w800, color: p.text)),
          const SizedBox(height: 4),
          Text(s.wallpaperSub,
              style: TextStyle(fontSize: 11.5, color: p.text2)),
          const SizedBox(height: 12),

          // ---------- live preview ----------
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: SizedBox(
                height: 190,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // background preview (mirrors ChatBgStore.buildBackground)
                    _previewBackground(p),
                    // mini chat preview content (v1.0.9: real dialogue + voice)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: _miniBubble(
                                AppState.I.lang.value.isFa ? 'صبحه؟' : 'Morning?',
                                false, p,
                                dark: _selectedDark()),
                          ),
                          const SizedBox(height: 7),
                          Align(
                            alignment: AlignmentDirectional.centerEnd,
                            child: _miniBubble(
                                AppState.I.lang.value.isFa
                                    ? 'نه توی توکیو اینجا شبه'
                                    : 'Nope, night in Tokyo',
                                true, p,
                                dark: _selectedDark()),
                          ),
                          const SizedBox(height: 7),
                          Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: _miniVoice(p, dark: _selectedDark()),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(children: [
              Icon(Icons.visibility_outlined, size: 12, color: p.text3),
              const SizedBox(width: 5),
              Text(s.previewLabel,
                  style: TextStyle(fontSize: 10.5, color: p.text3)),
            ]),
          ),
          const SizedBox(height: 10),

          // ---------- presets / pack / customs / bubble colors ----------
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
              children: [
                // -- v1.0.9 — your wallpapers (uploaded photos) --
                ValueListenableBuilder<List<String>>(
                  valueListenable: ChatBgStore.I.customs,
                  builder: (context, customs, _) {
                    if (customs.isEmpty) return const SizedBox.shrink();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _sectionLabel(p, s.myWallpapers),
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 4,
                            mainAxisSpacing: 10,
                            crossAxisSpacing: 10,
                            childAspectRatio: 0.82,
                          ),
                          itemCount: customs.length,
                          itemBuilder: (ctx, i) => _customTile(p, customs[i]),
                        ),
                        const SizedBox(height: 10),
                      ],
                    );
                  },
                ),
                // -- pack backgrounds --
                _sectionLabel(p, s.bgPackTitle),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 0.82,
                  ),
                  itemCount: ChatBgSetting.pack.length,
                  itemBuilder: (context, i) {
                    final item = ChatBgSetting.pack[i];
                    return _assetTile(p, item.$1, item.$2);
                  },
                ),
                const SizedBox(height: 10),
                // -- gradient presets --
                _sectionLabel(p, s.chatBgDefault),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 0.82,
                  ),
                  itemCount: ChatBgSetting.presets.length + 1,
                  itemBuilder: (context, i) {
                    if (i == 0) {
                      return _bgTile(p, '', null, s.resetWallpaper);
                    }
                    final preset = ChatBgSetting.presets[i - 1];
                    return _bgTile(p, preset.$1, preset.$2, preset.$1);
                  },
                ),
                const SizedBox(height: 12),
                // -- v1.0.9 — bubble colors --
                _sectionLabel(p, s.bubbleColor),
                Text(s.bubbleColorSub,
                    style: TextStyle(fontSize: 10.5, color: p.text3)),
                const SizedBox(height: 8),
                ValueListenableBuilder<String>(
                  valueListenable: BubbleColorStore.I.key,
                  builder: (context, bk, _) => Wrap(
                    spacing: 9,
                    runSpacing: 9,
                    children: [
                      for (final c in BubbleColorStore.presets)
                        GestureDetector(
                          onTap: () => BubbleColorStore.I.set(c.$1),
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(colors: [c.$2, c.$3]),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: bk == c.$1
                                    ? p.text
                                    : Colors.transparent,
                                width: 2.2,
                              ),
                            ),
                            child: bk == c.$1
                                ? const Icon(Icons.check_rounded,
                                    size: 18, color: Colors.white)
                                : null,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
              ],
            ),
          ),

          // ---------- custom photo ----------
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 14),
              child: Row(children: [
                Expanded(
                  child: GestureDetector(
                    onTap: _uploadPhoto,
                    child: Container(
                      height: 46,
                      decoration: BoxDecoration(
                        color: p.accentSoft,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                            color: p.accent.withValues(alpha: .3)),
                      ),
                      alignment: Alignment.center,
                      child: _uploading
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: p.accent))
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.image_outlined,
                                    size: 17, color: p.accent),
                                const SizedBox(width: 7),
                                Text(s.useCustomPhoto,
                                    style: TextStyle(
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w800,
                                        color: p.accent)),
                              ],
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                GestureDetector(
                  onTap: _removePhoto,
                  child: Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: const Color(0xFFEF4444).withValues(alpha: .1),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(Icons.delete_outline_rounded,
                        size: 19, color: Color(0xFFEF4444)),
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  bool _selectedDark() {
    if (_selected.startsWith('url:')) return false;
    return ChatBgSetting.isDarkPreset(_selected);
  }

  Widget _sectionLabel(Palette p, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7, top: 4),
      child: Text(label,
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: p.text3)),
    );
  }

  /// v1.0.9 — a tiny voice-message bubble for the preview (like the real one).
  Widget _miniVoice(Palette p, {bool dark = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF242C36) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(color: Color(0x1A000000), blurRadius: 5, offset: Offset(0, 2))
        ],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 22,
          height: 22,
          decoration: const BoxDecoration(
              gradient: C.ownBubbleGrad, shape: BoxShape.circle),
          child: const Icon(Icons.play_arrow_rounded,
              size: 14, color: Colors.white),
        ),
        const SizedBox(width: 7),
        SizedBox(
          width: 64,
          height: 12,
          child: CustomPaint(painter: _MiniWavePainter(color: p.text3)),
        ),
        const SizedBox(width: 6),
        Text('0:07',
            style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: p.text3)),
      ]),
    );
  }

  /// v1.0.9 — a tile of the user's uploaded wallpapers with a remove button.
  Widget _customTile(Palette p, String serverUrl) {
    final key = 'url:$serverUrl';
    final selected = _selected == key;
    return GestureDetector(
      onTap: () {
        setState(() => _selected = key);
        ChatBgStore.I.set(ChatBgSetting(presetKey: key));
      },
      child: Column(children: [
        Stack(children: [
          Container(
            height: 62,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: selected ? p.accent : p.border,
                  width: selected ? 2.2 : 1),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: CachedNetworkImage(
                imageUrl: ApiService.I.absoluteUrl(serverUrl),
                fit: BoxFit.cover,
                memCacheWidth: 160,
                httpHeaders: {'Cookie': ApiService.I.cookieHeader},
                errorWidget: (_, __, ___) =>
                    ColoredBox(color: p.bgSoft),
              ),
            ),
          ),
          PositionedDirectional(
            top: 3, end: 3,
            child: GestureDetector(
              onTap: () => ChatBgStore.I.removeCustom(serverUrl),
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .55),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close_rounded,
                    size: 11, color: Colors.white),
              ),
            ),
          ),
        ]),
      ]),
    );
  }

  /// v1.0.9 — a tile from the bundled pack.
  Widget _assetTile(Palette p, String file, String label) {
    final key = 'asset:$file';
    final selected = _selected == key;
    return GestureDetector(
      onTap: () {
        setState(() => _selected = key);
        ChatBgStore.I.set(ChatBgSetting(presetKey: key));
      },
      child: Column(children: [
        Stack(children: [
          Container(
            height: 62,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: selected ? p.accent : p.border,
                  width: selected ? 2.2 : 1),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.asset('assets/backgrounds/$file',
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => ColoredBox(color: p.bgSoft)),
            ),
          ),
        ]),
        const SizedBox(height: 4),
        Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 9.5, color: p.text3)),
      ]),
    );
  }

  Widget _previewBackground(Palette p) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // v1.0.6: the live preview now shows the custom photo too (it used to
    // render an empty box — "پیش‌نمایشش زشته")
    if (_selected.startsWith('url:')) {
      final url = ApiService.I.absoluteUrl(_selected.substring(4));
      return Stack(fit: StackFit.expand, children: [
        Image.network(
          url,
          fit: BoxFit.cover,
          headers: {'Cookie': ApiService.I.cookieHeader},
          errorBuilder: (_, __, ___) => DecoratedBox(
            decoration: BoxDecoration(
                color: dark ? C.chatFallbackD : C.chatFallbackL),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
              color: dark ? const Color(0x66000000) : const Color(0x24FFFFFF)),
        ),
      ]);
    }
    final colors = ChatBgSetting.colorsFor(_selected);
    if (colors != null) {
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: dark ? C.chatFallbackD : C.chatFallbackL,
      ),
    );
  }

  Widget _miniBubble(String text, bool own, Palette p, {bool dark = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        gradient: own ? C.ownBubbleGrad : null,
        color: own ? null : (dark ? const Color(0xFF242C36) : Colors.white),
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(color: Color(0x1A000000), blurRadius: 5, offset: Offset(0, 2))
        ],
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 11,
              color: own
                  ? Colors.white
                  : (dark ? Colors.white : Colors.black87),
              fontWeight: FontWeight.w600)),
    );
  }

  Widget _bgTile(Palette p, String key, List<Color>? colors, String label) {
    final selected = _selected == key;
    return GestureDetector(
      onTap: () {
        setState(() => _selected = key);
        ChatBgStore.I.set(ChatBgSetting(presetKey: key));
      },
      child: Column(children: [
        Stack(children: [
          Container(
            height: 62,
            decoration: BoxDecoration(
              gradient: colors == null
                  ? null
                  : LinearGradient(colors: colors),
              color: colors == null
                  ? (Theme.of(context).brightness == Brightness.dark
                      ? C.chatFallbackD
                      : C.chatFallbackL)
                  : null,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: p.border),
            ),
            alignment: Alignment.center,
            child: selected
                ? Container(
                    width: 26,
                    height: 26,
                    decoration: const BoxDecoration(
                        color: Colors.white, shape: BoxShape.circle),
                    child: Icon(Icons.check_rounded,
                        size: 16, color: p.accent),
                  )
                : null,
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: selected
                      ? Border.all(color: p.accent, width: 2.2)
                      : null,
                ),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 4),
        Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 9.5, color: p.text3)),
      ]),
    );
  }

  Future<void> _uploadPhoto() async {
    if (_uploading) return;
    setState(() => _uploading = true);
    try {
      final x = await image_picker.ImagePicker()
          .pickImage(source: image_picker.ImageSource.gallery,
              maxWidth: 1800, imageQuality: 85);
      if (x == null) {
        setState(() => _uploading = false);
        return;
      }
      final r = await ApiService.I.uploadChatBg(x.path);
      if (r.ok && r.data != null) {
        // v1.0.9 — every upload lands in "Your wallpapers" (persistent list),
        // selectable later and removable from the panel.
        await ChatBgStore.I.addCustom(r.data!);
        if (mounted) {
          setState(() => _selected = 'url:${r.data}');
          showGlassToast(context, AppState.I.str.wallpaperAdded);
        }
      } else if (mounted) {
        showGlassToast(context, AppState.I.str.error,
            icon: Icons.error_outline_rounded, color: const Color(0xFFEF4444));
      }
    } catch (_) {
      if (mounted) {
        showGlassToast(context, AppState.I.str.error,
            icon: Icons.error_outline_rounded, color: const Color(0xFFEF4444));
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _removePhoto() async {
    if (_selected.startsWith('url:')) {
      await ChatBgStore.I.removeCustom(_selected.substring(4));
    } else {
      await ApiService.I.removeChatBg();
      await ChatBgStore.I.set(const ChatBgSetting());
    }
    if (mounted) setState(() => _selected = ChatBgStore.I.current.value.presetKey);
  }
}

/// Tiny waveform painter for the preview voice bubble.
class _MiniWavePainter extends CustomPainter {
  final Color color;
  _MiniWavePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: .75)
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final bars = [3.0, 6.0, 9.0, 5.0, 11.0, 7.0, 4.0, 8.0, 5.0, 10.0, 6.0, 3.0];
    final bw = size.width / bars.length;
    for (var i = 0; i < bars.length; i++) {
      final x = i * bw + bw / 2;
      final h = bars[i].clamp(2.0, size.height);
      canvas.drawLine(Offset(x, (size.height - h) / 2),
          Offset(x, (size.height + h) / 2), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _MiniWavePainter old) => old.color != color;
}

/// v1.0.8 — simple glass-styled sub page wrapper (Contacts / Calls).
class _SubPageScaffold extends StatelessWidget {
  final String title;
  final Palette palette;
  final Widget child;
  const _SubPageScaffold({
    required this.title,
    required this.palette,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: palette.bg,
      body: SafeArea(
        child: Column(children: [
          Container(
            height: 58,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: palette.bg,
              border:
                  Border(bottom: BorderSide(color: palette.borderSoft)),
            ),
            child: Row(children: [
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  width: 34, height: 34,
                  decoration: BoxDecoration(
                    color: palette.bgSoft,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.arrow_back_rounded,
                      size: 19, color: palette.text),
                ),
              ),
              const SizedBox(width: 12),
              Text(title,
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w800,
                      color: palette.text)),
            ]),
          ),
          Expanded(child: child),
        ]),
      ),
    );
  }
}

// ==================== v1.0.9 Privacy & Security ====================
/// Drives the REAL backend rules:
///  • privacy_last_seen: all / contacts / nobody — "nobody" shows the OTHER
///    side "last seen recently"-style labels instead of an exact time
///  • privacy_dm: who can open a chat with you (server enforces it on send)
class PrivacyScreen extends StatefulWidget {
  final Palette p;
  const PrivacyScreen({super.key, required this.p});

  @override
  State<PrivacyScreen> createState() => _PrivacyScreenState();
}

class _PrivacyScreenState extends State<PrivacyScreen> {
  String _lastSeen = 'all';
  String _dm = 'all';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await ApiService.I.getPrivacy();
    if (!mounted) return;
    if (r.ok && r.data != null) {
      setState(() {
        _lastSeen = '${r.data!['privacy_last_seen'] ?? 'all'}';
        _dm = '${r.data!['privacy_dm'] ?? 'all'}';
        _loading = false;
      });
    } else {
      setState(() => _loading = false);
    }
  }

  Future<void> _saveLastSeen(String v) async {
    setState(() => _lastSeen = v);
    final r = await ApiService.I.setPrivacy(lastSeen: v);
    if (mounted) {
      showGlassToast(context,
          r.ok ? AppState.I.str.privacySavedToast : AppState.I.str.error,
          icon: r.ok ? Icons.lock_rounded : Icons.error_outline_rounded,
          color: r.ok ? null : const Color(0xFFEF4444));
    }
  }

  Future<void> _saveDm(String v) async {
    setState(() => _dm = v);
    final r = await ApiService.I.setPrivacy(dm: v);
    if (mounted) {
      showGlassToast(context,
          r.ok ? AppState.I.str.privacySavedToast : AppState.I.str.error,
          icon: r.ok ? Icons.lock_rounded : Icons.error_outline_rounded,
          color: r.ok ? null : const Color(0xFFEF4444));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    final s = AppState.I.str;
    final fa = AppState.I.lang.value.isFa;
    final opts = <(String, String)>[
      ('all', s.privEveryone),
      ('contacts', s.privContacts),
      ('nobody', s.privNobody),
    ];

    return _SubPageScaffold(
      title: s.privacy,
      palette: p,
      child: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _card(p, [
                  _rowTitle(p, s.privacyLastSeenTitle, s.privacyLastSeenSub),
                  const SizedBox(height: 6),
                  for (final o in opts)
                    _optionRow(p, o.$2, _lastSeen == o.$1,
                        () => _saveLastSeen(o.$1)),
                  const SizedBox(height: 4),
                  // explain the "nobody" behaviour (Telegram-style labels)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                    child: Text(
                      fa
                          ? 'اگر «هیچ‌کس» را انتخاب کنید، دیگران «آخرین بازدید به‌تازگی» یا «مدتی پیش» می‌بینند — نه زمان دقیق.'
                          : 'With "Nobody", others see "last seen recently" or "a long time ago" — never the exact time.',
                      style: TextStyle(fontSize: 10.5, color: p.text3),
                    ),
                  ),
                ]),
                const SizedBox(height: 14),
                _card(p, [
                  _rowTitle(p, s.privacyDmTitle, s.privacyDmSub),
                  const SizedBox(height: 6),
                  for (final o in opts)
                    _optionRow(p, o.$2, _dm == o.$1, () => _saveDm(o.$1)),
                ]),
              ],
            ),
    );
  }

  Widget _card(Palette p, List<Widget> children) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: p.bgCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.border),
      ),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }

  Widget _rowTitle(Palette p, String title, String sub) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: TextStyle(
                fontSize: 13.5, fontWeight: FontWeight.w800, color: p.text)),
        const SizedBox(height: 2),
        Text(sub, style: TextStyle(fontSize: 11, color: p.text3)),
      ],
    );
  }

  Widget _optionRow(Palette p, String label, bool active, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
        child: Row(children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? p.accent : Colors.transparent,
              border: Border.all(
                  color:
                      active ? p.accent : p.text3.withValues(alpha: .5),
                  width: 1.7),
            ),
            child: active
                ? const Icon(Icons.check_rounded,
                    size: 13, color: Colors.white)
                : null,
          ),
          const SizedBox(width: 11),
          Text(label,
              style: TextStyle(
                  fontSize: 12.8,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active ? p.accent : p.text)),
        ]),
      ),
    );
  }
}

// ==================== v1.0.9 Active Sessions ====================
/// Real backend: /api/sessions (+revoke / revoke_all). Shows device, IP,
/// last activity and lets you terminate any session (or all others).
class SessionsScreen extends StatefulWidget {
  final Palette p;
  const SessionsScreen({super.key, required this.p});

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  List<Map<String, dynamic>> _sessions = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await ApiService.I.sessions();
    if (!mounted) return;
    setState(() {
      _sessions = r.data ?? const [];
      _loading = false;
    });
  }

  String _deviceLabel(String ua) {
    final u = ua.toLowerCase();
    if (u.contains('android')) return 'Android';
    if (u.contains('iphone') || u.contains('ios')) return 'iPhone';
    if (u.contains('windows')) return 'Windows';
    if (u.contains('mac')) return 'macOS';
    if (u.contains('linux')) return 'Linux';
    if (u.contains('dart')) return 'Ravi App';
    return 'Web';
  }

  IconData _deviceIcon(String ua) {
    final u = ua.toLowerCase();
    if (u.contains('android')) return Icons.android_rounded;
    if (u.contains('iphone') || u.contains('ios')) return Icons.phone_iphone_rounded;
    if (u.contains('windows') || u.contains('mac') || u.contains('linux')) {
      return Icons.computer_rounded;
    }
    return Icons.language_rounded;
  }

  String _fmtActive(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    final d = DateTime.now().difference(dt);
    final fa = AppState.I.lang.value.isFa;
    if (d.inMinutes < 1) return fa ? 'همین حالا' : 'just now';
    if (d.inMinutes < 60) {
      return fa ? '${d.inMinutes} دقیقه پیش' : '${d.inMinutes}m ago';
    }
    if (d.inHours < 24) return fa ? '${d.inHours} ساعت پیش' : '${d.inHours}h ago';
    return fa ? '${d.inDays} روز پیش' : '${d.inDays}d ago';
  }

  Future<void> _revoke(String sid) async {
    final r = await ApiService.I.revokeSession(sid);
    if (!mounted) return;
    showGlassToast(context,
        r.ok ? AppState.I.str.sessionTerminatedToast : AppState.I.str.error,
        icon: r.ok ? Icons.power_settings_new_rounded : Icons.error_outline_rounded,
        color: r.ok ? null : const Color(0xFFEF4444));
    _load();
  }

  Future<void> _revokeAll() async {
    final s = AppState.I.str;
    final ok = await showRaviModal(
      context,
      icon: Icons.power_settings_new_rounded,
      iconColor: const Color(0xFFEF4444),
      title: s.terminateAll,
      body: s.sessionsAllTerminated,
      okText: s.terminateSession,
      cancelText: s.cancel,
      danger: true,
    );
    if (!ok) return;
    final r = await ApiService.I.revokeAllSessions('');
    if (!mounted) return;
    showGlassToast(context,
        r.ok ? s.sessionsAllTerminated : s.error,
        icon: r.ok ? Icons.power_settings_new_rounded : Icons.error_outline_rounded,
        color: r.ok ? null : const Color(0xFFEF4444));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    final s = AppState.I.str;
    final current =
        _sessions.where((e) => e['is_current'] == true).toList();
    final others =
        _sessions.where((e) => e['is_current'] != true).toList();

    return _SubPageScaffold(
      title: s.sessionsTitle,
      palette: p,
      child: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final e in current) ...[
                  _sessionCard(p, e, s.sessionsCurrent, current: true),
                  const SizedBox(height: 14),
                ],
                if (others.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(s.sessionsOther,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: p.text3)),
                  ),
                  for (final e in others) ...[
                    _sessionCard(p, e, '', current: false),
                    const SizedBox(height: 8),
                  ],
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 46,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor:
                            const Color(0xFFEF4444).withValues(alpha: .12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                      onPressed: _revokeAll,
                      child: Text(s.terminateAll,
                          style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFFEF4444))),
                    ),
                  ),
                ] else
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Center(
                      child: Text(s.sessionsEmpty,
                          style: TextStyle(fontSize: 11.5, color: p.text3)),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _sessionCard(Palette p, Map<String, dynamic> e, String label,
      {required bool current}) {
    final ua = '${e['ua'] ?? ''}';
    final ip = '${e['ip'] ?? ''}';
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
      decoration: BoxDecoration(
        color: p.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: current ? p.accent.withValues(alpha: .4) : p.border),
      ),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: current
                ? p.accentSoft
                : p.bgSoft,
            shape: BoxShape.circle,
          ),
          child: Icon(_deviceIcon(ua),
              size: 19, color: current ? p.accent : p.text2),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Flexible(
                  child: Text(
                      label.isNotEmpty
                          ? label
                          : _deviceLabel(ua),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12.8,
                          fontWeight: FontWeight.w800,
                          color: p.text)),
                ),
                if (current) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF22C55E).withValues(alpha: .15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                        AppState.I.lang.value.isFa ? 'فعال' : 'ACTIVE',
                        style: const TextStyle(
                            fontSize: 7.5,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF22C55E))),
                  ),
                ],
              ]),
              const SizedBox(height: 2),
              Text('$ip · ${_fmtActive('${e['last_active'] ?? ''}')}',
                  style: TextStyle(fontSize: 10.5, color: p.text3)),
            ],
          ),
        ),
        if (!current)
          GestureDetector(
            onTap: () => _revoke('${e['sid'] ?? ''}'),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFEF4444).withValues(alpha: .1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(AppState.I.str.terminateSession,
                  style: const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFFEF4444))),
            ),
          ),
      ]),
    );
  }
}
