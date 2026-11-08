import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as sio;

import 'constants.dart';

/// Central Socket.IO manager — one connection for the whole app, with
/// auto-reconnect and re-join logic (mirrors the web client behaviour).
///
/// v1.0.5 CRITICAL FIX: the Flask-SocketIO server authenticates the socket
/// upgrade through the **Flask session cookie**. The browser sends it
/// automatically; a raw socket.io client does NOT. Without the cookie the
/// server treated the app as anonymous:
///   • `handle_send_message` silently dropped every message  → endless "retry"
///   • `join_group_room`/`join_pv` were no-ops               → dead chats
///   • `toggle_reaction` was ignored                          → no reactions
/// We now attach the Cookie header and rebuild the socket whenever the
/// session changes (login / logout / re-login).
class SocketService {
  SocketService._();
  static final SocketService I = SocketService._();

  sio.Socket? _socket;
  String _cookie = '';
  bool _configured = false;

  // ---- event streams (broadcast; UI subscribes and cancels on dispose) ----
  final _newMessage = StreamController<Map<String, dynamic>>.broadcast();
  final _newPvMessage = StreamController<Map<String, dynamic>>.broadcast();
  final _pvChatsUpdated = StreamController<Map<String, dynamic>>.broadcast();
  final _typing = StreamController<Map<String, dynamic>>.broadcast();
  final _onlineList = StreamController<List<String>>.broadcast();
  final _userOnline = StreamController<String>.broadcast();
  final _userOffline = StreamController<String>.broadcast();
  final _messageDeleted = StreamController<Map<String, dynamic>>.broadcast();
  final _messageEdited = StreamController<Map<String, dynamic>>.broadcast();
  final _reactionUpdate = StreamController<Map<String, dynamic>>.broadcast();
  final _groupUnread = StreamController<Map<String, dynamic>>.broadcast();
  final _serverError = StreamController<Map<String, dynamic>>.broadcast();
  final _status = StreamController<SocketStatus>.broadcast();
  // v1.0.9 — real-time block/unblock + live room settings (slow mode etc.)
  final _userBlocked = StreamController<Map<String, dynamic>>.broadcast();
  final _userUnblocked = StreamController<Map<String, dynamic>>.broadcast();
  final _roomSettings = StreamController<Map<String, dynamic>>.broadcast();
  // v1.1.0 — membership events (join / leave / kick / ban) for the thin
  // glass center toasts, exactly like Telegram's service messages.
  final _memberEvent = StreamController<Map<String, dynamic>>.broadcast();
  // v1.1.1 — pinned-message updates (room + pv)
  final _pinsUpdate = StreamController<Map<String, dynamic>>.broadcast();
  // v1.5.0 — پیش‌نمایش زنده‌ی ردیف گروه/کانال در لیست چت‌ها (بدون رفرش)
  final _roomChatsUpdated = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get onNewMessage => _newMessage.stream;
  Stream<Map<String, dynamic>> get onNewPvMessage => _newPvMessage.stream;
  Stream<Map<String, dynamic>> get onPvChatsUpdated => _pvChatsUpdated.stream;
  Stream<Map<String, dynamic>> get onTyping => _typing.stream;
  Stream<List<String>> get onOnlineList => _onlineList.stream;
  Stream<String> get onUserOnline => _userOnline.stream;
  Stream<String> get onUserOffline => _userOffline.stream;
  Stream<Map<String, dynamic>> get onMessageDeleted => _messageDeleted.stream;
  Stream<Map<String, dynamic>> get onMessageEdited => _messageEdited.stream;
  Stream<Map<String, dynamic>> get onReactionUpdate => _reactionUpdate.stream;
  Stream<Map<String, dynamic>> get onGroupUnread => _groupUnread.stream;
  Stream<Map<String, dynamic>> get onServerError => _serverError.stream;
  Stream<SocketStatus> get onStatus => _status.stream;
  Stream<Map<String, dynamic>> get onUserBlocked => _userBlocked.stream;
  Stream<Map<String, dynamic>> get onUserUnblocked => _userUnblocked.stream;
  Stream<Map<String, dynamic>> get onRoomSettings => _roomSettings.stream;
  Stream<Map<String, dynamic>> get onMemberEvent => _memberEvent.stream;
  Stream<Map<String, dynamic>> get onPinsUpdate => _pinsUpdate.stream;
  // v1.5.0 — پیش‌نمایش گروه/کانال (اسم/ساعت/متن آخرین پیام) بدون رفرش
  Stream<Map<String, dynamic>> get onRoomChatsUpdated => _roomChatsUpdated.stream;

