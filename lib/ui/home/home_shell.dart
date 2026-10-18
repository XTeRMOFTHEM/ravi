import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/constants.dart';
import '../../core/i18n.dart';
import '../../core/socket_service.dart';
import '../chat/player_bar.dart';
import 'chats_page.dart';
import 'magazine_page.dart';
import 'profile_page.dart';
import 'settings_page.dart';

/// Home shell — the exact layout of index.html:
/// topbar (brand + search) → PageView pages → floating glass bottom nav.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with TickerProviderStateMixin {
  StreamSubscription? _subPvUpd, _subGroupUnread;

  late final PageController _page = PageController(initialPage: 0);
  late final List<Widget> _pages = [
    const ChatsPage(),
    const MagazinePage(),
    const SettingsPage(),
    const ProfilePage(),
  ];

  @override
  void initState() {
    super.initState();
    AppState.I.pageIndex.addListener(_onPageIdx);
    SocketService.I.connect();
    // Live unread/preview updates (v1.0.5) — the chats list reacts in place.
    _subPvUpd = SocketService.I.onPvChatsUpdated.listen((d) {
      final chatId = (d['chat_id'] is int)
          ? d['chat_id'] as int
          : int.tryParse('${d['chat_id']}') ?? 0;
      if (chatId <= 0) return;
      final sender = '${d['sender_username'] ?? ''}';
      final me = AppState.I.me.value.username;
      final unread = (d['unread_count'] is int)
          ? d['unread_count'] as int
          : int.tryParse('${d['unread_count']}') ?? 0;
      AppState.I.updatePvPreview(
        chatId,
        '${d['last_message'] ?? ''}',
        '${d['last_time'] ?? ''}',
        sender == me ? 0 : unread,
        sender,
      );
    });
    _subGroupUnread = SocketService.I.onGroupUnread.listen((d) {
      final roomId = '${d['room_id'] ?? ''}';
      if (roomId.isEmpty) return;
      final reset = d.containsKey('reader');
      AppState.I.bumpRoomUnread(roomId, reset ? -999 : 1);
    });
  }

  void _onPageIdx() {
    if (!_page.hasClients) return;
    final t = AppState.I.pageIndex.value;
    if ((_page.page ?? 0).round() != t) {
      _page.animateToPage(t,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic);
    }
  }

  @override
  void dispose() {
    _subPvUpd?.cancel();
    _subGroupUnread?.cancel();
    AppState.I.pageIndex.removeListener(_onPageIdx);
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;

    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        top: true,
        bottom: false,
        child: Column(
          children: [
            _topbar(p, s),
            // v1.0.7 — glass mini-player visible on ALL pages while audio
            // plays (playback itself never stops when navigating).
            const PlayerBar(),
            Expanded(
              child: PageView(
                controller: _page,
                physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                onPageChanged: (i) {
                  AppState.I.pageIndex.removeListener(_onPageIdx);
                  AppState.I.pageIndex.value = i;
                  AppState.I.pageIndex.addListener(_onPageIdx);
                },
                // Keep all 4 pages alive (no re-build storms on tab switch).
                allowImplicitScrolling: true,
                children: _pages,
              ),
            ),
          ],
        ),
      ),
      // floating glass bottom nav
      bottomNavigationBar: ValueListenableBuilder<int>(
        valueListenable: AppState.I.pageIndex,
        builder: (context, idx, _) => ValueListenableBuilder<int>(
          valueListenable: AppState.I.totalUnread,
          builder: (context, unread, _) => _bottomNav(p, s, idx, unread),
        ),
      ),
    );
  }

  // ---------- topbar: RAVI brand + search button ----------
  Widget _topbar(Palette p, S s) {
    return Container(
      height: 62,
      padding: const EdgeInsets.fromLTRB(18, 7, 18, 4),
      decoration: BoxDecoration(
        color: p.bg,
        border: Border(bottom: BorderSide(color: p.border)),
      ),
      child: Stack(
        alignment: AlignmentDirectional.center,
        children: [
          const Text(
            'RAVI',
            textDirection: TextDirection.ltr,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
              height: 1,
            ),
          ),
          Positioned.directional(
            textDirection: TextDirection.ltr,
            end: 0,
            child: _SearchButton(p: p, onTap: () => AppState.I.pageIndex.value = 1),
          ),
        ],
      ),
    );
  }

  // ---------- floating bottom nav ----------
  Widget _bottomNav(Palette p, S s, int idx, int unread) {
    final items = [
      (Icons.chat_bubble_outline_rounded, s.navChats, 0, unread),
      (Icons.auto_stories_outlined, s.navMagazine, 1, 0),
      (Icons.settings_outlined, s.navSettings, 2, 0),
      (Icons.person_outline_rounded, s.navProfile, 3, 0),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Container(
        height: 70,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: p.navBg,
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: p.borderSoft),
          boxShadow: const [
            BoxShadow(color: Color(0x241E3246), blurRadius: 30, offset: Offset(0, 10)),
            BoxShadow(color: Color(0x0A1E3246), blurRadius: 8, offset: Offset(0, 2)),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          textDirection: TextDirection.ltr,
          children: [
            for (final it in items) _navItem(p, it.$1, it.$2, it.$3, idx, it.$4),
          ],
        ),
      ),
    );
  }

  Widget _navItem(Palette p, IconData icon, String label, int page, int active, int badge) {
    final isActive = page == active;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => AppState.I.pageIndex.value = page,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          height: 58,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isActive ? p.accentSoft : Colors.transparent,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: isActive ? p.accent.withValues(alpha: 0.22) : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(icon,
                      size: 25,
                      color: isActive ? p.accent : p.text2),
                  if (badge > 0)
                    Positioned(
                      top: -7,
                      right: -11,
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 20),
                        height: 20,
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: p.accent,
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: const [
                            BoxShadow(color: Color(0x38000000), blurRadius: 6)
                          ],
                        ),
                        child: Text(
                          badge > 99 ? '99+' : '$badge',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 10.5,
                              fontWeight: FontWeight.w800, height: 1),
                        ),
                      ),
                    ),
                ],
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                alignment: AlignmentDirectional.centerStart,
                child: isActive
                    ? Padding(
                        padding: const EdgeInsetsDirectional.only(start: 6),
                        child: Text(label,
                            style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                                color: p.accent,
                                height: 1)),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchButton extends StatelessWidget {
  final Palette p;
  final VoidCallback onTap;
  const _SearchButton({required this.p, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(color: p.bgSoft, shape: BoxShape.circle),
        child: Icon(Icons.search_rounded, size: 20, color: p.text2),
      ),
    );
  }
}
