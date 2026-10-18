/// LIVE end-to-end smoke test against the real backend.
/// Proves: register → auto-login → identity parse → session cookie works,
/// and login with the fresh credentials → identity parse again.
///
/// Network only works inside tester.runAsync (flutter test intercepts raw
/// HttpClient calls otherwise).
///
/// Run: flutter test test/live_api_smoke_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ravi/core/api_service.dart';
import 'package:ravi/core/app_state.dart';

void main() {
  testWidgets('LIVE: register → identity → rooms authorized → re-login',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // flutter test installs a fake HttpOverrides that 400s every request;
    // this is a deliberate LIVE test, so restore real networking.
    HttpOverrides.global = null;
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final user = 'probe_$stamp';
    final api = ApiService.I;
    await (tester.runAsync(() => api.init()));

    // 1) register (server auto-logs the new user in)
    final reg = (await tester.runAsync(
        () => api.register(user, 'test1234', 'other', 'Probe $stamp')))!;
    expect(reg.ok, isTrue, reason: 'register failed: ${reg.message}');
    expect(api.cachedUsername, user,
        reason: 'identity must be parsed right after register');

    // 2) session must authorize /api/rooms (cookie captured from the 302!)
    final rooms = (await tester.runAsync(() => api.rooms()))!;
    expect(rooms.ok, isTrue,
        reason: 'rooms unauthorized right after register — cookie lost!');
    expect(rooms.isAuth, isFalse);

    // 3) profile endpoint for the fresh user
    final prof = (await tester.runAsync(() => api.userProfile(user)))!;
    expect(prof.ok, isTrue, reason: 'user_profile fetch failed');
    expect(prof.data?['username'], user);

    // 4) logout then log back in with the same credentials
    await (tester.runAsync(() => api.logout()));
    final login = (await tester.runAsync(() => api.login(user, 'test1234')))!;
    expect(login.ok, isTrue, reason: 'login failed: ${login.message}');
    expect(api.cachedUsername, user, reason: 'identity must parse after login');

    final rooms2 = (await tester.runAsync(() => api.rooms()))!;
    expect(rooms2.ok, isTrue,
        reason: 'rooms unauthorized after login — cookie lost!');

    // 5) GIF gallery endpoint answers for the live session
    final gifs = (await tester.runAsync(() => api.myGifs()))!;
    expect(gifs.ok, isTrue, reason: 'my_gifs failed: ${gifs.message}');

    // 6) wrong password must be rejected (not ok, not a network error)
    await (tester.runAsync(() => api.logout()));
    final bad = (await tester.runAsync(() => api.login(user, 'WRONG-pass')))!;
    expect(bad.ok, isFalse);
    expect(bad.status, ApiStatus.error);
    expect(bad.message, 'invalid');

    // 7) AppState kick path still works
    await (tester.runAsync(() => AppState.I.init()));
    await AppState.I.forceRelogin(localOnly: true);
    expect(AppState.I.kicked.value, isTrue);
    AppState.I.kicked.value = false;
  }, timeout: const Timeout(Duration(seconds: 120)));
}
