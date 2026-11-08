import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_manager.dart';
import 'api_service.dart';
import 'cache_service.dart';
import 'constants.dart';
import 'i18n.dart';
import 'models.dart';
import 'socket_service.dart';

export 'models.dart' show kSnippetFa;

/// Theme preference: light / dark / system (same choices as the web app).
enum ThemeModePref { light, dark, system }

/// Global app state — a handful of tiny notifiers so the UI can rebuild the
/// narrowest possible widget (ValueListenableBuilder) instead of the screen.
class AppState {
  AppState._();
  static final AppState I = AppState._();

  late SharedPreferences prefs;

  // ---- identity ----
  final ValueNotifier<RaviUser> me = ValueNotifier(const RaviUser(id: 0, username: '', name: ''));

  // ---- preferences ----
  final ValueNotifier<ThemeModePref> themePref = ValueNotifier(ThemeModePref.light);
  final ValueNotifier<Lang> lang = ValueNotifier(const Lang('fa'));
  final ValueNotifier<double> textScale = ValueNotifier(1.0);
  final ValueNotifier<bool> notificationsOn = ValueNotifier(true);
  final ValueNotifier<bool> soundsOn = ValueNotifier(true);

  // ---- chats list (network merged with cache) ----
  final ValueNotifier<List<ChatPreview>> chats = ValueNotifier([]);
  final ValueNotifier<bool> chatsLoading = ValueNotifier(true);

  // ---- v1.0.9 — archived chats (client-side, like Telegram's archive) ----
  final ValueNotifier<List<ChatPreview>> archived = ValueNotifier([]);

  // ---- unread badge on the Chats nav item ----
  final ValueNotifier<int> totalUnread = ValueNotifier(0);

  // ---- bottom nav index ----
  final ValueNotifier<int> pageIndex = ValueNotifier(0);

  // ---- forced logout: set to true when the session dies mid-app ----
  // RaviApp listens and routes to /auth, clearing the whole stack.
  final ValueNotifier<bool> kicked = ValueNotifier(false);

  S get str => S(lang.value);

  Future<void> init() async {
    prefs = await SharedPreferences.getInstance();
    final ti = prefs.getInt('pref.theme') ?? 0;
    themePref.value = ThemeModePref.values[(ti < 0 ? 0 : (ti >= ThemeModePref.values.length ? ThemeModePref.values.length - 1 : ti))];
    lang.value = Lang(prefs.getString('pref.lang') ?? 'fa');
    // v1.3.2 — Persian-first media snippet labels (reply previews)
    kSnippetFa = (prefs.getString('pref.lang') ?? 'fa') != 'en';
    textScale.value = prefs.getDouble('pref.textScale') ?? 1.0;
    notificationsOn.value = prefs.getBool('pref.notify') ?? true;
    soundsOn.value = prefs.getBool('pref.sounds') ?? true;
    AccentStore.key.value = prefs.getString('pref.accent') ?? 'blue';

    final u = ApiService.I;
    me.value = RaviUser(
      id: u.cachedUserId,
      username: u.cachedUsername,
      name: u.cachedName,
      avatar: u.cachedAvatar,
    );
  }

  Future<void> setAccent(String key) async {
    AccentStore.key.value = key;
    await prefs.setString('pref.accent', key);
  }

  // ---------- persistence setters ----------
  Future<void> setThemePref(ThemeModePref m) async {
    themePref.value = m;
    await prefs.setInt('pref.theme', m.index);
  }

  Future<void> setLang(Lang l) async {
    lang.value = l;
    kSnippetFa = l.code != 'en';
    await prefs.setString('pref.lang', l.code);
  }

  Future<void> setTextScale(double v) async {
    textScale.value = v;
    await prefs.setDouble('pref.textScale', v);
  }

  Future<void> setNotifications(bool v) async {
    notificationsOn.value = v;
    await prefs.setBool('pref.notify', v);
  }

  Future<void> setSounds(bool v) async {
    soundsOn.value = v;
    await prefs.setBool('pref.sounds', v);
  }