  bool get connected => _socket?.connected ?? false;

  /// Attach the (fresh) Flask session cookie. Must be called after
  /// ApiService.init() and again after every login/logout.
  /// An EMPTY cookie never opens a socket — an anonymous connection is
  /// useless server-side (send_message is dropped) and keeps timers alive.
  void configure({required String cookie}) {
    final changed = cookie != _cookie;
    _cookie = cookie;
    _configured = cookie.isNotEmpty;
    if (changed && _socket != null) {
      // Tear down so the next connect() re-upgrades with the new session.
      dispose();
    }
    if (_socket == null && _configured) _build();
  }

  void connect() {
    if (!_configured) return; // wait for a real session cookie
    if (_socket == null) _build();
  }

  void _build() {
    _status.add(SocketStatus.connecting);
    final headers = <String, String>{
      'X-Requested-With': 'XMLHttpRequest',
    };
    if (_cookie.isNotEmpty) headers['Cookie'] = _cookie;

    _socket = sio.io(
      kBaseUrl,
      sio.OptionBuilder()
          .setTransports(['websocket', 'polling'])
          .enableForceNew()
          .enableReconnection()
          .setReconnectionAttempts(9999)
          .setReconnectionDelay(1200)
          .setReconnectionDelayMax(6000)
          .setExtraHeaders(headers)
          .build(),
    );

    _socket!
      ..onConnect((_) {
        _status.add(SocketStatus.connected);
        // Re-join rooms after every (re)connect — like the web client.
        for (final _ in _joinedGeneral) emit('join_general', {});
        for (final id in _joinedPv) emit('join_pv', {'chat_id': id});
        for (final id in _joinedGroups) emit('join_group_room', {'room_id': id});
        _flushQueue();
      })
      ..onDisconnect((_) => _status.add(SocketStatus.disconnected))
      ..onConnectError((_) => _status.add(SocketStatus.disconnected))
      ..on('new_message', (d) => _safeAdd(_newMessage, d))
      ..on('new_pv_message', (d) => _safeAdd(_newPvMessage, d))
      ..on('pv_chats_updated', (d) => _safeAdd(_pvChatsUpdated, d))
      ..on('user_typing', (d) => _safeAdd(_typing, d))
      ..on('online_list', (d) {
        final list = (d is List) ? d.map((e) => '$e').toList() : <String>[];
        _onlineList.add(list);
      })
      ..on('user_online', (d) {
        final u = (d is Map ? d['username'] : null);
        if (u != null) _userOnline.add('$u');
      })
      ..on('user_offline', (d) {
        final u = (d is Map ? d['username'] : null);
        if (u != null) _userOffline.add('$u');
      })
      ..on('message_deleted', (d) => _safeAdd(_messageDeleted, d))
      ..on('message_edited', (d) => _safeAdd(_messageEdited, d))
      ..on('reaction_update', (d) => _safeAdd(_reactionUpdate, d))
      ..on('group_unread', (d) => _safeAdd(_groupUnread, d))
      ..on('group_unread_reset', (d) => _safeAdd(_groupUnread, d))
      ..on('user_blocked', (d) => _safeAdd(_userBlocked, d))
      ..on('user_unblocked', (d) => _safeAdd(_userUnblocked, d))
      ..on('room_settings_updated', (d) => _safeAdd(_roomSettings, d))
      ..on('error', (d) => _safeAdd(_serverError, d))
      // v1.1.0 — every plausible membership event name the backend may emit;
      // unknown ones simply never fire (zero cost).
      ..on('room_member_joined', (d) => _member(d, 'join'))
      ..on('member_joined', (d) => _member(d, 'join'))
      ..on('user_joined', (d) => _member(d, 'join'))
      ..on('member_added', (d) => _member(d, 'join'))
      ..on('room_member_left', (d) => _member(d, 'leave'))
      ..on('member_left', (d) => _member(d, 'leave'))
      ..on('user_left', (d) => _member(d, 'leave'))
      ..on('member_kicked', (d) => _member(d, 'kick'))
      ..on('user_kicked', (d) => _member(d, 'kick'))
      ..on('member_removed', (d) => _member(d, 'kick'))
      ..on('member_banned', (d) => _member(d, 'ban'))
      ..on('user_banned', (d) => _member(d, 'ban'))
      // v1.1.1 — pins: room + pv share one stream (payload carries the id)
      ..on('room_pins_update', (d) => _safeAdd(_pinsUpdate, d))
      ..on('pv_pins_update', (d) => _safeAdd(_pinsUpdate, d))
      // v1.5.0 — پیش‌نمایش زنده‌ی گروه/کانال در لیست چت‌ها
      ..on('room_chats_updated', (d) => _safeAdd(_roomChatsUpdated, d));
  }

