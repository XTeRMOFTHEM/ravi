import 'dart:async';
import 'dart:ui';
import 'dart:io';
import 'dart:math' as math;

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/media_download_manager.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api_service.dart';
import '../../core/app_state.dart';
import '../../core/chat_bg.dart';
import '../../core/chat_controller.dart';
import '../../core/constants.dart';
import '../../core/i18n.dart';
import '../../core/models.dart';
import '../../core/socket_service.dart';
import '../home/group_info_screen.dart';
import '../home/user_profile_screen.dart';
import '../widgets/common.dart';
import '../widgets/ravi_alerts.dart';
import 'chat_bubbles.dart';
import 'emoji_gif_panel.dart';
import 'forward_screen.dart';
import 'media_preview.dart';
import 'message_action_panel.dart';
import 'photo_viewer.dart';
import 'player_bar.dart';
import 'room_preview_sheet.dart';
import 'swipe_to_reply.dart';

/// Chatroom — blur header, bubbles, swipe-to-reply, reactions, voice notes
/// (hold + lock), Telegram upload rings, mention/link panels, forwarding.
class ChatScreen extends StatefulWidget {
  final ChatKind kind;
  final String title;
  final String peerUsername;
  final String avatarPath;
  final int chatId;
  final String roomId;
  final bool canPost;

  /// v1.4.0 — سیو مسیج: چت با خودمان؛ هدر به‌جای آواتار، آیکون بوکمارک نشان می‌دهد
  final bool isSelfChat;

  const ChatScreen({
    super.key,
    required this.kind,
    required this.title,
    this.peerUsername = '',
    this.avatarPath = '',
    this.chatId = 0,
    this.roomId = 'general',
    this.canPost = true,
    this.isSelfChat = false,
  });