  void refreshIdentity() {
    final u = ApiService.I;
    me.value = RaviUser(
      id: u.cachedUserId,
      username: u.cachedUsername,
      name: u.cachedName,
      avatar: u.cachedAvatar,
    );
    // v1.4.0 — چندحسابی: بعد از هر رفرش هویت، حساب فعال در لیست حساب‌ها تازه می‌شود
    if (u.cachedUsername.isNotEmpty && u.cookieHeader.isNotEmpty) {
      AccountManager.I.upsertCurrent(
        username: u.cachedUsername,
        name: u.cachedName,
        avatar: u.cachedAvatar,
        id: u.cachedUserId,
        cookie: u.cookieHeader,
      ).catchError((_) => false);
    }
  }

  /// Wipes the local session and signals RaviApp to route to /auth.
  /// [localOnly] keeps the server-side session untouched (used when the
  /// backend already told us the cookie is dead).
  Future<void> forceRelogin({bool localOnly = false}) async {
    try {
      if (!localOnly) await ApiService.I.logout();
      else await ApiService.I.jar.clear();
    } catch (_) {}
    // Drop the (now anonymous) socket connection.
    SocketService.I.configure(cookie: '');
    setChats(<ChatPreview>[]);
    try {
      CacheService.I.put(CacheService.I.chatsKey(), <Map<String, dynamic>>[]);
    } catch (_) {}
    kicked.value = true;
  }

  // ---------- chats list management ----------
  void setChats(List<ChatPreview> list) {
    chats.value = list;
    totalUnread.value = list.fold(0, (s, c) => s + c.unread);
  }

  // ---------- v1.0.9 archive ----------
  List<String> get _archivedKeys =>
      prefs.getStringList('chats.archived') ?? <String>[];

  bool isArchived(ChatPreview c) => _archivedKeys.contains(c.key);

  Future<void> setArchived(ChatPreview c, bool value) async {
    final keys = List<String>.from(_archivedKeys);
    if (value) {
      if (!keys.contains(c.key)) keys.add(c.key);
    } else {
      keys.remove(c.key);
    }
    await prefs.setStringList('chats.archived', keys);
    _sortAndPublish(List<ChatPreview>.from(chats.value));
  }

  void updatePvPreview(int chatId, String lastMessage, String lastTime, int unread, String otherUser,
      {String lastFileType = '',
      String displayName = '',
      String avatar = '',
      bool isSelf = false}) {
    final list = List<ChatPreview>.from(chats.value);
    final i = list.indexWhere((c) => c.kind == ChatKind.pv && c.id == chatId);
    if (i >= 0) {
      list[i] = list[i].copyWith(
        lastMessage: lastMessage.isNotEmpty ? lastMessage : list[i].lastMessage,
        lastTime: lastTime.isNotEmpty ? lastTime : list[i].lastTime,
        lastTs: lastTime.isNotEmpty ? lastTime : list[i].lastTs,
        unread: unread,
        lastUser: otherUser,
        // v1.3.2 — live GIF/music/video preview labels on the home screen
        lastFileType: lastFileType.isNotEmpty ? lastFileType : null,
        // سیو مسیج فقط وقتی تغییر می‌کند که خودِ ایونت صریح بگوید
        isSelf: isSelf || list[i].isSelf,
      );
    } else {
      // v1.5.0 — چت جدید: سطرِ کامل با اسم نمایشی + آواتار + @یوزرنیم ساخته
      // می‌شود و یک رفرش آرامِ پس‌زمینه داده‌ی واقعی سرور را جا می‌اندازد
      // (باگ «سطر سه‌نقطه بی‌نام و بی‌عکس»).
      final name = displayName.trim().isNotEmpty
          ? displayName.trim()
          : (otherUser.isNotEmpty ? otherUser : '');
      list.insert(0, ChatPreview(
        id: chatId, kind: ChatKind.pv, name: name,
        peerUsername: otherUser,
        avatar: avatar,
        lastMessage: lastMessage, lastTime: lastTime,
        lastTs: lastTime,
        unread: unread,
        lastUser: otherUser,
        lastFileType: lastFileType.isEmpty ? 'text' : lastFileType,
        isSelf: isSelf,
      ));
      _scheduleSilentRefresh();
    }
    _sortAndPublish(list);
  }

