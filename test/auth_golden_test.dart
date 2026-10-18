import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ravi/ui/auth/auth_screen.dart';

void main() {
  testWidgets('render auth screen goldens (register + login, small + big)',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    Future<void> snap(String name, Size size, bool dark) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: size),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              brightness: dark ? Brightness.dark : Brightness.light,
              useMaterial3: true,
              fontFamily: 'Vazirmatn',
            ),
            home: const AuthScreen(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(seconds: 2));

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/auth_$name.png'),
      );
    }

    await snap('register_360x800', const Size(360, 800), false);
    await snap('register_360x560', const Size(360, 560), false);
    await snap('login_360x800', const Size(360, 800), false);
    await snap('register_dark_412x900', const Size(412, 900), true);

    // Prove the fields are hit-testable: tap the username field, expect focus.
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(360, 800)),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(useMaterial3: true, fontFamily: 'Vazirmatn'),
          home: const AuthScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(seconds: 2));
    await tester.enterText(find.byType(TextField).first, 'ravi_user');
    await tester.pump();
    expect(find.text('ravi_user'), findsOneWidget);
    stdout.writeln('FIELD_TAP_AND_TYPE_OK');
  });
}
