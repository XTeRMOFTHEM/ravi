import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import '../../core/api_service.dart';
import '../../core/app_state.dart';
import '../../core/constants.dart';
import '../../core/i18n.dart';
import '../../core/models.dart';
import '../../core/socket_service.dart';
import '../chat/chat_screen.dart';
import '../widgets/common.dart';
import '../widgets/ravi_alerts.dart';
import 'create_chat_sheet.dart';

/// Chats page — 1:1 with index.html `page-chats`:
/// category chips → search pill → ad banner → chat rows.
class ChatsPage extends StatefulWidget {
  const ChatsPage({super.key});

  @override
  State<ChatsPage> createState() => _ChatsPageState();
}

class _ChatsPageState extends State<ChatsPage>
    with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  @override
  bool get wantKeepAlive => true;

  final TextEditingController _search = TextEditingController();
  String _cat = 'all';
  final ScrollController _listCtrl = ScrollController();
  bool _showFloat = false;

  // v1.0.9 — selection mode (Telegram): long-press a row → header becomes a
  // selection bar (archive / leave) and taps toggle rows instead of opening.
  bool _selecting = false;
  final Set<String> _picked = {};

  @override
  void initState() {
    super.initState();
    _listCtrl.addListener(() {
      final f = _listCtrl.position.extentAfter > 260;
      if (f != _showFloat && mounted) setState(() => _showFloat = f);
    });
    // First network refresh (cache already painted by shell/splash).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (AppState.I.chats.value.isEmpty) AppState.I.loadChatsCachedThenNetwork();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _listCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;

    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _selecting ? _selectionHeader(p, s) : _categories(p, s),
            if (!_selecting) _searchPill(p, s),
            if (!_selecting) _adBanner(p, s),
            Expanded(
              child: ValueListenableBuilder<List<ChatPreview>>(
                valueListenable: AppState.I.chats,
                builder: (context, chats, _) {
                  final q = _search.text.trim().toLowerCase();
                  final filtered = chats.where((c) {
                    final okCat = switch (_cat) {
                      'all' => true,
                      'personal' => c.kind == ChatKind.pv,
                      'group' => c.kind == ChatKind.group,
                      'channel' => c.kind == ChatKind.channel,
                      'official' => false,
                      _ => true,
                    };
                    if (!okCat) return false;
                    if (q.isEmpty) return true;
                    return c.name.toLowerCase().contains(q) ||
                        c.lastMessage.toLowerCase().contains(q);
                  }).toList(growable: false);
                  return RefreshIndicator(
                    color: p.accent,
                    backgroundColor: p.bgCard,
                    onRefresh: () async {
                      SocketService.I.connect();
                      await AppState.I.loadChatsCachedThenNetwork();
                    },
                    child: ListView.builder(
                      controller: _listCtrl,
                      physics: const AlwaysScrollableScrollPhysics(
                          parent: ClampingScrollPhysics()),
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 96),
                      scrollCacheExtent: const ScrollCacheExtent.pixels(700),
                      // v1.5.0 — پرفورمانس موبایل ضعیف
                      addAutomaticKeepAlives: false,
                      itemCount: filtered.length + 2,
                      itemBuilder: (context, i) {
                        if (i == 0) {
                          return _archiveRow(p, s);
                        }
                        if (i == 1) {
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(8, 4, 8, 3),
                            child: Text(s.recentChats,
                                style: TextStyle(
                                    fontSize: 12, color: p.text3,
                                    fontWeight: FontWeight.w600)),
                          );
                        }
                        final c = filtered[i - 2];
                        return _ChatRow(
                          key: ValueKey('chat-${c.key}'),
                          chat: c,
                          selecting: _selecting,
                          picked: _picked.contains(c.key),
                          onTap: () => _selecting
                              ? setState(() => _picked.contains(c.key)
                                  ? _picked.remove(c.key)
                                  : _picked.add(c.key))
                              : _openChat(c),
                          onLongPress: () {
                            if (!_selecting) {
                              setState(() {
                                _selecting = true;
                                _picked.add(c.key);
                              });
                              HapticFeedback.mediumImpact();
                            } else {
                              _showRowMenu(context, c);
                            }
                          },
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        // floating + button (new PV / group / channel) — v1.1.1: exactly one
        // breath above the floating nav capsule on ANY device (the capsule is
        // 64+10 high with a 6px gap, so 86px clears it everywhere).
        if (!_selecting)
          PositionedDirectional(
            bottom: 86,
            end: 16,
            child: _fab(p),
          ),
      ],
    );
  }

  // ---------- v1.0.9 selection header ----------
  Widget _selectionHeader(Palette p, S s) {
    final hasRoom = _picked.any((k) => k.startsWith('room-'));
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: p.bg,
        border: Border(bottom: BorderSide(color: p.border)),
      ),
      child: Row(children: [
        GestureDetector(
          onTap: () => setState(() {
            _selecting = false;
            _picked.clear();
          }),
          child: Icon(Icons.close_rounded, size: 21, color: p.text),
        ),
        const SizedBox(width: 12),
        Text(s.selectedCount(_picked.length),
            style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w800, color: p.text)),
        const Spacer(),
        GestureDetector(
          onTap: _picked.isEmpty ? null : () => _archivePicked(true),
          child: Row(children: [
            Icon(Icons.archive_outlined,
                size: 19,
                color: _picked.isEmpty ? p.text3 : p.accent),
            const SizedBox(width: 4),
            Text(s.archive,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: _picked.isEmpty ? p.text3 : p.accent)),
          ]),
        ),
        if (hasRoom) ...[
          const SizedBox(width: 16),
          GestureDetector(
            onTap: () => _leavePicked(),
            child: Row(children: [
              const Icon(Icons.logout_rounded,
                  size: 19, color: Color(0xFFEF4444)),
              const SizedBox(width: 4),
              Text(s.chatMenuLeave,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFEF4444))),
            ]),
          ),
        ],
      ]),
    );
  }

  Future<void> _archivePicked(bool value) async {
    final all = [...AppState.I.chats.value, ...AppState.I.archived.value];
    for (final k in _picked) {
      final c = all.where((x) => x.key == k).toList();
      if (c.isNotEmpty) await AppState.I.setArchived(c.first, value);
    }
    if (mounted) {
      showGlassToast(context,
          value ? AppState.I.str.archivedToast : AppState.I.str.unarchivedToast,
          icon: Icons.archive_outlined);
      setState(() {
        _selecting = false;
        _picked.clear();
      });
    }
  }

  Future<void> _leavePicked() async {
    final s = AppState.I.str;
    final ok = await showRaviModal(
      context,
      icon: Icons.logout_rounded,
      iconColor: const Color(0xFFEF4444),
      title: s.leaveConfirmTitle,
      body: s.leaveConfirmBody(s.chatMenuLeave),
      okText: s.chatMenuLeave,
      cancelText: s.cancel,
      danger: true,
    );
    if (!ok) return;
    final rooms = _picked.where((k) => k.startsWith('room-')).toList();
    for (final k in rooms) {
      final rid = k.substring(5);
      await ApiService.I.leaveRoom(rid);
    }
    await AppState.I.loadChatsCachedThenNetwork();
    if (mounted) {
      showGlassToast(context, s.leftRoomToast, icon: Icons.logout_rounded);
      setState(() {
        _selecting = false;
        _picked.clear();
      });
    }
  }

  void _openChat(ChatPreview c) async {
    if (AppState.I.isArchived(c)) {
      // opening an archived chat unpins it from the archive (Telegram-like)
      await AppState.I.setArchived(c, false);
    }
    // v1.1.0 — zero the badge NOW and persist it, so it never resurrects
    AppState.I.zeroUnread(c);
    if (c.kind == ChatKind.general) {
      Navigator.of(context, rootNavigator: true).push(ChatScreen.route(
        kind: ChatKind.general,
        title: 'Global',
        avatarPath: '',
      ));
      return;
    }
    if (c.kind == ChatKind.pv) {
      Navigator.of(context, rootNavigator: true).push(ChatScreen.route(
        kind: ChatKind.pv,
        title: c.isSelf ? AppState.I.str.savedMessages : c.name,
        avatarPath: c.avatar,
        chatId: c.id,
        peerUsername: c.peerUsername,
        isSelfChat: c.isSelf,
      ));
      return;
    }
    Navigator.of(context, rootNavigator: true).push(ChatScreen.route(
      kind: c.kind,
      title: c.name,
      avatarPath: c.avatar,
      roomId: c.roomId,
      canPost: c.canPost,
    ));
  }

  // ---------- v1.0.9 archive entry row ----------
  Widget _archiveRow(Palette p, S s) {
    return ValueListenableBuilder<List<ChatPreview>>(
      valueListenable: AppState.I.archived,
      builder: (context, archived, _) {
        if (archived.isEmpty) return const SizedBox.shrink();
        final unread = archived.fold<int>(0, (a, c) => a + c.unread);
        return Padding(
          padding: const EdgeInsets.fromLTRB(0, 2, 0, 4),
          child: InkWell(
            onTap: () => Navigator.of(context, rootNavigator: true)
                .push(MaterialPageRoute(builder: (_) => const ArchivedScreen())),
            borderRadius: BorderRadius.circular(14),
            child: Container(
              height: 62,
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
              child: Row(children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: p.bgSoft,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.archive_outlined, size: 22, color: p.text2),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(s.archivedChats,
                      style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: p.text)),
                ),
                if (unread > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 2.5),
                    decoration: BoxDecoration(
                      color: p.accent,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Text('$unread',
                        style: const TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                            color: Colors.white)),
                  ),
              ]),
            ),
          ),
        );
      },
    );
  }

  Widget _fab(Palette p) {
    return GestureDetector(
      onTap: () => CreateChatSheet.show(context),
      child: Container(
        width: 54,
        height: 54,
        decoration: BoxDecoration(
          gradient: C.ownBubbleGrad,
          shape: BoxShape.circle,
          boxShadow: const [
            BoxShadow(color: Color(0x3D14283C), blurRadius: 22, offset: Offset(0, 8)),
          ],
        ),
        child: const Icon(Icons.add_rounded, size: 27, color: Colors.white),
      ),
    );
  }

  // ---------- long-press context menu (pin/unpin) ----------
  void _showRowMenu(BuildContext rowContext, ChatPreview chat) {
    final p = Theme.of(rowContext).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: rowContext,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            color: p.bgCard.withValues(alpha: .97),
            child: SafeArea(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const SizedBox(height: 10),
                Container(
                    width: 40, height: 4,
                    decoration: BoxDecoration(
                        color: p.border,
                        borderRadius: BorderRadius.circular(2))),
                const SizedBox(height: 8),
                _menuItem(
                  ctx,
                  icon: chat.pinned
                      ? Icons.push_pin_outlined
                      : Icons.push_pin_rounded,
                  label: chat.pinned ? s.unpinChat : s.pinChat,
                  color: p.accent,
                  onTap: () {
                    Navigator.pop(ctx);
                    final err = AppState.I.togglePin(chat);
                    if (err == 'limit') {
                      showRaviToast(rowContext,
                          s.pinnedLimit(AppState.maxPinned),
                          icon: Icons.push_pin_rounded);
                    }
                  },
                ),
                _menuItem(
                  ctx,
                  icon: AppState.I.isArchived(chat)
                      ? Icons.unarchive_rounded
                      : Icons.archive_outlined,
                  label: AppState.I.isArchived(chat)
                      ? s.unarchive
                      : s.archive,
                  color: p.accent,
                  onTap: () {
                    Navigator.pop(ctx);
                    AppState.I
                        .setArchived(chat, !AppState.I.isArchived(chat));
                    showRaviToast(rowContext,
                        AppState.I.isArchived(chat)
                            ? s.archivedToast
                            : s.unarchivedToast,
                        icon: Icons.archive_outlined);
                  },
                ),
                _menuItem(
                  ctx,
                  icon: Icons.delete_outline_rounded,
                  label: s.deleteChat,
                  color: const Color(0xFFEF4444),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final ok = await showRaviModal(
                      context,
                      icon: Icons.delete_outline_rounded,
                      iconColor: const Color(0xFFEF4444),
                      title: s.deleteChat,
                      body: s.deleteChatConfirm,
                      okText: s.delete,
                      cancelText: s.cancel,
                      danger: true,
                    );
                    if (!ok) return;
                    await AppState.I.deleteChatLocally(chat);
                    if (!mounted) return;
                    showGlassToast(context, s.chatDeletedToast,
                        icon: Icons.delete_outline_rounded,
                        color: const Color(0xFFEF4444));
                  },
                ),
                const SizedBox(height: 10),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _menuItem(BuildContext ctx,
      {required IconData icon,
      required String label,
      required Color color,
      required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        child: Row(children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 13),
          Text(label,
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600, color: color)),
        ]),
      ),
    );
  }

  Widget _categories(Palette p, S s) {
    final cats = [
      ('all', s.catAll),
      ('personal', s.catPersonal),
      ('group', s.catGroup),
      ('channel', s.catChannel),
      ('bot', s.catBot),
      ('official', s.catOfficial),
    ];
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: p.bg,
        border: Border(bottom: BorderSide(color: p.border)),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        physics: const BouncingScrollPhysics(),
        children: [
          for (final c in cats)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 2),
              child: GestureDetector(
                onTap: () => setState(() => _cat = c.$1),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _cat == c.$1 ? p.accentSoft : Colors.transparent,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    c.$2,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: _cat == c.$1 ? FontWeight.w700 : FontWeight.w600,
                      color: _cat == c.$1 ? p.accent : p.text2,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---------- search pill ----------
  Widget _searchPill(Palette p, S s) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Container(
        height: 50,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: p.bgSoft,
          borderRadius: BorderRadius.circular(25),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                style: TextStyle(fontSize: 15, color: p.text),
                decoration: InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  hintText: s.searchChats,
                  hintStyle: TextStyle(fontSize: 15, color: p.text3),
                ),
              ),
            ),
            Icon(Icons.search_rounded, size: 23, color: p.text2),
          ],
        ),
      ),
    );
  }

  // ---------- ad banner ----------
  Widget _adBanner(Palette p, S s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      child: Container(
        height: 66,
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          color: p.bgCard,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: p.borderSoft),
          boxShadow: const [BoxShadow(color: Color(0x121E3246), blurRadius: 18, offset: Offset(0, 5))],
        ),
        child: Stack(
          children: [
            Row(
              children: [
                Container(
                  width: 45, height: 45,
                  decoration: BoxDecoration(
                    color: p.accentSoft,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  alignment: Alignment.center,
                  child: Text('R',
                      style: TextStyle(
                          color: p.accent, fontWeight: FontWeight.w800,
                          fontSize: 16)),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                            decoration: BoxDecoration(
                              border: Border.all(color: p.border),
                              borderRadius: BorderRadius.circular(7),
                            ),
                            child: Text(s.adLabel,
                                style: TextStyle(fontSize: 8, color: p.text3)),
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(s.adTitle,
                                maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 12, fontWeight: FontWeight.w700,
                                    color: p.text)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(s.adText,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 9.5, color: p.text2)),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: p.accentSoft,
                    borderRadius: BorderRadius.circular(17),
                  ),
                  child: Text(s.adAction,
                      style: TextStyle(
                          fontSize: 10, fontWeight: FontWeight.w700,
                          color: p.accent)),
                ),
              ],
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(width: 10, height: 4, decoration: BoxDecoration(color: p.accent, borderRadius: BorderRadius.circular(5))),
                  const SizedBox(width: 3),
                  Container(width: 4, height: 4, decoration: BoxDecoration(color: p.text3, shape: BoxShape.circle)),
                  const SizedBox(width: 3),
                  Container(width: 4, height: 4, decoration: BoxDecoration(color: p.text3, shape: BoxShape.circle)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ================= chat row =================

class _ChatRow extends StatefulWidget {
  final ChatPreview chat;
  final VoidCallback? onLongPress;
  final VoidCallback? onTap;
  final bool selecting;
  final bool picked;
  const _ChatRow({
    super.key,
    required this.chat,
    this.onLongPress,
    this.onTap,
    this.selecting = false,
    this.picked = false,
  });

  @override
  State<_ChatRow> createState() => _ChatRowState();
}

class _ChatRowState extends State<_ChatRow>
    with SingleTickerProviderStateMixin {
  // v1.0.7 — smooth "rise to top": when the row's position in the list
  // changes (new message → chat lifts up), slide it in from its old offset.
  int _lastIndex = -1;
  double _entrance = 0; // >0 when we moved
  AnimationController? _ctrl;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _trackMove();
  }

  @override
  void didUpdateWidget(covariant _ChatRow old) {
    super.didUpdateWidget(old);
    _trackMove();
  }

  void _trackMove() {
    // find our current index in the visible list
    final chats = AppState.I.chats.value;
    final idx = chats.indexWhere((c) => c.key == widget.chat.key);
    if (idx >= 0 && _lastIndex >= 0 && idx != _lastIndex) {
      _entrance = (_lastIndex - idx).toDouble().clamp(-3.0, 3.0);
      _ctrl?.dispose();
      _ctrl = AnimationController(
          vsync: this, duration: const Duration(milliseconds: 320))
        ..addListener(() {
          if (mounted) setState(() {});
        })
        ..forward();
    }
    if (idx >= 0) _lastIndex = idx;
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  String _previewText(bool isFa) {
    final chat = widget.chat;
    final me = AppState.I.me.value.username;
    // v1.1.0 — "You: " prefix when the last message is ours (Telegram)
    final mine = chat.lastUser.isNotEmpty && chat.lastUser == me;
    String body;
    switch (chat.lastFileType) {
      case 'image':
        body = isFa ? '📷 عکس' : '📷 Photo';
        break;
      case 'video':
        // v1.3.2 — the user-facing spelling, WhatsApp-clean
        body = isFa ? '🎥 ویدئو' : '🎥 Video';
        break;
      case 'music':
        // v1.3.2 — a SONG shows its clean name (server stores the title in
        // last_message), never a generic "voice message" label.
        final t = chat.lastMessage.trim();
        body = t.isEmpty
            ? (isFa ? '🎵 موزیک' : '🎵 Music')
            : '🎵 $t';
        break;
      case 'voice':
      case 'audio':
        body = isFa ? '🎤 پیام صوتی' : '🎤 Voice message';
        break;
      case 'gif':
        body = 'GIF';
        break;
      case 'file':
        body = isFa ? '📄 فایل' : '📄 File';
        break;
      default:
        body = chat.lastMessage;
    }
    // v1.3.1 — the preview NEVER renders as an empty line: old rows (before
    // last_file_type existed) or unusual kinds fall back to a neutral label
    // instead of a blank "…" strip.
    if (body.trim().isEmpty) {
      body = isFa ? '💬 پیام' : '💬 Message';
    }
    if (mine && body.isNotEmpty) {
      return AppState.I.str.youPrefix(body);
    }
    return body;
  }

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final chat = widget.chat;
    final slide = _ctrl == null
        ? 0.0
        : _entrance *
            79 *
            (1 - Curves.easeOutCubic.transform(_ctrl!.value));

    return Transform.translate(
      offset: Offset(0, slide),
      child: Material(
        color: widget.picked
            ? p.accent.withValues(alpha: .10)
            : (chat.pinned ? p.accent.withValues(alpha: .07) : Colors.transparent),
        child: InkWell(
          onTap: widget.onTap ?? (() => _open(context)),
          onLongPress: widget.onLongPress,
          child: Container(
            height: 79,
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: p.border, width: 1),
                top: BorderSide(
                  color: chat.pinned
                      ? p.accent.withValues(alpha: .12)
                      : Colors.transparent,
                  width: 1,
                ),
              ),
            ),
            child: Row(
              children: [
                // v1.0.9 — selection check circle (Telegram)
                if (widget.selecting) ...[
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    width: 24,
                    height: 24,
                    margin: const EdgeInsetsDirectional.only(end: 10),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: widget.picked ? p.accent : Colors.transparent,
                      border: Border.all(
                        color: widget.picked
                            ? p.accent
                            : p.text3.withValues(alpha: .5),
                        width: 1.7,
                      ),
                    ),
                    child: widget.picked
                        ? const Icon(Icons.check_rounded,
                            size: 15, color: Colors.white)
                        : null,
                  ),
                ],
                RaviAvatar(
                  name: chat.kind == ChatKind.general ? 'Global' : chat.name,
                  avatarPath: chat.avatar,
                  size: 57,
                  globe: chat.kind == ChatKind.general,
                  // v1.4.0 — سیو مسیج: آواتار بوکمارک طلایی مثل تلگرام
                  bookmark: chat.isSelf,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          if (chat.pinned) ...[
                            Icon(Icons.push_pin_rounded,
                                size: 12,
                                color: p.accent.withValues(alpha: .8)),
                            const SizedBox(width: 4),
                          ],
                          Expanded(
                            child: Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    // v1.0.9 — PV rows show the DISPLAY NAME, and
                                    // rooms never fall back to a raw empty string.
                                    // v1.4.0 — سیو مسیج عنوان ثابت خودش را دارد
                                    chat.isSelf
                                        ? AppState.I.str.savedMessages
                                        : (chat.name.trim().isNotEmpty
                                            ? chat.name
                                            : (chat.peerUsername.isNotEmpty
                                                ? chat.peerUsername
                                                : '…')),
                                    maxLines: 1, overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 15.5, fontWeight: FontWeight.w700,
                                        color: p.text, height: 1.2),
                                  ),
                                ),
                                // v1.3.2 — PRO star (blue tick) of the peer, like
                                // WhatsApp's business/verified badge in the list.
                                // Static mini star in rows (Telegram does the same;
                                // no 50 concurrent animations in a scrolling list).
                                if (chat.kind == ChatKind.pv && chat.isPro) ...[
                                  const SizedBox(width: 4),
                                  const ProStarBadge(size: 14, animate: false),
                                ],
                                if (chat.kind == ChatKind.pv && chat.isOfficial && !chat.isPro) ...[
                                  const SizedBox(width: 4),
                                  const VerifiedBadge(size: 13),
                                ],
                              ],
                            ),
                          ),
                          if (chat.lastTime.isNotEmpty)
                            Text(chat.lastTime,
                                style: TextStyle(
                                    fontSize: 10.5,
                                    color: p.text3)),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _previewText(AppState.I.lang.value.isFa),
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12.5,
                                  color: p.text2),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (!widget.selecting)
                  SizedBox(
                    width: 30,
                    child: Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: UnreadPill(count: chat.unread),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final chat = widget.chat;
    if (AppState.I.isArchived(chat)) {
      await AppState.I.setArchived(chat, false);
    }
    if (chat.kind == ChatKind.general) {
      Navigator.of(context, rootNavigator: true).push(ChatScreen.route(
        kind: ChatKind.general,
        title: 'Global',
        avatarPath: '',
      ));
      return;
    }
    if (chat.kind == ChatKind.pv) {
      Navigator.of(context, rootNavigator: true).push(ChatScreen.route(
        kind: ChatKind.pv,
        // v1.5.0 — سیو مسیج: عنوان و ایکون بوکمارک درست منتقل می‌شود
        title: chat.isSelf ? AppState.I.str.savedMessages : chat.name,
        avatarPath: chat.avatar,
        chatId: chat.id,
        peerUsername: chat.peerUsername,
        isSelfChat: chat.isSelf,
      ));
      return;
    }
    // group / channel
    Navigator.of(context, rootNavigator: true).push(ChatScreen.route(
      kind: chat.kind,
      title: chat.name,
      avatarPath: chat.avatar,
      roomId: chat.roomId,
      canPost: chat.canPost,
    ));
  }
}