  static Route route({
    required ChatKind kind,
    required String title,
    String peerUsername = '',
    String avatarPath = '',
    int chatId = 0,
    String roomId = 'general',
    bool canPost = true,
    bool isSelfChat = false,
  }) {
    return PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 260),
      reverseTransitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (_, __, ___) => ChatScreen(
        kind: kind,
        title: title,
        peerUsername: peerUsername,
        avatarPath: avatarPath,
        chatId: chatId,
        roomId: roomId,
        canPost: canPost,
        isSelfChat: isSelfChat,
      ),
      transitionsBuilder: (_, anim, __, child) {
        final curved =
            CurvedAnimation(parent: anim, curve: const Cubic(0.22, 0.61, 0.36, 1));
        return SlideTransition(
          position: Tween(begin: const Offset(0, 0.04), end: Offset.zero)
              .animate(curved),
          child: FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween(begin: 0.99, end: 1.0).animate(curved),
              child: child,
            ),
          ),
        );
      },
      opaque: false,
      barrierColor: Colors.black38,
    );
  }

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final ChatController _ctl = ChatController(
    kind: widget.kind,
    chatId: widget.chatId,
    roomId: widget.kind == ChatKind.general ? 'general' : widget.roomId,
    selfOnly: widget.isSelfChat,
  );
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _inputFocus = FocusNode();

  String? _replyToId, _replyAuthor, _replyText;
  bool _emojiOpen = false;
  int? _highlightId; // message being highlighted after a reply-jump

  // ---- v1.3.1 — GLIDING KEYBOARD (WhatsUp/Telegram logic) ----
  // The remembered keyboard height lets the emoji/GIF panel occupy EXACTLY
  // the keyboard's space (switching keyboard⇄panel never reflows the chat)
  // and `resizeToAvoidBottomInset:false` + AnimatedPadding moves the
  // composer up WITH the keyboard's own animation — no more snap/jump.
  double _kbH = 262.0;
  static const String _kKbPref = 'ravi_chat_kb_h_v1';

  // ---- v1.0.9 — selection mode (Telegram-style) ----
  bool _selectionMode = false;
  final Set<int> _selected = {};

  // ---- v1.0.9 — edit inside the composer (Telegram-style) ----
  Message? _editing;

  // ---- v1.0.9 — sticky glass date label under the header ----
  // v1.2.0 PERF — the sticky date now lives in a ValueNotifier so day
  // crossings while scrolling do NOT rebuild the whole chat list (this was
  // one of the biggest frame-drops on weak phones).
  final ValueNotifier<String?> _stickyDateN = ValueNotifier(null);
  DateTime _lastStickyCalc = DateTime.fromMillisecondsSinceEpoch(0);
  // v1.1.1 — the in-list day pills are GONE (they rendered after basically
  // every bubble because PV payloads only carried HH:MM, and each pill
  // insert/remove shifted the list = jumps). The ONLY date chip is the
  // sticky one under the header, exactly like the user asked.
  final Map<int, String> _msgDates = {};

  // ---- v1.1.0 — smooth arrival: appear-animation + scroll anchoring ----
  final Set<int> _liveIds = {}; // messages that arrived while the screen is open
  final Set<int> _knownIds = {};
  bool _listBootstrapped = false;
  int _lastCount = 0;
  double _lastMaxExtent = 0;
  bool _nearBottom = true;

  // ---- v1.0.9 — slow mode countdown ----
  int _slowRemaining = 0;
  Timer? _slowTimer;
  // jump-to-message: GlobalKey per rendered message id
  final Map<int, GlobalKey> _msgKeys = {};
  final Map<int, BuildContext> _msgCtx = {};

  // ---- voice recording state (v1.2.0 REBUILD, Telegram logic) ----
  final AudioRecorder _recorder = AudioRecorder();
  bool _recording = false;
  bool _recLocked = false;
  bool _recPaused = false;
  int _recMs = 0; // real elapsed milliseconds (no more 1s counter)
  int _recStartEpochMs = 0;
  int _recGen = 0; // generation guard: press→release races
  Timer? _recTimer;
  String? _recPath;
  bool _recCancelled = false;
  bool _micGranted = false; // cached permission → instant start
  double _lockDy = 0; // swipe-up distance while holding
  double _cancelDx = 0; // v1.0.8 — slide-away-to-cancel distance
  Offset? _holdPos;
  // v1.2.1 — the floating voice circle FOLLOWS THE FINGER (Telegram): the
  // user always sees what's happening while holding the mic.
  Offset _recPointer = Offset.zero;
  Size _screenSize = Size.zero;
  // v1.2.0 — live amplitude waveform while recording (Telegram feel)
  final List<double> _recAmps = [];
  static const int _recAmpBars = 34;
  // v1.2.0 — suppress load-older while the anchor jump settles
  DateTime _lastOlderTry = DateTime.fromMillisecondsSinceEpoch(0);

  // v1.1.0 — composer text direction follows the first strong character
  // (fixes emoji/EN landing "behind" Persian text while typing).
  TextDirection _inputDir = TextDirection.rtl;

  @override
  void initState() {
    super.initState();
    _ctl.load();
    _scroll.addListener(_onScroll);
    _input.addListener(_onInputChanged);
    _bindLive();
    // v1.3.1 — restore the remembered keyboard height for a jump-free
    // keyboard⇄emoji-panel swap (WhatsUp pattern).
    SharedPreferences.getInstance().then((p) {
      final v = p.getDouble(_kKbPref);
      if (v != null && v >= 180 && v <= 480 && mounted) {
        setState(() => _kbH = v);
      }
    });
    // v1.0.9 — THE unread-badge fix: opening a room now ALSO tells the server
    // (socket) “I have read everything” → the home badge on every device
    // resets. Previously only the DB row updated and the badge showed 56
    // forever. (pv already did this via mark_all_pv_read.)
    if (widget.kind == ChatKind.group || widget.kind == ChatKind.channel) {
      Future.delayed(const Duration(milliseconds: 400), () {
        SocketService.I.emit('group_read', {'room_id': _ctl.roomId});
        AppState.I.bumpRoomUnread(_ctl.roomId, -999);
      });
    }
  }

  // ---------- v1.1.1 — SERVER-side pins (multi-pin, Telegram-style) ----------

  Future<void> _togglePin(Message m) async {
    final already = _ctl.pins.any((p) => '${p['message_id']}' == '${m.id}');
    final ok = already ? await _ctl.unpinMessage(m.id) : await _ctl.pinMessage(m);
    if (!mounted) return;
    if (ok) {
      showGlassToast(context,
          already ? AppState.I.str.messageUnpinned : AppState.I.str.messagePinned,
          icon: Icons.push_pin_rounded,
          color: already ? null : const Color(0xFFF59E0B));
    } else {
      showGlassToast(context, AppState.I.str.error,
          icon: Icons.error_outline_rounded, color: const Color(0xFFEF4444));
    }
  }

  // v1.0.9 — real-time block/unblock + live room settings (slow mode…)
  StreamSubscription? _subBlocked, _subUnblocked, _subSettings, _subSrvErr;
  StreamSubscription? _subMember; // v1.1.0 — join/leave/kick toasts
  void _bindLive() {
    final sock = SocketService.I;
    _subBlocked = sock.onUserBlocked.listen((d) {
      if (widget.kind != ChatKind.pv) return;
      final by = '${d['blocked_by'] ?? ''}';
      final target = '${d['blocked_user'] ?? ''}';
      final me = ApiService.I.cachedUsername;
      if (by != me && target == widget.peerUsername) {
        // the peer blocked ME — react instantly
        _refreshPv();
        if (mounted) showGlassToast(context, AppState.I.str.blockedLiveToast,
            icon: Icons.block_rounded, color: const Color(0xFFEF4444));
      }
    });
    _subUnblocked = sock.onUserUnblocked.listen((d) {
      if (widget.kind != ChatKind.pv) return;
      final by = '${d['unblocked_by'] ?? ''}';
      final target = '${d['unblocked_user'] ?? ''}';
      final me = ApiService.I.cachedUsername;
      if (by != me && target == widget.peerUsername) {
        _refreshPv();
        if (mounted) showGlassToast(context, AppState.I.str.unblockedLiveToast,
            icon: Icons.lock_open_rounded);
      }
    });
    _subSettings = sock.onRoomSettings.listen((d) {
      if (widget.kind != ChatKind.group && widget.kind != ChatKind.channel) {
        return;
      }
      if ('${d['room_id'] ?? ''}' != _ctl.roomId) return;
      // slow mode countdown for members (Telegram live behaviour)
      final st = d['settings'];
      if (st is Map) {
        final sm = (st['slow_mode'] ?? 0) is int
            ? st['slow_mode'] as int
            : int.tryParse('${st['slow_mode']}') ?? 0;
        setState(() => _roomSlowMode = sm);
        _restartSlowTick();
      }
    });
    // v1.1.0 — thin glass center toasts for membership changes.
    // Suppression rule (like the backend's big-group logic): once the group
    // is LARGE (>= 50 members) join/leave toasts stop; removals/bans always
    // show so moderators can audit them.
    _subMember = sock.onMemberEvent.listen((d) {
      final isRoom =
          widget.kind == ChatKind.group || widget.kind == ChatKind.channel;
      if (!isRoom) return;
      final room = '${d['room_id'] ?? d['room'] ?? ''}';
      if (room.isNotEmpty && room != _ctl.roomId) return;
      final kind = '${d['event_kind'] ?? ''}';
      final who = '${d['username'] ?? d['user'] ?? d['display_name'] ?? ''}';
      if (who.isEmpty) return;
      final bigGroup = (_ctl.memberCount ?? 0) >= 50;
      if ((kind == 'join' || kind == 'leave') && bigGroup) return;
      if (!mounted) return;
      final s2 = AppState.I.str;
      switch (kind) {
        case 'join':
          showGlassToast(context, s2.userJoinedToast(who),
              icon: Icons.person_add_alt_1_rounded,
              color: const Color(0xFF22C55E));
          break;
        case 'leave':
          showGlassToast(context, s2.userLeftToast(who),
              icon: Icons.logout_rounded);
          break;
        case 'kick':
          showGlassToast(context, s2.userKickedToast(who),
              icon: Icons.person_remove_rounded,
              color: const Color(0xFFEF4444));
          break;
        case 'ban':
          showGlassToast(context, s2.userBannedToast(who),
              icon: Icons.gavel_rounded, color: const Color(0xFFEF4444));
          break;
      }
    });
    _subSrvErr = sock.onServerError.listen((d) {
      final code = '${d['code'] ?? ''}';
      if (code == 'rate_limited') {
        final rem = (d['remaining'] ?? 0) is int
            ? d['remaining'] as int
            : int.tryParse('${d['remaining']}') ?? 5;
        if (mounted) {
          setState(() => _slowRemaining = rem);
          _restartSlowTick();
        }
      }
    });
  }

  int _roomSlowMode = 0;

  Future<void> _refreshPv() async {
    if (widget.kind != ChatKind.pv || widget.chatId <= 0) return;
    final r = await ApiService.I.pvInfo(widget.chatId);
    if (r.ok && r.data != null) _ctl.setPvInfo(PvInfo.fromJson(r.data!));
  }

  void _restartSlowTick() {
    _slowTimer?.cancel();
    if (_slowRemaining <= 0 && _roomSlowMode <= 0) return;
    _slowTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        if (_slowRemaining > 0) _slowRemaining--;
      });
    });
  }

  @override
  void dispose() {
    _recTimer?.cancel();
    _slowTimer?.cancel();
    _subBlocked?.cancel();
    _subUnblocked?.cancel();
    _subSettings?.cancel();
    _subSrvErr?.cancel();
    _subMember?.cancel();
    _stickyDateN.dispose();
    try {
      _recorder.dispose();
    } catch (_) {}
    _ctl.dispose();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _input.removeListener(_onInputChanged);
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _onScroll() {
    _nearBottom = _scroll.position.pixels < 90;
    _lastMaxExtent = _scroll.position.maxScrollExtent;
    // v1.4.0 — ضدپرش واتساپی: دور از انتهای چت => پیام‌های جدید صف شوند
    _ctl.holdIncoming = !_nearBottom;
    // رسیدن به انتهای چت => همه‌ی پیام‌های صف‌شده یکجا با انیمیشن اضافه شوند
    if (_nearBottom && _ctl.pendingIncomingCount > 0) {
      _ctl.flushIncoming();
    }
    // v1.2.0 — load older ONLY on a genuine upward USER drag. The anchored
    // jumpTo() we do after prepending fires the listener with direction=idle,
    // and that self-retarget was chaining page-loads down to the first
    // message ever. ScrollDirection gate + 600ms throttle = one page per
    // gesture, exactly like Telegram.
    final now = DateTime.now();
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 260 &&
        _scroll.hasClients &&
        _scroll.position.maxScrollExtent > 400 &&
        _scroll.position.userScrollDirection == ScrollDirection.forward &&
        now.difference(_lastOlderTry).inMilliseconds > 600) {
      _lastOlderTry = now;
      _ctl.loadOlder();
    }
    _calcStickyDate();
  }

  // ---------- v1.1.0 — smooth arrivals (Telegram) ----------
  // v1.2.1 REWRITE of the bottom-arrival path:
  //  • the new row itself GROWS into place (BubbleAppear now animates height
  //    0 → full + fade + slide). A reverse ListView then pushes the older
  //    bubbles up smoothly frame-by-frame — that IS the Telegram send
  //    animation, and it works for text, photos, GIFs, voice and incoming
  //    messages alike. The old jumpTo(delta)+glide hack is GONE: it painted
  //    one shifted frame before the correction (the visible "jump" for
  //    other people's messages).
  //  • prepended history pages still pixel-freeze (nothing moves).
  void _syncListState() {
    final msgs = _ctl.messages;
    final n = msgs.length;
    if (!_listBootstrapped) {
      if (_ctl.historyLoaded) {
        for (final m in msgs) {
          if (m.id > 0) _knownIds.add(m.id);
        }
        _lastCount = n;
        _listBootstrapped = true;
      }
      return;
    }
    for (final m in msgs) {
      if (m.id > 0 && !_knownIds.contains(m.id)) {
        _knownIds.add(m.id);
        _liveIds.add(m.id);
        // v1.2.1 — forget the "live" flag once the entrance finished so
        // scrolling away/back never replays the grow animation.
        final id = m.id;
        Timer(const Duration(milliseconds: 900), () => _liveIds.remove(id));
      }
    }
    final prepended = _ctl.justLoadedOlder;
    _ctl.justLoadedOlder = false;
    final appended = n - _lastCount;
    _lastCount = n;
    if (prepended && !mounted) return;
    if (prepended) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        final newMax = _scroll.position.maxScrollExtent;
        final delta = newMax - _lastMaxExtent;
        if (delta > 0) {
          // pixel-freeze while reading history
          _scroll.jumpTo(
              (_scroll.position.pixels + delta).clamp(0.0, newMax));
        }
        _lastMaxExtent = newMax;
      });
      return;
    }
    if (appended > 0 && _nearBottom && _scroll.hasClients) {
      // keep the viewport pinned to the fresh bubble while the row grows in.
      // v1.3.1 — when we are ALREADY at the bottom (offset ≈ 0) the growing
      // row itself is the animation; an extra animateTo() fought the growth
      // and produced the visible "double hop". Only glide when we are a few
      // pixels away from the bottom edge.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        _lastMaxExtent = _scroll.position.maxScrollExtent;
        if (_scroll.position.pixels > 6) {
          _scroll.animateTo(0,
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic);
        }
      });
    }
  }

  // ---------- v1.0.9 sticky glass date label (Telegram, v1.1.0 REWRITE) ----------
  // Shows the date of the TOPMOST visible message and glides between days as
  // you scroll. Hides while the matching in-list section pill is still on
  // screen — so a pill only ever appears when the day actually changes.
  void _calcStickyDate() {
    final now = DateTime.now();
    if (now.difference(_lastStickyCalc).inMilliseconds < 90) return;
    _lastStickyCalc = now;
    if (_ctl.messages.isEmpty || !_scroll.hasClients) {
      _setSticky(null);
      return;
    }
    // The list area starts right under the header; the pill overlaps it.
    String? best;
    double bestDy = double.infinity;
    double bestBottom = 0;
    for (final e in _msgCtx.entries) {
      final ro = e.value.findRenderObject();
      if (ro is! RenderBox || !ro.attached || !ro.hasSize) continue;
      final dy = ro.localToGlobal(Offset.zero).dy;
      final bottom = dy + ro.size.height;
      // a row counts as visible only if its BOTTOM edge is still below the
      // top of the list — fully scrolled-out rows are ignored (this is what
      // made the old pill "come from the bottom-most message").
      if (bottom < 4) continue;
      if (dy < bestDy) {
        bestDy = dy;
        bestBottom = bottom;
        best = _msgDates[e.key];
      }
    }
    // hide only when the chat is empty — the sticky pill is THE single date
    // indicator now (in-list pills removed in v1.1.1).
    _setSticky(best);
  }

  int? _topmostMsgId() {
    double? bestDy;
    int? bestId;
    for (final e in _msgCtx.entries) {
      final ro = e.value.findRenderObject();
      if (ro is! RenderBox || !ro.attached || !ro.hasSize) continue;
      final dy = ro.localToGlobal(Offset.zero).dy;
      if (dy + ro.size.height < 4) continue;
      if (bestDy == null || dy < bestDy) {
        bestDy = dy;
        bestId = e.key;
      }
    }
    return bestId;
  }

  void _setSticky(String? k) {
    if (_stickyDateN.value == k) return;
    // v1.2.0 — ValueNotifier: only the pill widget rebuilds, never the list.
    _stickyDateN.value = k;
  }

  // ---------- v1.0.9 selection mode ----------
  void _enterSelection(Message first) {
    if (_selectionMode) return;
    setState(() {
      _selectionMode = true;
      _selected.clear();
      if (first.id > 0) _selected.add(first.id);
    });
    HapticFeedback.mediumImpact();
  }

  void _toggleSelect(Message m) {
    if (m.id <= 0) return;
    setState(() {
      if (_selected.contains(m.id)) {
        _selected.remove(m.id);
        if (_selected.isEmpty) _selectionMode = false;
      } else {
        _selected.add(m.id);
      }
    });
  }

  void _exitSelection() => setState(() {
        _selectionMode = false;
        _selected.clear();
      });

  Future<void> _deleteSelected() async {
    final s = AppState.I.str;
    final ok = await showRaviModal(
      context,
      icon: Icons.delete_outline_rounded,
      iconColor: const Color(0xFFEF4444),
      title: s.deleteMsgTitle,
      body: s.deleteMsgConfirm,
      okText: s.delete,
      cancelText: s.cancel,
      danger: true,
    );
    if (!ok) return;
    final ids = List<int>.from(_selected);
    _exitSelection();
    for (final id in ids) {
      final m = _ctl.messages.firstWhere((x) => x.id == id,
          orElse: () => _ctl.messages.first);
      _ctl.deleteOwn(m);
    }
  }

  Future<void> _forwardSelected() async {
    final ids = List<int>.from(_selected)
        .where((id) => id > 0)
        .toList();
    if (ids.isEmpty) return;
    _exitSelection();
    await ForwardScreen.open(context, messages: _ctl.messages.where((m) => ids.contains(m.id)).toList());
  }

  void _onInputChanged() {
    final hasText = _input.text.trim().isNotEmpty;
    _ctl.setTyping(hasText);
    // v1.1.0 — the composer follows the first strong character, so an emoji
    // typed AFTER Persian stays at the visual END of the message and English
    // sentences lay out left-to-right. Only rebuild when it actually flips.
    final want = bidiDirectionOf(_input.text,
        fallback: AppState.I.lang.value.isRtl
            ? TextDirection.rtl
            : TextDirection.ltr);
    if (want != _inputDir && mounted) {
      setState(() => _inputDir = want);
    }
  }

  void _setReply(Message m) {
    setState(() {
      _replyToId = '${m.id}';
      _replyAuthor = m.isMe
          ? (ApiService.I.cachedName.isEmpty
              ? ApiService.I.cachedUsername
              : ApiService.I.cachedName)
          : m.authorLabel;
      _replyText = m.previewSnippet.length > 90
          ? '${m.previewSnippet.substring(0, 90)}…'
          : m.previewSnippet;
    });
    _inputFocus.requestFocus();
  }

  void _clearReply() => setState(() {
        _replyToId = null;
        _replyAuthor = null;
        _replyText = null;
      });

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    // v1.0.9 — editing-in-composer: confirm edit instead of sending
    if (_editing != null) {
      final target = _editing!;
      _input.clear();
      setState(() => _editing = null);
      final r = await _ctl.editMessage(target, text);
      if (!mounted) return;
      if (!r) {
        showGlassToast(context, AppState.I.str.messageEditFailed,
            icon: Icons.error_outline_rounded,
            color: const Color(0xFFEF4444));
      }
      return;
    }
    _input.clear();
    final ok = await _ctl.send(text,
        replyToId: _replyToId, replyAuthor: _replyAuthor, replyText: _replyText);
    if (!mounted) return;
    _clearReply();
    // v1.2.1 — slow mode: arm the local countdown right after a successful
    // send (the server enforces it; the chip now ALWAYS appears, not just
    // after a rejected attempt).
    if (ok && _ctl.slowMode > 0) {
      setState(() => _slowRemaining = _ctl.slowMode);
      _restartSlowTick();
    }
  }

  /// v1.2.1 — arm the slow-mode countdown after media/voice sends too.
  void _armSlowModeAfterSend(bool ok) {
    if (ok && _ctl.slowMode > 0 && mounted) {
      setState(() => _slowRemaining = _ctl.slowMode);
      _restartSlowTick();
    }
  }

  void _startEditing(Message m) {
    setState(() {
      _editing = m;
      _input.text = m.text;
      _input.selection = TextSelection.collapsed(offset: _input.text.length);
    });
    _inputFocus.requestFocus();
  }

  void _cancelEditing() => setState(() {
        _editing = null;
        _input.clear();
      });

  // -------------------------------------------------- media actions

  // v1.1.0 — Telegram attach flow: multi-select gallery + crop-first editor;
  // several photos share one albumId so they render inside ONE bubble.
  Future<void> _attach() async {
    await showAttachSheet(
      context,
      onSend: (items, caption) async {
        final albumId = items.length > 1
            ? 'al_${DateTime.now().millisecondsSinceEpoch}'
            : '';
        var allOk = true;
        for (final it in items) {
          final ok = await _ctl.sendMedia(it.path,
              fileType: it.fileType,
              caption: it.fileType == 'image' ? caption : '',
              albumId: albumId,
              // v1.2.1 — music files carry their parsed metadata
              isVoiceNote: it.isVoice,
              durationMs: it.durationMs,
              mediaTitle: it.title,
              mediaArtist: it.artist,
              mediaCover: it.coverPath,
              replyToId: _replyToId,
              replyAuthor: _replyAuthor,
              replyText: _replyText);
          if (!ok) allOk = false;
        }
        _armSlowModeAfterSend(allOk);
        return allOk;
      },
    );
    _clearReply();
  }

  // v1.0.8 — _pickGif removed: GIFs are picked inside the combined
  // emoji/GIF panel (second tab).

  Future<void> _openMedia(Message m) async {
    if (m.fileUrl.isEmpty && m.localPath.isEmpty) return;
    if (m.localPath.isNotEmpty) return; // still uploading — ignore taps
    await openMediaViewer(
      context,
      fileUrl: m.fileUrl,
      isVideo: m.isVideo,
      title: m.authorLabel,
      subtitle: m.time,
    );
  }

  void _openProfile(Message m) {
    if (m.username.isEmpty) return;
    Navigator.of(context, rootNavigator: true)
        .push(UserProfileScreen.route(m.username));
  }

  // @mention / URL tap → profile or room-join panel (exactly like index)
  Future<void> _onTokenTap(String token) async {
    final s = AppState.I.str;
    final raw = token.trim();
    if (raw.startsWith('@')) {
      final u = raw.substring(1);
      final exists = await ApiService.I.userExists(u);
      if (!mounted) return;
      if (exists.ok && exists.data == true) {
        Navigator.of(context, rootNavigator: true)
            .push(UserProfileScreen.route(u));
        return;
      }
      RoomPreviewSheet.openFromToken(context, u);
      return;
    }
    // URL — check for an invite link pattern first
    final invite = RegExp(r'/invite/([A-Za-z0-9_-]+)').firstMatch(raw);
    if (invite != null) {
      RoomPreviewSheet.openById(context, invite.group(1)!);
      return;
    }
    // a bare www/http link — open the in-app room resolver if it looks like
    // a handle, otherwise show a toast with the URL.
    RoomPreviewSheet.openFromToken(context, raw);
    if (raw.startsWith('http')) {
      // Plain external URL: copy to clipboard (no webview inside the app).
      await Clipboard.setData(ClipboardData(text: raw));
      if (mounted) showGlassToast(context, s.copied, icon: Icons.link_rounded);
    }
  }

  Future<void> _downloadMedia(Message m) async {
    final s = AppState.I.str;
    if (m.fileUrl.isEmpty) return;
    // v1.5.0 — دانلود با حلقه‌ی پیشرفت + ذخیره‌ی دائمی روی دیسک اپ و سپس
    // کپی در گالری/Downloads (مثل تلگرام). تیک سبز روی همان حباب می‌نشیند.
    showGlassToast(context, s.downloadingMedia,
        icon: Icons.downloading_rounded);
    await MediaDownloadManager.I.downloadAndSave(m.fileUrl);
  }

  // -------------------------------------------------- voice recording
  // v1.2.0 FULL REBUILD (Telegram logic):
  //  • the bar + timer appear INSTANTLY on pointer-down (no dead press)
  //  • a generation counter closes the press→release race: if the recorder
  //    finishes spinning up AFTER the finger lifted, it stops + discards
  //  • real elapsed milliseconds (the old 1s counter threw away sub-second
  //    takes and mis-timed the minimum-length rule)
  //  • live amplitude waveform (dBFS → bars) while recording
  //  • locked mode gets pause/resume like Telegram
  Future<void> _startRecording() async {
    final s = AppState.I.str;
    final gen = ++_recGen;
    _recCancelled = false;
    _recPaused = false;
    _recLocked = false;
    _lockDy = 0;
    _cancelDx = 0;
    _recAmps.clear();
    _recMs = 0;
    _recStartEpochMs = DateTime.now().millisecondsSinceEpoch;
    if (mounted) setState(() => _recording = true);
    HapticFeedback.lightImpact();

    if (!_micGranted) {
      try {
        _micGranted = await _recorder.hasPermission();
      } catch (_) {
        _micGranted = false;
      }
      if (!_micGranted) {
        if (mounted) {
          showGlassToast(context, s.micPermission,
              icon: Icons.mic_off_rounded, color: const Color(0xFFEF4444));
        }
        _abortRecordingUi();
        return;
      }
    }

    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/v_${DateTime.now().millisecondsSinceEpoch}.m4a';
    try {
      await _recorder.start(
        const RecordConfig(
            encoder: AudioEncoder.aacLc, bitRate: 64000, sampleRate: 44100),
        path: path,
      );
    } catch (_) {
      if (gen == _recGen) _abortRecordingUi();
      return;
    }
    // finger already lifted while the recorder spun up → bail out cleanly
    if (gen != _recGen) {
      try {
        await _recorder.stop();
      } catch (_) {}
      try {
        File(path).delete();
      } catch (_) {}
      return;
    }
    _recPath = path;
    _recStartEpochMs = DateTime.now().millisecondsSinceEpoch;
    _recTimer = Timer.periodic(
        const Duration(milliseconds: 100), (_) => _recTick(gen));
  }

  void _recTick(int gen) {
    if (gen != _recGen || !mounted || !_recording) return;
    if (!_recPaused) {
      _recMs = DateTime.now().millisecondsSinceEpoch - _recStartEpochMs;
      _sampleAmplitude();
    }
    setState(() {});
  }

  Future<void> _sampleAmplitude() async {
    double v = 0.10;
    try {
      final a = await _recorder.getAmplitude();
      // dBFS (-160..0) → 0..1; speech sits roughly above -45dB
      final db = a.current.clamp(-45.0, 0.0);
      v = ((db + 45.0) / 45.0).clamp(0.06, 1.0);
    } catch (_) {}
    _recAmps.add(v);
    if (_recAmps.length > _recAmpBars) {
      _recAmps.removeRange(0, _recAmps.length - _recAmpBars);
    }
  }

  void _abortRecordingUi() {
    _recTimer?.cancel();
    _recording = false;
    _recLocked = false;
    _recPaused = false;
    _lockDy = 0;
    _cancelDx = 0;
    if (mounted) setState(() {});
  }

  Future<void> _toggleRecPause() async {
    try {
      if (_recPaused) {
        await _recorder.resume();
      } else {
        await _recorder.pause();
      }
      _recPaused = !_recPaused;
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _stopRecording({required bool send}) async {
    final gen = ++_recGen;
    _recTimer?.cancel();
    final wasRecording = _recording;
    final elapsedMs = wasRecording
        ? DateTime.now().millisecondsSinceEpoch - _recStartEpochMs
        : 0;
    _recording = false;
    _recPaused = false;
    _recLocked = false;
    _lockDy = 0;
    _cancelDx = 0;
    if (mounted) setState(() {});
    if (!wasRecording) return;
    final path = _recPath;
    _recPath = null;
    String? stopped;
    try {
      stopped = await _recorder.stop();
    } catch (_) {}
    final file = (stopped != null && stopped.isNotEmpty) ? stopped : path;
    if (!send || _recCancelled || file == null || elapsedMs < 700) {
      try {
        if (file != null) File(file).delete();
      } catch (_) {}
      if (elapsedMs < 700 && mounted && !_recCancelled) {
        showGlassToast(context, AppState.I.str.voiceTooShort,
            icon: Icons.timer_off_rounded);
      }
      return;
    }
    await _ctl.sendMedia(file,
        fileType: 'audio',
        caption: '',
        // v1.2.1 — a recorded take IS a voice note (real duration included)
        isVoiceNote: true,
        durationMs: elapsedMs,
        replyToId: _replyToId,
        replyAuthor: _replyAuthor,
        replyText: _replyText);
    _armSlowModeAfterSend(true);
    _clearReply();
  }

  // -------------------------------------------------- jump to replied message
  // v1.1.0 REWRITE — pages history back until the target exists, then scrolls
  // PRECISELY onto it (multi-attempt for unbuilt rows) with a glow highlight.
  Future<void> _jumpToReply(Message m) async {
    final targetId = int.tryParse(m.replyToId ?? '') ?? 0;
    if (targetId <= 0) return;
    var exists = _ctl.messages.any((x) => x.id == targetId);
    if (!exists) {
      if (mounted) {
        showGlassToast(context, AppState.I.str.loadingReply,
            icon: Icons.search_rounded);
      }
      exists = await _ctl.loadUntilMessage(targetId);
      if (!exists) {
        if (mounted) {
          showGlassToast(context, AppState.I.str.replyNotFound,
              icon: Icons.history_rounded);
        }
        return;
      }
    }
    if (!mounted) return;
    await _scrollToMessage(targetId);
  }

  Future<void> _scrollToMessage(int id, {int attempt = 0}) async {
    if (!mounted || attempt > 6) return;
    final bctx = _msgCtx[id];
    final ro = bctx?.findRenderObject();
    if (bctx != null && ro is RenderBox && ro.attached && ro.hasSize) {
      // v1.2.0 — ONE long, buttery glide onto the target (the old 300ms hop
      // + retry loop felt like a stuttering jump). Then a soft mark.
      await Scrollable.ensureVisible(
        bctx,
        duration: Duration(milliseconds: attempt == 0 ? 620 : 480),
        curve: Curves.easeInOutCubic,
        alignment: 0.35,
      );
      if (!mounted) return;
      setState(() => _highlightId = id);
      Timer(const Duration(milliseconds: 1500), () {
        if (mounted && _highlightId == id) {
          setState(() => _highlightId = null);
        }
      });
      return;
    }
    // not built yet — estimate the offset by index, glide there, retry.
    final n = _ctl.messages.length;
    final idx = _ctl.messages.indexWhere((x) => x.id == id);
    if (idx < 0 || !_scroll.hasClients) return;
    final revIdx = n - 1 - idx;
    final est = (_scroll.position.maxScrollExtent * (revIdx / (n + 1)))
        .clamp(0.0, _scroll.position.maxScrollExtent);
    await _scroll.animateTo(est,
        duration: const Duration(milliseconds: 560),
        curve: Curves.easeInOutCubic);
    await Future.delayed(const Duration(milliseconds: 110));
    if (mounted) await _scrollToMessage(id, attempt: attempt + 1);
  }

  // v1.3.1 — the bottom gap under the composer block:
  //  • keyboard open → the real keyboard inset (glides via AnimatedPadding)
  //  • emoji panel open → 0 (the panel itself fills that space)
  //  • idle → just the gesture-bar inset
  double _bottomGap(double kb, double bottomPad) {
    if (_emojiOpen) return 0;
    if (kb > 0) return kb;
    return bottomPad;
  }

  // -------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;
    final bottomPad = MediaQuery.of(context).padding.bottom;
    final topInset = MediaQuery.of(context).padding.top;
    // v1.3.1 — remember the real keyboard height (WhatsUp pattern) so the
    // emoji panel can later occupy EXACTLY the same space.
    final kbNow = MediaQuery.viewInsetsOf(context).bottom;
    if (kbNow > _kbH + 8) {
      _kbH = kbNow.clamp(180.0, 480.0);
      SharedPreferences.getInstance()
          .then((v) => v.setDouble(_kKbPref, _kbH));
    }

    // v1.4.0 — RTL FIX: چیدمان چت هیچ‌وقت در فارسی برعکس نمی‌شود.
    // حباب خودی همیشه راست، حباب طرف مقابل چپ، دکمه ارسال راست — دقیقا واتساپ.
    // (متن پیام‌ها خودشان bidi-aware هستند و فارسی درست رندر می‌شود)
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        // v1.3.1 — manual inset control: the bottom block glides via
        // AnimatedPadding below (the Scaffold snap was the "input jumps" bug).
        resizeToAvoidBottomInset: false,
        body: AnimatedBuilder(
          animation: _ctl,
          builder: (context, _) {
            _syncListState();
            final pvInfo = _ctl.pvInfo;
            final channelMode = widget.kind == ChatKind.channel;
            // v1.0.9 — admins/owner CAN post in channels (is_room_poster);
            // only true non-managers see the read-only bar.
            final canPost = widget.canPost && _ctl.canPost;
            final iBlocked = widget.kind == ChatKind.pv &&
                (pvInfo?.iBlockedThem ?? false);
            final amBlocked = widget.kind == ChatKind.pv &&
                (pvInfo?.isBlocked ?? false);
            return Stack(
              fit: StackFit.expand,
              children: [
                ChatBgStore.buildBackground(context),
                // v1.1.0 — edge-to-edge: content flows BEHIND the transparent
                // status bar so the glass header shows the wallpaper through it.
                SafeArea(
                  top: false,
                  bottom: false,
                  child: Column(
                    children: [
                      _selectionMode
                          ? _selectionHeader(p, s)
                          : _header(p, s, pvInfo, topInset),
                      // v1.1.0 — Telegram-style pinned message bar
                      _pinnedBar(p),
                      // v1.0.7 — glass mini-player (Telegram-style) while an
                      // audio/voice plays; managed from ANY chat or page.
                      const PlayerBar(),
                      // v1.0.9 — bubble-color preset reacts live
                      Expanded(
                        child: ValueListenableBuilder<String>(
                          valueListenable: BubbleColorStore.I.key,
                          builder: (context, __, ___) => _messagesArea(p, s),
                        ),
                      ),
                      // ---- v1.3.1 — ONE bottom block that GLIDES with the
                      // keyboard (reply bar + composer + emoji panel). When the
                      // keyboard opens the gap animates 0→kb with the system
                      // curve; opening the emoji panel swaps kb-height for
                      // panel-height — visually seamless.
                      AnimatedPadding(
                        duration: const Duration(milliseconds: 240),
                        curve: Curves.easeOutCubic,
                        padding: EdgeInsets.only(bottom: _bottomGap(kbNow, bottomPad)),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _replyBar(p),
                            if (_editing != null) _editingBar(p, s),
                            if (canPost && !iBlocked && !amBlocked) ...[
                              _recording || _recLocked
                                  ? _recordingBar(p, s)
                                  : _composer(p, s),
                            ] else
                              _bottomStatusArea(p, s,
                                  iBlocked: iBlocked, amBlocked: amBlocked),
                            // v1.1.1 — the emoji panel sits UNDER the composer
                            // (like Telegram). v1.3.1 — its height == keyboard
                            // height → keyboard⇄panel swap never moves layout.
                            if (_emojiOpen && canPost && !iBlocked && !amBlocked)
                              SafeArea(top: false, child: _emojiPanel(p)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // v1.2.1 — THE VOICE CIRCLE that follows the finger (Telegram):
                // stays visible the whole time you hold the mic and moves with
                // it, so the user always understands the recording is live.
                if (_recording && !_recLocked) _recFloatingCircle(p),
                // v1.4.0 — پیل «پیام جدید» (واتساپ): وقتی کاربر دور از انتهای
                // چت است و پیام می‌آید، لیست ثابت می‌ماند و این پیل ظاهر می‌شود
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  bottom: _emojiOpen ? 260 : 92,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      transitionBuilder: (child, anim) => ScaleTransition(
                        scale: anim,
                        child: FadeTransition(opacity: anim, child: child),
                      ),
                      child: _ctl.pendingIncomingCount > 0
                          ? GestureDetector(
                              key: ValueKey('pill-${_ctl.pendingIncomingCount}'),
                              onTap: () {
                                _ctl.holdIncoming = false;
                                _ctl.flushIncoming();
                                if (_scroll.hasClients) {
                                  _scroll.animateTo(0,
                                      duration: const Duration(milliseconds: 280),
                                      curve: Curves.easeOutCubic);
                                }
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 8),
                                decoration: BoxDecoration(
                                  color: p.chatHeadBg.withValues(alpha: .97),
                                  borderRadius: BorderRadius.circular(999),
                                  border:
                                      Border.all(color: p.borderSoft, width: 1),
                                  boxShadow: const [
                                    BoxShadow(
                                        color: Color(0x2E12314E),
                                        blurRadius: 18,
                                        offset: Offset(0, 6)),
                                  ],
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      _ctl.pendingIncomingCount == 1
                                          ? (AppState.I.lang.value.isFa
                                              ? '۱ پیام جدید'
                                              : '1 new message')
                                          : (AppState.I.lang.value.isFa
                                              ? '‎${_ctl.pendingIncomingCount} پیام جدید'
                                              : '${_ctl.pendingIncomingCount} new messages'),
                                      style: TextStyle(
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w800,
                                          color: p.accent),
                                    ),
                                    const SizedBox(width: 5),
                                    Icon(Icons.arrow_downward_rounded,
                                        size: 15, color: p.accent),
                                  ],
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // ---------- v1.1.1 — pinned message bar (SERVER pins, cycles on tap) ----------
  Widget _pinnedBar(Palette p) {
    final pin = _ctl.currentPin;
    if (pin == null) return const SizedBox.shrink();
    final total = _ctl.pins.length;
    final idx = total > 1 ? _ctl.pinCursor + 1 : 0;
    final mid = int.tryParse('${pin['message_id']}') ?? 0;
    final preview = '${pin['preview'] ?? ''}';
    final author = '${pin['author_display'] ?? pin['author'] ?? ''}';
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      child: GestureDetector(
        onTap: () {
          // Telegram: tap → jump to the pinned message; with several pins
          // the bar cycles to the next one after the jump.
          if (mid > 0) _scrollToMessage(mid);
          _ctl.cyclePin();
        },
        behavior: HitTestBehavior.opaque,
        child: Container(
              padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
              decoration: BoxDecoration(
                color: p.chatHeadBg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: p.chatHeadBorder),
              ),
              child: Row(children: [
                Container(
                  width: 3.2,
                  height: 30,
                  margin: EdgeInsetsDirectional.only(
                      start: rtl ? 0 : 2, end: rtl ? 2 : 0),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        const Color(0xFFF59E0B),
                        const Color(0xFFF59E0B).withValues(alpha: .3)
                      ],
                    ),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 9),
                Icon(Icons.push_pin_rounded,
                    size: 15, color: const Color(0xFFF59E0B)),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Text(AppState.I.str.pinnedMessage,
                            style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                                color: const Color(0xFFF59E0B))),
                        if (total > 1) ...[
                          const SizedBox(width: 5),
                          Text('$idx/$total',
                              textDirection: TextDirection.ltr,
                              style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800,
                                  color: const Color(0xFFF59E0B)
                                      .withValues(alpha: .75))),
                        ],
                        if (author.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(author,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w700,
                                    color: p.chatText3)),
                          ),
                        ],
                      ]),
                      const SizedBox(height: 1),
                      Text(
                        preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11.6, color: p.chatText2),
                      ),
                    ],
                  ),
                ),
                if (_ctl.canPin)
                  GestureDetector(
                    onTap: () => _ctl.unpinMessage(mid),
                    child: Container(
                      width: 30,
                      height: 30,
                      margin: const EdgeInsetsDirectional.only(end: 2),
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: p.chatText2.withValues(alpha: .12)),
                      child: Icon(Icons.close_rounded,
                          size: 15, color: p.chatText2),
                    ),
                  ),
              ]),
        ),
      ),
    );
  }

  // ---------- v1.0.9 selection-mode header (Telegram) ----------
  Widget _selectionHeader(Palette p, S s) {
    final canDeleteAll = _selected.every((id) {
      final m = _ctl.messages.where((x) => x.id == id).toList();
      if (m.isEmpty) return false;
      final msg = m.first;
      return msg.isMe || _canModerate;
    });
    return Container(
      // v1.2.0 FIX — the selection bar must clear the STATUS BAR. It used to
      // be a bare 60px row glued to the very top of the screen, so on
      // edge-to-edge builds it slid under the notification icons and the
      // buttons were un-tappable.
      margin: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: p.chatHeadBg,
        border: Border(bottom: BorderSide(color: p.chatHeadBorder)),
      ),
      child: Row(children: [
        GestureDetector(
          onTap: _exitSelection,
          child: Icon(Icons.close_rounded, size: 22, color: p.chatText),
        ),
        const SizedBox(width: 12),
        Text(s.selectedCount(_selected.length),
            style: TextStyle(
                fontSize: 14.5, fontWeight: FontWeight.w800, color: p.chatText)),
        const Spacer(),
        GestureDetector(
          onTap: _selected.isEmpty ? null : _forwardSelected,
          child: Icon(Icons.shortcut_rounded,
              size: 21,
              color: _selected.isEmpty ? p.chatText3 : p.chatText),
        ),
        const SizedBox(width: 18),
        GestureDetector(
          onTap: canDeleteAll && _selected.isNotEmpty ? _deleteSelected : null,
          child: Icon(Icons.delete_outline_rounded,
              size: 21,
              color: canDeleteAll && _selected.isNotEmpty
                  ? const Color(0xFFEF4444)
                  : p.chatText3),
        ),
      ]),
    );
  }

  /// v1.0.9 — admins/owner of a room can delete/edit others' messages
  /// (server enforces the same rule).
  bool get _canModerate {
    if (widget.kind != ChatKind.group && widget.kind != ChatKind.channel) {
      return false;
    }
    return _ctl.myRole == 'owner' || _ctl.myRole == 'admin';
  }

  // ---------- v1.0.9 bottom status: block bars (Telegram) ----------
  Widget _bottomStatusArea(Palette p, S s,
      {required bool iBlocked, required bool amBlocked}) {
    if (iBlocked) {
      // WE blocked them — full-width Unblock button (like Telegram/screenshot)
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: GestureDetector(
          onTap: () async {
            final u = widget.peerUsername;
            if (u.isEmpty) return;
            final r = await ApiService.I.unblockUser(u);
            if (!mounted) return;
            if (r.ok) {
              showGlassToast(context, s.unblockedToast,
                  icon: Icons.lock_open_rounded);
            }
            await _refreshPv();
          },
          child: Container(
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: p.chatHeadBg,
              borderRadius: BorderRadius.circular(23),
              border: Border.all(color: p.chatHeadBorder),
            ),
            child: Text(s.unblock,
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: p.chatText)),
          ),
        ),
      );
    }
    if (amBlocked) {
      // THEY blocked us — nothing can be sent (banner only)
      return Padding(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 10),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: p.chatHeadBg,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: p.chatHeadBorder),
            ),
            child: Text(s.blockedYouBanner,
                style: TextStyle(fontSize: 11.5, color: p.chatText2)),
          ),
        ),
      );
    }
    // channel without posting rights (non-manager)
    return _readOnlyBar(p, s);
  }

  // ---------- v1.0.9 editing bar above the composer ----------
  Widget _editingBar(Palette p, S s) {
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      padding: const EdgeInsets.fromLTRB(12, 7, 6, 7),
      decoration: BoxDecoration(
        color: p.chatHeadBg,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: p.accent.withValues(alpha: .45)),
      ),
      child: Row(children: [
        Icon(Icons.edit_rounded, size: 16, color: p.accent),
        const SizedBox(width: 9),
        Expanded(
          child: Text(s.editingMsg,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12.2,
                  fontWeight: FontWeight.w700,
                  color: p.accent)),
        ),
        GestureDetector(
          onTap: _cancelEditing,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: p.chatText2.withValues(alpha: .12)),
            child: Icon(Icons.close_rounded, size: 15, color: p.chatText2),
          ),
        ),
      ]),
    );
  }

  // ---------- header (v1.1.0 — glass, status-bar aware, call button) ----------
  Widget _header(Palette p, S s, PvInfo? pvInfo, double topInset) {
    final fa = AppState.I.lang.value.isFa;
    final isOnline = widget.kind == ChatKind.pv &&
        widget.peerUsername.isNotEmpty &&
        _ctl.isPeerOnline(widget.peerUsername);
    final typingCount = _ctl.typingUsers.length;
    final showTyping =
        _ctl.otherTyping || (widget.kind != ChatKind.pv && typingCount > 0);
    final connecting = _ctl.socketStatus != SocketStatus.connected &&
        _ctl.socketStatus == SocketStatus.connecting;

    String subtitle;
    bool accentSubtitle = false;
    if (showTyping) {
      if (widget.kind == ChatKind.pv) {
        subtitle = '${pvInfo?.name.isNotEmpty == true ? pvInfo!.name : widget.peerUsername} ${s.typing}';
      } else {
        final names = _ctl.typingUsers.take(2).toList();
        subtitle = names.join('، ') +
            (typingCount > 2 ? ' +${typingCount - 2}' : '') +
            ' ${s.typing}';
      }
      accentSubtitle = true;
    } else if (widget.kind == ChatKind.general) {
      if (_ctl.onlineCount != null) {
        subtitle = _ctl.onlineCount! > 0
            ? s.membersOnline(_ctl.onlineCount!)
            : '';
      } else if (connecting) {
        subtitle = s.connectingDots;
        accentSubtitle = true;
      } else {
        subtitle = '';
      }
    } else if (widget.kind == ChatKind.pv) {
      if (isOnline) {
        subtitle = s.online;
        accentSubtitle = true;
      } else if (pvInfo != null && pvInfo.lastSeenLabel(fa).isNotEmpty) {
        subtitle = pvInfo.lastSeenLabel(fa);
      } else if (pvInfo != null) {
        // real "last seen recently" instead of an eternal "connecting…"
        subtitle = s.lastSeenRecently;
      } else if (connecting) {
        subtitle = s.connectingDots;
      } else {
        subtitle = s.lastSeenRecently;
      }
    } else if (widget.kind == ChatKind.channel) {
      // v1.0.8 — channel: subscriber count (like Telegram)
      subtitle = _ctl.memberCount != null
          ? s.subscribersCount(_ctl.memberCount!)
          : '';
    } else {
      // v1.0.8 — group: "N members, M online" (Telegram)
      final members = _ctl.memberCount;
      final online = _ctl.groupOnlineCount;
      if (members != null) {
        subtitle = s.membersWithOnline(members, online);
      } else if (connecting) {
        subtitle = s.connectingDots;
        accentSubtitle = true;
      } else {
        subtitle = '';
      }
    }

    return GestureDetector(
      onTap: () {
        if (widget.kind == ChatKind.pv) {
          final u = widget.peerUsername;
          if (u.isNotEmpty) {
            Navigator.of(context, rootNavigator: true)
                .push(UserProfileScreen.route(u));
          }
        } else if (widget.kind == ChatKind.group ||
            widget.kind == ChatKind.channel) {
          _openRoomInfo();
        }
      },
      behavior: HitTestBehavior.opaque,
      child: ClipRect(
        // v1.2.0 PERF — the fake-glass blur is GONE. A BackdropFilter over a
        // scrolling list re-filters every single frame (full-screen GPU
        // readback) — THE biggest source of jank on weak phones. Telegram's
        // own Android header is a solid translucent bar; we match it.
        child: Container(
          padding: EdgeInsets.fromLTRB(12, topInset, 12, 0),
          decoration: BoxDecoration(
            color: p.chatHeadBg,
            border: Border(bottom: BorderSide(color: p.chatHeadBorder)),
            boxShadow: const [
              BoxShadow(color: Color(0x24000000), blurRadius: 18)
            ],
          ),
            child: SizedBox(
              height: 60,
              child: Row(
          children: [
            _roundIconBtn(p, Icons.arrow_back_rounded, () => Navigator.of(context).pop()),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () {
                if (widget.kind == ChatKind.general) return;
                final url = ApiService.I.avatarUrl(widget.avatarPath);
                if (url.isNotEmpty && !widget.avatarPath.contains('default.png')) {
                  openMediaViewer(context, fileUrl: url, title: widget.title);
                } else if (widget.kind == ChatKind.pv && widget.peerUsername.isNotEmpty) {
                  Navigator.of(context, rootNavigator: true)
                      .push(UserProfileScreen.route(widget.peerUsername));
                } else if (widget.kind == ChatKind.group ||
                    widget.kind == ChatKind.channel) {
                  Navigator.of(context, rootNavigator: true)
                      .push(GroupInfoScreen.route(widget.roomId));
                }
              },
              child: Stack(children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    gradient: widget.kind == ChatKind.general ? C.globeGrad : C.crAvatarGrad,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: widget.kind == ChatKind.general
                          ? const Color(0x8C38BDF8)
                          : const Color(0x8C8B5CF6),
                      width: 2,
                    ),
                  ),
                  child: widget.isSelfChat
                      // v1.4.0 — سیو مسیج: آیکون بوکمارک مثل تلگرام
                      ? const Center(
                          child: Icon(Icons.bookmark_rounded,
                              size: 19, color: Colors.white))
                      : widget.kind == ChatKind.general
                      ? Padding(
                          padding: const EdgeInsets.all(8),
                          child: CustomPaint(painter: _GlobeMini()),
                        )
                      : ClipOval(
                          child: widget.avatarPath.isNotEmpty &&
                                  !widget.avatarPath.contains('default.png')
                              ? Image.network(
                                  ApiService.I.avatarUrl(widget.avatarPath),
                                  fit: BoxFit.cover,
                                  headers: {'Cookie': ApiService.I.cookieHeader},
                                  errorBuilder: (_, __, ___) => Center(
                                    child: Text(widget.title.isEmpty
                                        ? '?'
                                        : widget.title[0].toUpperCase(),
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w800,
                                            fontSize: 15)),
                                  ),
                                )
                              : Center(
                                  child: Text(widget.title.isEmpty
                                      ? '?'
                                      : widget.title[0].toUpperCase(),
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w800,
                                          fontSize: 15)),
                                ),
                        ),
                ),
                if (isOnline && !showTyping)
                  Positioned(
                    bottom: 0,
                    left: 0,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: C.onlinePurple,
                        shape: BoxShape.circle,
                        border: Border.all(color: p.chatHeadBg, width: 2),
                      ),
                    ),
                  ),
              ]),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // v1.3.2 — PRO star (blue tick) beside the peer's name in the
                  // PV header, with the Telegram-inspired entrance pop.
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(widget.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w800,
                                color: p.chatText)),
                      ),
                      if (widget.kind == ChatKind.pv &&
                          pvInfo != null &&
                          pvInfo.isPro) ...[
                        const SizedBox(width: 5),
                        const ProStarBadge(size: 16, entrance: true),
                      ],
                      if (widget.kind == ChatKind.pv &&
                          pvInfo != null &&
                          pvInfo.isAdmin &&
                          !pvInfo.isPro) ...[
                        const SizedBox(width: 5),
                        const VerifiedBadge(size: 14),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(children: [
                    Flexible(
                      child: Text(subtitle,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 10,
                              color: accentSubtitle
                                  ? C.onlinePurple
                                  : p.chatText2,
                              fontWeight: accentSubtitle
                                  ? FontWeight.w600
                                  : FontWeight.w400)),
                    ),
                    if (showTyping) ...[
                      const SizedBox(width: 5),
                      const _TypingDots(),
                    ],
                  ]),
                ],
              ),
            ),
            if (widget.kind == ChatKind.pv && _ctl.pvInfo?.iBlockedThem == true)
              GestureDetector(
                onTap: () async {
                  final u = widget.peerUsername;
                  if (u.isEmpty) return;
                  await ApiService.I.unblockUser(u);
                  if (!mounted) return;
                  showGlassToast(context, s.unblockedToast);
                  final r = await ApiService.I.pvInfo(widget.chatId);
                  if (r.ok && r.data != null) _ctl.setPvInfo(PvInfo.fromJson(r.data!));
                },
                child: Icon(Icons.block_rounded, size: 20, color: p.text2),
              )
            else ...[
              // v1.1.0 — Telegram-style call button (PV chats)
              if (widget.kind == ChatKind.pv && widget.peerUsername.isNotEmpty)
                _roundIconBtn(p, Icons.phone_outlined, () {
                  showGlassToast(context, s.callsComingSoon,
                      icon: Icons.phone_outlined,
                      color: const Color(0xFF22C55E));
                }),
              Builder(builder: (btnCtx) => _roundIconBtn(
                  p, Icons.more_vert_rounded,
                  () => _showChatMenu(p, s, btnCtx))),
            ],
          ],
              ),
            ),
          ),
        ),
    );
  }

  // v1.1.0 — open room info; if the user picked a media and hit the EYE,
  // come back and scroll the chat onto that exact message.
  Future<void> _openRoomInfo() async {
    final jumpedId = await Navigator.of(context, rootNavigator: true)
        .push<int>(GroupInfoScreen.route(widget.roomId));
    if (jumpedId != null && jumpedId > 0 && mounted) {
      await _scrollToMessage(jumpedId);
    }
  }

  Widget _roundIconBtn(Palette p, IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: const BoxDecoration(color: Colors.transparent, shape: BoxShape.circle),
        child: Icon(icon, size: 21, color: p.chatText),
      ),
    );
  }

  // -------------------------------------------------- v1.0.8 chat ⋮ menu
  // Telegram-style floating glass panel anchored under the ⋮ button:
  // Info / Mute–Unmute / Ravi AI / Leave (group+channel) / Block (pv).
  void _showChatMenu(Palette p, S s, BuildContext btnCtx) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final box = btnCtx.findRenderObject() as RenderBox?;
    final anchor = box != null
        ? box.localToGlobal(Offset.zero)
        : const Offset(0, 60);
    final isRoom =
        widget.kind == ChatKind.group || widget.kind == ChatKind.channel;
    final items = <MenuItem>[
      if (widget.kind == ChatKind.pv && widget.peerUsername.isNotEmpty)
        MenuItem(Icons.person_outline_rounded, s.viewProfile,
            const Color(0xFF8B5CF6), () {
          Navigator.of(context, rootNavigator: true)
              .push(UserProfileScreen.route(widget.peerUsername));
        })
      else if (isRoom)
        MenuItem(Icons.info_outline_rounded, s.chatMenuInfo,
            const Color(0xFF8B5CF6), _openRoomInfo),
      if (isRoom)
        MenuItem(
            _ctl.isRoomMuted
                ? Icons.notifications_active_rounded
                : Icons.notifications_off_rounded,
            _ctl.isRoomMuted ? s.chatMenuUnmute : s.chatMenuMute,
            const Color(0xFF38BDF8), () async {
          final r = await ApiService.I.toggleRoomMute(widget.roomId);
          if (!mounted) return;
          if (r.ok) {
            setState(() => _ctl.setRoomMuted(r.data == true));
            showGlassToast(context,
                r.data == true ? s.mutedToast : s.unmutedToast,
                icon: r.data == true
                    ? Icons.notifications_off_rounded
                    : Icons.notifications_active_rounded);
          } else {
            showGlassToast(context, s.error,
                icon: Icons.error_outline_rounded,
                color: const Color(0xFFEF4444));
          }
        }),
      MenuItem(Icons.auto_awesome_rounded, s.chatMenuAI,
          const Color(0xFFF59E0B), () {
        showGlassToast(context, s.chatMenuAISoon,
            icon: Icons.auto_awesome_rounded, color: const Color(0xFFF59E0B));
      }),
      // v1.1.0 — block/unblock straight from the chat ⋮ menu (Telegram)
      if (widget.kind == ChatKind.pv && widget.peerUsername.isNotEmpty)
        MenuItem(
            _ctl.pvInfo?.iBlockedThem == true
                ? Icons.lock_open_rounded
                : Icons.block_rounded,
            _ctl.pvInfo?.iBlockedThem == true ? s.unblockUser : s.blockUser,
            const Color(0xFFEF4444), () async {
          final u = widget.peerUsername;
          if (u.isEmpty) return;
          if (_ctl.pvInfo?.iBlockedThem == true) {
            final r = await ApiService.I.unblockUser(u);
            if (!mounted) return;
            if (r.ok) {
              showGlassToast(context, s.unblockedToast,
                  icon: Icons.lock_open_rounded);
            }
          } else {
            final r = await ApiService.I.blockUser(u);
            if (!mounted) return;
            if (r.ok) {
              showGlassToast(context, s.blockedToast,
                  icon: Icons.block_rounded,
                  color: const Color(0xFFEF4444));
            }
          }
          final r2 = await ApiService.I.pvInfo(widget.chatId);
          if (r2.ok && r2.data != null) {
            _ctl.setPvInfo(PvInfo.fromJson(r2.data!));
          }
        }),
      if (isRoom)
        MenuItem(Icons.logout_rounded, s.chatMenuLeave,
            const Color(0xFFEF4444), () => _confirmLeave()),
    ];

    showFloatingMenu(
      context,
      items: items,
      dark: dark,
      alignEnd: true,
      anchor: anchor,
    );
  }

  Future<void> _confirmLeave() async {
    final s = AppState.I.str;
    final ok = await showRaviModal(
      context,
      icon: Icons.logout_rounded,
      iconColor: const Color(0xFFEF4444),
      title: s.leaveConfirmTitle,
      body: s.leaveConfirmBody(widget.title),
      okText: s.chatMenuLeave,
      cancelText: s.cancel,
      danger: true,
    );
    if (!ok) return;
    final r = await ApiService.I.leaveRoom(widget.roomId);
    if (!mounted) return;
    if (r.ok) {
      showGlassToast(context, s.leftRoomToast, icon: Icons.logout_rounded);
      Navigator.of(context).pop();
    } else {
      showGlassToast(context,
          r.message == 'owner_cannot_leave' ? s.ownerCannotLeave : s.error,
          icon: Icons.error_outline_rounded, color: const Color(0xFFEF4444));
    }
  }


  // ---------- messages list ----------
  Widget _messagesArea(Palette p, S s) {
    if (_ctl.messages.isEmpty && _ctl.error != null) {
      return _errorState(p, s);
    }
    if (_ctl.messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.chat_bubble_outline_rounded, size: 34, color: p.chatText3),
            const SizedBox(height: 10),
            Text(s.emptyChatTitle,
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700,
                    color: p.chatText2)),
            const SizedBox(height: 4),
            Text(s.emptyChatSub, style: TextStyle(fontSize: 11.5, color: p.chatText3)),
          ],
        ),
      );
    }

    final msgs = _ctl.messages;
    final n = msgs.length;
    final channelMode = widget.kind == ChatKind.channel;
    final showAvatars = !channelMode &&
        (widget.kind == ChatKind.general || widget.kind == ChatKind.group);

    // ---- v1.1.1 — Telegram-style ALBUM grouping (SINGLE PASS, O(n)) ----
    // Consecutive caption-less photos from the same sender (same day, within
    // ~2 minutes, or sharing a client albumId) collapse into ONE bubble.
    // The old nested-walk version was O(n²) and stuttered on weak phones.
    final gStart = List<int>.filled(n, 0);
    final gLen = List<int>.filled(n, 0);
    var s0 = 0;
    for (var k = 1; k <= n; k++) {
      if (k == n || !_albumJoinable(msgs[k - 1], msgs[k])) {
        for (var t = s0; t < k; t++) {
          gStart[t] = s0;
          gLen[t] = k - s0;
        }
        s0 = k;
      }
    }

    // v1.3.2 — one row builder shared by the keyed ListView below (same
    // logic as before, just lifted out of itemBuilder so keys stay readable).
    Widget _messageRow(int msgIndex, Message msg) {
      final dateKey = msg.dateKey;

      // bookkeeping for the floating date pill + reply jumps
      if (msg.id > 0) {
        _msgDates[msg.id] = dateKey;
      }

      // v1.1.0 — appear animation for LIVE arrivals + optimistic sends
      final animate = msg.pending ||
          msg.failed ||
          _liveIds.contains(msg.id) ||
          (msg.clientMsgId.isNotEmpty && !msg.isMe && _ctl.historyLoaded);

      // v1.1.0 — album bubbles: only the FIRST message of a group
      // renders (with all the photos); the rest collapse away.
      final gs = gStart[msgIndex];
      final gl = gLen[msgIndex];
      final isAlbumStart = gl > 1 && msgIndex == gs;
      final albumMsgs = gl > 1 ? msgs.sublist(gs, gs + gl) : <Message>[];

      // global key per message id (for jump-to-reply)
      final mkey = msg.id > 0 ? (_msgKeys[msg.id] ??= GlobalKey()) : null;
      final isSel = _selected.contains(msg.id);

      if (gl > 1 && !isAlbumStart) {
        return const SizedBox.shrink();
      }

      return RepaintBoundary(
        child: BubbleAppear(
          animate: animate,
          child: BubbleRemover(
            removing: albumMsgs.isEmpty
                ? msg.removing
                : albumMsgs.every((m) => m.removing),
            child: SwipeToReply(
              onSwipeReply: () => _setReply(msg),
              child: Builder(
                builder: (bctx) {
                  if (msg.id > 0) _msgCtx[msg.id] = bctx;
                  // v1.0.9 — SINGLE TAP anywhere on the row:
                  //  • selection mode → toggle selection
                  //  • panel open for this message → close
                  //  • else → open the panel anchored to this row
                  // Long-press still opens too (muscle memory).
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      if (_selectionMode) {
                        _toggleSelect(msg);
                        return;
                      }
                      _showActions(bctx, msg, fromTap: true);
                    },
                    onLongPress: () {
                      if (_selectionMode) {
                        _toggleSelect(msg);
                        return;
                      }
                      _showActions(bctx, msg);
                    },
                    child: _selectWrap(
                      p,
                      selected: isSel,
                      selecting: _selectionMode,
                      child: HighlightBox(
                        highlight:
                            _highlightId != null && msg.id == _highlightId,
                        child: MessageBubble(
                          msg: msg,
                          kind: widget.kind,
                          showAvatar: showAvatars,
                          channelMode: channelMode,
                          album: isAlbumStart ? albumMsgs : null,
                          onReply: _setReply,
                          onReact: (m, e) => _ctl.toggleReaction(m, e),
                          onOpenProfile: _openProfile,
                          onOpenMedia: _openMedia,
                          onJumpToReply: _jumpToReply,
                          onForward: (m) =>
                              ForwardScreen.open(context, messages: [m]),
                          // v1.0.9 — admins/owner can also delete
                          // OTHERS' messages in groups/channels.
                          onDelete: (msg.isMe || _canModerate)
                              ? (m) => _confirmDelete(m)
                              : null,
                          onSaveGif: msg.fileType == 'gif'
                              ? (m) async {
                                  final r = await ApiService.I
                                      .saveGifFromChat(m.fileUrl);
                                  if (!mounted) return;
                                  showGlassToast(context,
                                      r.ok ? s.gifSavedToLibrary : s.error,
                                      icon: r.ok
                                          ? Icons.favorite_rounded
                                          : Icons.error_outline_rounded);
                                }
                              : null,
                          onDownload: _downloadMedia,
                          onTokenTap: _onTokenTap,
                          // v1.2.1 — long-press a single album
                          // photo → ITS action panel (reply!)
                          onAlbumItemLongPress: (bctx, item) {
                            if (_selectionMode) {
                              _toggleSelect(item);
                              return;
                            }
                            _showActions(bctx, item);
                          },
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
    }

    // v1.3.2 — WHATSUP-STYLE STABLE ITEM IDENTITIES (the real anti-jump):
    // without per-item keys Flutter matches sliver children BY INDEX, so on
    // every insert every visible row received its neighbour's data — photos
    // and GIFs flashed (placeholder + fade-in re-ran) and the rows above the
    // new bubble visibly "jumped". Keying each row by its message id (or the
    // optimistic clientMsgId) + findChildIndexCallback keeps every existing
    // element alive: only the NEW row is created, everything else stays
    // pixel-identical — exactly how WhatsUp keeps its chat smooth.
    String _keyOf(Message m, int fallbackIdx) {
      if (m.clientMsgId.isNotEmpty) return 'c${m.clientMsgId}';
      if (m.id > 0) return 'm${m.id}';
      return 'x$fallbackIdx';
    }

    return Stack(
      children: [
        ListView.builder(
          controller: _scroll,
          reverse: true,
          physics: const BouncingScrollPhysics(parent: ClampingScrollPhysics()),
          padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
          // v1.5.0 — بهینه‌سازی موبایل ضعیف: کش‌اکستنت بیشتر (اسکرول نرم‌تر
          // بدون لگ) + ساخت children کمتر در هر فریم
          cacheExtent: 720,
          addAutomaticKeepAlives: false,
          addRepaintBoundaries: false, // هر ردیف خودش RepaintBoundary دارد
          itemCount: n + (_ctl.historyDone ? 0 : 1),
          findChildIndexCallback: (key) {
            final v = key is ValueKey<String> ? key.value : '';
            if (v.isEmpty) return null;
            int msgIndex;
            if (v.startsWith('m')) {
              final id = int.tryParse(v.substring(1)) ?? 0;
              if (id <= 0) return null;
              msgIndex = msgs.indexWhere((m) => m.id == id);
            } else if (v.startsWith('c')) {
              msgIndex = msgs.indexWhere((m) => m.clientMsgId == v.substring(1));
            } else {
              return null;
            }
            if (msgIndex < 0) return null;
            final i = n - 1 - msgIndex;
            return (i >= 0 && i < n) ? i : null;
          },
          itemBuilder: (context, i) {
            if (!_ctl.historyDone && i == n) {
              return KeyedSubtree(
                key: const ValueKey('history-loader'),
                child: Padding(
                padding: const EdgeInsets.all(10),
                child: Center(
                  child: _ctl.loadingHistory
                      ? const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const SizedBox.shrink(),
                ),
              ),
              );
            }
            final msgIndex = n - 1 - i;
            final msg = msgs[msgIndex];
            final itemKey = ValueKey<String>(_keyOf(msg, i));

            Widget row;
            // v1.2.1 — Telegram SERVICE messages (member joined / left) are
            // centered glass capsules, never a normal bubble.
            if (msg.isService) {
              row = Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: _serviceRow(p, msg),
              );
            } else {
              row = _messageRow(msgIndex, msg);
            }
            return KeyedSubtree(key: itemKey, child: row);
          },
        ),
        // v1.1.1 — sticky glass date pill glides between days with a soft
        // fade+slide, exactly under the header. This is the ONLY date chip
        // in the whole chat now (the in-list pills are gone).
        // v1.2.0 PERF — listens to a ValueNotifier: scrolling no longer
        // rebuilds the bubble list just to move the date pill.
        if (!_selectionMode)
          Positioned(
            top: 6,
            left: 0,
            right: 0,
            child: Center(
              child: ValueListenableBuilder<String?>(
                valueListenable: _stickyDateN,
                builder: (context, stickyDate, _) => AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, anim) => FadeTransition(
                    opacity: anim,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, -0.35),
                        end: Offset.zero,
                      ).animate(anim),
                      child: child,
                    ),
                  ),
                  child: stickyDate == null
                      ? const SizedBox.shrink(key: ValueKey('no-date'))
                      : _StickyDatePill(
                          key: ValueKey('date-' + stickyDate),
                          dateKey: stickyDate,
                          palette: p,
                          lang: AppState.I.lang.value,
                        ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// v1.1.0 — Telegram-style selection wrapper: a soft green halo around the
  /// picked bubble + a floating glass check-badge on its corner.
  Widget _selectWrap(Palette p,
      {required bool selected,
      required bool selecting,
      required Widget child}) {
    if (!selecting) return child;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            color: selected
                ? const Color(0x2922C55E)
                : Colors.black.withValues(alpha: .18),
            border: Border.all(
              color: selected
                  ? const Color(0x8822C55E)
                  : Colors.transparent,
              width: 1.4,
            ),
          ),
          padding: const EdgeInsets.all(3),
          child: child,
        ),
        PositionedDirectional(
          top: -5,
          end: -5,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected ? const Color(0xFF22C55E) : p.chatHeadBg,
              border: Border.all(
                color: selected
                    ? const Color(0xFF22C55E)
                    : p.chatText3.withValues(alpha: .6),
                width: 1.5,
              ),
              boxShadow: const [
                BoxShadow(color: Color(0x33000000), blurRadius: 8),
              ],
            ),
            child: selected
                ? const Icon(Icons.check_rounded,
                    size: 14, color: Colors.white)
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }

  /// v1.1.0 — can two consecutive messages render as one photo album?
  bool _albumJoinable(Message a, Message b) {
    if (a.username != b.username) return false;
    if (a.fileType != 'image' || b.fileType != 'image') return false;
    if (a.text.trim().isNotEmpty || b.text.trim().isNotEmpty) return false;
    if (a.dateKey != b.dateKey) return false;
    if (a.albumId.isNotEmpty && b.albumId.isNotEmpty) {
      return a.albumId == b.albumId;
    }
    int mins(String t) {
      final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(t.trim());
      if (m == null) return -1;
      return (int.parse(m.group(1)!) * 60) + int.parse(m.group(2)!);
    }
    final ta = mins(a.time), tb = mins(b.time);
    if (ta < 0 || tb < 0) return false;
    return (tb - ta).abs() <= 2;
  }

  Future<void> _confirmDelete(Message msg) async {
    final s = AppState.I.str;
    final ok = await showRaviModal(
      context,
      icon: Icons.delete_outline_rounded,
      iconColor: const Color(0xFFEF4444),
      title: s.deleteMsgTitle,
      body: s.deleteMsgConfirm,
      okText: s.delete,
      cancelText: s.cancel,
      danger: true,
    );
    if (ok) _ctl.deleteOwn(msg);
  }

  void _showActions(BuildContext context, Message msg, {bool fromTap = false}) {
    final s = AppState.I.str;
    // v1.0.9 — Telegram-style TOGGLE: tapping the SAME message while its panel
    // is open closes it; tapping another message MOVES the panel there.
    if (fromTap && MessageActionPanel.toggleFor(msg.id)) return;
    if (!fromTap) MessageActionPanel.closeCurrent();
    final box = context.findRenderObject() as RenderBox?;
    final rect = box != null
        ? box.localToGlobal(Offset.zero) & box.size
        : Rect.zero;
    MessageActionPanel.show(
      context,
      msg: msg,
      anchorRect: rect,
      onReply: () => _setReply(msg),
      onSelect: msg.id > 0 ? () => _enterSelection(msg) : null,
      // v1.0.9 — edit lands IN THE COMPOSER (Telegram-style), not a dialog.
      // Admins of rooms may edit channel posts too (server allows it).
      onEdit: msg.id > 0 &&
              msg.text.trim().isNotEmpty &&
              !msg.isAudio &&
              (msg.isMe || _canModerate)
          ? () => _startEditing(msg)
          : null,
      onCopy: () async {
        await Clipboard.setData(ClipboardData(text: msg.text));
        if (!mounted) return;
        showGlassToast(context, s.copied);
      },
      onSaveGif: msg.fileType == 'gif' && msg.fileUrl.isNotEmpty
          ? () async {
              final res = await ApiService.I.saveGifFromChat(msg.fileUrl);
              if (!mounted) return;
              showGlassToast(context, res.ok ? s.gifSavedToLibrary : s.error,
                  icon: res.ok ? Icons.favorite_rounded : Icons.error_outline_rounded);
            }
          : null,
      onForward: msg.id > 0
          ? () => ForwardScreen.open(context, messages: [msg])
          : null,
      onDelete: (msg.isMe || _canModerate) ? () => _confirmDelete(msg) : null,
      // v1.1.0 — Telegram-style client-side pin
      onPin: (msg.id > 0 && _ctl.canPin) ? () => _togglePin(msg) : null,
      onReact: (e) => _ctl.toggleReaction(msg, e),
    );
  }

  Widget _errorState(Palette p, S s) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.cloud_off_rounded, size: 36, color: p.chatText3),
          const SizedBox(height: 12),
          Text(s.serverUnreachable,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: p.chatText2)),
          const SizedBox(height: 14),
          OutlinedButton(
            onPressed: () => _ctl.refresh(),
            style: OutlinedButton.styleFrom(
                foregroundColor: p.accent,
                side: BorderSide(color: p.accent.withValues(alpha: .4))),
            child: Text(s.retry),
          ),
        ],
      ),
    );
  }

  // ---------- reply bar (v1.0.8 — Telegram-style) ----------
  // Rounded card that slides in above the composer: gradient accent bar on
  // the reply side, bold accent name, single-line snippet, spring-in entry.
  Widget _replyBar(Palette p) {
    if (_replyToId == null) return const SizedBox.shrink();
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      child: Container(
        padding: const EdgeInsets.fromLTRB(0, 7, 0, 7),
        decoration: BoxDecoration(
          color: p.chatHeadBg,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: p.chatHeadBorder),
        ),
            child: Row(
              children: [
                const SizedBox(width: 4),
                // v1.2.0 — slim NEUTRAL accent line (the old chunky gradient
                // bar read as a heavy purple stripe; Telegram uses a thin
                // colored line only).
                Container(
                  width: 2.5,
                  height: 30,
                  margin: EdgeInsetsDirectional.only(
                      start: rtl ? 0 : 9, end: rtl ? 9 : 0),
                  decoration: BoxDecoration(
                    color: p.accent.withValues(alpha: .85),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_replyAuthor ?? '',
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12.2,
                              fontWeight: FontWeight.w800,
                              color: p.accent)),
                      const SizedBox(height: 1.5),
                      Text(_replyText ?? '',
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11.6,
                              height: 1.2,
                              color: p.chatText2)),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: _clearReply,
                  child: Container(
                    width: 30, height: 30,
                    margin: const EdgeInsetsDirectional.only(end: 6),
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: p.chatText2.withValues(alpha: .12)),
                    child: Icon(Icons.close_rounded,
                        size: 15, color: p.chatText2),
                  ),
                ),
              ],
            ),
      ),
    );
  }

  // ---------- composer ----------
  Widget _readOnlyBar(Palette p, S s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: p.chatHeadBg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: p.chatHeadBorder),
          ),
          child: Text(s.channelPostOnly,
              style: TextStyle(fontSize: 11.5, color: p.chatText2)),
        ),
      ),
    );
  }

  Widget _composer(Palette p, S s) {
    // v1.3.1 — the AnimatedPadding wrapper above owns ALL bottom insets.
    // v1.0.9 — slow mode: show the live countdown chip; send stays enabled
    // (the server enforces it and we surface the exact remaining seconds).
    if (_slowRemaining > 0) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(7, 0, 7, 7),
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: p.chatInputBg,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
                color: const Color(0xFFF59E0B).withValues(alpha: .5)),
          ),
          child: Row(children: [
            const Icon(Icons.hourglass_top_rounded,
                size: 17, color: Color(0xFFF59E0B)),
            const SizedBox(width: 9),
            Expanded(
              child: Text(s.slowModeWait(_slowRemaining),
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: p.chatText2)),
            ),
          ]),
        ),
      );
    }
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _input,
      builder: (context, tv, _) {
        final hasText = tv.text.trim().isNotEmpty;
        return Padding(
          padding: const EdgeInsets.fromLTRB(7, 0, 7, 7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.fromLTRB(4, 3, 4, 3),
                  decoration: BoxDecoration(
                    color: p.chatInputBg,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: p.chatHeadBorder),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      GestureDetector(
                        onTap: _attach,
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Icon(Icons.add_rounded, size: 24,
                              color: p.chatInputText.withValues(alpha: .75)),
                        ),
                      ),
                      // v1.0.8 — the standalone GIF button is gone: GIFs live
                      // inside the emoji panel's second tab (Telegram-like).
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 9),
                          child: TextField(
                            controller: _input,
                            focusNode: _inputFocus,
                            onTap: () {
                              if (_emojiOpen) {
                                setState(() => _emojiOpen = false);
                              }
                            },
                            maxLines: 5,
                            minLines: 1,
                            textInputAction: TextInputAction.newline,
                            keyboardType: TextInputType.multiline,
                            // v1.1.0 — bidi-aware direction (fixes emoji/EN
                            // landing behind Persian text while typing)
                            textDirection: _inputDir,
                            style: TextStyle(
                                fontSize: 13.8, color: p.chatInputText, height: 1.35),
                            decoration: InputDecoration(
                              isCollapsed: true,
                              border: InputBorder.none,
                              hintText: s.messageHint,
                              hintStyle: TextStyle(
                                  fontSize: 13.8, color: p.chatInputPh),
                            ),
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: () {
                          setState(() => _emojiOpen = !_emojiOpen);
                          if (_emojiOpen) _inputFocus.unfocus();
                          else _inputFocus.requestFocus();
                        },
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(4, 8, 8, 8),
                          child: Icon(
                              _emojiOpen
                                  ? Icons.keyboard_rounded
                                  : Icons.emoji_emotions_outlined,
                              size: 23,
                              color: p.chatInputText.withValues(alpha: .75)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // send / mic — instant switch driven by the live text value;
              // while EDITING a message the pill becomes a confirm check.
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 130),
                transitionBuilder: (child, anim) => ScaleTransition(
                    scale: anim, child: child),
                child: _editing != null
                    ? _EditCheckButton(key: const ValueKey('editcheck'), onTap: _send)
                    : _SendOrMic(
                        key: ValueKey(hasText ? 'send' : 'mic'),
                        isSend: hasText,
                        recording: !hasText && (_recording || _recLocked),
                        onTap: hasText ? _send : null, // mic uses hold gestures below
                        onHoldStart: hasText ? null : _onRecStart,
                        onHoldUpdate: hasText ? null : _onRecDrag,
                        onHoldEnd: hasText ? null : (_) => _onRecRelease(),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _onRecStart(PointerDownEvent e) {
    _holdPos = e.position;
    _recPointer = e.position;
    _screenSize = MediaQuery.sizeOf(context);
    _startRecording();
  }

  void _onRecDrag(PointerMoveEvent e) {
    if (!_recording || _recLocked) return;
    _recPointer = e.position;
    final startDy = _holdPos?.dy ?? e.position.dy;
    final dy = e.position.dy - startDy; // negative = up
    final dx = e.position.dx - (_holdPos?.dx ?? e.position.dx);
    if (dy < -60 && !_recLocked) {
      setState(() {
        _recLocked = true;
        _lockDy = 0;
        _cancelDx = 0;
      });
      HapticFeedback.mediumImpact();
      return;
    }
    setState(() {
      _lockDy = dy.clamp(-80.0, 0.0);
      // v1.0.8 — slide toward the list edge to cancel (Telegram)
      _cancelDx = dx.clamp(-90.0, 0.0);
    });
  }

  void _onRecRelease() {
    if (!_recording) return;
    if (_recLocked) {
      // locked: keep recording; the lock bar has pause/delete/send buttons
      setState(() => _lockDy = 0);
    } else if (_cancelDx < -55) {
      // slid away → discard (Telegram "slide to cancel")
      _recCancelled = true;
      _stopRecording(send: false);
      setState(() => _cancelDx = 0);
    } else {
      _stopRecording(send: true);
      setState(() => _cancelDx = 0);
    }
  }

  /// v1.2.0 — mm:ss from real elapsed milliseconds
  String get _recClock {
    final total = (_recMs / 1000).floor();
    final mins = (total ~/ 60).toString().padLeft(2, '0');
    final secs = (total % 60).toString().padLeft(2, '0');
    return '$mins:$secs';
  }

  // ---------- v1.2.0 Telegram-style recording bar (REBUILT) ----------
  // Holding: pulsing red mic + live amplitude waveform + timer + sliding
  // "‹ slide to cancel" chip + slide-up lock. Locked: pause / delete / send
  // controls, exactly like Telegram's hands-free mode.
  Widget _recordingBar(Palette p, S s) {
    final rtl = Directionality.of(context) == TextDirection.rtl;

    if (_recLocked) {
      // LOCKED bar — pause/resume + trash + send, no holding needed
      return Padding(
        padding: const EdgeInsets.fromLTRB(7, 0, 7, 7),
        child: Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: p.chatInputBg,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0x33EF4444)),
          ),
          child: Row(children: [
            _PulsingRedDot(size: 11),
            const SizedBox(width: 10),
            Text(_recClock,
                textDirection: TextDirection.ltr,
                style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: C.recordRedText)),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: C.recordRed.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.lock_rounded, size: 12, color: C.recordRed),
                const SizedBox(width: 4),
                Text(s.lockedRecord,
                    style: const TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: C.recordRedText)),
              ]),
            ),
            const Spacer(),
            // v1.2.0 — pause / resume (Telegram hands-free)
            GestureDetector(
              onTap: _toggleRecPause,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: (_recPaused ? Colors.green : C.recordRed)
                      .withValues(alpha: .12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                    _recPaused
                        ? Icons.play_arrow_rounded
                        : Icons.pause_rounded,
                    size: 19,
                    color: _recPaused ? Colors.green : C.recordRed),
              ),
            ),
            const SizedBox(width: 10),
            GestureDetector(
              onTap: () {
                _recCancelled = true;
                _stopRecording(send: false);
              },
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFEF4444).withValues(alpha: .12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.delete_outline_rounded,
                    size: 19, color: C.recordRed),
              ),
            ),
            const SizedBox(width: 10),
            GestureDetector(
              onTap: () => _stopRecording(send: true),
              child: Container(
                width: 40, height: 40,
                decoration: const BoxDecoration(
                  gradient: C.ownBubbleGrad,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.send_rounded, size: 18, color: Colors.white),
              ),
            ),
          ]),
        ),
      );
    }

    // HOLDING state — Telegram feel:
    //  • the whole bar tinted soft red
    //  • live amplitude waveform (v1.2.0)
    //  • "‹ Slide to cancel" chip slides with the finger toward the edge
    //  • lock chevron appears above the mic while lifting
    final cancelT = (-_cancelDx / 60).clamp(0.0, 1.0);
    final lockT = (-_lockDy / 60).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(7, 0, 7, 7),
      child: Stack(clipBehavior: Clip.none, children: [
        // lock hint bubble (top, fades in as the finger lifts)
        if (lockT > 0.05)
          Positioned(
            top: -46 - 10 * lockT, left: 0, right: 0,
            child: Opacity(
              opacity: lockT.clamp(0.0, 1.0),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: p.chatHeadBg,
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: C.recordRed.withValues(alpha: .55)),
                    boxShadow: const [
                      BoxShadow(color: Color(0x28000000), blurRadius: 12),
                    ],
                  ),
                  child: Icon(Icons.lock_open_rounded,
                      size: 17,
                      color: lockT > 0.85 ? C.recordRed : p.chatText2),
                ),
              ),
            ),
          ),
        Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: p.chatInputBg,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
                color: C.recordRed.withValues(alpha: .25 + .2 * cancelT)),
          ),
          child: Row(children: [
            _PulsingRedDot(size: 11),
            const SizedBox(width: 10),
            Text(_recClock,
                textDirection: TextDirection.ltr,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    fontFeatures: [FontFeature.tabularFigures()],
                    color: C.recordRedText)),
            const SizedBox(width: 10),
            // v1.2.0 — LIVE AMPLITUDE WAVEFORM (Telegram)
            Expanded(
              child: Stack(children: [
                // waveform, hidden as the cancel chip takes over
                Opacity(
                  opacity: (1 - cancelT).clamp(0.0, 1.0),
                  child: SizedBox(
                    height: 26,
                    width: double.infinity,
                    child: CustomPaint(
                      size: const Size(double.infinity, 26),
                      painter: _RecWavePainter(amps: _recAmps),
                    ),
                  ),
                ),
                // sliding cancel chip (Telegram-style)
                if (cancelT > 0.02)
                  Transform.translate(
                    offset: Offset(rtl ? 0 : _cancelDx * .55, 0),
                    child: Opacity(
                      opacity: cancelT,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.delete_outline_rounded,
                            size: 15, color: C.recordRed),
                        const SizedBox(width: 5),
                        Text(s.slideToCancel,
                            style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: C.recordRedText)),
                      ]),
                    ),
                  ),
              ]),
            ),
            // slide-up lock chevron at the mic side
            AnimatedOpacity(
              duration: const Duration(milliseconds: 140),
              opacity: lockT > 0.15 ? 1 : 0,
              child: Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: C.recordRed.withValues(alpha: .12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.keyboard_arrow_up_rounded,
                    size: 17, color: C.recordRed),
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  // ---------- v1.2.1 — floating voice circle (follows the finger) ----------
  // Telegram: while HOLDING the mic a circular bubble (mic + timer) glides
  // with your finger — release anywhere, slide up to lock, slide away to
  // cancel. It never disappears mid-hold.
  Widget _recFloatingCircle(Palette p) {
    final size = _screenSize == Size.zero
        ? MediaQuery.sizeOf(context)
        : _screenSize;
    const d = 66.0;
    final left = (_recPointer.dx - d / 2).clamp(8.0, size.width - d - 8);
    final top = (_recPointer.dy - d / 2)
        .clamp(MediaQuery.of(context).padding.top + 70, size.height - d - 120);
    return Positioned(
      left: left,
      top: top,
      // IgnorePointer keeps the drag flowing through to the mic Listener
      child: IgnorePointer(
        child: Container(
          width: d,
          height: d,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: p.chatHeadBg.withValues(alpha: .96),
            border: Border.all(
                color: C.recordRed.withValues(alpha: .55), width: 1.6),
            boxShadow: const [
              BoxShadow(color: Color(0x3ADC2626), blurRadius: 22, spreadRadius: 2),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const _PulsingRedDot(size: 13),
              const SizedBox(height: 4),
              Text(_recClock,
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      fontFeatures: [FontFeature.tabularFigures()],
                      color: C.recordRedText)),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- v1.2.1 — Telegram service capsule (join / leave) ----------
  // The backend marks membership events with a sys_* file_type; they render
  // as a small centered glass pill — NOT a normal bubble from the user.
  Widget _serviceRow(Palette p, Message m) {
    final s = AppState.I.str;
    final who = m.text.trim();
    final member = _ctl.memberOf(who);
    final name = (member?.name.isNotEmpty == true ? member!.name : who);
    final String label;
    final IconData icon;
    if (m.isServiceLeave) {
      label = s.userLeftToast(name);
      icon = Icons.logout_rounded;
    } else if (m.isServiceJoin) {
      label = s.userJoinedToast(name);
      icon = Icons.person_add_alt_1_rounded;
    } else {
      label = who;
      icon = Icons.info_outline_rounded;
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: p.chatHeadBg.withValues(alpha: .92),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: p.chatHeadBorder),
            boxShadow: const [BoxShadow(color: Color(0x1E000000), blurRadius: 10)],
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 13, color: p.chatText2),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: p.chatText2)),
          ]),
        ),
      ),
    );
  }

  // ---------- v1.0.8 combined Emoji + GIF panel ----------
  // One panel, two bottom tabs (like Telegram): Emoji picker + GIF library.
  // v1.1.0 — sending a GIF NO LONGER closes the panel: keep sending until
  // the user closes it themselves.
  Widget _emojiPanel(Palette p) {
    return EmojiGifPanel(
      palette: p,
      // v1.3.1 — the panel is EXACTLY as tall as the keyboard → the
      // keyboard⇄panel switch never reflows the chat (WhatsUp logic).
      height: _kbH.clamp(240.0, 380.0),
      emojiController: _input,
      onGifPicked: (url) {
        _ctl.sendGif(url,
            replyToId: _replyToId,
            replyAuthor: _replyAuthor,
            replyText: _replyText);
        _clearReply();
      },
    );
  }
}

