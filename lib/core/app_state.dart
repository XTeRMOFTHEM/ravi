import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';
import 'cache_service.dart';
import 'constants.dart';
import 'i18n.dart';
import 'models.dart';
import 'socket_service.dart';

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

  void updatePvPreview(int chatId, String lastMessage, String lastTime, int unread, String otherUser) {
    final list = List<ChatPreview>.from(chats.value);
    final i = list.indexWhere((c) => c.kind == ChatKind.pv && c.id == chatId);
    if (i >= 0) {
      list[i] = list[i].copyWith(
        lastMessage: lastMessage.isNotEmpty ? lastMessage : list[i].lastMessage,
        lastTime: lastTime.isNotEmpty ? lastTime : list[i].lastTime,
        lastTs: lastTime.isNotEmpty ? lastTime : list[i].lastTs,
        unread: unread,
      );
    } else {
      list.insert(0, ChatPreview(
        id: chatId, kind: ChatKind.pv, name: otherUser,
        lastMessage: lastMessage, lastTime: lastTime, unread: unread,
      ));
    }
    _sortAndPublish(list);
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
    final out = <ChatPreview>[...pinned, global, ...unpinned];
    final marked =
        out.map((c) => c.copyWith(pinned: pinnedSet.contains(c.key))).toList();

    // v1.0.9 — split archived chats out of the main list (they keep their
    // unread badges inside the Archived screen, like Telegram).
    archived.value = marked.where((c) => archivedSet.contains(c.key)).toList();
    setChats(marked.where((c) => !archivedSet.contains(c.key)).toList());
    _persistChats(marked);
  }

  // ------------------------- pinning (max 4) -------------------------

  static const maxPinned = 4;

  List<String> get pinnedKeys => prefs.getStringList('chats.pinned') ?? <String>[];

  /// Returns null on success, 'limit' when 4 chats are already pinned.
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

  void _persistChats(List<ChatPreview> list) {
    CacheService.I.put(CacheService.I.chatsKey(),
        list.map((c) => {
      'id': c.id, 'kind': c.kind.index, 'name': c.name, 'avatar': c.avatar,
      'rid': c.roomId, 'pu': c.peerUsername, 'ts': c.lastTs,
      'lm': c.lastMessage, 'lt': c.lastTime, 'lu': c.lastUser, 'u': c.unread,
      'ft': c.lastFileType,
    }).toList());
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
