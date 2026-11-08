import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'api_service.dart';
import 'cache_service.dart';
import 'media_download_manager.dart';
import 'models.dart';
import 'socket_service.dart';

/// Full chat state for one conversation (general / pv / group).
/// Telegram-style behaviours:
///  • paint from disk cache instantly
///  • merge network history (paginated)
///  • optimistic sends with pending → confirmed / failed
///  • offline queue re-flushed on reconnect
///  • typing + online status streams
///  • emoji reactions (socket toggle_reaction / reaction_update)
class ChatController extends ChangeNotifier {
  final ChatKind kind;
  final int chatId; // pv chat id
  final String roomId; // group room id (general => 'general')

  ChatController({
    required this.kind,
    this.chatId = 0,
    this.roomId = 'general',
    this.selfOnly = false,
  });

  /// چت «پیام‌های ذخیره‌شده»: فقط پیام‌های خودِ کاربر نمایش داده می‌شود.
  final bool selfOnly;
  bool _keep(Message m) => !selfOnly || m.isMe;

  final List<Message> _messages = [];
  /// لغو آپلودِ در حال انجام (دکمه‌ی ✕ روی حباب)
  void cancelUpload(String clientMsgId) => UploadRegistry.cancel(clientMsgId);
  // v1.4.0 — ضدپرش به سبک واتساپ: وقتی کاربر دارد تاریخچه را می‌خواند (دور از
  // انتهای چت است)، پیام‌های تازه به‌جای درج در لیست (که باعث پرش می‌شد) اینجا
  // صف می‌شوند؛ با لمس «N پیام جدید» یا ارسال پیام، یکجا با انیمیشن اضافه می‌شوند.
  final List<Message> _pendingIncoming = [];
  int get pendingIncomingCount => _pendingIncoming.length;
  /// صفحه وقتی دور از انتهای لیست است این فلگ را true می‌گذارد
  bool holdIncoming = false;
  bool _loadingHistory = false;
  bool _historyDone = false;
  bool _sending = false;
  String? _error;
  bool _otherTyping = false;
  Timer? _typingTimer;
  int? _onlineCount;
  final Set<String> _onlineUsers = {};

  // v1.0.8 — group/channel header data: "N members, M online".
  int? _memberCount;
  int? get memberCount => _memberCount;
  Set<String> get onlineUsers => _onlineUsers;
  /// online count within this group/channel (online list ∩ members)
  int get groupOnlineCount =>
      kind == ChatKind.general ? (_onlineCount ?? 0) : _groupMemberOnline;
  int _groupMemberOnline = 0;
  List<String> _memberUsernames = const [];
  bool _roomMuted = false;
  bool get isRoomMuted => _roomMuted;
  void setRoomMuted(bool v) {
    _roomMuted = v;
    notifyListeners();
  }

  // v1.0.6: group typing = a SET of usernames ("Ali, Sara are typing…").
  final Map<String, Timer> _groupTyping = {};
  Set<String> get typingUsers => _groupTyping.keys.toSet();

  // v1.1.0 — member role map (owner / admin) for coloured author tags.
  final Map<String, RoomMember> _memberMap = {};
  RoomMember? memberOf(String username) => _memberMap[username];
  bool isOwner(String username) => _memberMap[username]?.isOwner ?? false;
  bool isAdmin(String username) => _memberMap[username]?.isRoomAdmin ?? false;

  // v1.0.6: room meta from /api/room/<id>/messages (can_post, room_type…).
  bool _canPost = true;
  bool get canPost => _canPost;
  String _roomType = '';
  String get roomType => _roomType;
  // v1.0.9 — my role in this room ('owner' | 'admin' | 'member')
  String _myRole = 'member';
  String get myRole => _myRole;
  // v1.2.1 — slow mode (seconds between messages) from room settings
  int _slowMode = 0;
  int get slowMode => _slowMode;

  // v1.0.6: socket status drives the header "connecting…" state.
  SocketStatus _socketStatus = SocketStatus.disconnected;
  SocketStatus get socketStatus => _socketStatus;

  /// v1.0.5: real last-seen for PVs ("آخرین بازدید به‌تازگی" instead of "...").
  PvInfo? _pvInfo;
  PvInfo? get pvInfo => _pvInfo;

  /// v1.0.9 — live block/unblock: swap the cached PvInfo without a refetch.
  void setPvInfo(PvInfo info) {
    _pvInfo = info;
    notifyListeners();
  }

  /// True once the first network refresh finished — used by the UI to decide
  /// which bubbles get the Telegram-style appear animation.
  bool historyLoaded = false;

  List<Message> get messages => _messages;
  bool get loadingHistory => _loadingHistory;
  bool get historyDone => _historyDone;
  bool get sending => _sending;
  String? get error => _error;
  bool get otherTyping => _otherTyping;
  int? get onlineCount => _onlineCount;
  bool isPeerOnline(String username) =>
      _onlineUsers.contains(username) || (_pvInfo?.online ?? false);

  String get cacheKey => kind == ChatKind.pv
      ? CacheService.I.msgsKey('pv', chatId)
      : kind == ChatKind.general
          ? CacheService.I.generalKey
          // v1.0.7 CRITICAL: room ids are hex STRINGS — the old int.tryParse
          // collapsed every room to cache file msgs_room_0 (all chats looked
          // identical and deleted messages "came back" from foreign caches).
          : CacheService.I.msgsKeyRaw('room', roomId);

  /// v1.0.7 — the room name the SERVER expects for typing / socket rooms:
  /// 'general' | 'pv_<chat_id>' | 'private_<hex_room_id>'
  String get serverRoom => switch (kind) {
        ChatKind.general => 'general',
        ChatKind.pv => 'pv_$chatId',
        _ => 'private_$roomId',
      };

  String get socketRoom => kind == ChatKind.pv ? 'pv_$chatId' : roomId;

