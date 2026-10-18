import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ravi/ui/auth/auth_screen.dart';

/// Reproduces the user's report: "a grey container comes over the register
/// page, can't do anything, stretches to the end". We render the auth screen
/// with the KEYBOARD OPEN (viewInsets simulated) at several sizes and dump
/// goldens so the grey blob (if any) is visible.
void main() {
  testWidgets('auth screen with keyboard open / edge sizes', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    Future<void> snap(String name, Size size, double kb) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      tester.view.viewInsets = FakeViewPadding(bottom: kb);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(
            size: size,
            viewInsets: EdgeInsets.only(bottom: kb),
          ),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(useMaterial3: true, fontFamily: 'Vazirmatn'),
            home: const AuthScreen(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(seconds: 2));
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/kb_$name.png'),
      );
    }

    // Keyboard open (280px) on a normal phone and a small phone.
    await snap('register_360x800_kb280', const Size(360, 800), 280);
    await snap('register_360x640_kb280', const Size(360, 640), 280);
    await snap('register_360x560_kb300', const Size(360, 560), 300);
    // Keyboard fully open on tiny screen.
    await snap('register_320x480_kb260', const Size(320, 480), 260);

    // And the interaction proof again: with the keyboard "open", typing must
    // still work (nothing grey should be eating the touches).
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewInsets = FakeViewPadding(bottom: 280);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
            size: Size(360, 800), viewInsets: EdgeInsets.only(bottom: 280)),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(useMaterial3: true, fontFamily: 'Vazirmatn'),
          home: const AuthScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(seconds: 2));
    await tester.enterText(find.byType(TextField).first, 'kb_test');
    await tester.pump();
    expect(find.text('kb_test'), findsOneWidget);
  });
}