  /// v1.5.0 — پیش‌نمایش زنده‌ی گروه/کانال: متن/ساعت آخرین پیام + بج ناخوانده
  /// بدون هیچ رفرشی (ایونت room_chats_updated از سرور).
  void updateRoomPreview(String roomId, String lastMessage, String lastTime,
      String lastFileType, int unreadDelta) {
    final list = List<ChatPreview>.from(chats.value);
    final i = list.indexWhere((c) =>
        (c.kind == ChatKind.group || c.kind == ChatKind.channel) &&
        c.roomId == roomId);
    if (i < 0) {
      _scheduleSilentRefresh(); // گروه تازه‌ساخته‌شده — رفرش آرام
      return;
    }
    final next = (list[i].unread + unreadDelta).clamp(0, 999);
    list[i] = list[i].copyWith(
      lastMessage: lastMessage.isNotEmpty ? lastMessage : list[i].lastMessage,
      lastTime: lastTime.isNotEmpty ? lastTime : list[i].lastTime,
      lastTs: lastTime.isNotEmpty ? lastTime : list[i].lastTs,
      lastFileType: lastFileType.isNotEmpty ? lastFileType : null,
      unread: next,
    );
    _sortAndPublish(list);
  }

  // v1.5.0 — رفرش آرامِ تکراری برای «بدون رفرش»: وقتی اپ باز است هر ۳۰
  // ثانیه یک بار لیست چت‌ها بی‌صدا از سرور تازه می‌شود. تا وقتی صفحه در
  // پس‌زمینه است متوقف است؛ پس بار سرور ناچیز می‌ماند.
  Timer? _autoRefreshTimer;
  DateTime _lastSilentRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  bool _inForeground = true;

  void setAppForeground(bool v) => _inForeground = v;

