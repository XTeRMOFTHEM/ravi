import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'api_service.dart';
import 'cache_service.dart';
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
  });

  final List<Message> _messages = [];
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

  // v1.0.6: room meta from /api/room/<id>/messages (can_post, room_type…).
  bool _canPost = true;
  bool get canPost => _canPost;
  String _roomType = '';
  String get roomType => _roomType;
  // v1.0.9 — my role in this room ('owner' | 'admin' | 'member')
  String _myRole = 'member';
  String get myRole => _myRole;

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

  StreamSubscription? _subNew, _subNewPv, _subTyping, _subOnline, _subDel, _subStatus, _subUserOn, _subUserOff, _subReactions, _subEdited;

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
        _memberUsernames = ((j['members'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => '${e['username'] ?? ''}')
            .where((u) => u.isNotEmpty)
            .toList();
        _recountGroupOnline();
        notifyListeners();
      });
    }

    // 2) instant disk cache
    final cached = CacheService.I.getSync(cacheKey);
    if (cached != null && cached.isNotEmpty) {
      _messages
        ..clear()
        ..addAll(cached.map(Message.fromCache).where((m) => !m.pending));
      notifyListeners();
    }

    // 3) network history
    await refresh();
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
      final fresh = res.data!;
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
      _historyDone = fresh.length < 60;
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
    _loadingHistory = true;
    notifyListeners();
    final oldest = _messages.first.id;
    final res = switch (kind) {
      ChatKind.general => await ApiService.I.generalMessages(before: oldest, limit: 40),
      ChatKind.pv => await ApiService.I.pvMessages(chatId, before: oldest, limit: 40),
      _ => await ApiService.I.roomMessages(roomId, before: oldest, limit: 40),
    };
    if (res.ok && res.data != null) {
      if (res.data!.isNotEmpty) {
        _messages.insertAll(0, res.data!);
        _persist();
      }
      if (res.data!.length < 40) _historyDone = true;
    }
    _loadingHistory = false;
    notifyListeners();
  }

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
      if (kind == ChatKind.pv) _onIncoming(d);
      if (d['private_chat_id'] != null &&
          '${d['private_chat_id']}' == '$chatId') {
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
    // de-dup by id
    if (msg.id > 0 && _messages.any((m) => m.id == msg.id)) return;
    _messages.add(msg);
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
    return payload;
  }

  Future<bool> send(String text, {String? replyToId, String? replyAuthor, String? replyText}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _sending) return false;
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
        seenCount: m.seenCount,
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
  Future<bool> sendMedia(String filePath,
      {required String fileType,
      String caption = '',
      String? replyToId,
      String? replyAuthor,
      String? replyText}) async {
    final now = DateTime.now();
    final cmid = 'm_${now.millisecondsSinceEpoch}';
    int size = 0;
    try {
      size = File(filePath).lengthSync();
    } catch (_) {}
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
      replyToId: replyToId,
      replyAuthor: replyAuthor,
      replyText: replyText,
    );
    _messages.add(msg);
    _sending = true;
    notifyListeners();
    _persist();

    // Upload with live progress (throttled UI updates).
    DateTime lastTick = DateTime.now();
    final res = await ApiService.I.uploadMediaWithProgress(filePath,
        fileType: fileType, onProgress: (pct) {
      final n = DateTime.now();
      final done = pct >= 1.0;
      if (!done && n.difference(lastTick).inMilliseconds < 120) return;
      lastTick = n;
      final idx = _messages.indexWhere((m) => m.clientMsgId == cmid);
      if (idx >= 0) {
        _messages[idx] = _messages[idx].copyWith(uploadPct: pct);
        notifyListeners();
      }
    });
    _sending = false;
    if (!_disposed && res.ok && res.data != null) {
      final url = res.data!['file_url'] ?? '';
      if (url.isEmpty) return false;
      final idx = _messages.indexWhere((m) => m.clientMsgId == cmid);
      if (idx >= 0) {
        _messages[idx] = _messages[idx].copyWith(
          fileUrl: url,
          localPath: '',
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

  /// Animated delete (v1.0.6): collapse + fade first, then really remove —
  /// mirrors the smooth removal of the web version.
  void deleteOwn(Message m) {
    if (m.id > 0) SocketService.I.deleteMessage(m.id);
    final idx = _messages.indexWhere(
        (x) => x.clientMsgId == m.clientMsgId || (m.id > 0 && x.id == m.id));
    if (idx < 0) return;
    _messages[idx] = _messages[idx].copyWith(removing: true);
    notifyListeners();
    Timer(const Duration(milliseconds: 240), () {
      if (_disposed) return;
      _messages.removeWhere(
          (x) => x.clientMsgId == m.clientMsgId || (m.id > 0 && x.id == m.id));
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
    _memberUsernames = ((j['members'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => '${e['username'] ?? ''}')
        .where((u) => u.isNotEmpty)
        .toList();
    _recountGroupOnline();
    notifyListeners();
  }

  // ------------------------------------------------ cache

  void _persist() {
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
