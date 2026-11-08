import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/api_service.dart';
import '../../core/app_state.dart';
import '../../core/i18n.dart';
import '../../core/socket_service.dart';
import '../home/home_shell.dart';

/// Auth screen — v2.0 commercial redesign ("premium glass"):
///  • always-dark deep-blue gradient backdrop (#0A1633 → #101B3E) with
///    slowly drifting glow orbs for depth
///  • glassmorphism card (frosted blur, white 8%/5% gradient fill,
///    white 12% border, radius 28) holding the whole form
///  • brand header: floating glyph with breathing neon glow, RAVI wordmark
///    (Inter, letterSpacing 8) + tagline; shrinks via AnimatedScale when the
///    keyboard opens instead of disappearing
///  • AnimatedAlign sliding-pill segmented Login/Register switch
///  • premium fields: white 5% fill, radius 18, floating labels, cyan
///    (#38BDF8) focus glow border, eye toggle, live inline helpers
///  • gradient CTA (#198FD5 → #7C3AED) with press-scale + in-button spinner
///  • staggered entrance choreography (card 600ms easeOutCubic, fields 60ms
///    apart), error box with shake, and a dimmed hand-off overlay while the
///    socket/chats bootstrap runs
///
/// The post-auth flow is unchanged: configure socket with the fresh session
/// cookie, connect, load chats cached-then-network, pushReplacement HomeShell.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> with TickerProviderStateMixin {
  // Same rule as the backend's edit_profile USERNAME_RE so a username picked
  // today can still be kept after later edits.
  static final RegExp _usernameRe = RegExp(r'^[A-Za-z0-9_]{3,20}$');

  // Register first: a brand-new install must land on SIGN UP (user request),
  // login stays one tap away on the same segmented switch.
  bool _showRegister = true;
  bool _busy = false;
  bool _handoff = false;
  bool _userInvalid = false;
  String? _error;
  String _gender = 'other';

  // ---- ambient / entrance controllers ----
  late final AnimationController _float = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 3200))
    ..repeat(reverse: true);
  late final AnimationController _orb = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 9000))
    ..repeat();
  late final AnimationController _entrance = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1150));
  late final AnimationController _shake = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 420));

  late final Animation<double> _brandIn = CurvedAnimation(parent: _entrance,
      curve: const Interval(0, .40, curve: Curves.easeOutCubic));
  // Card: 600ms fade + slide-up, easeOutCubic.
  late final Animation<double> _cardIn = CurvedAnimation(parent: _entrance,
      curve: const Interval(.05, .60, curve: Curves.easeOutCubic));
  // Fields stagger 60ms each (0.06 of the 1150ms controller).
  late final List<Animation<double>> _stag =
      List<Animation<double>>.generate(7, (int i) {
    return CurvedAnimation(
        parent: _entrance,
        curve: Interval(.10 + .06 * i, .40 + .06 * i,
            curve: Curves.easeOutCubic));
  });

  // login fields
  final _liUser = TextEditingController();
  final _liPass = TextEditingController();
  // register fields
  final _rgUser = TextEditingController();
  final _rgName = TextEditingController();
  final _rgPass = TextEditingController();

  @override
  void initState() {
    super.initState();
    _entrance.forward();
    // Rebuild on keystrokes so the inline helpers stay live.
    _rgUser.addListener(_onRegisterTextChanged);
    _rgPass.addListener(_onRegisterTextChanged);
  }

  void _onRegisterTextChanged() {
    if (mounted) setState(() => _userInvalid = false);
  }

  @override
  void dispose() {
    _float.dispose();
    _orb.dispose();
    _entrance.dispose();
    _shake.dispose();
    _liUser.dispose();
    _liPass.dispose();
    _rgUser.dispose();
    _rgName.dispose();
    _rgPass.dispose();
    super.dispose();
  }

  bool get _fa => AppState.I.lang.value.isFa;

  // ---------- auth flow (unchanged behaviour) ----------

  void _fail(String msg) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _error = msg);
    _shake.forward(from: 0);
  }

  void _setMode(bool register) {
    if (_showRegister == register) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _showRegister = register;
      _error = null;
    });
  }

  Future<void> _handoffToHome() async {
    if (!mounted) return;
    setState(() => _handoff = true);
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
    if (_busy || _handoff) return;
    setState(() => _error = null);
    final user = _liUser.text.trim();
    if (user.isEmpty || _liPass.text.isEmpty) {
      _fail(s.fillFields);
      return;
    }
    setState(() => _busy = true);
    final res = await ApiService.I.login(user, _liPass.text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (res.ok) {
      AppState.I.refreshIdentity();
      await _handoffToHome();
    } else {
      _fail(res.message == 'banned'
          ? s.bannedAccount
          : res.status == ApiStatus.networkError
              ? s.serverUnreachable
              : s.loginFailed);
    }
  }

  Future<void> _doRegister() async {
    final s = AppState.I.str;
    if (_busy || _handoff) return;
    setState(() => _error = null);
    final user = _rgUser.text.trim();
    if (user.isEmpty || _rgPass.text.isEmpty) {
      _fail(s.fillFields);
      return;
    }
    if (!_usernameRe.hasMatch(user)) {
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() => _userInvalid = true);
      _fail(s.fieldUsernameInvalid);
      return;
    }
    if (_rgPass.text.length < 4) {
      _fail(s.fieldPasswordShort);
      return;
    }
    setState(() => _busy = true);
    final res = await ApiService.I.register(user, _rgPass.text, _gender,
        _rgName.text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (res.ok) {
      AppState.I.refreshIdentity();
      await _handoffToHome();
    } else {
      _fail(res.status == ApiStatus.networkError
          ? s.serverUnreachable
          : s.registerFailed);
    }
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    final s = AppState.I.str;
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    // Viewport height inside the SafeArea (Scaffold already subtracts the
    // keyboard via resizeToAvoidBottomInset) — used to center the card when
    // the keyboard is closed.
    final minH = math.max(
        0.0,
        MediaQuery.sizeOf(context).height -
            MediaQuery.paddingOf(context).vertical -
            MediaQuery.viewInsetsOf(context).bottom);

    return Scaffold(
      backgroundColor: _kBgTop,
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [_kBgTop, _kBgBottom],
                ),
              ),
            ),
          ),
          // ---- drifting glow orbs (depth) ----
          Positioned(
              top: -130,
              right: -100,
              child: _GlowOrb(
                  size: 330, color: const Color(0x2B198FD5), anim: _orb)),
          Positioned(
              bottom: -160,
              left: -130,
              child: _GlowOrb(
                  size: 420,
                  color: const Color(0x307C3AED),
                  anim: _orb,
                  phase: .33)),
          Positioned(
              top: 150,
              left: -150,
              child: _GlowOrb(
                  size: 300,
                  color: const Color(0x1E38BDF8),
                  anim: _orb,
                  phase: .62)),
          Positioned.fill(
            child: SafeArea(
              child: SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: minH),
                  child: IntrinsicHeight(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Entrance(
                          anim: _brandIn,
                          dy: -14,
                          child: _BrandMark(
                            float: _float,
                            shrunk: keyboardOpen,
                            tagline: _fa
                                ? 'اتصال، گفتگو، بازی.'
                                : 'Connect, Chat, Play.',
                          ),
                        ),
                        const SizedBox(height: 26),
                        _Entrance(anim: _cardIn, dy: 26, child: _buildCard(s)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_handoff)
            _LoadingOverlay(label: _fa ? 'در حال ورود…' : 'Signing you in…'),
        ],
      ),
    );
  }

  // ---------- glass card ----------

  Widget _buildCard(S s) {
    return Container(
      decoration: const BoxDecoration(
        borderRadius: BorderRadius.all(Radius.circular(28)),
        boxShadow: [
          BoxShadow(
              color: Color(0x59000000),
              blurRadius: 44,
              offset: Offset(0, 22),
              spreadRadius: -8),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withValues(alpha: .08),
                  Colors.white.withValues(alpha: .05),
                ],
              ),
              border: Border.all(color: Colors.white.withValues(alpha: .12)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Entrance(
                  anim: _stag[0],
                  dy: 14,
                  child: _Segmented(
                    register: _showRegister,
                    onChanged: _setMode,
                    loginLabel: s.login,
                    registerLabel: s.register,
                  ),
                ),
                const SizedBox(height: 18),
                AnimatedSize(
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOut,
                  alignment: Alignment.topCenter,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    transitionBuilder: (child, anim) =>
                        FadeTransition(opacity: anim, child: child),
                    child: _showRegister
                        ? _registerFields(s, const ValueKey('reg'))
                        : _loginFields(s, const ValueKey('log')),
                  ),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  alignment: Alignment.topCenter,
                  child: _error == null
                      ? const SizedBox(width: double.infinity)
                      : Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _errorBox(_error!),
                        ),
                ),
                _Entrance(
                  anim: _stag[5],
                  dy: 16,
                  child: _Cta(
                    label: _showRegister ? s.register : s.login,
                    busy: _busy,
                    onTap: _showRegister ? _doRegister : _doLogin,
                  ),
                ),
                const SizedBox(height: 12),
                _Entrance(anim: _stag[6], dy: 12, child: _switchRow(s)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------- forms ----------

  Widget _loginFields(S s, Key key) {
    return Column(
      key: key,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(s.welcomeBack,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w800,
                color: Colors.white)),
        const SizedBox(height: 4),
        Text(s.loginSub,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12.5, color: Colors.white.withValues(alpha: .6))),
        const SizedBox(height: 16),
        _Entrance(
          anim: _stag[1],
          dy: 14,
          child: _AuthField(
            controller: _liUser,
            label: s.username,
            hint: s.usernameHint,
            icon: Icons.alternate_email_rounded,
            keyboardType: TextInputType.emailAddress,
            onSubmitted: () => FocusScope.of(context).nextFocus(),
          ),
        ),
        const SizedBox(height: 12),
        _Entrance(
          anim: _stag[2],
          dy: 14,
          child: _AuthField(
            controller: _liPass,
            label: s.password,
            hint: s.passwordHint,
            icon: Icons.lock_outline_rounded,
            obscure: true,
            textInputAction: TextInputAction.done,
            onSubmitted: _doLogin,
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _registerFields(S s, Key key) {
    final user = _rgUser.text;
    final pass = _rgPass.text;
    final Color userHelperColor;
    if (user.isEmpty) {
      userHelperColor = Colors.white.withValues(alpha: .40);
    } else if (_usernameRe.hasMatch(user)) {
      userHelperColor = const Color(0xFF34D399);
    } else {
      userHelperColor = _kRedSoft;
    }
    return Column(
      key: key,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(s.createAccount,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w800,
                color: Colors.white)),
        const SizedBox(height: 4),
        Text(s.registerSub,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12.5, color: Colors.white.withValues(alpha: .6))),
        const SizedBox(height: 16),
        _Entrance(
          anim: _stag[1],
          dy: 14,
          child: _AuthField(
            controller: _rgUser,
            label: s.username,
            hint: s.usernameHint,
            icon: Icons.alternate_email_rounded,
            keyboardType: TextInputType.emailAddress,
            error: _userInvalid,
            helper: s.usernameRule,
            helperColor: userHelperColor,
            onSubmitted: () => FocusScope.of(context).nextFocus(),
          ),
        ),
        const SizedBox(height: 12),
        _Entrance(
          anim: _stag[2],
          dy: 14,
          child: _AuthField(
            controller: _rgName,
            label: s.displayNameField,
            hint: _fa ? 'مثلاً رها' : 'e.g. Sara',
            icon: Icons.badge_outlined,
            onSubmitted: () => FocusScope.of(context).nextFocus(),
          ),
        ),
        const SizedBox(height: 12),
        _Entrance(
          anim: _stag[3],
          dy: 14,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 6),
                child: Text(s.gender,
                    style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.1,
                        color: Colors.white.withValues(alpha: .5))),
              ),
              _GenderPicker(
                value: _gender,
                onChanged: (v) => setState(() => _gender = v),
                maleLabel: s.genderMale,
                femaleLabel: s.genderFemale,
                otherLabel: s.genderOther,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _Entrance(
          anim: _stag[4],
          dy: 14,
          child: _AuthField(
            controller: _rgPass,
            label: s.password,
            hint: s.passwordHint,
            icon: Icons.lock_outline_rounded,
            obscure: true,
            textInputAction: TextInputAction.done,
            onSubmitted: _doRegister,
            helper: (pass.isNotEmpty && pass.length < 4)
                ? s.fieldPasswordShort
                : null,
            helperColor: _kRedSoft,
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  // ---------- error + footer ----------

  Widget _errorBox(String msg) {
    return AnimatedBuilder(
      animation: _shake,
      builder: (context, child) {
        final t = _shake.value;
        final dx = math.sin(t * math.pi * 4) * 7 * (1 - t);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: const Color(0x1AEF4444),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0x40EF4444)),
        ),
        child: Row(
          children: [
            const Icon(Icons.error_outline_rounded, color: _kRed, size: 18),
            const SizedBox(width: 9),
            Expanded(
              child: Text(msg,
                  style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: _kRedSoft)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _switchRow(S s) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
                _showRegister ? s.haveAccount : s.noAccount,
                maxLines: 1,
                style: TextStyle(
                    fontSize: 12.5,
                    color: Colors.white.withValues(alpha: .6))),
          ),
        ),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _setMode(!_showRegister),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Text(_showRegister ? s.login : s.register,
                style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: _kLinkCyan)),
          ),
        ),
      ],
    );
  }
}

