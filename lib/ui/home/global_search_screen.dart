import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api_service.dart';
import '../../core/app_state.dart';
import '../../core/constants.dart';
import '../../core/i18n.dart';
import '../../core/models.dart';
import '../chat/chat_screen.dart';
import '../chat/room_preview_sheet.dart';
import '../widgets/common.dart';
import 'user_profile_screen.dart';

/// v1.1.0 — GLOBAL SEARCH (Telegram-style):
///  • your own chats match instantly as you type
///  • @handles / names resolve USERS (open profile, start a PV)
///  • public group / channel usernames resolve to a JOIN panel
/// Everything happens in-app — no browser hop.
class GlobalSearchScreen extends StatefulWidget {
  const GlobalSearchScreen({super.key});

  @override
  State<GlobalSearchScreen> createState() => _GlobalSearchScreenState();
}

class _GlobalSearchScreenState extends State<GlobalSearchScreen> {
  final TextEditingController _q = TextEditingController();
  final FocusNode _focus = FocusNode();
  Timer? _debounce;

  // local results
  List<ChatPreview> _local = [];
  // global results
  RaviUser? _user;
  Map<String, dynamic>? _room;
  bool _searching = false;
  bool _noGlobal = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    // local filter is instant
    final query = v.trim().toLowerCase();
    setState(() {
      _local = query.isEmpty
          ? []
          : AppState.I.chats.value
              .where((c) =>
                  c.name.toLowerCase().contains(query) ||
                  c.peerUsername.toLowerCase().contains(query))
              .take(12)
              .toList();
    });
    if (query.length < 3) {
      setState(() {
        _user = null;
        _room = null;
        _searching = false;
        _noGlobal = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 550), _runGlobal);
  }