/// v1.0.9 — the confirm-check pill while editing a message.
class _EditCheckButton extends StatelessWidget {
  final VoidCallback onTap;
  const _EditCheckButton({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: const BoxDecoration(
          gradient: C.ownBubbleGrad,
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.check_rounded, size: 22, color: Colors.white),
      ),
    );
  }
}

/// Send / mic pill — send when text is present; otherwise a hold-to-record
/// mic that also supports slide-up lock (via raw pointer tracking).
/// v1.1.0 — while recording, soft red pulse rings breathe around the mic.
class _SendOrMic extends StatefulWidget {
  final bool isSend;
  final bool recording;
  final VoidCallback? onTap;
  final void Function(PointerDownEvent)? onHoldStart;
  final void Function(PointerMoveEvent)? onHoldUpdate;
  final void Function(PointerEvent)? onHoldEnd;

  const _SendOrMic({
    super.key,
    required this.isSend,
    this.recording = false,
    this.onTap,
    this.onHoldStart,
    this.onHoldUpdate,
    this.onHoldEnd,
  });

  @override
  State<_SendOrMic> createState() => _SendOrMicState();
}

class _SendOrMicState extends State<_SendOrMic>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void initState() {
    super.initState();
    if (widget.recording) _pulse.repeat();
  }

  @override
  void didUpdateWidget(covariant _SendOrMic old) {
    super.didUpdateWidget(old);
    if (widget.recording && !_pulse.isAnimating) {
      _pulse.repeat();
    } else if (!widget.recording && _pulse.isAnimating) {
      _pulse.stop();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isSend) {
      return GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(
            gradient: C.ownBubbleGrad,
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.send_rounded, size: 20, color: Colors.white),
        ),
      );
    }
    final recording = widget.recording;
    // mic: hold to record (Listener so the drag keeps flowing outside)
    return Listener(
      onPointerDown: (e) => widget.onHoldStart?.call(e),
      onPointerMove: (e) => widget.onHoldUpdate?.call(e),
      onPointerUp: (e) => widget.onHoldEnd?.call(e),
      onPointerCancel: (e) => widget.onHoldEnd?.call(e),
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) {
          final t = _pulse.value;
          return Container(
            width: 44,
            height: 44,
            foregroundDecoration: recording
                ? BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFFEF4444)
                          .withValues(alpha: .55 * (1 - t)),
                      width: 1.6 + 2.2 * t,
                    ),
                  )
                : null,
            child: child,
          );
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            gradient: recording
                ? const LinearGradient(colors: [
                    Color(0xFFF87171),
                    Color(0xFFDC2626),
                  ])
                : C.ownBubbleGrad,
            shape: BoxShape.circle,
            boxShadow: recording
                ? const [
                    BoxShadow(
                        color: Color(0x55DC2626),
                        blurRadius: 14,
                        spreadRadius: 2),
                  ]
                : null,
          ),
          child: Icon(recording ? Icons.mic_rounded : Icons.mic_none_rounded,
              size: 20, color: Colors.white),
        ),
      ),
    );
  }
}