// ===========================================================================
// Private building blocks
// ====================================================================================

const Color _kBgTop = Color(0xFF0A1633);
const Color _kBgBottom = Color(0xFF101B3E);
const Color _kFocusCyan = Color(0xFF38BDF8);
const Color _kLinkCyan = Color(0xFF7DD3FC);
const Color _kRed = Color(0xFFEF4444);
const Color _kRedSoft = Color(0xFFF87171);

/// Fade + slide entrance driven by an (already curved) animation.
class _Entrance extends StatelessWidget {
  const _Entrance({required this.anim, required this.child, this.dy = 16});

  final Animation<double> anim;
  final Widget child;
  final double dy;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: anim,
      builder: (context, child) => Opacity(
        opacity: anim.value,
        child: Transform.translate(
          offset: Offset(0, dy * (1 - anim.value)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// Slowly drifting ambient glow orb.
class _GlowOrb extends StatelessWidget {
  const _GlowOrb({
    required this.size,
    required this.color,
    required this.anim,
    this.phase = 0,
  });

  final double size;
  final Color color;
  final Animation<double> anim;
  final double phase;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: anim,
        builder: (context, _) {
          final t = anim.value + phase;
          final wave = math.sin(2 * math.pi * t);
          return Opacity(
            opacity: 0.82 + 0.18 * wave,
            child: Transform.translate(
              offset: Offset(wave * 16, math.cos(2 * math.pi * t) * 12),
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                      colors: [color, color.withValues(alpha: 0)]),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Brand header — floating glyph with a breathing neon glow, wordmark and
/// tagline. Shrinks (AnimatedScale) when the keyboard opens, never removed.
class _BrandMark extends StatelessWidget {
  const _BrandMark({
    required this.float,
    required this.shrunk,
    required this.tagline,
  });

  final Animation<double> float;
  final bool shrunk;
  final String tagline;

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: shrunk ? 0.72 : 1.0,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
      child: Column(
        children: [
          SizedBox(
            width: 124,
            height: 124,
            child: AnimatedBuilder(
              animation: float,
              builder: (context, _) {
                final t = Curves.easeInOut.transform(float.value);
                final dy = -6.0 * t;
                return Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    // soft brand glow
                    Container(
                      width: 150,
                      height: 150,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(colors: [
                          const Color(0xFF58B9EF)
                              .withValues(alpha: .10 + .08 * t),
                          const Color(0xFF58B9EF).withValues(alpha: 0),
                        ]),
                      ),
                    ),
                    // blurred neon copy behind the glyph
                    Opacity(
                      opacity: .45 + .25 * t,
                      child: Transform.scale(
                        scale: 1.16,
                        child: ImageFiltered(
                          imageFilter:
                              ui.ImageFilter.blur(sigmaX: 13, sigmaY: 13),
                          child: ColorFiltered(
                            colorFilter: const ColorFilter.mode(
                                Color(0xFF58B9EF), BlendMode.srcATop),
                            child: Transform.translate(
                              offset: Offset(0, dy),
                              child: Image.asset(
                                  'assets/images/logo_glyph.png',
                                  width: 104,
                                  height: 104),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Transform.translate(
                      offset: Offset(0, dy),
                      child: Image.asset('assets/images/logo_glyph.png',
                          width: 104, height: 104),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 10),
          // letterSpacing trails after the last glyph — nudge right to keep
          // the wordmark optically centered.
          Transform.translate(
            offset: const Offset(4, 0),
            child: const Text('RAVI',
                style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 25,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 8,
                    color: Colors.white)),
          ),
          const SizedBox(height: 4),
          Opacity(
            opacity: .75,
            child: Text(tagline,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 11.5,
                    letterSpacing: .6,
                    fontWeight: FontWeight.w500,
                    color: Colors.white.withValues(alpha: .9))),
          ),
        ],
      ),
    );
  }
}

/// Login / Register segmented switch with a sliding pill (AnimatedAlign).
class _Segmented extends StatelessWidget {
  const _Segmented({
    required this.register,
    required this.onChanged,
    required this.loginLabel,
    required this.registerLabel,
  });

  final bool register;
  final ValueChanged<bool> onChanged;
  final String loginLabel;
  final String registerLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 46,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: .08)),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            alignment: register ? Alignment.centerRight : Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: .5,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .13),
                  borderRadius: BorderRadius.circular(12),
                  border:
                      Border.all(color: Colors.white.withValues(alpha: .14)),
                  boxShadow: const [
                    BoxShadow(
                        color: Color(0x33000000),
                        blurRadius: 10,
                        offset: Offset(0, 3)),
                  ],
                ),
              ),
            ),
          ),
          Row(
            children: [
              _cell(loginLabel, !register, () => onChanged(false)),
              _cell(registerLabel, register, () => onChanged(true)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _cell(String label, bool active, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Center(
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 200),
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 13.5,
              fontWeight: active ? FontWeight.w800 : FontWeight.w600,
              color: active ? Colors.white : Colors.white.withValues(alpha: .55),
            ),
            child: Text(label),
          ),
        ),
      ),
    );
  }
}

/// Premium auth input: white 5% fill, radius 18, floating label, cyan focus
/// glow border, optional eye toggle and live helper text.
class _AuthField extends StatefulWidget {
  const _AuthField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.icon,
    this.obscure = false,
    this.keyboardType,
    this.textInputAction = TextInputAction.next,
    this.onSubmitted,
    this.helper,
    this.helperColor,
    this.error = false,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData icon;
  final bool obscure;
  final TextInputType? keyboardType;
  final TextInputAction textInputAction;
  final VoidCallback? onSubmitted;
  final String? helper;
  final Color? helperColor;
  final bool error;

