import 'package:flutter/material.dart';

import '../core/api_service.dart';
import '../core/app_state.dart';
import '../core/cache_service.dart';
import '../core/socket_service.dart';
import 'auth/auth_screen.dart';
import 'home/home_shell.dart';

/// Splash — bootstraps the session: checks the stored cookie, warms caches,
/// then routes to Home or Auth. Painted instantly from local assets so it
/// never flashes white.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 700));
  late final Animation<double> _scale =
      CurvedAnimation(parent: _c, curve: Curves.easeOutBack);
  bool _routed = false;

  @override
  void initState() {
    super.initState();
    _c.forward();
    _boot();
  }

  Future<void> _boot() async {
    // Give the splash its minimum beat (600ms) while real work happens.
    final sw = Stopwatch()..start();
    // v1.0.7 — NEVER bounce a valid session to /auth just because the probe
    // timed out ("keeps getting logged out"). Only an EXPLICIT 302/HTML
    // answer (unauthorized) means the cookie died; a timeout/network error
    // with a cached identity goes straight to Home (offline-first), which
    // paints from the disk cache and recovers when the network returns.
    final v = await ApiService.I.verifySession().timeout(
      const Duration(milliseconds: 4000),
      onTimeout: () => const ApiResult(ApiStatus.networkError),
    );
    final hasIdentity = ApiService.I.cachedUsername.isNotEmpty;
    final hasSession = v.ok || (v.status == ApiStatus.networkError && hasIdentity);

    if (v.ok) {
      await ApiService.I.ensureIdentity();
      AppState.I.refreshIdentity();
      // Warm chats cache → instant list.
      await Future.wait([
        AppState.I.loadChatsCachedThenNetwork(),
        CacheService.I.init(),
      ]);
      SocketService.I.connect();
    } else if (hasSession) {
      // Offline boot: paint caches, try a quiet reconnect in the background.
      await CacheService.I.init();
      await AppState.I.loadChatsCachedThenNetwork();
      SocketService.I.connect();
    }

    final left = const Duration(milliseconds: 600) - Duration(milliseconds: sw.elapsedMilliseconds);
    if (left.inMilliseconds > 0) await Future.delayed(left);
    if (!mounted || _routed) return;
    _routed = true;
    Navigator.of(context, rootNavigator: true).pushReplacement(MaterialPageRoute(
      builder: (_) => hasSession ? const HomeShell() : const AuthScreen(),
    ));
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark ? const Color(0xFF0A0A0F) : const Color(0xFF00278A);
    return Scaffold(
      backgroundColor: bg,
      body: Center(
        child: ScaleTransition(
          scale: _scale,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // v1.0.9 — the transparent neon-R glyph floating on the brand
              // gradient (no clipped square), matching the new icon.
              Image.asset('assets/images/logo_glyph.png',
                  width: 132, height: 132),
              const SizedBox(height: 18),
              Text(
                'RAVI',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 6,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Connect, Chat, Play',
                style: TextStyle(
                  fontSize: 11.5,
                  color: Colors.white.withValues(alpha: 0.72),
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
