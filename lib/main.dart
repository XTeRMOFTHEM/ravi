import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/api_service.dart';
import 'core/app_state.dart';
import 'core/cache_service.dart';
import 'core/chat_bg.dart';
import 'core/socket_service.dart';
import 'ravi_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Telegram-style: lock to portrait (chat apps don't rotate; also saves a
  // whole layout rebuild pass and keeps IME behaviour predictable).
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
  ));

  // v1.0.5: never show the ugly gray-red ErrorWidget in release — a soft,
  // themed placeholder keeps the app usable (fixes the "gray box" reports).
  ErrorWidget.builder = (details) {
    if (details.exception is FlutterError) {
      FlutterError.presentError(details);
    }
    return Container(
      color: const Color(0x00FFFFFF),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(16),
      child: const SizedBox.shrink(),
    );
  };

  await Future.wait([
    ApiService.I.init(),
    CacheService.I.init(),
    ChatBgStore.I.load(),
    BubbleColorStore.I.load(),
  ]);
  await AppState.I.init();

  // v1.0.5 CRITICAL: give the socket the Flask session cookie BEFORE it
  // connects, otherwise every send_message is silently dropped server-side
  // (endless retry) and room joins never happen.
  SocketService.I.configure(cookie: ApiService.I.cookieHeader);

  runApp(const RaviApp());
}
