import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/api_service.dart';
import '../../core/app_state.dart';
import '../../core/constants.dart';
import '../../core/i18n.dart';
import '../../core/socket_service.dart';
import '../home/home_shell.dart';

/// Auth screen — compact, keyboard-aware login/register.
///
/// v1.0.9 — commercial redesign:
///  • the brand is now the TRANSPARENT neon-R glyph floating (soft bob +
///    breathing neon glow) — no box, no frame, no clipped square
///  • ambient glow orbs in the background for depth
///  • everything else keeps the v1.0.3 keyboard-aware structure
/// v1.0.3 redesign after the "page stretches forever" report:
///  • the brand block COLLAPSES as soon as the keyboard opens, so the form
///    always fits above it even on small phones
///  • ClampingScrollPhysics — no bounce/stretch overscroll that made the
///    page feel endlessly rubber-banded
///  • tighter vertical rhythm: everything fits 360×640 with the keyboard open
///  • standard TextField + InputDecoration everywhere (guaranteed hit-testing)
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen>
    with SingleTickerProviderStateMixin {
  // Register first: a brand-new install must land on SIGN UP (user request),
  // login stays one tap away on the same segmented switch.
  bool _showRegister = true;

  late final TickerProvider _vsync = this;
  late final AnimationController _float = AnimationController(
      vsync: _vsync, duration: const Duration(milliseconds: 2800))
    ..repeat(reverse: true);

  // login fields
  final _liUser = TextEditingController();
  final _liPass = TextEditingController();

  // register fields
  final _rgUser = TextEditingController();
  final _rgName = TextEditingController();
  final _rgPass = TextEditingController();

  String _gender = 'other';

  bool _liObscure = true, _rgObscure = true;
  bool _busyLogin = false, _busyRegister = false;
  String? _loginError, _registerError;

  @override
  void dispose() {
    _float.dispose();
    _liUser.dispose(); _liPass.dispose();
    _rgUser.dispose(); _rgName.dispose(); _rgPass.dispose();
    super.dispose();
  }

  bool get _dark => Theme.of(context).brightness == Brightness.dark;

  Future<void> _afterAuth() async {
    // v1.0.5 CRITICAL: rebuild the socket with the fresh session cookie —
    // without it the server drops every send_message as anonymous.
    SocketService.I.configure(cookie: ApiService.I.cookieHeader);
    SocketService.I.connect();
    await AppState.I.loadChatsCachedThenNetwork();
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true)
        .pushReplacement(MaterialPageRoute(builder: (_) => const HomeShell()));
  }

  Future<void> _doLogin() async {
    final s = AppState.I.str;
    setState(() { _loginError = null; });
    if (_liUser.text.trim().isEmpty || _liPass.text.isEmpty) {
      setState(() => _loginError = s.fillFields);
      return;
    }
    setState(() => _busyLogin = true);
    final res = await ApiService.I.login(_liUser.text.trim(), _liPass.text);
    if (!mounted) return;
    setState(() => _busyLogin = false);
    if (res.ok) {
      AppState.I.refreshIdentity();
      await _afterAuth();
    } else {
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() {
        _loginError = res.message == 'banned'
            ? s.bannedAccount
            : res.status == ApiStatus.networkError
                ? s.serverUnreachable
                : s.loginFailed;
      });
    }
  }

  Future<void> _doRegister() async {
    final s = AppState.I.str;
    setState(() { _registerError = null; });
    final user = _rgUser.text.trim();
    if (user.isEmpty || _rgPass.text.isEmpty) {
      setState(() => _registerError = s.fillFields);
      return;
    }
    // Same rule as the backend's edit_profile USERNAME_RE so a username
    // picked today can still be kept after later edits.
    if (!RegExp(r'^[A-Za-z0-9_]{3,20}$').hasMatch(user)) {
      setState(() => _registerError = s.fieldUsernameInvalid);
      return;
    }
    if (_rgPass.text.length < 4) {
      setState(() => _registerError = s.fieldPasswordShort);
      return;
    }
    setState(() => _busyRegister = true);
    final res = await ApiService.I.register(user, _rgPass.text, _gender, _rgName.text);
    if (!mounted) return;
    setState(() => _busyRegister = false);
    if (res.ok) {
      AppState.I.refreshIdentity();
      await _afterAuth();
    } else {
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() {
        _registerError = res.status == ApiStatus.networkError
            ? s.serverUnreachable
            : s.registerFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _dark ? const Palette.dark() : const Palette.light();
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Scaffold(
      backgroundColor: _dark ? C.pfBgD : C.bgL,
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          // ---- ambient glow orbs (depth, commercial feel) ----
          PositionedDirectional(
            top: -140,
            end: -100,
            child: _GlowOrb(size: 320, color: Color(0x24198FD5)),
          ),
          PositionedDirectional(
            bottom: -160,
            start: -120,
            child: _GlowOrb(
                size: 380,
                color: _dark
                    ? const Color(0x1E7C3AED)
                    : const Color(0x167C3AED)),
          ),
          SafeArea(
            child: SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.fromLTRB(
                  24, keyboardOpen ? 4 : 18, 24, keyboardOpen ? 12 : 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Brand collapses when the keyboard takes the screen — the
                  // form itself always stays visible and reachable.
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    transitionBuilder: (child, anim) => SizeTransition(
                      sizeFactor: anim,
                      axisAlignment: -1,
                      child: FadeTransition(opacity: anim, child: child),
                    ),
                    child: keyboardOpen
                        ? const SizedBox(
                            key: ValueKey('brand-off'),
                            width: double.infinity)
                        : _brand(p, const ValueKey('brand-on')),
                  ),
                  SizedBox(height: keyboardOpen ? 4 : 22),
                  _modeSwitch(p),
                  const SizedBox(height: 16),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    transitionBuilder: (child, anim) =>
                        FadeTransition(opacity: anim, child: child),
                    child: _showRegister
                        ? _registerForm(p, const ValueKey('reg'))
                        : _loginForm(p, const ValueKey('log')),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- shared building blocks ----------

  Widget _brand(Palette p, Key key) {
    // v1.0.9 — floating transparent glyph, NO frame/box: the neon R with a
    // soft breathing glow behind it, gently bobbing. A commercial wordmark
    // (lighter tracking, no gradient-over-text) sits underneath.
    return Column(
      key: key,
      children: [
        const SizedBox(height: 14),
        SizedBox(
          width: 132,
          height: 132,
          child: AnimatedBuilder(
            animation: _float,
            builder: (context, _) {
              final t = _float.value; // 0..1
              final dy = -7.0 * Curves.easeInOut.transform(t);
              final glow = 0.42 + 0.22 * Curves.easeInOut.transform(t);
              return Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  // neon glow — blurred tinted copy of the glyph behind
                  Positioned.fill(
                    child: Opacity(
                      opacity: glow,
                      child: Transform.scale(
                        scale: 1.16,
                        child: ImageFiltered(
                          imageFilter: ui.ImageFilter.blur(
                              sigmaX: 13, sigmaY: 13),
                          child: ColorFiltered(
                            colorFilter: const ColorFilter.mode(
                                Color(0xFF58B9EF), BlendMode.srcATop),
                            child: Transform.translate(
                              offset: Offset(0, dy),
                              child: Image.asset(
                                  'assets/images/logo_glyph.png'),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Transform.translate(
                    offset: Offset(0, dy),
                    child: Image.asset('assets/images/logo_glyph.png',
                        width: 118, height: 118),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        Text('RAVI',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 27,
              fontWeight: FontWeight.w800,
              letterSpacing: 7,
              color: p.text,
            )),
        const SizedBox(height: 5),
        Text(
          AppState.I.lang.value.isFa
              ? 'اتصال، گفتگو، بازی — همه در یک اپ'
              : 'Connect · Chat · Play — all in one',
          style: TextStyle(
              fontSize: 11.5, letterSpacing: .3, color: p.text2),
        ),
      ],
    );
  }

  Widget _modeSwitch(Palette p) {
    final s = AppState.I.str;
    return Container(
      height: 44,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: p.bgSoft,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          _segment(p, s.login, !_showRegister, () => setState(() => _showRegister = false)),
          _segment(p, s.register, _showRegister, () => setState(() => _showRegister = true)),
        ],
      ),
    );
  }

  Widget _segment(Palette p, String label, bool active, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? p.bgCard : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
            boxShadow: active
                ? [BoxShadow(
                    color: Colors.black.withValues(alpha: _dark ? 0.3 : 0.08),
                    blurRadius: 10, offset: const Offset(0, 2))]
                : const [],
          ),
          child: Text(label, style: TextStyle(
              fontSize: 13.5,
              fontWeight: active ? FontWeight.w700 : FontWeight.w600,
              color: active ? p.text : p.text2)),
        ),
      ),
    );
  }

  /// Vanilla, guaranteed-tappable input. No custom chrome beyond
  /// InputDecoration — the pattern Flutter itself documents.
  Widget _field({
    required TextEditingController ctl,
    required String hint,
    required IconData icon,
    bool obscure = false,
    Widget? suffix,
    TextInputAction action = TextInputAction.next,
    VoidCallback? onSubmitted,
    TextInputType? type,
  }) {
    final p = _dark ? const Palette.dark() : const Palette.light();
    return TextField(
      controller: ctl,
      obscureText: obscure,
      keyboardType: type,
      textInputAction: action,
      onSubmitted: (_) => onSubmitted?.call(),
      cursorColor: p.accent,
      enableInteractiveSelection: true,
      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: p.text, height: 1.2),
      decoration: InputDecoration(
        filled: true,
        fillColor: p.bgSoft,
        isDense: true,
        prefixIcon: Icon(icon, size: 20, color: p.text3),
        hintText: hint,
        hintStyle: TextStyle(fontSize: 13.5, color: p.text3, fontWeight: FontWeight.w500),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: BorderSide(color: p.border.withValues(alpha: .5)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: BorderSide(color: p.accent.withValues(alpha: .65), width: 1.4),
        ),
        suffixIcon: suffix,
        suffixIconConstraints: suffix == null ? const BoxConstraints() : null,
      ),
    );
  }

  Widget _cta({required String label, required bool busy, required VoidCallback onTap}) {
    return SizedBox(
      height: 52,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF198FD5), Color(0xFF7C3AED)],
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF198FD5).withValues(alpha: 0.35),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
          onPressed: busy ? null : onTap,
          child: busy
              ? const SizedBox(
                  width: 22, height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.4, color: Colors.white))
              : Text(label,
                  style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800)),
        ),
      ),
    );
  }

  Widget _errorBox(String msg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFEF4444).withValues(alpha: .1),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: .25)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: Color(0xFFEF4444), size: 18),
          const SizedBox(width: 9),
          Expanded(
            child: Text(msg,
                style: const TextStyle(fontSize: 12.5, color: Color(0xFFEF4444),
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  // ---------- forms ----------

  Widget _loginForm(Palette p, Key key) {
    final s = AppState.I.str;
    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(s.welcomeBack,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: p.text)),
        const SizedBox(height: 4),
        Text(s.loginSub,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: p.text2)),
        const SizedBox(height: 16),
        _field(
          ctl: _liUser, hint: s.usernameHint,
          icon: Icons.alternate_email_rounded,
          action: TextInputAction.next,
        ),
        const SizedBox(height: 11),
        _field(
          ctl: _liPass, hint: s.passwordHint,
          icon: Icons.lock_outline_rounded,
          obscure: _liObscure,
          action: TextInputAction.done,
          onSubmitted: _doLogin,
          suffix: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _liObscure = !_liObscure),
            child: Icon(_liObscure ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                size: 19, color: p.text3),
          ),
        ),
        const SizedBox(height: 14),
        if (_loginError != null) ...[
          _errorBox(_loginError!),
          const SizedBox(height: 11),
        ],
        _cta(label: s.login, busy: _busyLogin, onTap: _doLogin),
        const SizedBox(height: 14),
        _loginFormRow(p, s),
      ],
    );
  }

  Widget _registerForm(Palette p, Key key) {
    final s = AppState.I.str;
    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(s.createAccount,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: p.text)),
        const SizedBox(height: 4),
        Text(s.registerSub,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: p.text2)),
        const SizedBox(height: 14),
        _field(
          ctl: _rgUser, hint: s.usernameHint,
          icon: Icons.alternate_email_rounded,
          type: TextInputType.emailAddress,
          action: TextInputAction.next,
        ),
        const SizedBox(height: 10),
        _field(
          ctl: _rgName, hint: s.displayNameField,
          icon: Icons.badge_outlined,
          action: TextInputAction.next,
        ),
        const SizedBox(height: 10),
        _genderPicker(p),
        const SizedBox(height: 10),
        _field(
          ctl: _rgPass, hint: s.passwordHint,
          icon: Icons.lock_outline_rounded,
          obscure: _rgObscure,
          action: TextInputAction.done,
          onSubmitted: _doRegister,
          suffix: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _rgObscure = !_rgObscure),
            child: Icon(_rgObscure ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                size: 19, color: p.text3),
          ),
        ),
        const SizedBox(height: 14),
        if (_registerError != null) ...[
          _errorBox(_registerError!),
          const SizedBox(height: 11),
        ],
        _cta(label: s.register, busy: _busyRegister, onTap: _doRegister),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(s.haveAccount,
                    maxLines: 1,
                    style: TextStyle(fontSize: 12.5, color: p.text2)),
              ),
            ),
            TextButton(
              onPressed: () => setState(() => _showRegister = false),
              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6)),
              child: Text(s.login,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: p.accent)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _loginFormRow(Palette p, S s) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(s.noAccount,
                maxLines: 1,
                style: TextStyle(fontSize: 12.5, color: p.text2)),
          ),
        ),
        TextButton(
          onPressed: () => setState(() => _showRegister = true),
          style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6)),
          child: Text(s.register,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: p.accent)),
        ),
      ],
    );
  }

  Widget _genderPicker(Palette p) {
    final s = AppState.I.str;
    final opts = [
      ('male', Icons.male_rounded, s.genderMale),
      ('female', Icons.female_rounded, s.genderFemale),
      ('other', Icons.auto_awesome_rounded, s.genderOther),
    ];
    return Row(
      children: [
        for (final o in opts) ...[
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _gender = o.$1),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                height: 46,
                decoration: BoxDecoration(
                  color: _gender == o.$1 ? p.accentSoft : p.bgSoft,
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(
                    width: 1.4,
                    color: _gender == o.$1
                        ? p.accent.withValues(alpha: .5)
                        : Colors.transparent,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(o.$2, size: 17,
                        color: _gender == o.$1 ? p.accent : p.text3),
                    const SizedBox(width: 5),
                    // Scale down instead of ever overflowing on tiny screens.
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(o.$3, style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: _gender == o.$1 ? p.accent : p.text2)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (o != opts.last) const SizedBox(width: 8),
        ],
      ],
    );
  }
}

/// Soft ambient glow orb used behind the auth content.
class _GlowOrb extends StatelessWidget {
  final double size;
  final Color color;
  const _GlowOrb({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
        ),
      ),
    );
  }
}
