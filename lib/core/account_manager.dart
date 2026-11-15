import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Multi-account manager inspired by Telegram:
/// • Standard accounts: up to 3 simultaneous accounts
/// • PRO (if ANY stored account is Pro): up to 5 accounts
/// • Session cookies are encrypted at rest using FlutterSecureStorage
///   (Android Keystore / EncryptedSharedPreferences), automatically migrating
///   any legacy plaintext SharedPreferences entries.
class RaviAccount {
  final String username;
  final String name;
  final String avatar;
  final int id;
  final String cookie;
  final bool isPro;

  const RaviAccount({
    required this.username,
    required this.name,
    required this.avatar,
    required this.id,
    required this.cookie,
    this.isPro = false,
  });

  Map<String, dynamic> toJson() => {
        'u': username,
        'n': name,
        'a': avatar,
        'id': id,
        'c': cookie,
        'p': isPro,
      };

  static RaviAccount fromJson(Map<dynamic, dynamic> j) => RaviAccount(
        username: '${j['u'] ?? ''}',
        name: '${j['n'] ?? ''}',
        avatar: '${j['a'] ?? ''}',
        id: j['id'] is int ? j['id'] as int : int.tryParse('${j['id']}') ?? 0,
        cookie: '${j['c'] ?? ''}',
        isPro: j['p'] == true,
      );

  bool get isEmpty => username.isEmpty && cookie.isEmpty;
}

class AccountManager {
  AccountManager._();
  static final AccountManager I = AccountManager._();

  static const _kAccounts = 'ravi.accounts.v1';
  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  List<RaviAccount> _accounts = [];
  int _active = 0;
  bool _loaded = false;

  List<RaviAccount> get accounts => List.unmodifiable(_accounts);
  int get activeIndex => _active;
  bool get loaded => _loaded;
  bool get hasMultiple => _accounts.length > 1;
  bool get hasAnyStoredPro => _accounts.any((a) => a.isPro);

  /// Max accounts: 5 when any stored/active account is Pro, otherwise 3.
  int maxAccounts({required bool anyPro}) => (anyPro || hasAnyStoredPro) ? 5 : 3;

  RaviAccount? get active {
    if (_accounts.isEmpty) return null;
    if (_active < 0 || _active >= _accounts.length) return null;
    return _accounts[_active];
  }

  Future<void> load() async {
    if (_loaded) return;
    String? raw;
    try {
      raw = await _secure.read(key: _kAccounts);
    } catch (_) {
      raw = null;
    }
    final p = await SharedPreferences.getInstance();
    // Migrate legacy plaintext storage to FlutterSecureStorage
    if (raw == null || raw.isEmpty) {
      final legacy = p.getString(_kAccounts);
      if (legacy != null && legacy.isNotEmpty) {
        raw = legacy;
        try {
          await _secure.write(key: _kAccounts, value: legacy);
          await p.remove(_kAccounts);
        } catch (_) {}
      }
    }
    try {
      if (raw != null && raw.isNotEmpty) {
        final list = (jsonDecode(raw) as List)
            .map((e) => RaviAccount.fromJson(e as Map<dynamic, dynamic>))
            .where((a) => !a.isEmpty)
            .toList();
        _accounts = list;
      }
      _active = p.getInt('$_kAccounts.idx') ?? 0;
      if (_active >= _accounts.length) _active = 0;
      if (_active < 0) _active = 0;
    } catch (_) {
      _accounts = [];
      _active = 0;
    }
    _loaded = true;
  }

  Future<void> _persist() async {
    final encoded = jsonEncode(_accounts.map((a) => a.toJson()).toList());
    final p = await SharedPreferences.getInstance();
    try {
      await _secure.write(key: _kAccounts, value: encoded);
      await p.remove(_kAccounts);
    } catch (_) {
      // Fallback for headless widget tests without platform channels
      await p.setString(_kAccounts, encoded);
    }
    await p.setInt('$_kAccounts.idx', _active);
  }

  bool canAddAccount({required bool anyPro}) {
    return _accounts.length < maxAccounts(anyPro: anyPro);
  }

  Future<bool> upsertCurrent({
    required String username,
    required String name,
    required String avatar,
    required int id,
    required String cookie,
    bool? isPro,
  }) async {
    await load();
    if (username.isEmpty || cookie.isEmpty) return false;
    final idx = _accounts.indexWhere(
        (a) => a.username.toLowerCase() == username.toLowerCase());
    final prevPro = idx >= 0 ? _accounts[idx].isPro : false;
    final acc = RaviAccount(
      username: username,
      name: name,
      avatar: avatar,
      id: id,
      cookie: cookie,
      isPro: isPro ?? prevPro,
    );
    if (idx >= 0) {
      _accounts[idx] = acc;
      _active = idx;
    } else {
      _accounts.add(acc);
      _active = _accounts.length - 1;
    }
    await _persist();
    return true;
  }

  Future<RaviAccount?> switchTo(int index) async {
    await load();
    if (index < 0 || index >= _accounts.length) return null;
    _active = index;
    await _persist();
    return _accounts[index];
  }

  Future<void> removeAt(int index) async {
    await load();
    if (index < 0 || index >= _accounts.length) return;
    _accounts.removeAt(index);
    if (_active >= _accounts.length) _active = _accounts.length - 1;
    if (_active < 0) _active = 0;
    await _persist();
  }

  Future<void> removeByUsername(String username) async {
    await load();
    final idx = _accounts.indexWhere(
        (a) => a.username.toLowerCase() == username.toLowerCase());
    if (idx >= 0) {
      await removeAt(idx);
    }
  }

  Future<void> refreshActive({
    required String name,
    required String avatar,
    bool? isPro,
  }) async {
    await load();
    if (_accounts.isEmpty) return;
    final a = _accounts[_active];
    _accounts[_active] = RaviAccount(
      username: a.username,
      name: name.isNotEmpty ? name : a.username,
      avatar: avatar.isNotEmpty ? avatar : a.avatar,
      id: a.id,
      cookie: a.cookie,
      isPro: isPro ?? a.isPro,
    );
    await _persist();
  }
}