  @override
  State<_AuthField> createState() => _AuthFieldState();
}

class _AuthFieldState extends State<_AuthField> {
  final FocusNode _focus = FocusNode();
  late bool _hidden = widget.obscure;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_rebuild);
    _focus.addListener(_rebuild);
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_rebuild);
    _focus.removeListener(_rebuild);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focus.hasFocus;
    final showLabel = focused || widget.controller.text.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Floating label above the field.
        AnimatedOpacity(
          duration: const Duration(milliseconds: 160),
          opacity: showLabel ? 1 : 0,
          child: Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 180),
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
                color: focused
                    ? _kFocusCyan
                    : Colors.white.withValues(alpha: .5),
              ),
              child: Text(widget.label),
            ),
          ),
        ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .05),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              width: focused || widget.error ? 1.4 : 1,
              color: widget.error
                  ? const Color(0x99EF4444)
                  : focused
                      ? _kFocusCyan.withValues(alpha: .85)
                      : Colors.white.withValues(alpha: .10),
            ),
            boxShadow: focused
                ? const [
                    BoxShadow(
                        color: Color(0x2938BDF8),
                        blurRadius: 18,
                        offset: Offset(0, 4)),
                  ]
                : const [],
          ),
          child: Row(
            children: [
              const SizedBox(width: 14),
              Icon(widget.icon,
                  size: 20,
                  color: focused
                      ? _kFocusCyan
                      : Colors.white.withValues(alpha: .45)),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focus,
                  obscureText: _hidden,
                  keyboardType: widget.keyboardType,
                  textInputAction: widget.textInputAction,
                  onSubmitted: (_) => widget.onSubmitted?.call(),
                  cursorColor: _kFocusCyan,
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                      height: 1.2),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: widget.hint,
                    hintStyle: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: Colors.white.withValues(alpha: .35)),
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: 15),
                  ),
                ),
              ),
              if (widget.obscure)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _hidden = !_hidden),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 12, 14, 12),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 160),
                      transitionBuilder: (child, anim) => FadeTransition(
                        opacity: anim,
                        child: ScaleTransition(scale: anim, child: child),
                      ),
                      child: Icon(
                        _hidden
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        key: ValueKey<bool>(_hidden),
                        size: 19,
                        color: Colors.white.withValues(alpha: .55),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (widget.helper != null)
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 6),
            child: Text(
              widget.helper!,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: widget.helperColor ??
                      Colors.white.withValues(alpha: .40)),
            ),
          ),
      ],
    );
  }
}