  StreamSubscription? _subNew, _subNewPv, _subTyping, _subOnline, _subDel, _subStatus, _subUserOn, _subUserOff, _subReactions, _subEdited, _subPins;
  // v1.1.0 — PV seen-tick poller (cancelled on dispose)
  Timer? _seenTimer;

  // ==================== v1.1.1 — SERVER-side pins (Telegram) ====================
  // Multiple pinned messages per chat, stored on the backend:
  //  • rooms  → shared with every member (admins/owner pin)
  //  • pv     → personal (each side has its own list)
  // The pinned bar cycles through the list on tap; live updates arrive via
  // 'room_pins_update' / 'pv_pins_update' socket events.
  List<Map<String, dynamic>> _pins = const [];
  int _pinCursor = 0;
  List<Map<String, dynamic>> get pins => _pins;
  int get pinCursor => _pinCursor;

  bool get canPin {
    if (kind == ChatKind.pv) return chatId > 0;
    if (kind == ChatKind.general) return false;
    return _myRole == 'owner' || _myRole == 'admin';
  }

  Map<String, dynamic>? get currentPin {
    if (_pins.isEmpty) return null;
    return _pins[_pinCursor.clamp(0, _pins.length - 1)];
  }

  Future<void> loadPins() async {
    final res = kind == ChatKind.pv
        ? await ApiService.I.pvPins(chatId)
        : kind == ChatKind.general
            ? const ApiResult<List<Map<String, dynamic>>>(ApiStatus.ok, data: [])
            : await ApiService.I.roomPins(roomId);
    if (_disposed || !res.ok || res.data == null) return;
    _pins = res.data!;
    if (_pinCursor >= _pins.length) _pinCursor = 0;
    notifyListeners();
  }

  void cyclePin() {
    if (_pins.length < 2) return;
    _pinCursor = (_pinCursor + 1) % _pins.length;
    notifyListeners();
  }

  Future<bool> pinMessage(Message m) async {
    if (m.id <= 0 || !canPin) return false;
    final res = kind == ChatKind.pv
        ? await ApiService.I.pinPvMessage(chatId, m.id)
        : await ApiService.I.pinRoomMessage(roomId, m.id);
    if (res.ok) await loadPins();
    return res.ok;
  }

  Future<bool> unpinMessage(int messageId) async {
    final res = kind == ChatKind.pv
        ? await ApiService.I.unpinPvMessage(chatId, messageId)
        : await ApiService.I.unpinRoomMessage(roomId, messageId);
    if (res.ok) await loadPins();
    return res.ok;
  }

  // v1.1.1 — belt & braces with the server's auto-read: whenever a new room
  // message lands while the chat is OPEN, re-tell the backend "I've read it".
  // (The server ALSO advances reads for socket-room viewers itself.)
  Timer? _readPing;
  void _pingRoomRead() {
    if (kind != ChatKind.group && kind != ChatKind.channel) return;
    if (_readPing?.isActive == true) return;
    _readPing = Timer(const Duration(milliseconds: 2500), () {});
    SocketService.I.emit('group_read', {'room_id': roomId});
  }

  // ------------------------------------------------ lifecycle