  void startAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_inForeground && SocketService.I.connected) {
        loadChatsCachedThenNetwork();
      }
    });
  }

  void stopAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = null;
  }

  void _scheduleSilentRefresh() {
    final now = DateTime.now();
    if (now.difference(_lastSilentRefresh).inMilliseconds < 1500) return;
    _lastSilentRefresh = now;
    Future.delayed(const Duration(milliseconds: 900), () {
      if (_inForeground) loadChatsCachedThenNetwork();
    });
  }

  /// v1.1.0 — zero a chat's unread badge the moment its screen opens and
  /// persist it, so the badge NEVER "comes back" after a refresh.
  void zeroUnread(ChatPreview chat) {
    final list = List<ChatPreview>.from(chats.value);
    final i = list.indexWhere((c) => c.key == chat.key);
    if (i < 0 || list[i].unread == 0) return;
    list[i] = list[i].copyWith(unread: 0);
    setChats(list);
    _persistChats(list);
  }

  /// Live unread bump for a group/channel row (socket `group_unread`).
  /// v1.0.7: matches by the HEX roomId string (ids are not ints!).
  void bumpRoomUnread(String roomId, int delta) {
    final list = List<ChatPreview>.from(chats.value);
    final i = list.indexWhere((c) =>
        (c.kind == ChatKind.group || c.kind == ChatKind.channel) &&
        c.roomId == roomId);
    if (i < 0) return;
    final next = delta == -999 ? 0 : (list[i].unread + delta).clamp(0, 999);
    list[i] = list[i].copyWith(unread: next, lastTime: list[i].lastTime);
    _sortAndPublish(list);
  }

  /// v1.0.7 — chats list ordering with PIN support (max 4):
  ///  • pinned chats first, in pin order (always on top)
  ///  • Global leads the unpinned block
  ///  • everything else sorted by last activity (newest first) so a new
  ///    message smoothly lifts its chat to the top
  void _sortAndPublish(List<ChatPreview> list) {
    final pinnedSet = prefs.getStringList('chats.pinned') ?? const <String>[];
    final archivedSet = _archivedKeys.toSet();
    ChatPreview global;
    final rest = <ChatPreview>[];
    if (list.isNotEmpty && list.first.kind == ChatKind.general) {
      global = list.first;
      rest.addAll(list.skip(1));
    } else {
      global = ChatPreview.global();
      rest.addAll(list.where((c) => c.kind != ChatKind.general));
    }

    int rank(ChatPreview c) {
      final p = pinnedSet.indexOf(c.key);
      return p >= 0 ? p : 99; // pinned order 0..3, unpinned at the end
    }

    rest.sort((a, b) {
      final ra = rank(a), rb = rank(b);
      if (ra != rb) return ra.compareTo(rb);
      // both unpinned → newest activity first
      final ta = a.sortTs, tb = b.sortTs;
      if (ta != tb) return tb.compareTo(ta);
      return 0;
    });

    final pinned = rest.where((c) => rank(c) < 99).toList();
    final unpinned = rest.where((c) => rank(c) == 99).toList();
    // v1.4.0 — سیو مسیج همیشه بالای لیست (بعد از پین‌شده‌ها، مثل تلگرام)
    final saved = unpinned.where((c) => c.isSelf).toList();
    final normal = unpinned.where((c) => !c.isSelf).toList();
    final out = <ChatPreview>[...pinned, ...saved, global, ...normal];
    final marked =
        out.map((c) => c.copyWith(pinned: pinnedSet.contains(c.key))).toList();

    // v1.0.9 — split archived chats out of the main list (they keep their
    // unread badges inside the Archived screen, like Telegram).
    archived.value = marked.where((c) => archivedSet.contains(c.key)).toList();
    setChats(marked.where((c) => !archivedSet.contains(c.key)).toList());
    _persistChats(marked);
  }

  // ------------------------- pinning (max 5, v1.1.0) -------------------------

  static const maxPinned = 5;

  List<String> get pinnedKeys => prefs.getStringList('chats.pinned') ?? <String>[];

  /// Returns null on success, 'limit' when 5 chats are already pinned.
  String? togglePin(ChatPreview chat) {
    final cur = List<String>.from(pinnedKeys);
    final k = chat.key;
    if (cur.contains(k)) {
      cur.remove(k);
    } else {
      if (cur.length >= maxPinned) return 'limit';
      if (chat.kind == ChatKind.general) return 'general';
      cur.add(k);
    }
    prefs.setStringList('chats.pinned', cur);
    _sortAndPublish(List<ChatPreview>.from(chats.value));
    return null;
  }

  /// v1.1.0 — Telegram-style "delete chat": drops the row from the list and
  /// wipes its cached messages from this device (server history untouched).
  Future<void> deleteChatLocally(ChatPreview chat) async {
    final list = List<ChatPreview>.from(chats.value)
      ..removeWhere((c) => c.key == chat.key);
    final arch = List<ChatPreview>.from(archived.value)
      ..removeWhere((c) => c.key == chat.key);
    // clear caches
    try {
      if (chat.kind == ChatKind.pv) {
        CacheService.I.put(CacheService.I.msgsKey('pv', chat.id), <Map<String, dynamic>>[]);
      } else if (chat.kind != ChatKind.general) {
        CacheService.I.put(CacheService.I.msgsKeyRaw('room', chat.roomId),
            <Map<String, dynamic>>[]);
      }
    } catch (_) {}
    // forget pin/archive marks
    final pins = List<String>.from(pinnedKeys)..remove(chat.key);
    await prefs.setStringList('chats.pinned', pins);
    final archKeys = List<String>.from(_archivedKeys)..remove(chat.key);
    await prefs.setStringList('chats.archived', archKeys);
    archived.value = arch;
    setChats(list);
  }

  void _persistChats(List<ChatPreview> list) {
    CacheService.I.put(CacheService.I.chatsKey(),
        list.map((c) => {
      'id': c.id, 'kind': c.kind.index, 'name': c.name, 'avatar': c.avatar,
      'rid': c.roomId, 'pu': c.peerUsername, 'ts': c.lastTs,
      'lm': c.lastMessage, 'lt': c.lastTime, 'lu': c.lastUser, 'u': c.unread,
      'ft': c.lastFileType,
      'ip': c.isPro, 'io': c.isOfficial, 'self': c.isSelf,
    }).toList());
  }

  /// v1.4.0 — سوییچ به حساب دیگر (مثل تلگرام): کوکی عوض می‌شود، سوکت ری‌کانکت
  /// و چت‌ها از نو لود می‌شوند. null یعنی ایندکس نامعتبر.
  Future<bool> switchAccount(int index) async {
    final acc = await AccountManager.I.switchTo(index);
    if (acc == null) return false;
    await ApiService.I.jar.setRaw(acc.cookie);
    // هویت کش‌شده فوراً ست شود تا UI منتظر شبکه نمونه
    ApiService.I.applyIdentityDirect(username: acc.username, name: acc.name, avatar: acc.avatar, id: acc.id);
    refreshIdentity();
    // چت‌های قدیمی پاک شوند (مال حساب قبلی‌اند)
    setChats(<ChatPreview>[]);
    try {
      CacheService.I.put(CacheService.I.chatsKey(), <Map<String, dynamic>>[]);
    } catch (_) {}
    // سوکت با کوکی نو دوباره وصل شود
    SocketService.I.configure(cookie: ApiService.I.cookieHeader);
    SocketService.I.connect();
    await loadChatsCachedThenNetwork();
    return true;
  }

  /// Load chats from disk first (instant paint), then refresh from network.
  Future<void> loadChatsCachedThenNetwork() async {
    chatsLoading.value = true;
    final cached = CacheService.I.getSync(CacheService.I.chatsKey());
    if (cached != null && cached.isNotEmpty && chats.value.isEmpty) {
      try {
        final list = cached.map((m) {
          final kind = ChatKind.values[(m['kind'] ?? 0) as int];
          return ChatPreview(
            id: (m['id'] ?? 0) is int ? m['id'] as int : int.tryParse('${m['id']}') ?? 0,
            kind: kind,
            name: '${m['name'] ?? ''}',
            avatar: '${m['avatar'] ?? ''}',
            roomId: '${m['rid'] ?? ''}',
            peerUsername: '${m['pu'] ?? ''}',
            lastMessage: '${m['lm'] ?? ''}',
            lastTime: '${m['lt'] ?? ''}',
            lastTs: '${m['ts'] ?? ''}',
            lastUser: '${m['lu'] ?? ''}',
            lastFileType: '${m['ft'] ?? 'text'}',
            unread: (m['u'] ?? 0) is int ? m['u'] as int : int.tryParse('${m['u']}') ?? 0,
            isPro: m['ip'] == true,
            isOfficial: m['io'] == true,
            isSelf: m['self'] == true,
          );
        }).toList();
        setChats(list);
      } catch (_) {}
    }

    final results = await Future.wait([
      ApiService.I.rooms(),
      ApiService.I.pvs(),
    ]);

    // Session died while we were inside the app → go back to register/login.
    if (results[0].isAuth || results[1].isAuth) {
      chatsLoading.value = false;
      await forceRelogin(localOnly: true);
      return;
    }

    final rooms = results[0].ok ? (results[0].data ?? <ChatPreview>[]) : <ChatPreview>[];
    final pvs = results[1].ok ? (results[1].data ?? <ChatPreview>[]) : <ChatPreview>[];

    if (results[0].ok || results[1].ok) {
      // Keep [Global, rooms sorted by recency, PVs sorted by recency] — same
      // order as the web list: Global row, groups, then private chats.
      final list = <ChatPreview>[ChatPreview.global(), ...rooms, ...pvs];
      _sortAndPublish(list);
    }
    chatsLoading.value = false;
  }
}

/// Resolves the material ThemeMode from our stored preference.
ThemeMode resolveTheme(ThemeModePref pref, Brightness system) {
  switch (pref) {
    case ThemeModePref.light:
      return ThemeMode.light;
    case ThemeModePref.dark:
      return ThemeMode.dark;
    case ThemeModePref.system:
      return system == Brightness.dark ? ThemeMode.dark : ThemeMode.light;
  }
}

/// Image cache warming + misc performance bootstrap.
Future<void> warmImageCache() async {
  // Pre-paint the logo so the splash/auth screens never flash.
  try {
    await precacheImage(const AssetImage('assets/images/logo.png'), _warmCtx!);
  } catch (_) {}
}

BuildContext? _warmCtx;
void setWarmContext(BuildContext c) => _warmCtx = c;

/// Debug-friendly logger (stripped in release via kDebugMode check at callsite).
void logDbg(String msg) {
  if (kDebugMode) debugPrint('[RAVI] $msg');
}