// ================= v1.0.9 archived chats screen =================
class ArchivedScreen extends StatelessWidget {
  const ArchivedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: p.text),
        title: Text(s.archivedChats,
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: p.text)),
      ),
      body: ValueListenableBuilder<List<ChatPreview>>(
        valueListenable: AppState.I.archived,
        builder: (context, archived, _) {
          if (archived.isEmpty) {
            return Center(
              child: Text(s.noChatsTitle,
                  style: TextStyle(fontSize: 12.5, color: p.text3)),
            );
          }
          return ListView.builder(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 30),
            itemCount: archived.length,
            itemBuilder: (context, i) {
              final c = archived[i];
              return Container(
                height: 74,
                margin: const EdgeInsets.only(bottom: 2),
                child: Row(children: [
                  RaviAvatar(
                    name: c.name,
                    avatarPath: c.avatar,
                    size: 52,
                    globe: c.kind == ChatKind.general,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(c.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w700,
                                color: p.text)),
                        const SizedBox(height: 2),
                        Text(
                          c.lastMessage.isEmpty ? '…' : c.lastMessage,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: p.text2),
                        ),
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: () async {
                      await AppState.I.setArchived(c, false);
                      showRaviToast(context, s.unarchivedToast,
                          icon: Icons.unarchive_rounded);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 11, vertical: 6),
                      decoration: BoxDecoration(
                        color: p.accentSoft,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(s.unarchive,
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: p.accent)),
                    ),
                  ),
                ]),
              );
            },
          );
        },
      ),
    );
  }
}
