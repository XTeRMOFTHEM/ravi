import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// v1.4.0 — مدیریت چندحسابی مثل تلگرام
/// • کاربر معمولی: تا ۳ حساب همزمان
/// • کاربر PRO (هر یک از حساب‌ها پرو باشد): تا ۵ حساب
/// سوییچ بین حساب‌ها = جابجایی کوکی سشن + هویت، بدون خروج واقعی از سرور.
class RaviAccount {
  final String username;
  final String name;
  final String avatar;
  final int id;
  final String cookie;

  const RaviAccount({
    required this.username,
    required this.name,
    required this.avatar,
    required this.id,
    required this.cookie,
  });

  Map<String, dynamic> toJson() => {
        'u': username, 'n': name, 'a': avatar, 'id': id, 'c': cookie,
      };

  static RaviAccount fromJson(Map<dynamic, dynamic> j) => RaviAccount(
        username: '${j['u'] ?? ''}',
        name: '${j['n'] ?? ''}',
        avatar: '${j['a'] ?? ''}',
        id: j['id'] is int ? j['id'] as int : int.tryParse('${j['id']}') ?? 0,
        cookie: '${j['c'] ?? ''}',
      );

  bool get isEmpty => username.isEmpty && cookie.isEmpty;
}

class AccountManager {
  AccountManager._();
  static final AccountManager I = AccountManager._();

  static const _kAccounts = 'ravi.accounts.v1';

  /// همه‌ی حساب‌های ذخیره‌شده (به‌ترتیب افزودن)
  List<RaviAccount> _accounts = [];
  /// ایندکس حساب فعال
  int _active = 0;
  bool _loaded = false;

  List<RaviAccount> get accounts => List.unmodifiable(_accounts);
  int get activeIndex => _active;
  bool get loaded => _loaded;
  bool get hasMultiple => _accounts.length > 1;

  /// سقف حساب‌ها: اگر «هر یک» از حساب‌های ذخیره‌شده پرو باشد ۵، وگرنه ۳
  int maxAccounts({required bool anyPro}) => anyPro ? 5 : 3;

  RaviAccount? get active {
    if (_accounts.isEmpty) return null;
    if (_active < 0 || _active >= _accounts.length) return null;
    return _accounts[_active];
  }

  Future<void> load() async {
    if (_loaded) return;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kAccounts);
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
    final p = await SharedPreferences.getInstance();
    await p.setString(_kAccounts,
        jsonEncode(_accounts.map((a) => a.toJson()).toList()));
    await p.setInt('$_kAccounts.idx', _active);
  }

  /// آیا می‌شود حساب جدید اضافه کرد؟ (سقف: معمولی ۳ / پرو ۵)
  /// [anyPro] یعنی کاربرِ لاگین‌شده فعلی پرو است (از پروفایلش خوانده می‌شود)
  bool canAddAccount({required bool anyPro}) {
    return _accounts.length < maxAccounts(anyPro: anyPro);
  }

  /// افزودن/به‌روزرسانی حساب (مثلاً بعد از لاگین یا رفرش هویت).
  /// اگر username از قبل بود، اطلاعات و کوکی‌اش تازه می‌شود و فعال می‌گردد.
  /// (سقف تعداد در canAddAccount چک می‌شود — اینجا فقط ثبت می‌کنیم)
  Future<bool> upsertCurrent({
    required String username,
    required String name,
    required String avatar,
    required int id,
    required String cookie,
  }) async {
    await load();
    if (username.isEmpty || cookie.isEmpty) return false;
    final acc = RaviAccount(username: username, name: name, avatar: avatar, id: id, cookie: cookie);
    final idx = _accounts.indexWhere((a) => a.username.toLowerCase() == username.toLowerCase());
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

  /// سوییچ به حساب دیگر — کوکی و هویت برمی‌گردد تا ApiService آن را بلعاید
  Future<RaviAccount?> switchTo(int index) async {
    await load();
    if (index < 0 || index >= _accounts.length) return null;
    _active = index;
    await _persist();
    return _accounts[index];
  }

  /// حذف یک حساب از لیست (فقط محلی؛ خروج سمت سرور جدا انجام می‌شود)
  Future<void> removeAt(int index) async {
    await load();
    if (index < 0 || index >= _accounts.length) return;
    _accounts.removeAt(index);
    if (_active >= _accounts.length) _active = _accounts.length - 1;
    if (_active < 0) _active = 0;
    await _persist();
  }

  /// همگام‌سازی اطلاعات حساب فعال (اسم/آواتار جدید مثلاً)
  Future<void> refreshActive({
    required String name,
    required String avatar,
  }) async {
    await load();
    if (_accounts.isEmpty) return;
    final a = _accounts[_active];
    _accounts[_active] = RaviAccount(
      username: a.username, name: name.isNotEmpty ? name : a.username,
      avatar: avatar.isNotEmpty ? avatar : a.avatar, id: a.id, cookie: a.cookie,
    );
    await _persist();
  }
}