/// Gender segmented picker (male / female / other) with icons.
class _GenderPicker extends StatelessWidget {
  const _GenderPicker({
    required this.value,
    required this.onChanged,
    required this.maleLabel,
    required this.femaleLabel,
    required this.otherLabel,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final String maleLabel;
  final String femaleLabel;
  final String otherLabel;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _cell('male', Icons.male_rounded, maleLabel),
        const SizedBox(width: 8),
        _cell('female', Icons.female_rounded, femaleLabel),
        const SizedBox(width: 8),
        _cell('other', Icons.auto_awesome_rounded, otherLabel),
      ],
    );
  }

  Widget _cell(String v, IconData icon, String label) {
    final sel = value == v;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(v),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          height: 46,
          decoration: BoxDecoration(
            color: sel
                ? const Color(0x2438BDF8)
                : Colors.white.withValues(alpha: .05),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              width: 1.3,
              color: sel
                  ? const Color(0x8C38BDF8)
                  : Colors.white.withValues(alpha: .08),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 17,
                  color: sel
                      ? _kLinkCyan
                      : Colors.white.withValues(alpha: .55)),
              const SizedBox(width: 5),
              // Scale down instead of ever overflowing on tiny screens.
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(label,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: sel
                              ? Colors.white
                              : Colors.white.withValues(alpha: .6))),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Gradient CTA with press-scale animation and in-button spinner.
