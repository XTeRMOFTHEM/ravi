import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/account_manager.dart';
import '../../core/api_service.dart';
import '../../core/app_state.dart';
import '../../core/constants.dart';
import '../../core/i18n.dart';
import '../../core/models.dart' show ChatKind;
import '../../core/socket_service.dart';
import '../chat/chat_screen.dart';
import '../chat/player_bar.dart';
import 'chats_page.dart';
import 'global_search_screen.dart';
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

class _HomeShellState extends State<HomeShell> with TickerProviderStateMixin, WidgetsBindingObserver {
  StreamSubscription? _subPvUpd, _subGroupUnread, _subRoomUpd;
  int _pressedPage = -1; // v1.2.0 — nav press feedback

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
    WidgetsBinding.instance.addObserver(this);
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
      // v1.5.0 — اسم نمایشی + آواتار فرستنده داخل ایونت است؛ سطر جدیدِ چت
      // دیگر «سه نقطه بی‌نام و بی‌عکس» نمی‌شود.
      AppState.I.updatePvPreview(
        chatId,
        '${d['last_message'] ?? ''}',
        '${d['last_time'] ?? ''}',
        sender == me ? 0 : unread,
        sender,
        // v1.3.2 — live media labels (GIF / 🎵 music / 🎥 ویدئو) on the list
        lastFileType: '${d['last_file_type'] ?? ''}',
        displayName: '${d['sender_display_name'] ?? ''}',
        avatar: '${d['sender_avatar'] ?? ''}',
        isSelf: d['is_self'] == true,
      );
    });
    _subGroupUnread = SocketService.I.onGroupUnread.listen((d) {
      final roomId = '${d['room_id'] ?? ''}';
      if (roomId.isEmpty) return;
      final reset = d.containsKey('reader');
      AppState.I.bumpRoomUnread(roomId, reset ? -999 : 1);
    });
    // v1.5.0 — پیش‌نمایش زنده‌ی گروه/کانال بدون رفرش
    _subRoomUpd = SocketService.I.onRoomChatsUpdated.listen((d) {
      final roomId = '${d['room_id'] ?? ''}';
      if (roomId.isEmpty) return;
      final from = '${d['sender_username'] ?? ''}';
      final me = AppState.I.me.value.username;
      AppState.I.updateRoomPreview(
        roomId,
        '${d['last_message'] ?? ''}',
        '${d['last_time'] ?? ''}',
        '${d['last_file_type'] ?? ''}',
        from == me ? 0 : 1,
      );
    });
    // v1.5.0 — رفرش آرام تکراری (بدون رفرش دستی)
    AppState.I.startAutoRefresh();
  }

  // v1.5.0 — وقتی اپ به پس‌زمینه میرود رفرش خودکار متوقف می‌شود
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      AppState.I.setAppForeground(true);
      SocketService.I.connect();
      AppState.I.loadChatsCachedThenNetwork(); // مثل همه‌ی پیام‌رسان‌ها
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      AppState.I.setAppForeground(false);
    }
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
    WidgetsBinding.instance.removeObserver(this);
    _subPvUpd?.cancel();
    _subGroupUnread?.cancel();
    _subRoomUpd?.cancel();
    AppState.I.stopAutoRefresh();
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

    return AnnotatedRegion<SystemUiOverlayStyle>(
      // v1.1.1 — theme-aware system-bar icons: on the light theme the old
      // hardcoded white icons were invisible on the transparent status bar
      // (the "panels are under the notification bar" report).
      value: Theme.of(context).brightness == Brightness.dark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      child: Scaffold(
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
      ),
    );
  }

  // ---------- topbar: v1.5.0 — برند «Ravi» سمت چپ؛ وقتی چت‌ها در حال رفرش
  // هستند با انیمیشن نرم «Updating…» جای آن می‌نشیند (مثل همه‌ی پیام‌رسان‌ها).
  // سه‌نقطه => پنل شناور با انیمیشن: سیو مسیج / روز و شب / پروفایل من
  Widget _topbar(Palette p, S s) {
    return Container(
      height: 62,
      padding: const EdgeInsets.fromLTRB(18, 7, 12, 4),
      decoration: BoxDecoration(
        color: p.bg,
        border: Border(bottom: BorderSide(color: p.border)),
      ),
      child: Row(
        textDirection: TextDirection.ltr,
        children: [
          // برند — «Ravi» با فونت Inter؛ هنگام رفرش: «Updating…» پالس‌دار
          ValueListenableBuilder<bool>(
            valueListenable: AppState.I.chatsLoading,
            builder: (context, loading, _) {
              final child = loading
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      textDirection: TextDirection.ltr,
                      children: [
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 1.8, color: Color(0xFF38BDF8)),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          s.updating,
                          textDirection: TextDirection.ltr,
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.3,
                            height: 1,
                            color: Color(0xFF38BDF8),
                          ),
                        ),
                      ],
                    )
                  : ShaderMask(
                      shaderCallback: (b) => const LinearGradient(
                        colors: [Color(0xFF38BDF8), Color(0xFF7C3AED)],
                      ).createShader(b),
                      blendMode: BlendMode.srcIn,
                      child: const Text(
                        'Ravi',
                        textDirection: TextDirection.ltr,
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.6,
                          height: 1,
                        ),
                      ),
                    );
              return AnimatedSwitcher(
                duration: const Duration(milliseconds: 360),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position: Tween(
                            begin: const Offset(0, 0.15), end: Offset.zero)
                        .animate(anim),
                    child: child,
                  ),
                ),
                child: KeyedSubtree(
                    key: ValueKey(loading), child: child),
              );
            },
          ),
          const Spacer(),
          _topIconBtn(
            p,
            icon: Icons.search_rounded,
            onTap: _openGlobalSearch,
          ),
          const SizedBox(width: 8),
          _topIconBtn(
            p,
            icon: Icons.more_vert_rounded,
            onTap: _showHomeMenu,
          ),
        ],
      ),
    );
  }

  Widget _topIconBtn(Palette p, {required IconData icon, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: p.bgSoft,
          border: Border.all(color: p.borderSoft),
        ),
        child: Icon(icon, size: 21, color: p.text2),
      ),
    );
  }

  // ---------- v1.4.0 — پنل شناور سه‌نقطه (انیمیشن scale+fade از گوشه بالا-راست) ----------
  void _showHomeMenu() {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;
    final isDarkNow = Theme.of(context).brightness == Brightness.dark;
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'menu',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (_, __, ___) => const SizedBox.shrink(),
      transitionBuilder: (_, anim, __, ___) {
        final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return Stack(
          children: [
            // لایه‌ی شفاف برای بستن با کلیک بیرون
            Positioned.fill(
              child: GestureDetector(onTap: () => Navigator.of(context).pop()),
            ),
            Positioned(
              top: MediaQuery.paddingOf(context).top + 52,
              right: 14,
              child: Transform.scale(
                scale: 0.82 + 0.18 * curved.value,
                alignment: Alignment.topRight,
                child: FadeTransition(
                  opacity: curved,
                  child: Material(
                    color: Colors.transparent,
                    child: Container(
                      width: 252,
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: p.navBg,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: p.borderSoft),
                        boxShadow: const [
                          BoxShadow(color: Color(0x36122A46), blurRadius: 30, offset: Offset(0, 14)),
                          BoxShadow(color: Color(0x14122A46), blurRadius: 8, offset: Offset(0, 3)),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _menuItem(
                            p,
                            icon: Icons.bookmark_rounded,
                            iconColor: const Color(0xFFF59E0B),
                            label: s.savedMessages,
                            onTap: () {
                              Navigator.of(context).pop();
                              _openSavedMessages();
                            },
                          ),
                          _divider(p),
                          _menuItem(
                            p,
                            icon: isDarkNow
                                ? Icons.light_mode_rounded
                                : Icons.dark_mode_rounded,
                            iconColor: isDarkNow
                                ? const Color(0xFFFBBF24)
                                : const Color(0xFF818CF8),
                            label: isDarkNow ? s.themeLight : s.themeDark,
                            trailing: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              width: 40,
                              height: 23,
                              padding: const EdgeInsets.all(2.5),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(999),
                                color: isDarkNow ? p.accentSoft : p.bgSoft,
                                border: Border.all(color: p.borderSoft),
                              ),
                              child: AnimatedAlign(
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.easeOutCubic,
                                // روشن: دسته سمت راست با خورشید — تاریک: سمت چپ با ماه
                                alignment: isDarkNow
                                    ? Alignment.centerLeft
                                    : Alignment.centerRight,
                                child: Icon(
                                  isDarkNow
                                      ? Icons.dark_mode_rounded
                                      : Icons.light_mode_rounded,
                                  size: 14,
                                  color: isDarkNow ? p.accent : p.text2,
                                ),
                              ),
                            ),
                            onTap: () {
                              // سوییچ سریع روز/شب (برعکس حالت فعلی)
                              AppState.I.setThemePref(
                                isDarkNow ? ThemeModePref.light : ThemeModePref.dark,
                              );
                              Navigator.of(context).pop();
                            },
                          ),
                          _divider(p),
                          _menuItem(
                            p,
                            icon: Icons.person_rounded,
                            iconColor: p.accent,
                            label: s.myProfile,
                            onTap: () {
                              Navigator.of(context).pop();
                              AppState.I.pageIndex.value = 3; // تب پروفایل من
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _menuItem(
    Palette p, {
    required IconData icon,
    required Color iconColor,
    required String label,
    Widget? trailing,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(15),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.13),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, size: 18, color: iconColor),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: p.text,
                  height: 1,
                ),
              ),
            ),
            if (trailing != null) trailing,
          ],
        ),
      ),
    );
  }

  Widget _divider(Palette p) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        child: Divider(height: 1, thickness: 0.7, color: p.border),
      );

  // ---------- v1.4.0 — سیو مسیج: باز کردن چت «پیام‌های ذخیره‌شده» ----------
  Future<void> _openSavedMessages() async {
    final s = AppState.I.str;
    final me = AppState.I.me.value;
    final chatId = await ApiService.I.savedChat();
    if (chatId == null || !mounted) return;
    Navigator.of(context, rootNavigator: true).push(ChatScreen.route(
      kind: ChatKind.pv,
      title: s.savedMessages,
      avatarPath: '', // آیکون بوکمارک در هدر چت با avatarPath خالی + isSelfChat
      chatId: chatId,
      peerUsername: me.username,
      isSelfChat: true,
    ));
  }

  // v1.1.0 — GLOBAL search (users / public rooms / own chats)
  void _openGlobalSearch() {
    Navigator.of(context, rootNavigator: true)
        .push(MaterialPageRoute(builder: (_) => const GlobalSearchScreen()));
  }

  // ---------- floating bottom nav (v1.1.0 — Soroush+ capsule look) ----------
  Widget _bottomNav(Palette p, S s, int idx, int unread) {
    final items = [
      (Icons.chat_bubble_outline_rounded, s.navChats, 0, unread),
      (Icons.auto_stories_outlined, s.navMagazine, 1, 0),
      (Icons.settings_outlined, s.navSettings, 2, 0),
      (Icons.person_outline_rounded, s.navProfile, 3, 0),
    ];
    // v1.1.1 — FULL bottom inset: on phones with a gesture bar the capsule
    // now floats entirely ABOVE the system buttons (the old 0.45× factor
    // left it half-buried in the nav bar).
    final inset = MediaQuery.paddingOf(context).bottom;
    final gap = inset > 0 ? 6.0 : 12.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(14, 0, 14, gap + inset),
      child: Container(
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
        decoration: BoxDecoration(
          color: p.navBg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: p.borderSoft),
          boxShadow: const [
            BoxShadow(color: Color(0x2A1E3246), blurRadius: 28, offset: Offset(0, 10)),
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
        // v1.2.0 — soft press-down feedback (Telegram island feel)
        onTapDown: (_) => setState(() => _pressedPage = page),
        onTapUp: (_) => setState(() => _pressedPage = -1),
        onTapCancel: () => setState(() => _pressedPage = -1),
        onTap: () => AppState.I.pageIndex.value = page,
        child: AnimatedScale(
          scale: _pressedPage == page ? 0.92 : 1.0,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          height: 54,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isActive ? p.accentSoft : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    transitionBuilder: (child, anim) => ScaleTransition(
                        scale: anim, child: child),
                    child: Icon(
                      // filled glyph for the active tab (Soroush+ style)
                      isActive
                          ? (icon == Icons.chat_bubble_outline_rounded
                              ? Icons.chat_bubble_rounded
                              : icon == Icons.auto_stories_outlined
                                  ? Icons.auto_stories_rounded
                                  : icon == Icons.settings_outlined
                                      ? Icons.settings_rounded
                                      : Icons.person_rounded)
                          : icon,
                      key: ValueKey(isActive),
                      size: 23,
                      color: isActive ? p.accent : p.text2,
                    ),
                  ),
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
                          color: const Color(0xFFEF4444),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: p.navBg, width: 1.6),
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
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                alignment: AlignmentDirectional.centerStart,
                child: isActive
                    ? Padding(
                        padding: const EdgeInsetsDirectional.only(start: 7),
                        child: Text(label,
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                color: p.accent,
                                height: 1)),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
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