  Future<void> _runGlobal() async {
    final raw = _q.text.trim().replaceFirst(RegExp(r'^@'), '');
    if (raw.length < 3) return;
    setState(() {
      _searching = true;
      _noGlobal = false;
    });
    // resolve user + public room in parallel
    final up = await ApiService.I.userProfile(raw);
    final rr = await ApiService.I.roomResolve(raw);
    if (!mounted || _q.text.trim().replaceFirst(RegExp(r'^@'), '') != raw) {
      return; // stale
    }
    RaviUser? u;
    if (up.ok && up.data != null) {
      try {
        u = RaviUser.fromJson(Map<String, dynamic>.from(up.data!));
        if (u.id == 0 && u.username.isEmpty) u = null;
      } catch (_) {}
    }
    Map<String, dynamic>? room;
    if (rr.ok && rr.data != null && '${rr.data!['room_id'] ?? ''}'.isNotEmpty) {
      room = rr.data;
    }
    setState(() {
      _user = u;
      _room = room;
      _searching = false;
      _noGlobal = u == null && room == null;
    });
  }

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
        titleSpacing: 0,
        title: Container(
          height: 44,
          margin: const EdgeInsetsDirectional.only(end: 14),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: p.bgSoft,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Row(children: [
            Icon(Icons.search_rounded, size: 19, color: p.text3),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _q,
                focusNode: _focus,
                onChanged: _onChanged,
                onSubmitted: (_) => _runGlobal(),
                textInputAction: TextInputAction.search,
                style: TextStyle(fontSize: 14.5, color: p.text),
                decoration: InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  hintText: s.globalSearchHint,
                  hintStyle: TextStyle(fontSize: 13.5, color: p.text3),
                ),
              ),
            ),
            if (_q.text.isNotEmpty)
              GestureDetector(
                onTap: () {
                  _q.clear();
                  _onChanged('');
                },
                child: Icon(Icons.close_rounded, size: 17, color: p.text3),
              ),
          ]),
        ),
      ),
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 40),
        children: [
          if (_local.isNotEmpty) ...[
            _label(p, s.recentChats),
            ..._local.map((c) => _chatRow(p, c)),
            const SizedBox(height: 8),
          ],
          if (_searching)
            const Padding(
              padding: EdgeInsets.all(26),
              child: Center(
                  child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2))),
            ),
          if (!_searching && _user != null) ...[
            _label(p, s.catPersonal),
            _userCard(p, _user!),
            const SizedBox(height: 8),
          ],
          if (!_searching && _room != null) ...[
            _label(p, s.globalRooms),
            _roomCard(p, _room!),
            const SizedBox(height: 8),
          ],
          if (!_searching &&
              _noGlobal &&
              _local.isEmpty &&
              _q.text.trim().length >= 3)
            Padding(
              padding: const EdgeInsets.all(30),
              child: Column(children: [
                Icon(Icons.travel_explore_rounded, size: 38, color: p.text3),
                const SizedBox(height: 10),
                Text(s.globalNoResults,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12.5, color: p.text2)),
              ]),
            ),
          if (_q.text.trim().isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 26, 10, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.globalSearchHintLong,
                      style: TextStyle(fontSize: 12.5, color: p.text3)),
                  const SizedBox(height: 14),
                  _tip(p, Icons.person_search_rounded, s.globalTipUsers),
                  const SizedBox(height: 8),
                  _tip(p, Icons.tag_rounded, s.globalTipRooms),
                  const SizedBox(height: 8),
                  _tip(p, Icons.chat_rounded, s.globalTipChats),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _label(Palette p, String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
        child: Text(t,
            style: TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w700, color: p.text3)),
      );

  Widget _tip(Palette p, IconData icon, String text) => Row(children: [
        Icon(icon, size: 16, color: p.text3),
        const SizedBox(width: 8),
        Expanded(
            child: Text(text, style: TextStyle(fontSize: 12, color: p.text2))),
      ]);

  Widget _chatRow(Palette p, ChatPreview c) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        Navigator.of(context, rootNavigator: true).push(ChatScreen.route(
          kind: c.kind,
          title: c.name.trim().isEmpty ? c.peerUsername : c.name,
          avatarPath: c.avatar,
          chatId: c.id,
          peerUsername: c.peerUsername,
          roomId: c.roomId,
          canPost: c.canPost,
        ));
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: p.bgCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: p.borderSoft),
        ),
        child: Row(children: [
          RaviAvatar(
            name: c.name,
            avatarPath: c.avatar,
            size: 42,
            globe: c.kind == ChatKind.general,
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: p.text)),
                if (c.lastMessage.isNotEmpty)
                  Text(c.lastMessage,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: p.text3)),
              ],
            ),
          ),
          Icon(Icons.arrow_forward_ios_rounded, size: 12, color: p.text3),
        ]),
      ),
    );
  }

  Widget _userCard(Palette p, RaviUser u) {
    final s = AppState.I.str;
    return GestureDetector(
      onTap: () => Navigator.of(context, rootNavigator: true)
          .push(UserProfileScreen.route(u.username)),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: p.bgCard,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: p.borderSoft),
        ),
        child: Row(children: [
          RaviAvatar(name: u.name, avatarPath: u.avatar, size: 52),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(u.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: p.text)),
                  ),
                  if (u.isOfficial) ...[
                    const SizedBox(width: 4),
                    const Icon(Icons.verified_rounded,
                        size: 14, color: Color(0xFF38BDF8)),
                  ],
                  // v1.2.1 — the PRO star now shows in global search too
                  if (u.isPro) ...[
                    const SizedBox(width: 4),
                    const ProStarBadge(size: 15, animate: false),
                  ],
                ]),
                Text('@${u.username}',
                    textDirection: TextDirection.ltr,
                    style: TextStyle(fontSize: 11.5, color: p.accent)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
            decoration: BoxDecoration(
              color: p.accentSoft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(s.viewProfile,
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: p.accent)),
          ),
        ]),
      ),
    );
  }

  Widget _roomCard(Palette p, Map<String, dynamic> room) {
    final s = AppState.I.str;
    final name = '${room['room_name'] ?? room['name'] ?? ''}';
    final type = '${room['room_type'] ?? 'group'}';
    final members = (room['member_count'] ?? 0) is int
        ? room['member_count'] as int
        : int.tryParse('${room['member_count']}') ?? 0;
    final avatar = '${room['room_avatar'] ?? room['avatar'] ?? ''}';
    final username = '${room['username'] ?? ''}';
    return GestureDetector(
      onTap: () => RoomPreviewSheet.openFromToken(
          context, username.isNotEmpty ? username : name),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: p.bgCard,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: p.borderSoft),
        ),
        child: Row(children: [
          RaviAvatar(name: name, avatarPath: avatar, size: 52),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: p.text)),
                  ),
                  const SizedBox(width: 5),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: type == 'channel'
                          ? const Color(0xFF38BDF8).withValues(alpha: .14)
                          : const Color(0xFF8B5CF6).withValues(alpha: .14),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(type == 'channel' ? s.catChannel : s.catGroup,
                        style: TextStyle(
                            fontSize: 8.5,
                            fontWeight: FontWeight.w800,
                            color: type == 'channel'
                                ? const Color(0xFF38BDF8)
                                : const Color(0xFF8B5CF6))),
                  ),
                ]),
                Text(s.membersCountShort(members),
                    style: TextStyle(fontSize: 11.5, color: p.text3)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
            decoration: BoxDecoration(
              gradient: C.ownBubbleGrad,
              borderRadius: BorderRadius.circular(13),
            ),
            child: Text(s.joinGroupBtn,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: Colors.white)),
          ),
        ]),
      ),
    );
  }
}