class _Cta extends StatefulWidget {
  const _Cta({required this.label, required this.busy, this.onTap});

  final String label;
  final bool busy;
  final VoidCallback? onTap;

  @override
  State<_Cta> createState() => _CtaState();
}

class _CtaState extends State<_Cta> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final enabled = !widget.busy && widget.onTap != null;
    return GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _down = true) : null,
      onTapCancel: enabled ? () => setState(() => _down = false) : null,
      onTapUp: enabled ? (_) => setState(() => _down = false) : null,
      onTap: enabled ? widget.onTap : null,
      child: AnimatedScale(
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        scale: _down ? 0.965 : 1.0,
        child: Container(
          height: 54,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF198FD5), Color(0xFF7C3AED)],
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF198FD5)
                    .withValues(alpha: widget.busy ? .12 : .38),
                blurRadius: 22,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: widget.busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.4, color: Colors.white))
              : Text(widget.label,
                  style: const TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: .3)),
        ),
      ),
    );
  }
}

/// Dimmed, blurred overlay shown while the post-auth bootstrap runs.
class _LoadingOverlay extends StatelessWidget {
  const _LoadingOverlay({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Container(
        color: const Color(0x8C0A1633),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .07),
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: Colors.white.withValues(alpha: .12)),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(14),
                    child: CircularProgressIndicator(
                        strokeWidth: 2.6, color: _kLinkCyan),
                  ),
                ),
                const SizedBox(height: 16),
                Text(label,
                    style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: .2,
                        color: Colors.white)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