  Future<void> load() async {
    // 1) socket listeners
    _bindSocket();

    // 1b) pv header info (real last seen) — non-blocking
    if (kind == ChatKind.pv && chatId > 0) {
      ApiService.I.pvInfo(chatId).then((res) {
        if (res.ok && res.data != null) {
          _pvInfo = PvInfo.fromJson(res.data!);
          notifyListeners();
        }
      });
    }

    // 1c) v1.0.8 — group/channel meta for the header subtitle
    //     ("۱۲ members, ۴ online" / "۳۵ subscribers") + mute state.
    if (kind == ChatKind.group || kind == ChatKind.channel) {
      ApiService.I.roomInfo(roomId).then((res) {
        if (_disposed || !res.ok || res.data == null) return;
        final j = res.data!;
        _memberCount = j['member_count'] is int
            ? j['member_count'] as int
            : int.tryParse('${j['member_count']}') ?? 0;
        _ingestMembers(j);
        _recountGroupOnline();
        // v1.2.1 — slow mode from the room settings block
        final st = j['settings'];
        if (st is Map) {
          _slowMode = st['slow_mode'] is int
              ? st['slow_mode'] as int
              : int.tryParse('${st['slow_mode']}') ?? 0;
        }
        notifyListeners();
      });
    }

    // 1d) v1.1.0 — keep PV read-ticks alive while the chat is open: a quiet
    // periodic refresh of the tail merges is_read without touching anything.
    if (kind == ChatKind.pv && chatId > 0) {
      _seenTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (_disposed) return;
        pollPvSeen();
      });
    }

    // 1d) v1.1.1 — server-side pinned messages
    loadPins();

    // 2) instant disk cache
    final cached = CacheService.I.getSync(cacheKey);
    if (cached != null && cached.isNotEmpty) {
      _messages
        ..clear()
        ..addAll(cached.map(Message.fromCache).where((m) => !m.pending && _keep(m)));
      notifyListeners();
    }

    // 3) network history
    await refresh();
  }

  /// v1.1.0 — parse the members array of a roomInfo payload once.
  void _ingestMembers(Map<String, dynamic> j) {
    final list = (j['members'] as List?) ?? const [];
    _memberMap.clear();
    _memberUsernames = list
        .whereType<Map>()
        .map((e) {
          final m = RoomMember.fromMap(Map<String, dynamic>.from(e));
          _memberMap[m.username] = m;
          return m.username;
        })
        .where((u) => u.isNotEmpty)
        .toList();
  }

  /// v1.1.0 — REAL-TIME seen ticks: quietly refresh the tail of a PV and
  /// merge ONLY the is_read flags (no list churn, no scroll jumps).
  Future<void> pollPvSeen() async {
    if (kind != ChatKind.pv || chatId <= 0) return;
    final res = await ApiService.I.pvMessages(chatId, limit: 30);
    if (_disposed || !res.ok || res.data == null) return;
    var changed = false;
    for (final fresh in res.data!) {
      if (!fresh.isMe) continue;
      final i = _messages.indexWhere((m) => m.id == fresh.id);
      if (i >= 0 && !_messages[i].isRead && fresh.isRead) {
        _messages[i] = _messages[i].copyWith(isRead: true);
        changed = true;
      }
    }
    if (changed) {
      _persist();
      notifyListeners();
    }
  }

  /// v1.1.0 — jump-to-reply support: page backwards until [targetId] is in
  /// memory (max ~15 pages ≈ 600 messages), so old replies always resolve.
  Future<bool> loadUntilMessage(int targetId) async {
    if (targetId <= 0) return false;
    for (var guard = 0; guard < 15; guard++) {
      if (_disposed) return false;
      if (_messages.any((m) => m.id == targetId)) return true;
      if (_historyDone || _loadingHistory) return false;
      final before = _messages.length;
      await loadOlder();
      if (_messages.length == before) return false; // no progress
    }
    return _messages.any((m) => m.id == targetId);
  }

  Future<void> refresh() async {
    if (kind == ChatKind.group || kind == ChatKind.channel) {
      await _refreshRoom();
      return;
    }
    final ApiResult<List<Message>> res;
    switch (kind) {
      case ChatKind.general:
        res = await ApiService.I.generalMessages(limit: 60);
        break;
      case ChatKind.pv:
        res = await ApiService.I.pvMessages(chatId, limit: 60);
        break;
      default:
        res = await ApiService.I.roomMessages(roomId, limit: 60);
    }
    if (res.ok && res.data != null) {
      final fresh = res.data!.where(_keep).toList();
      // Preserve pending/failed optimistic messages at the tail.
      final tail = _messages.where((m) => m.pending || m.failed).toList();
      _messages
        ..clear()
        ..addAll(fresh);
      for (final t in tail) {
        if (!_messages.any((m) => m.clientMsgId == t.clientMsgId)) {
          _messages.add(t);
        }
      }
      _historyDone = res.data!.length < 60;
      _error = null;
      _persist();
      historyLoaded = true;
    } else if (res.isAuth) {
      _error = 'auth';
    } else if (res.status == ApiStatus.networkError) {
      _error = 'network';
      // keep cached content visible; retry quietly
      Future.delayed(const Duration(seconds: 8), () {
        if (!_disposed && _messages.isEmpty) refresh();
      });
    }
    notifyListeners();
  }

  /// v1.0.6: room/group/channel history — reads the MAP payload
  /// ({messages, can_post, room_type…}) so groups & channels finally load.
  Future<void> _refreshRoom() async {
    final res = await ApiService.I.roomMessagesFull(roomId, limit: 60);
    if (res.ok && res.data != null) {
      final hist = res.data!;
      final tail = _messages.where((m) => m.pending || m.failed).toList();
      _messages
        ..clear()
        ..addAll(hist.messages);
      for (final t in tail) {
        if (!_messages.any((m) => m.clientMsgId == t.clientMsgId)) {
          _messages.add(t);
        }
      }
      _historyDone = hist.messages.length < 60;
      _canPost = hist.canPost;
      _roomType = hist.roomType;
      _myRole = hist.myRole;
      _error = null;
      _persist();
      historyLoaded = true;
    } else if (res.isAuth) {
      _error = 'auth';
    } else if (res.status == ApiStatus.networkError) {
      _error = 'network';
      Future.delayed(const Duration(seconds: 8), () {
        if (!_disposed && _messages.isEmpty) refresh();
      });
    }
    notifyListeners();
  }

  Future<void> loadOlder() async {
    if (_loadingHistory || _historyDone || _messages.isEmpty) return;
    // v1.2.0 — CASCADE FIX: the scroll anchor keeps the viewport pinned at
    // the top edge after every prepend, and the programmatic jumpTo re-fires
    // the scroll listener → pages were chained back-to-back until the very
    // first message (the "stutters and loads everything" bug on weak phones).
    // A hard cooldown breaks the chain: one page per user gesture max.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastOlderLoadMs < 900) return;
    _lastOlderLoadMs = nowMs;
    _loadingHistory = true;
    notifyListeners();
    final oldest = _messages.first.id;
    final res = switch (kind) {
      ChatKind.general => await ApiService.I.generalMessages(before: oldest, limit: 40),
      ChatKind.pv => await ApiService.I.pvMessages(chatId, before: oldest, limit: 40),
      _ => await ApiService.I.roomMessages(roomId, before: oldest, limit: 40),
    };
    if (res.ok && res.data != null) {
      final older = res.data!.where(_keep).toList();
      if (older.isNotEmpty) {
        _messages.insertAll(0, older);
        justLoadedOlder = true; // v1.2.0 — screen freezes viewport for prepends
        _persist();
      }
      // v1.2.0 — an empty page means there is nothing older: stop asking.
      if (res.data!.length < 40) _historyDone = true;
    } else {
      // network hiccup → do not hammer; require a fresh user scroll
      _lastOlderLoadMs = DateTime.now().millisecondsSinceEpoch;
    }
    _loadingHistory = false;
    notifyListeners();
  }

  /// v1.2.0 — set when a history page just landed; the screen reads it to
  /// distinguish "prepend" (freeze viewport) from "append" (slide-in).
  int _lastOlderLoadMs = 0;
  bool justLoadedOlder = false;

  // ------------------------------------------------ socket

  void _bindSocket() {
    final sock = SocketService.I;
    // join rooms
    switch (kind) {
      case ChatKind.general:
        sock.joinGeneral();
        break;
      case ChatKind.pv:
        sock.joinPv(chatId);
        sock.markPvAllRead(chatId);
        break;
      default:
        sock.joinGroup(roomId);
    }

    _subNew = sock.onNewMessage.listen((d) {
      if (kind == ChatKind.general) {
        _onIncoming(d);
      } else if (kind == ChatKind.group || kind == ChatKind.channel) {
        // v1.0.7: GROUP + CHANNEL live messages — the old filter only routed
        // 'general', so group chats never received live messages.
        if ('${d['room'] ?? ''}' == serverRoom) _onIncoming(d);
      }
    });
    _subNewPv = sock.onNewPvMessage.listen((d) {
      // v1.4.0 CRITICAL FIX — باگ بحرانی «قاطی شدن چت‌ها و پیوی‌ها»:
      // سوکتِ اپ بعد از هر ری‌کانکت به «همه‌ی» پیوی‌هایی که قبلا باز شده‌اند
      // دوباره join می‌شود (_joinedPv). پس ایونت new_pv_message از چت A هم
      // می‌تواند وقتی چت B باز است برسد؛ قبلاً بدون چک، پیامِ چت A داخل
      // چت B درج می‌شد! الان فقط پیام همان چتِ باز نمایش داده می‌شود؛
      // پیام چت‌های دیگر فقط پیش‌نمایش لیست را آپدیت می‌کند (سرور هم از
      // v1.4.0 ایونت‌های پیوی را فقط به دو طرف خود چت می‌فرستد).
      final incomingChat = '${d['private_chat_id'] ?? ''}';
      if (kind == ChatKind.pv && incomingChat == '$chatId') {
        _onIncoming(d);
      }
      if (incomingChat == '$chatId') {
        // also mark read when we are inside this pv
        sock.markPvAllRead(chatId);
      }
    });
    _subTyping = sock.onTyping.listen((d) {
      // v1.0.7 — server payload is {room, users:[usernames]} (a LIST),
      // not {username, is_typing}. The old parse meant typing NEVER showed.
      final room = '${d['room'] ?? ''}';
      if (room != serverRoom) return;
      final me = ApiService.I.cachedUsername;
      final users = (d['users'] as List?)
              ?.map((e) => '$e')
              .where((u) => u.isNotEmpty && u != me)
              .toList() ??
          const <String>[];
      // auto-expiry: the server doesn't send periodic refreshes
      for (final t in _groupTyping.values) {
        t.cancel();
      }
      _groupTyping.clear();
      for (final u in users) {
        _groupTyping[u] = Timer(const Duration(seconds: 5), () {
          _groupTyping.remove(u);
          notifyListeners();
        });
      }
      if (kind == ChatKind.pv) {
        _otherTyping = users.isNotEmpty;
        _typingTimer?.cancel();
        if (users.isNotEmpty) {
          _typingTimer = Timer(const Duration(seconds: 5), () {
            _otherTyping = false;
            notifyListeners();
          });
        }
      }
      notifyListeners();
    });
    _subOnline = sock.onOnlineList.listen((list) {
      _onlineUsers
        ..clear()
        ..addAll(list);
      if (kind == ChatKind.general) {
        _onlineCount = list.length;
      } else {
        _recountGroupOnline();
      }
      notifyListeners();
    });
    _subUserOn = sock.onUserOnline.listen((u) {
      _onlineUsers.add(u);
      if (kind == ChatKind.general) {
        _onlineCount = _onlineUsers.length;
      } else {
        _recountGroupOnline();
      }
      notifyListeners();
    });
    _subUserOff = sock.onUserOffline.listen((u) {
      _onlineUsers.remove(u);
      if (kind == ChatKind.general) {
        _onlineCount = _onlineUsers.length;
      } else {
        _recountGroupOnline();
      }
      notifyListeners();
    });
    _subDel = sock.onMessageDeleted.listen((d) {
      // Server sends BOTH 'message_id' and 'msg_id' — accept either.
      final id = (d['message_id'] ?? d['msg_id']) is int
          ? (d['message_id'] ?? d['msg_id']) as int
          : int.tryParse('${d['message_id'] ?? d['msg_id']}') ?? 0;
      if (id <= 0) return;
      final i = _messages.indexWhere((m) => m.id == id);
      if (i < 0) return;
      // Telegram-style collapse animation, then really remove.
      _messages[i] = _messages[i].copyWith(removing: true);
      notifyListeners();
      Timer(const Duration(milliseconds: 220), () {
        if (_disposed) return;
        _messages.removeWhere((m) => m.id == id);
        _persist();
        notifyListeners();
      });
    });
    _subEdited = sock.onMessageEdited.listen((d) {
      final id = (d['message_id'] ?? d['msg_id']) is int
          ? (d['message_id'] ?? d['msg_id']) as int
          : int.tryParse('${d['message_id'] ?? d['msg_id']}') ?? 0;
      final newText = '${d['new_text'] ?? ''}';
      if (id <= 0) return;
      final i = _messages.indexWhere((m) => m.id == id);
      if (i < 0) return;
      _messages[i] =
          _messages[i].copyWith(text: newText, isEdited: true);
      _persist();
      notifyListeners();
    });
    // v1.1.1 — live pin updates for THIS chat only
    _subPins = sock.onPinsUpdate.listen((d) {
      if (kind == ChatKind.general) return;
      final rid = '${d['room_id'] ?? ''}';
      final cid = '${d['chat_id'] ?? ''}';
      final mine = kind == ChatKind.pv ? '$chatId' : roomId;
      if ((kind == ChatKind.pv && cid == mine) ||
          (kind != ChatKind.pv && rid == mine)) {
        loadPins();
      }
    });
    _subReactions = sock.onReactionUpdate.listen((d) {
      final id = (d['message_id'] is int)
          ? d['message_id'] as int
          : int.tryParse('${d['message_id']}') ?? 0;
      if (id <= 0) return;
      final rx = ReactionSummary.listFrom(d['reactions']);
      final i = _messages.indexWhere((m) => m.id == id);
      if (i >= 0) {
        _messages[i] = _messages[i].copyWith(reactions: rx);
        _persist();
        notifyListeners();
      }
    });
    _subStatus = sock.onStatus.listen((st) {
      _socketStatus = st;
      if (st == SocketStatus.connected && _messages.any((m) => m.pending)) {
        // Re-send queued optimistic messages after reconnect.
        for (final m in _messages.where((m) => m.pending).toList()) {
          sock.emit('send_message', _payloadFor(m));
        }
      }
      notifyListeners();
    });
    _socketStatus = sock.connected
        ? SocketStatus.connected
        : SocketStatus.connecting;
  }

  void _onIncoming(Map<String, dynamic> d) {
    final cmid = '${d['client_msg_id'] ?? ''}';
    // Own optimistic message confirmed by the server echo.
    if (cmid.isNotEmpty) {
      final idx = _messages.indexWhere((m) => m.clientMsgId == cmid);
      if (idx >= 0) {
        confirmSent(d);
        return;
      }
    }
    final msg = Message.fromSocket(d, ApiService.I.cachedUsername);
    if (!_keep(msg)) return;
    // de-dup by id
    if (msg.id > 0 && _messages.any((m) => m.id == msg.id)) return;
    // v1.4.0 — ضدپرش واتساپی: دور از انتهای چت؟ پیام به صف میرود، لیست ثابت می‌ماند
    if (holdIncoming && !msg.isMe) {
      if (_pendingIncoming.any((m) => m.id == msg.id)) return;
      _pendingIncoming.add(msg);
      notifyListeners();
      return;
    }
    _messages.add(msg);
    _persist();
    // v1.1.1 — keep the read-state pinned to the newest message while open
    _pingRoomRead();
    notifyListeners();
  }

  /// v1.4.0 — تخلیه‌ی صف پیام‌های نگه‌داشته‌شده (لمس پیل «پیام جدید» یا ارسال پیام)
  void flushIncoming() {
    if (_pendingIncoming.isEmpty) return;
    for (final m in _pendingIncoming) {
      if (m.id > 0 && _messages.any((x) => x.id == m.id)) continue;
      _messages.add(m);
    }
    _pendingIncoming.clear();
    _persist();
    notifyListeners();
  }

  // ------------------------------------------------ sending

  Map<String, dynamic> _payloadFor(Message m) {
    final payload = <String, dynamic>{
      'message': m.text,
      'room': kind == ChatKind.general ? 'general' : 'private_$roomId',
      'file_url': m.fileUrl.isEmpty ? null : m.fileUrl,
      'file_type': m.fileType,
      'client_msg_id': m.clientMsgId,
    };
    if (kind == ChatKind.pv) payload['private_chat_id'] = chatId;
    if (m.replyToId != null && m.replyToId!.isNotEmpty) {
      payload['reply_to'] = int.tryParse(m.replyToId!) ?? m.replyToId;
    }
    // v1.2.1 — Telegram-style media metadata travels WITH the message so
    // receivers get dims / music tags without decoding the file first.
    // v1.3.1 — audio ALWAYS carries an explicit kind (voice | music) so the
    // server stores it and the bubble type can never be "guessed" again.
    final meta = <String, dynamic>{};
    if (m.fileType == 'audio') {
      meta['kind'] = m.isVoiceNote ? 'voice' : 'music';
    }
    if (m.isVoiceNote) meta['kind'] = 'voice';
    if (m.mediaDurMs > 0) meta['dur'] = m.mediaDurMs;
    if (m.mediaW > 0 && m.mediaH > 0) {
      meta['w'] = m.mediaW;
      meta['h'] = m.mediaH;
    }
    if (m.mediaTitle.isNotEmpty) meta['title'] = m.mediaTitle;
    if (m.mediaArtist.isNotEmpty) meta['artist'] = m.mediaArtist;
    if (m.mediaCover.isNotEmpty) meta['cover'] = m.mediaCover;
    if (meta.isNotEmpty) payload['media_meta'] = meta;
    return payload;
  }

  Future<bool> send(String text, {String? replyToId, String? replyAuthor, String? replyText}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _sending) return false;
    // v1.4.0 — ارسال یعنی برگشت به انتهای چت: صفِ پیام‌های جدید اول تخلیه شود
    holdIncoming = false;
    flushIncoming();
    final now = DateTime.now();
    final cmid = 'm_${now.millisecondsSinceEpoch}';
    final msg = Message(
      id: 0,
      clientMsgId: cmid,
      username: ApiService.I.cachedUsername,
      displayName: ApiService.I.cachedName,
      text: trimmed,
      time: '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
      dateKey: '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}',
      avatar: ApiService.I.cachedAvatar,
      isMe: true,
      pending: true,
      replyToId: replyToId,
      replyAuthor: replyAuthor,
      replyText: replyText,
    );
    _messages.add(msg);
    _sending = true;
    notifyListeners();
    _persist();

    SocketService.I.emit('send_message', _payloadFor(msg));
    SocketService.I.sendTyping(serverRoom, false);

    // Watchdog: confirm or retry.
    unawaited(_awaitConfirmation(cmid));
    _sending = false;
    return true;
  }

  Future<void> _awaitConfirmation(String cmid) async {
    for (var i = 0; i < 10; i++) {
      await Future.delayed(const Duration(milliseconds: 600));
      if (_disposed) return;
      final idx = _messages.indexWhere((m) => m.clientMsgId == cmid);
      if (idx < 0) return; // already replaced by real message
      if (!_messages[idx].pending) return;
    }
    final idx = _messages.indexWhere((m) => m.clientMsgId == cmid);
    if (idx >= 0 && _messages[idx].pending) {
      _messages[idx] = _messages[idx].copyWith(pending: false, failed: true);
      _persist();
      notifyListeners();
    }
  }

  void confirmSent(Map<String, dynamic> d) {
    final cmid = '${d['client_msg_id'] ?? ''}';
    final realId = (d['message_id'] is int)
        ? d['message_id'] as int
        : int.tryParse('${d['message_id']}') ?? 0;
    final idx = _messages.indexWhere((m) => m.clientMsgId == cmid);
    if (idx >= 0) {
      final m = _messages[idx];
      // v1.3.2 — merge the server echo's media_meta (the echo carries the
      // normalized kind/music tags) so a song is a MUSIC bubble from the
      // optimistic frame until forever — never a temporary voice bubble.
      final mm = Message.parseMediaMeta(d['media_meta']);
      _messages[idx] = Message(
        id: realId,
        clientMsgId: cmid,
        username: m.username,
        displayName: m.displayName,
        text: m.text,
        time: '${d['timestamp'] ?? m.time}',
        dateKey: m.dateKey,
        avatar: '${d['avatar'] ?? m.avatar}',
        fileUrl: '${d['file_url'] ?? m.fileUrl}',
        fileType: '${d['file_type'] ?? m.fileType}',
        isMe: true,
        replyToId: m.replyToId,
        replyAuthor: m.replyAuthor,
        replyText: m.replyText,
        reactions: m.reactions,
        forwardFrom: '${d['forward_from'] ?? m.forwardFrom}',
        forwardFromUsername: '${d['forward_from_username'] ?? m.forwardFromUsername}',
        isPro: d['is_pro'] == true,
        isOfficial: d['is_official'] == true,
        adminTitle: '${d['admin_title'] ?? ''}',
        isOwner: d['sender_is_owner'] == true,
        seenCount: m.seenCount,
        // v1.2.1 — keep the local media metadata (dims/music tags)
        // v1.3.2 — prefer the server echo's values when present
        localPath: m.localPath,
        fileSize: m.fileSize,
        mediaW: mm.w > 0 ? mm.w : m.mediaW,
        mediaH: mm.h > 0 ? mm.h : m.mediaH,
        mediaTitle: mm.title.isNotEmpty ? mm.title : m.mediaTitle,
        mediaArtist: mm.artist.isNotEmpty ? mm.artist : m.mediaArtist,
        mediaCover: mm.cover.isNotEmpty ? mm.cover : m.mediaCover,
        mediaDurMs: mm.durMs > 0 ? mm.durMs : m.mediaDurMs,
        isVoiceNote: mm.voice || m.isVoiceNote,
        isMusicKind: mm.music || m.isMusicKind,
        albumId: m.albumId,
      );
      _persist();
      notifyListeners();
    }
  }

  void retryFailed(String cmid) {
    final idx = _messages.indexWhere((m) => m.clientMsgId == cmid);
    if (idx < 0) return;
    _messages[idx] = _messages[idx].copyWith(pending: true, failed: false);
    notifyListeners();
    SocketService.I.emit('send_message', _payloadFor(_messages[idx]));
    unawaited(_awaitConfirmation(cmid));
  }

  /// Toggle an emoji reaction on a confirmed message.
  void toggleReaction(Message m, String emoji) {
    if (m.id <= 0) return; // optimistic messages can't carry reactions yet
    SocketService.I.toggleReaction(m.id, emoji,
        chatId: kind == ChatKind.pv ? chatId : null);
    // Optimistic local toggle; the reaction_update echo confirms it.
    final mine = ApiService.I.cachedUsername;
    final list = List<ReactionSummary>.from(m.reactions);
    final i = list.indexWhere((r) => r.emoji == emoji);
    if (i >= 0) {
      final r = list[i];
      final hadMine = r.usernames.contains(mine);
      if (hadMine && r.count <= 1) {
        list.removeAt(i);
      } else {
        list[i] = ReactionSummary(
          emoji: r.emoji,
          count: r.count + (hadMine ? -1 : 1),
          usernames: hadMine
              ? r.usernames.where((u) => u != mine).toList()
              : [...r.usernames, mine],
        );
      }
    } else {
      list.add(ReactionSummary(emoji: emoji, count: 1, usernames: [mine]));
    }
    final idx = _messages.indexWhere((x) => x.id == m.id);
    if (idx >= 0) {
      _messages[idx] = _messages[idx].copyWith(reactions: list);
      _persist();
      notifyListeners();
    }
  }

  Future<String?> sendImage(String filePath) async {
    final res = await ApiService.I.uploadImage(filePath);
    if (!res.ok) return null;
    final url = res.data?['file_url'] ?? '';
    final now = DateTime.now();
    final cmid = 'm_${now.millisecondsSinceEpoch}';
    final msg = Message(
      id: 0,
      clientMsgId: cmid,
      username: ApiService.I.cachedUsername,
      displayName: ApiService.I.cachedName,
      text: '',
      time: '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
      dateKey: '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}',
      avatar: ApiService.I.cachedAvatar,
      fileUrl: url,
      fileType: 'image',
      isMe: true,
      pending: true,
    );
    _messages.add(msg);
    notifyListeners();
    _persist();
    SocketService.I.emit('send_message', _payloadFor(msg));
    unawaited(_awaitConfirmation(cmid));
    return url;
  }

  /// Generic media send (image / video / audio / gif after upload).
  /// v1.0.6 Telegram-style flow:
  ///  1. optimistic bubble with the LOCAL file + file size
  ///  2. upload with real progress → ring updates live (like Telegram)
  ///  3. swap to the remote URL and emit over the socket
  /// v1.1.0 — [albumId] groups several photos into ONE rendered bubble.
  /// v1.2.1 — Telegram media metadata: image dims kill the send-jump; music
  /// tags (title/artist/cover) power the dedicated music bubble; voice notes
  /// carry their real duration.
  Future<bool> sendMedia(String filePath,
      {required String fileType,
      String caption = '',
      String? replyToId,
      String? replyAuthor,
      String? replyText,
      String albumId = '',
      bool isVoiceNote = false,
      int durationMs = 0,
      String mediaTitle = '',
      String mediaArtist = '',
      String mediaCover = '',
      int mediaWidth = 0,
      int mediaHeight = 0}) async {
    // v1.4.0 — ارسال مدیا هم یعنی برگشت به انتهای چت
    holdIncoming = false;
    flushIncoming();
    final now = DateTime.now();
    final cmid = 'm_${now.millisecondsSinceEpoch}';
    int size = 0;
    try {
      size = File(filePath).lengthSync();
    } catch (_) {}
    // Telegram reserves the photo aspect BEFORE the upload starts — decode
    // the header synchronously-ish so the bubble never shifts on first paint.
    var w = mediaWidth, h = mediaHeight;
    if ((fileType == 'image') && (w == 0 || h == 0)) {
      try {
        final d = await _decodeImageSize(filePath);
        w = d.$1;
        h = d.$2;
      } catch (_) {}
    }
    final msg = Message(
      id: 0,
      clientMsgId: cmid,
      username: ApiService.I.cachedUsername,
      displayName: ApiService.I.cachedName,
      text: caption,
      time: '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
      dateKey: '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}',
      avatar: ApiService.I.cachedAvatar,
      localPath: filePath,
      fileSize: size,
      fileType: fileType,
      isMe: true,
      pending: true,
      albumId: albumId,
      isVoiceNote: isVoiceNote,
      mediaDurMs: durationMs,
      mediaTitle: mediaTitle,
      mediaArtist: mediaArtist,
      mediaCover: mediaCover,
      mediaW: w,
      mediaH: h,
      replyToId: replyToId,
      replyAuthor: replyAuthor,
      replyText: replyText,
    );
    _messages.add(msg);
    _sending = true;
    notifyListeners();
    _persist();

    // Upload with live progress (throttled UI updates).
    final token = TransferCancelToken();
    UploadRegistry.tokens[cmid] = token;
    DateTime lastTick = DateTime.fromMillisecondsSinceEpoch(0);
    final res = await ApiService.I.uploadMediaWithProgress(filePath,
        fileType: fileType,
        cancel: token,
        onBytes: (sent, total) {
      final n = DateTime.now();
      if (n.difference(lastTick).inMilliseconds < 100) return;
      lastTick = n;
      final idx = _messages.indexWhere((m) => m.clientMsgId == cmid);
      if (idx >= 0 && !_disposed) {
        _messages[idx] = _messages[idx].copyWith(
            uploadPct: total > 0 ? (sent / total).clamp(0.0, 0.99) : 0,
            uploadSent: sent);
        notifyListeners();
      }
    });
    UploadRegistry.tokens.remove(cmid);
    if (token.isCancelled) {
      // کاربر ✕ زد: حباب بی‌سروصدا حذف می‌شود (نه «ناموفق»)
      _messages.removeWhere((m) => m.clientMsgId == cmid);
      _sending = _messages.any((m) => m.pending);
      if (!_disposed) {
        _persist();
        notifyListeners();
      }
      return false;
    }
    _sending = false;
    if (!_disposed && res.ok && res.data != null) {
      final url = res.data!['file_url'] ?? '';
      if (url.isEmpty) return false;
      final idx = _messages.indexWhere((m) => m.clientMsgId == cmid);
      if (idx >= 0) {
        // v1.3.2 — localPath is KEPT after the upload: the bubble keeps
        // painting the local file and crossfades to the remote URL only
        // when it has decoded (chat_bubbles [smoothConfirm]) — the sent
        // photo/GIF no longer flashes a placeholder at confirm time.
        // (localPath is never persisted to the message cache, so leaving
        // the chat and coming back shows the pure remote copy.)
        _messages[idx] = _messages[idx].copyWith(
          fileUrl: url,
          uploadPct: 0,
        );
        _persist();
        notifyListeners();
        SocketService.I.emit('send_message', _payloadFor(_messages[idx]));
        SocketService.I.sendTyping(serverRoom, false);
        unawaited(_awaitConfirmation(cmid));
        return true;
      }
      return true;
    }
    // failure → failed bubble (tap to retry deletes / re-sends)
    final idx = _messages.indexWhere((m) => m.clientMsgId == cmid);
    if (idx >= 0 && !_disposed) {
      _messages[idx] = _messages[idx].copyWith(pending: false, failed: true);
      _persist();
      notifyListeners();
    }
    return false;
  }

  /// v1.2.1 — image pixel size via dart:ui ImageDescriptor: parses ONLY the
  /// container header (no full decode) → exact w/h in a couple of ms.
  static Future<(int, int)> _decodeImageSize(String path) async {
    final bytes = await File(path).readAsBytes();
    final buf = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final desc = await ui.ImageDescriptor.encoded(buf);
      final r = (desc.width, desc.height);
      desc.dispose();
      return r;
    } finally {
      buf.dispose();
    }
  }

  /// Animated delete (v1.0.6 → v1.1.0 FIXED): collapse + fade first, then
  /// really remove.
  /// v1.1.0 CRITICAL FIX: the old matcher
  ///   `x.clientMsgId == m.clientMsgId || (m.id > 0 && x.id == m.id)`
  /// matched EVERY network message when m.clientMsgId was '' (server rows
  /// have no client id) → deleting ONE message wiped the whole list.
  void deleteOwn(Message m) {
    if (m.id > 0) SocketService.I.deleteMessage(m.id);
    bool matches(Message x) =>
        m.id > 0 ? x.id == m.id : m.clientMsgId.isNotEmpty && x.clientMsgId == m.clientMsgId;
    final idx = _messages.indexWhere(matches);
    if (idx < 0) return;
    _messages[idx] = _messages[idx].copyWith(removing: true);
    notifyListeners();
    Timer(const Duration(milliseconds: 240), () {
      if (_disposed) return;
      _messages.removeWhere(matches);
      _persist();
      notifyListeners();
    });
  }

  /// v1.0.7 — edit own text message (like index /edit_message). Optimistic:
  /// the bubble updates instantly, the server broadcast keeps peers in sync.
  Future<bool> editMessage(Message m, String newText) async {
    final text = newText.trim();
    if (text.isEmpty || text == m.text) return true;
    if (m.id <= 0) return false; // optimistic-only messages can't be edited
    final idx = _messages.indexWhere((x) => x.id == m.id);
    if (idx < 0) return false;
    final old = _messages[idx].text;
    _messages[idx] =
        _messages[idx].copyWith(text: text, isEdited: true);
    _persist();
    notifyListeners();
    final r = await ApiService.I.editMessage(m.id, text);
    if (r.ok) return true;
    // roll back on failure
    final i2 = _messages.indexWhere((x) => x.id == m.id);
    if (i2 >= 0 && !_disposed) {
      _messages[i2] = _messages[i2].copyWith(text: old, isEdited: false);
      _persist();
      notifyListeners();
    }
    return false;
  }

  Future<bool> _emitOptimistic({
    required String text,
    required String fileUrl,
    required String fileType,
    String? replyToId,
    String? replyAuthor,
    String? replyText,
  }) async {
    final now = DateTime.now();
    final cmid = 'm_${now.millisecondsSinceEpoch}';
    final msg = Message(
      id: 0,
      clientMsgId: cmid,
      username: ApiService.I.cachedUsername,
      displayName: ApiService.I.cachedName,
      text: text,
      time: '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
      dateKey: '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}',
      avatar: ApiService.I.cachedAvatar,
      fileUrl: fileUrl,
      fileType: fileType,
      isMe: true,
      pending: true,
      replyToId: replyToId,
      replyAuthor: replyAuthor,
      replyText: replyText,
    );
    _messages.add(msg);
    _sending = true;
    notifyListeners();
    _persist();
    SocketService.I.emit('send_message', _payloadFor(msg));
    SocketService.I.sendTyping(serverRoom, false);
    unawaited(_awaitConfirmation(cmid));
    _sending = false;
    return true;
  }

  Future<bool> sendGif(String gifUrl, {String? replyToId, String? replyAuthor, String? replyText}) async {
    final url = gifUrl.trim();
    if (url.isEmpty || _sending) return false;
    // v1.4.0 — ارسال گیف هم یعنی برگشت به انتهای چت
    holdIncoming = false;
    flushIncoming();
    final now = DateTime.now();
    final cmid = 'm_${now.millisecondsSinceEpoch}';
    final msg = Message(
      id: 0,
      clientMsgId: cmid,
      username: ApiService.I.cachedUsername,
      displayName: ApiService.I.cachedName,
      text: '',
      time: '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
      dateKey: '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}',
      avatar: ApiService.I.cachedAvatar,
      fileUrl: url,
      fileType: 'gif',
      isMe: true,
      pending: true,
      replyToId: replyToId,
      replyAuthor: replyAuthor,
      replyText: replyText,
    );
    _messages.add(msg);
    _sending = true;
    notifyListeners();
    _persist();
    SocketService.I.emit('send_message', _payloadFor(msg));
    unawaited(_awaitConfirmation(cmid));
    _sending = false;
    return true;
  }

  void setTyping(bool typing) => SocketService.I.sendTyping(serverRoom, typing);

  /// v1.0.8 — online count inside this group = |online ∩ members|.
  void _recountGroupOnline() {
    if (kind != ChatKind.group && kind != ChatKind.channel) {
      _groupMemberOnline = 0;
      return;
    }
    if (_memberUsernames.isEmpty) {
      _groupMemberOnline = 0;
      return;
    }
    _groupMemberOnline = _memberUsernames
        .where(_onlineUsers.contains)
        .length;
  }

  /// v1.0.8 — refresh meta after leave / mute / ban etc.
  Future<void> reloadMeta() async {
    if (kind != ChatKind.group && kind != ChatKind.channel) return;
    final res = await ApiService.I.roomInfo(roomId);
    if (_disposed || !res.ok || res.data == null) return;
    final j = res.data!;
    _memberCount = j['member_count'] is int
        ? j['member_count'] as int
        : int.tryParse('${j['member_count']}') ?? 0;
    _ingestMembers(j);
    _recountGroupOnline();
    notifyListeners();
  }

  // ------------------------------------------------ cache

  void _persist() {
    // v1.1.1 — DEBOUNCED disk write: history pagination used to jsonEncode
    // the whole tail on every page, which stuttered the UI thread on weak
    // phones. Coalesce the writes instead.
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 700), _doPersist);
  }

  Timer? _persistTimer;

  void _doPersist() {
    if (_messages.isEmpty) return;
    // Keep only the most recent 200 messages on disk (fast + bounded).
    final slice = _messages.length > 200
        ? _messages.sublist(_messages.length - 200)
        : _messages;
    CacheService.I.put(cacheKey, slice.map((m) => m.toCache()).toList());
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _typingTimer?.cancel();
    _seenTimer?.cancel();
    _readPing?.cancel();
    _persistTimer?.cancel();
    _doPersist(); // v1.1.1 — flush the coalesced cache write on close
    for (final t in _groupTyping.values) {
      t.cancel();
    }
    _subNew?.cancel();
    _subNewPv?.cancel();
    _subTyping?.cancel();
    _subOnline?.cancel();
    _subDel?.cancel();
    _subStatus?.cancel();
    _subUserOn?.cancel();
    _subUserOff?.cancel();
    _subReactions?.cancel();
    _subPins?.cancel();
    switch (kind) {
      case ChatKind.general:
        SocketService.I.leaveGeneral();
        break;
      case ChatKind.pv:
        SocketService.I.leavePv(chatId);
        break;
      default:
        SocketService.I.leaveGroup(roomId);
    }
    super.dispose();
  }
}