/// Animated 3-dot typing indicator (like the web .typing-dots).
class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1200))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        return Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.2),
              child: Transform.translate(
                offset: Offset(
                    0, -3.2 * (0.5 + 0.5 * math.sin((_c.value * 2 * math.pi) - i * 0.9))),
                child: Container(
                  width: 3.5, height: 3.5,
                  decoration: BoxDecoration(
                    color: C.onlinePurple
                        .withValues(alpha: .35 + 0.65 * (0.5 + 0.5 * math.sin(_c.value * 2 * math.pi - i * 0.9)).abs()),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
        ]);
      },
    );
  }
}

/// v1.2.0 — jump-to-reply highlight, exactly Telegram's: a soft tinted
/// backdrop appears BEHIND the bubble and gently fades away. The old
/// glowing purple ring (border + shadow) is gone — no more "purple bar",
/// no lifting or jumping of the message.
class HighlightBox extends StatefulWidget {
  final bool highlight;
  final bool selected;
  final Widget child;
  const HighlightBox(
      {super.key, this.highlight = false, this.selected = false,
      required this.child});

  @override
  State<HighlightBox> createState() => _HighlightBoxState();
}

class _HighlightBoxState extends State<HighlightBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 240));

  @override
  void initState() {
    super.initState();
    if (widget.highlight) _c.value = 1;
  }

  @override
  void didUpdateWidget(covariant HighlightBox old) {
    super.didUpdateWidget(old);
    if (widget.highlight && !old.highlight) {
      _c.forward(from: 0);
    } else if (!widget.highlight && old.highlight) {
      _c.reverse();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_c.value);
        if (t <= 0.01 && !widget.selected) return child!;
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: widget.selected
                ? Border.all(
                    color: const Color(0xFF22C55E).withValues(alpha: .8),
                    width: 1.6)
                : null,
            color: widget.selected
                ? const Color(0x1422C55E)
                : accent.withValues(alpha: .16 * t),
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// v1.0.9 — sticky glass date label under the chat header (Telegram):
/// "Today / Yesterday / dd/mm" glides between days while you scroll.
class _StickyDatePill extends StatelessWidget {
  final String dateKey;
  final Palette palette;
  final Lang lang;
  const _StickyDatePill(
      {super.key,
      required this.dateKey,
      required this.palette,
      required this.lang});

  @override
  Widget build(BuildContext context) {
    final label = _DatePill(dateKey: dateKey, palette: palette, lang: lang)
        ._label;
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 7),
      decoration: BoxDecoration(
        color: palette.chatHeadBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: palette.chatHeadBorder),
        boxShadow: const [
          BoxShadow(color: Color(0x22000000), blurRadius: 14),
        ],
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11.5,
              color: palette.chatText2,
              fontWeight: FontWeight.w700)),
    );
  }
}

