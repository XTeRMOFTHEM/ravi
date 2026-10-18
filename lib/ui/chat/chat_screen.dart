import 'dart:async';
import 'dart:ui';
import 'dart:io';
import 'dart:math' as math;

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

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

  const ChatScreen({
    super.key,
    required this.kind,
    required this.title,
    this.peerUsername = '',
    this.avatarPath = '',
    this.chatId = 0,
    this.roomId = 'general',
    this.canPost = true,
  });

  static Route route({
    required ChatKind kind,
    required String title,
    String peerUsername = '',
    String avatarPath = '',
    int chatId = 0,
    String roomId = 'general',
    bool canPost = true,
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
  );
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _inputFocus = FocusNode();

  String? _replyToId, _replyAuthor, _replyText;
  bool _emojiOpen = false;
  int? _highlightId; // message being highlighted after a reply-jump

  // ---- v1.0.9 — selection mode (Telegram-style) ----
  bool _selectionMode = false;
  final Set<int> _selected = {};

  // ---- v1.0.9 — edit inside the composer (Telegram-style) ----
  Message? _editing;

  // ---- v1.0.9 — sticky glass date label under the header ----
  String? _stickyDate;
  DateTime _lastStickyCalc = DateTime.fromMillisecondsSinceEpoch(0);

  // ---- v1.0.9 — slow mode countdown ----
  int _slowRemaining = 0;
  Timer? _slowTimer;

  // jump-to-message: GlobalKey per rendered message id
  final Map<int, GlobalKey> _msgKeys = {};
  final Map<int, BuildContext> _msgCtx = {};

  // ---- voice recording state ----
  final AudioRecorder _recorder = AudioRecorder();
  bool _recording = false;
  bool _recLocked = false;
  int _recSeconds = 0;
  Timer? _recTimer;
  String? _recPath;
  bool _recCancelled = false;
  double _lockDy = 0; // swipe-up distance while holding
  double _cancelDx = 0; // v1.0.8 — slide-away-to-cancel distance
  Offset? _holdPos;

  @override
  void initState() {
    super.initState();
    _ctl.load();
    _scroll.addListener(_onScroll);
    _input.addListener(_onInputChanged);
    _bindLive();
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

  // v1.0.9 — real-time block/unblock + live room settings (slow mode…)
  StreamSubscription? _subBlocked, _subUnblocked, _subSettings, _subSrvErr;
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
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 260 &&
        _scroll.hasClients &&
        _scroll.position.maxScrollExtent > 400) {
      _ctl.loadOlder();
    }
    _calcStickyDate();
  }

  // ---------- v1.0.9 sticky glass date label (Telegram) ----------
  // The pill under the header shows the date of the OLDEST (topmost) visible
  // message and glides between days as you scroll. It hides while the matching
  // in-list section pill is still on screen.
  void _calcStickyDate() {
    final now = DateTime.now();
    if (now.difference(_lastStickyCalc).inMilliseconds < 60) return;
    _lastStickyCalc = now;
    if (_ctl.messages.isEmpty || !_scroll.hasClients) {
      _setSticky(null);
      return;
    }
    final vp = _scroll.position.viewportDimension;
    final headLine = vp - 78; // reverse list: top edge ≈ vp, measured from bottom
    String? best;
    double bestDy = double.infinity;
    for (final e in _msgCtx.entries) {
      final ro = e.value.findRenderObject();
      if (ro is! RenderBox || !ro.attached || !ro.hasSize) continue;
      final dy = ro.localToGlobal(Offset.zero).dy;
      // topmost = smallest dy that is still (mostly) below the header
      if (dy >= -ro.size.height * 0.55 && dy < bestDy) {
        bestDy = dy;
        final m = _ctl.messages.firstWhere((m) => m.id == e.key,
            orElse: () => _ctl.messages.first);
        best = m.dateKey;
      }
    }
    // hide when the section pill for this date is visible near the top
    if (best != null && bestDy < headLine + 44) {
      best = null;
    }
    _setSticky(best);
  }

  void _setSticky(String? k) {
    if (_stickyDate == k) return;
    if (mounted) setState(() => _stickyDate = k);
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
    await _ctl.send(text,
        replyToId: _replyToId, replyAuthor: _replyAuthor, replyText: _replyText);
    _clearReply();
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

  Future<void> _attach() async {
    await showAttachSheet(
      context,
      onSend: (path, kind, caption) => _ctl.sendMedia(path,
          fileType: kind,
          caption: caption,
          replyToId: _replyToId,
          replyAuthor: _replyAuthor,
          replyText: _replyText),
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
    final dir = await getTemporaryDirectory();
    final name = m.fileUrl.split('/').last;
    final ok = await ApiService.I.downloadToFile(m.fileUrl, '${dir.path}/$name');
    if (!mounted) return;
    showGlassToast(context,
        ok ? s.downloadDone : s.downloadFailed,
        icon: ok ? Icons.download_done_rounded : Icons.error_outline_rounded,
        color: ok ? null : const Color(0xFFEF4444));
  }

  // -------------------------------------------------- voice recording

  Future<void> _startRecording() async {
    final s = AppState.I.str;
    try {
      if (!await _recorder.hasPermission()) {
        if (!mounted) return;
        showGlassToast(context, s.micPermission,
            icon: Icons.mic_off_rounded, color: const Color(0xFFEF4444));
        return;
      }
      final dir = await getTemporaryDirectory();
      _recPath =
          '${dir.path}/v_${DateTime.now().millisecondsSinceEpoch}.m4a';
      _recCancelled = false;
      _recLocked = false;
      _lockDy = 0;
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000, sampleRate: 44100),
        path: _recPath!,
      );
      setState(() {
        _recording = true;
        _recSeconds = 0;
      });
      _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _recSeconds++);
      });
      HapticFeedback.lightImpact();
    } catch (_) {
      _recording = false;
    }
  }

  Future<void> _stopRecording({required bool send}) async {
    _recTimer?.cancel();
    if (!_recording) return;
    setState(() => _recording = false);
    String? path;
    try {
      path = await _recorder.stop();
    } catch (_) {}
    if (!send || _recCancelled || path == null || _recSeconds < 1) {
      try {
        if (path != null) File(path).delete();
      } catch (_) {}
      if (_recSeconds < 1 && mounted && !_recCancelled) {
        showGlassToast(context, AppState.I.str.voiceTooShort,
            icon: Icons.timer_off_rounded);
      }
      return;
    }
    await _ctl.sendMedia(path,
        fileType: 'audio',
        caption: '',
        replyToId: _replyToId,
        replyAuthor: _replyAuthor,
        replyText: _replyText);
    _clearReply();
  }

  // -------------------------------------------------- jump to replied message

  void _jumpToReply(Message m) {
    final targetId = int.tryParse(m.replyToId ?? '') ?? 0;
    if (targetId <= 0) return;
    final idx = _ctl.messages.indexWhere((x) => x.id == targetId);
    if (idx < 0) return;
    final key = _msgKeys[targetId];
    final bctx = _msgCtx[targetId];
    if (bctx != null) {
      Scrollable.ensureVisible(
        bctx,
        duration: const Duration(milliseconds: 380),
        curve: Curves.easeOutCubic,
        alignment: 0.4,
      );
    } else if (key != null) {
      // not built — nudge the list; the builder will rebuild around it
      final n = _ctl.messages.length;
      // approximate index in the reversed list
      final revIdx = n - 1 - idx;
      final est = _scroll.position.maxScrollExtent * (revIdx / (n + 1));
      _scroll.animateTo(est.clamp(0.0, _scroll.position.maxScrollExtent),
          duration: const Duration(milliseconds: 360), curve: Curves.easeOutCubic);
    }
    setState(() => _highlightId = targetId);
    Timer(const Duration(milliseconds: 1300), () {
      if (mounted && _highlightId == targetId) {
        setState(() => _highlightId = null);
      }
    });
  }

  // -------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: true,
      body: AnimatedBuilder(
        animation: _ctl,
        builder: (context, _) {
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
              SafeArea(
                bottom: false,
                child: Column(
                  children: [
                    _selectionMode
                        ? _selectionHeader(p, s)
                        : _header(p, s, pvInfo),
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
                    _replyBar(p),
                    if (_editing != null) _editingBar(p, s),
                    if (canPost && !iBlocked && !amBlocked) ...[
                      _recording || _recLocked
                          ? _recordingBar(p, s, bottomPad)
                          : _composer(p, s, bottomPad),
                    ] else
                      _bottomStatusArea(p, s, bottomPad,
                          iBlocked: iBlocked, amBlocked: amBlocked),
                    if (_emojiOpen && canPost && !iBlocked && !amBlocked)
                      _emojiPanel(p),
                  ],
                ),
              ),
            ],
          );
        },
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
  Widget _bottomStatusArea(Palette p, S s, double bottomPad,
      {required bool iBlocked, required bool amBlocked}) {
    if (iBlocked) {
      // WE blocked them — full-width Unblock button (like Telegram/screenshot)
      return Padding(
        padding: EdgeInsets.fromLTRB(12, 8, 12, 10 + bottomPad * 0.6),
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
        padding: EdgeInsets.fromLTRB(0, 8, 0, 10 + bottomPad * 0.6),
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
    return _readOnlyBar(p, s, bottomPad);
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

  // ---------- header ----------
  Widget _header(Palette p, S s, PvInfo? pvInfo) {
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
          Navigator.of(context, rootNavigator: true)
              .push(GroupInfoScreen.route(widget.roomId));
        }
      },
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 60,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: p.chatHeadBg,
          border: Border(bottom: BorderSide(color: p.chatHeadBorder)),
          boxShadow: const [BoxShadow(color: Color(0x24000000), blurRadius: 18)],
        ),
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
                  child: widget.kind == ChatKind.general
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
                  Text(widget.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w800,
                          color: p.chatText)),
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
                  if (r.ok && r.data != null) _ctl.refresh();
                },
                child: Icon(Icons.block_rounded, size: 20, color: p.text2),
              )
            else
              Builder(builder: (btnCtx) => _roundIconBtn(
                  p, Icons.more_vert_rounded,
                  () => _showChatMenu(p, s, btnCtx))),
          ],
        ),
      ),
    );
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
            const Color(0xFF8B5CF6), () {
          Navigator.of(context, rootNavigator: true)
              .push(GroupInfoScreen.route(widget.roomId));
        }),
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

    final n = _ctl.messages.length;
    final channelMode = widget.kind == ChatKind.channel;
    final showAvatars = !channelMode &&
        (widget.kind == ChatKind.general || widget.kind == ChatKind.group);

    return Stack(
      children: [
        ListView.builder(
          controller: _scroll,
          reverse: true,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
          cacheExtent: 420,
          itemCount: n + (_ctl.historyDone ? 0 : 1),
          itemBuilder: (context, i) {
            if (!_ctl.historyDone && i == n) {
              return Padding(
                padding: const EdgeInsets.all(10),
                child: Center(
                  child: _ctl.loadingHistory
                      ? const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const SizedBox.shrink(),
                ),
              );
            }
            final msgIndex = n - 1 - i;
            final msg = _ctl.messages[msgIndex];
            final olderIdx = msgIndex + 1;
            final showDate = olderIdx >= n ||
                _ctl.messages[olderIdx].dateKey != msg.dateKey;
            final dateKey = msg.dateKey;

            final animate = msg.pending ||
                (msg.clientMsgId.isNotEmpty && !msg.isMe && _ctl.historyLoaded);

            // global key per message id (for jump-to-reply)
            final mkey = msg.id > 0
                ? (_msgKeys[msg.id] ??= GlobalKey())
                : null;
            final isSel = _selected.contains(msg.id);

            return RepaintBoundary(
              child: Column(
                children: [
                  if (showDate)
                    _DatePill(dateKey: dateKey, palette: p, lang: AppState.I.lang.value),
                  BubbleAppear(
                    animate: animate,
                    child: BubbleRemover(
                      removing: msg.removing,
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
                              child: HighlightBox(
                                highlight: _highlightId != null && msg.id == _highlightId,
                                selected: isSel,
                                child: MessageBubble(
                                  msg: msg,
                                  kind: widget.kind,
                                  showAvatar: showAvatars,
                                  channelMode: channelMode,
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
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        // v1.0.9 — sticky glass date pill under the header (Telegram-style):
        // follows the topmost visible day while scrolling, hides at the seam.
        if (_stickyDate != null && !_selectionMode)
          Positioned(
            top: 6,
            left: 0,
            right: 0,
            child: Center(
              child: _StickyDatePill(
                dateKey: _stickyDate!,
                palette: p,
                lang: AppState.I.lang.value,
              ),
            ),
          ),
      ],
    );
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
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
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
                // gradient accent bar hugging the reply side
                Container(
                  width: 3.4,
                  height: 32,
                  margin: EdgeInsetsDirectional.only(
                      start: rtl ? 0 : 8, end: rtl ? 8 : 0),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [p.accent, p.accent.withValues(alpha: .35)],
                    ),
                    borderRadius: BorderRadius.circular(3),
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
        ),
      ),
    );
  }

  // ---------- composer ----------
  Widget _readOnlyBar(Palette p, S s, double bottomPad) {
    return Padding(
      padding: EdgeInsets.fromLTRB(0, 8, 0, 8 + bottomPad * 0.6),
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

  Widget _composer(Palette p, S s, double bottomPad) {
    // v1.0.9 — slow mode: show the live countdown chip; send stays enabled
    // (the server enforces it and we surface the exact remaining seconds).
    if (_slowRemaining > 0) {
      return Padding(
        padding: EdgeInsets.fromLTRB(7, 0, 7, 7 + bottomPad * 0.6),
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
          padding: EdgeInsets.fromLTRB(7, 0, 7, 7 + bottomPad * 0.6),
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
    _startRecording();
  }

  void _onRecDrag(PointerMoveEvent e) {
    if (!_recording || _recLocked) return;
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
      // locked: keep recording; the lock bar has send/cancel buttons
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

  // ---------- v1.0.8 Telegram-style recording bar ----------
  // Holding: pulsing red mic + timer + "‹ slide to cancel" that slides with
  // the finger + slide-up lock. Locked: independent trash/send controls.
  Widget _recordingBar(Palette p, S s, double bottomPad) {
    final mins = (_recSeconds ~/ 60).toString().padLeft(2, '0');
    final secs = (_recSeconds % 60).toString().padLeft(2, '0');
    final rtl = Directionality.of(context) == TextDirection.rtl;

    if (_recLocked) {
      // LOCKED bar — independent controls, no holding needed
      return Padding(
        padding: EdgeInsets.fromLTRB(7, 0, 7, 7 + bottomPad * 0.6),
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
            Text('$mins:$secs',
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
    //  • timer + live hint
    //  • "‹ Slide to cancel" chip slides with the finger toward the edge
    //  • lock chevron appears above the mic while lifting
    final cancelT = (-_cancelDx / 60).clamp(0.0, 1.0);
    final lockT = (-_lockDy / 60).clamp(0.0, 1.0);
    return Padding(
      padding: EdgeInsets.fromLTRB(7, 0, 7, 7 + bottomPad * 0.6),
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
            Text('$mins:$secs',
                textDirection: TextDirection.ltr,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    fontFeatures: [FontFeature.tabularFigures()],
                    color: C.recordRedText)),
            const SizedBox(width: 12),
            Expanded(
              child: Stack(alignment: AlignmentDirectional.centerStart, children: [
                Opacity(
                  opacity: 1 - cancelT,
                  child: Text(s.releaseToSend,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11.5, color: p.chatText2)),
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

  // ---------- v1.0.8 combined Emoji + GIF panel ----------
  // One panel, two bottom tabs (like Telegram): Emoji picker + GIF library.
  Widget _emojiPanel(Palette p) {
    return EmojiGifPanel(
      palette: p,
      emojiController: _input,
      onGifPicked: (url) {
        setState(() => _emojiOpen = false);
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
class _SendOrMic extends StatelessWidget {
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
  Widget build(BuildContext context) {
    if (isSend) {
      return GestureDetector(
        onTap: onTap,
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
    // mic: hold to record (Listener so the drag keeps flowing outside)
    return Listener(
      onPointerDown: (e) => onHoldStart?.call(e),
      onPointerMove: (e) => onHoldUpdate?.call(e),
      onPointerUp: (e) => onHoldEnd?.call(e),
      onPointerCancel: (e) => onHoldEnd?.call(e),
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

/// Soft highlight ring for the jumped-to replied message + selection ring.
class HighlightBox extends StatelessWidget {
  final bool highlight;
  final bool selected;
  final Widget child;
  const HighlightBox(
      {super.key, this.highlight = false, this.selected = false,
      required this.child});

  @override
  Widget build(BuildContext context) {
    if (!highlight && !selected) return child;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: selected
              ? const Color(0xFF22C55E).withValues(alpha: .8)
              : const Color(0xFF8B5CF6).withValues(alpha: .55),
          width: 1.6,
        ),
        boxShadow: [
          BoxShadow(
            color: selected
                ? const Color(0x3322C55E)
                : const Color(0x338B5CF6),
            blurRadius: 18,
          ),
        ],
      ),
      child: child,
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
      {required this.dateKey, required this.palette, required this.lang});

  @override
  Widget build(BuildContext context) {
    final label = _DatePill(dateKey: dateKey, palette: palette, lang: lang)
        ._label;
    if (label.isEmpty) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
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
        ),
      ),
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
