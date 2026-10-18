import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ravi/ravi_app.dart';
import 'package:ravi/core/app_state.dart';

/// Pumps the REAL app (RaviApp — RTL Persian, real theme, real fonts) and
/// lets the splash route to the auth screen, with and without the keyboard.
/// A release-mode build exception shows as a full-screen GREY box — this
/// test exposes it with a stack trace + goldens.
void main() {
  testWidgets('REAL app boot → auth screen (rtl/fa) light + dark + keyboard',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    HttpOverrides.global = null;

    Future<void> snap(String name, Brightness b, double kb) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.platformBrightnessTestValue = b;
      tester.view.viewInsets = FakeViewPadding(bottom: kb);
      addTearDown(tester.view.reset);

      await AppState.I.init();
      AppState.I.themePref.value =
          b == Brightness.dark ? ThemeModePref.dark : ThemeModePref.light;

      await tester.pumpWidget(const RaviApp());
      await tester.pump(); // splash builds
      // splash: min 600ms beat + session probe (network blocked/fails fast)
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(seconds: 6));

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/real_$name.png'),
      );

      // Everything visible must be tappable: find a TextField and type.
      final fields = find.byType(TextField);
      if (tester.any(fields)) {
        await tester.enterText(fields.first, 'سلام تست');
        await tester.pump();
        expect(find.text('سلام تست'), findsOneWidget,
            reason: 'field must accept input (nothing grey blocking it)');
      } else {
        fail('no TextField found — something is covering the auth screen!');
      }
    }

    await snap('auth_light', Brightness.light, 0);
    await snap('auth_light_kb', Brightness.light, 280);
    await snap('auth_dark', Brightness.dark, 0);
  }, timeout: const Timeout(Duration(seconds: 120)));
}