/// Date separator pill (Today / Yesterday / dd/mm/yyyy).
class _DatePill extends StatelessWidget {
  final String dateKey;
  final Palette palette;
  final Lang lang;

  const _DatePill({required this.dateKey, required this.palette, required this.lang});

  String get _label {
    final s = S(lang);
    if (dateKey.isEmpty) return '';
    final today = DateTime.now();
    final tk =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    final y = today.subtract(const Duration(days: 1));
    final yk =
        '${y.year}-${y.month.toString().padLeft(2, '0')}-${y.day.toString().padLeft(2, '0')}';
    if (dateKey == tk) return s.today;
    if (dateKey == yk) return s.yesterday;
    final parts = dateKey.split('-');
    if (parts.length == 3) return '${parts[2]}/${parts[1]}/${parts[0]}';
    return dateKey;
  }

  @override
  Widget build(BuildContext context) {
    if (_label.isEmpty) return const SizedBox.shrink();
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 7),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
        decoration: BoxDecoration(
          color: palette.chatHeadBg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: palette.chatHeadBorder),
        ),
        child: Text(_label,
            style: TextStyle(
                fontSize: 11,
                color: palette.chatText2,
                fontWeight: FontWeight.w600)),
      ),
    );
  }
}

class _GlobeMini extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = Colors.white;
    final c = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(c, size.width / 2, paint);
    canvas.drawOval(
        Rect.fromCenter(
            center: c, width: size.width * 0.45, height: size.width),
        paint);
    canvas.drawLine(Offset(0, c.dy), Offset(size.width, c.dy), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// v1.2.0 — live amplitude bars while recording (Telegram-style waveform).
/// Bars append on the RIGHT (sound timeline stays LTR even in RTL chats).
class _RecWavePainter extends CustomPainter {
  final List<double> amps;
  _RecWavePainter({required this.amps});

  @override
  void paint(Canvas canvas, Size size) {
    const maxBars = 34;
    final n = amps.length.clamp(1, maxBars);
    final slot = size.width / maxBars;
    final w = slot * 0.55;
    final paint = Paint()
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFFF87171);
    final start = amps.length > maxBars ? amps.length - maxBars : 0;
    for (var i = 0; i < n; i++) {
      final v = amps[start + i].clamp(0.05, 1.0);
      final h = (0.18 + 0.82 * v) * size.height;
      final x = slot * i + slot / 2;
      canvas.drawLine(Offset(x, (size.height - h) / 2),
          Offset(x, (size.height + h) / 2), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RecWavePainter old) => true;
}

/// Pulsing red recording dot (Telegram's live REC indicator).
class _PulsingRedDot extends StatefulWidget {
  final double size;
  const _PulsingRedDot({this.size = 11});

  @override
  State<_PulsingRedDot> createState() => _PulsingRedDotState();
}

class _PulsingRedDotState extends State<_PulsingRedDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value;
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: C.recordRed.withValues(alpha: .45 + .55 * t),
            boxShadow: [
              BoxShadow(
                color: C.recordRed.withValues(alpha: .5 * t),
                blurRadius: 5 + 5 * t,
                spreadRadius: 1 + 1.5 * t,
              ),
            ],
          ),
        );
      },
    );
  }
}
