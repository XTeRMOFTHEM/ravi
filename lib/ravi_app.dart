import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/app_state.dart';
import 'core/constants.dart';
import 'core/i18n.dart';
import 'core/media_download_manager.dart';
import 'ui/auth/auth_screen.dart';
import 'ui/home/home_shell.dart';
import 'ui/splash_screen.dart';

class RaviApp extends StatefulWidget {
  const RaviApp({super.key});

  static final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

  static Route<Object?> onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case '/home':
        return _fade(const HomeShell(), settings);
      case '/auth':
        return _fade(const AuthScreen(), settings);
      default:
        return _fade(const SplashScreen(), settings);
    }
  }

  static PageRouteBuilder _fade(Widget page, RouteSettings settings) {
    return PageRouteBuilder(
      settings: settings,
      transitionDuration: const Duration(milliseconds: 260),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, anim, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
        child: child,
      ),
    );
  }

  @override
  State<RaviApp> createState() => _RaviAppState();
}

class _RaviAppState extends State<RaviApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Session died mid-app (cookie expired / server restart) → back to auth.
    AppState.I.kicked.addListener(_onKicked);
  }

  void _onKicked() {
    if (!AppState.I.kicked.value) return;
    AppState.I.kicked.value = false;
    RaviApp.navKey.currentState
        ?.pushNamedAndRemoveUntil('/auth', (route) => false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppState.I.kicked.removeListener(_onKicked);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: AccentStore.key,
      builder: (context, _, __) => ValueListenableBuilder<Lang>(
        valueListenable: AppState.I.lang,
        builder: (context, lang, _) {
          return ValueListenableBuilder<ThemeModePref>(
            valueListenable: AppState.I.themePref,
            builder: (context, pref, _) {
            return MaterialApp(
              title: kAppName,
              debugShowCheckedModeBanner: false,
              navigatorKey: RaviApp.navKey,
              theme: _buildTheme(Brightness.light),
              darkTheme: _buildTheme(Brightness.dark),
              themeMode: resolveTheme(pref, View.of(context).platformDispatcher.platformBrightness),
              locale: lang.isFa ? const Locale('fa') : const Locale('en'),
              supportedLocales: const [Locale('fa'), Locale('en')],
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              onGenerateRoute: RaviApp.onGenerateRoute,
              builder: (context, child) {
                // Global text scale (settings > text size) + font fallbacks.
                final mq = MediaQuery.of(context);
                // v1.4.0 — پل toast سراسری برای دانلودهای مدیا (بدون context)
                ToastBus.attach((msg) {
                  final overlay = Overlay.of(RaviApp.navKey.currentContext!, rootOverlay: true);
                  final entry = OverlayEntry(
                    builder: (_) => Positioned(
                      bottom: 96,
                      left: 0,
                      right: 0,
                      child: IgnorePointer(
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                            decoration: BoxDecoration(
                              color: Colors.black87,
                              borderRadius: BorderRadius.circular(30),
                            ),
                            child: Text(msg,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 13)),
                          ),
                        ),
                      ),
                    ),
                  );
                  overlay.insert(entry);
                  Future.delayed(
                      const Duration(milliseconds: 1800), () => entry.remove());
                });
                return ValueListenableBuilder<double>(
                  valueListenable: AppState.I.textScale,
                  builder: (context, scale, _) => MediaQuery(
                    data: mq.copyWith(textScaler: TextScaler.linear(scale)),
                    child: Directionality(
                      textDirection: lang.isRtl ? TextDirection.rtl : TextDirection.ltr,
                      child: child ?? const SizedBox.shrink(),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
      ),
    );
  }

  ThemeData _buildTheme(Brightness b) {
    final p = b == Brightness.light ? const Palette.light() : const Palette.dark();
    return ThemeData(
      brightness: b,
      useMaterial3: true,
      fontFamily: 'Vazirmatn',
      scaffoldBackgroundColor: p.bg,
      colorScheme: ColorScheme(
        brightness: b,
        primary: p.accent,
        onPrimary: Colors.white,
        secondary: C.bubOwn1,
        onSecondary: Colors.white,
        surface: p.bg,
        onSurface: p.text,
        error: const Color(0xFFEF4444),
        onError: Colors.white,
        // v1.0.7: pin the derived M3 tones that render as odd pale
        // yellow/gold lines (outlineVariant drives Dividers).
        outline: b == Brightness.dark
            ? const Color(0xFF3A424B)
            : const Color(0xFFD9DEE3),
        outlineVariant:
            b == Brightness.dark ? const Color(0xFF2A313A) : const Color(0xFFEDF0F2),
        surfaceContainerHighest:
            b == Brightness.dark ? const Color(0xFF232A32) : const Color(0xFFF1F4F6),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0x1424283C),
        thickness: 0.8,
        space: 1,
      ),
      textTheme: const TextTheme().apply(
        bodyColor: p.text,
        displayColor: p.text,
        fontFamily: 'Vazirmatn',
      ),
      splashFactory: InkSparkle.splashFactory,
      highlightColor: Colors.transparent,
      splashColor: Colors.transparent,
      appBarTheme: AppBarTheme(
        backgroundColor: p.bg,
        elevation: 0,
        systemOverlayStyle: b == Brightness.light
            ? SystemUiOverlayStyle.dark
            : SystemUiOverlayStyle.light,
      ),
    );
  }
}