  void _safeAdd(StreamController<Map<String, dynamic>> c, dynamic d) {
    if (d is Map) c.add(Map<String, dynamic>.from(d));
  }

  void _member(dynamic d, String kind) {
    if (d is! Map) return;
    final m = Map<String, dynamic>.from(d);
    m['event_kind'] = kind;
    _memberEvent.add(m);
  }

  // ---- room bookkeeping (re-joined automatically on reconnect) ----
  final Set<String> _joinedGeneral = {}; // 'general'
  final Set<int> _joinedPv = {};
  final Set<String> _joinedGroups = {};

  void joinGeneral() {
    _joinedGeneral.add('general');
    emit('join_general', {});
  }

  void leaveGeneral() {
    _joinedGeneral.remove('general');
  }

  void joinPv(int chatId) {
    _joinedPv.add(chatId);
    emit('join_pv', {'chat_id': chatId});
  }

  void leavePv(int chatId) {
    _joinedPv.remove(chatId);
    emit('leave_pv', {'chat_id': chatId});
  }

  void joinGroup(String roomId) {
    _joinedGroups.add(roomId);
    emit('join_group_room', {'room_id': roomId});
  }

  void leaveGroup(String roomId) {
    _joinedGroups.remove(roomId);
    emit('leave_group_room', {'room_id': roomId});
  }

  // ---- offline-tolerant emit queue (like web `unsent`) ----
  final List<MapEntry<String, Map<String, dynamic>>> _queue = [];

  void emit(String event, Map<String, dynamic> payload) {
    if (connected) {
      try {
        _socket?.emit(event, payload);
      } catch (_) {
        _queue.add(MapEntry(event, payload));
      }
    } else if (event == 'send_message') {
      // Only chat sends are queued; bookkeeping events are skipped when offline.
      _queue.add(MapEntry(event, payload));
      if (_queue.length > 60) _queue.removeAt(0);
    }
  }

  void _flushQueue() {
    if (_queue.isEmpty) return;
    final copy = List<MapEntry<String, Map<String, dynamic>>>.from(_queue);
    _queue.clear();
    for (final e in copy) {
      emit(e.key, e.value);
    }
  }

  // ---- typing helper (throttled by caller) ----
  void sendTyping(String room, bool isTyping) {
    emit('typing', {'is_typing': isTyping, 'room': room});
  }

  void markGeneralRead(List<int> messageIds) {
    for (final id in messageIds) {
      emit('mark_as_read', {'message_id': id, 'room': 'general'});
    }
  }

  void markPvAllRead(int chatId) => emit('mark_all_pv_read', {'chat_id': chatId});

  void deleteMessage(int messageId) =>
      emit('delete_message', {'message_id': messageId});

  /// Toggle a reaction (backend ALLOWED_REACTIONS: 👍 ❤️ 😂 😮 😢 🙏 🔥 🎉).
  void toggleReaction(int messageId, String emoji, {int? chatId}) {
    emit('toggle_reaction', {
      'message_id': messageId,
      'emoji': emoji,
      if (chatId != null) 'chat_id': chatId,
    });
  }

  void dispose() {
    try {
      _socket?.dispose();
    } catch (_) {}
    _socket = null;
  }
}

enum SocketStatus { connecting, connected, disconnected }
