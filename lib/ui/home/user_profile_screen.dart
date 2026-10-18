import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart' as ip;

import '../../core/api_service.dart';
import '../../core/app_state.dart';
import '../../core/constants.dart';
import '../../core/models.dart';
import '../../core/presets.dart';
import '../../core/socket_service.dart';
import '../chat/chat_screen.dart';
import '../chat/photo_viewer.dart';
import '../widgets/common.dart';
import '../widgets/ravi_alerts.dart';

/// v1.0.6 — full-screen user profile rebuilt 1:1 with the web version:
/// big cover (photo / theme / avatar-blur), avatar with a properly SCALED
/// frame + glow, name row with verified/pro badges, @handle, followers line,
/// posts/followers/following stats, follow + message actions, bio box and
/// realtime block/unblock. The frame is rendered 1.5× the avatar and
/// centered (BoxFit.contain) so it wraps the avatar instead of a tiny dot.
class UserProfileScreen extends StatefulWidget {
  final String username;

  const UserProfileScreen({super.key, required this.username});

  static Route route(String username) => PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 240),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (_, __, ___) => UserProfileScreen(username: username),
        transitionsBuilder: (_, anim, __, child) => SlideTransition(
          position: Tween(begin: const Offset(0, 0.04), end: Offset.zero)
              .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
          child: FadeTransition(opacity: anim, child: child),
        ),
      );

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  Map<String, dynamic>? _prof;
  bool _loading = true;
  bool _busyFollow = false;
  bool _isFollowing = false;
  bool _iBlocked = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await ApiService.I.userProfile(widget.username);
    if (!mounted) return;
    setState(() {
      _prof = r.ok ? r.data : null;
      _loading = false;
      _isFollowing = _prof?['is_following'] == true;
      _iBlocked = _prof?['i_blocked_them'] == true ||
          _prof?['is_blocked_by_me'] == true;
    });
  }

  bool get _isSelf =>
      '${_prof?['username'] ?? ''}' == ApiService.I.cachedUsername ||
      widget.username == ApiService.I.cachedUsername;

  String get _u => '${_prof?['username'] ?? widget.username}';

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;
    final dark = Theme.of(context).brightness == Brightness.dark;

    final isPro = _prof?['is_pro'] == true;
    final isVerified = _prof?['is_verified'] == true || _prof?['is_admin'] == true;
    final followers = _asInt(_prof?['followers']);
    final following = _asInt(_prof?['following']);
    final posts = _asInt(_prof?['posts']);
    final bio = '${_prof?['bio'] ?? ''}';
    final avatar = '${_prof?['avatar'] ?? ''}';
    final frameUrl = '${_prof?['avatar_frame_url'] ?? ''}';
    final hasFrame = isPro && frameUrl.isNotEmpty && frameUrl != 'None';
    final hasCover = _prof?['has_cover'] == true;
    final coverUrl = '${_prof?['profile_cover'] ?? ''}';
    final themeKey = ProPresets.cssToKey['${_prof?['cover_theme_css'] ?? ''}'] ??
        (hasCover ? '' : 'default');
    final name = ('${_prof?['name'] ?? ''}').trim().isNotEmpty
        ? '${_prof?['name']}'
        : _u;
    final createdAt = '${_prof?['created_at'] ?? ''}';

    return Scaffold(
      backgroundColor: p.pfBg,
      body: RefreshIndicator(
        color: p.accent,
        onRefresh: _load,
        child: _loading
            ? ListView(children: const [
                SizedBox(height: 300),
                Center(child: CircularProgressIndicator(strokeWidth: 2)),
              ])
            : _prof == null
                ? ListView(children: [
                    const SizedBox(height: 160),
                    Icon(Icons.person_off_outlined, size: 44, color: p.text3),
                    const SizedBox(height: 12),
                    Center(
                        child: Text(AppState.I.str.userNotFound,
                            style: TextStyle(color: p.text2, fontSize: 14))),
                  ])
                : ListView(
                    padding: const EdgeInsets.only(bottom: 40),
                    children: [
                      // ================= cover =================
                      Stack(
                        children: [
                          Container(
                            height: 232,
                            width: double.infinity,
                            decoration: BoxDecoration(
                              // v1.0.9 — banner-less profiles are NOT purple
                              // anymore: plain card color (black on dark,
                              // white on light). Gradients only when the Pro
                              // user actually picked a theme.
                              color: p.pfCard,
                              gradient: (themeKey.isNotEmpty &&
                                      themeKey != 'default')
                                  ? LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: ProPresets
                                              .profileThemes[themeKey] ??
                                          ProPresets.profileThemes['default']!,
                                    )
                                  : null,
                            ),
                            child: hasCover && coverUrl.isNotEmpty
                                ? GestureDetector(
                                    onTap: () => openMediaViewer(
                                        context, fileUrl: coverUrl, title: _u),
                                    child: CachedNetworkImage(
                                      imageUrl: ApiService.I.absoluteUrl(coverUrl),
                                      fit: BoxFit.cover,
                                      httpHeaders: {'Cookie': ApiService.I.cookieHeader},
                                    ),
                                  )
                                : null,
                          ),
                          // readability scrim ONLY over real covers/themes —
                          // never over the flat card background
                          if ((hasCover && coverUrl.isNotEmpty) ||
                              (themeKey.isNotEmpty && themeKey != 'default'))
                            Positioned.fill(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.black.withValues(alpha: .05),
                                      Colors.black.withValues(alpha: .22),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          // back + more buttons
                          SafeArea(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  _roundBtn(context, Icons.arrow_back_rounded,
                                      () => Navigator.of(context).pop()),
                                  if (!_isSelf)
                                    Builder(builder: (btnCtx) => _roundBtn(
                                        context, Icons.more_vert_rounded,
                                        () => _userMenu(btnCtx), null)),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),

                      // ================= header =================
                      Transform.translate(
                        offset: const Offset(0, -56),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  // ---- avatar + real frame (2×, web-like) ----
                                  GestureDetector(
                                    onTap: avatar.isNotEmpty
                                        ? () => openMediaViewer(context,
                                            fileUrl:
                                                ApiService.I.avatarUrl(avatar),
                                            title: _u)
                                        : null,
                                    child: FrameAvatar(
                                      name: name,
                                      avatarPath: avatar,
                                      frameUrl: hasFrame ? frameUrl : '',
                                      size: 104,
                                    ),
                                  ),
                                  SizedBox(width: hasFrame ? 34 : 8),
                                  const Spacer(),
                                ],
                              ),
                              const SizedBox(height: 8),

                              // ---- name row (color fixed for LIGHT mode) ----
                              // v1.0.9 — the Pro star is on the NAME (like the
                              // blue check); the separate badges column is gone
                              // (its breathing glow pushed the layout around).
                              Row(children: [
                                Flexible(
                                  child: Text(name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 21,
                                          fontWeight: FontWeight.w800,
                                          color: p.pfName)),
                                ),
                                if (isVerified) ...[
                                  const SizedBox(width: 5),
                                  const Icon(Icons.verified_rounded,
                                      size: 17, color: Color(0xFF38BDF8)),
                                ],
                                if (isPro) ...[
                                  const SizedBox(width: 5),
                                  const ProStarBadge(size: 20),
                                ],
                              ]),
                              const SizedBox(height: 2),
                              Text('$_u',
                                  textDirection: TextDirection.ltr,
                                  style: TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600,
                                      color: p.pfHandle)),
                              const SizedBox(height: 5),
                              Text(
                                  '$followers ${AppState.I.str.followers}',
                                  style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w600,
                                      color: p.text2)),
                              const SizedBox(height: 8),
                              // meta chips: joined
                              Row(children: [
                                Icon(Icons.calendar_today_rounded,
                                    size: 12, color: p.text3),
                                const SizedBox(width: 5),
                                Flexible(
                                  child: Text(
                                      createdAt.isEmpty
                                          ? '—'
                                          : createdAt,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 11.5, color: p.text3)),
                                ),
                              ]),
                            ],
                          ),
                        ),
                      ),

                      // ================= actions =================
                      if (!_isSelf)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(children: [
                            Expanded(
                              child: GestureDetector(
                                onTap: _busyFollow ? null : _toggleFollow,
                                child: AnimatedContainer(
                                  duration:
                                      const Duration(milliseconds: 200),
                                  height: 44,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    gradient: _isFollowing
                                        ? null
                                        : LinearGradient(colors: [
                                            p.accent,
                                            p.accent.withValues(alpha: .8)
                                          ]),
                                    color: _isFollowing
                                        ? p.bgSoft
                                        : null,
                                    borderRadius:
                                        BorderRadius.circular(14),
                                    border: _isFollowing
                                        ? Border.all(color: p.border)
                                        : null,
                                    boxShadow: _isFollowing
                                        ? null
                                        : [
                                            BoxShadow(
                                                color: p.accent
                                                    .withValues(alpha: .3),
                                                blurRadius: 14,
                                                offset:
                                                    const Offset(0, 6)),
                                          ],
                                  ),
                                  child: _busyFollow
                                      ? SizedBox(
                                          width: 17, height: 17,
                                          child:
                                              CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  color: _isFollowing
                                                      ? p.text2
                                                      : Colors.white))
                                      : Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                                _isFollowing
                                                    ? Icons.check_rounded
                                                    : Icons.add_rounded,
                                                size: 17,
                                                color: _isFollowing
                                                    ? p.text
                                                    : Colors.white),
                                            const SizedBox(width: 5),
                                            Text(
                                                _isFollowing
                                                    ? s.followingOf
                                                    : s.follow,
                                                style: TextStyle(
                                                    fontSize: 13.5,
                                                    fontWeight:
                                                        FontWeight.w800,
                                                    color: _isFollowing
                                                        ? p.text
                                                        : Colors.white)),
                                          ],
                                        ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: GestureDetector(
                                onTap: _openPv,
                                child: Container(
                                  height: 44,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: p.accentSoft,
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                        color:
                                            p.accent.withValues(alpha: .25)),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.chat_bubble_outline_rounded,
                                          size: 17, color: p.accent),
                                      const SizedBox(width: 6),
                                      Text(s.gotoChat,
                                          style: TextStyle(
                                              fontSize: 13.5,
                                              fontWeight: FontWeight.w800,
                                              color: p.accent)),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ]),
                        ),

                      // ================= stats =================
                      Transform.translate(
                        offset:
                            Offset(0, !_isSelf ? 14 : 0),
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                              16, !_isSelf ? 16 : 0, 16, 0),
                          child: Container(
                            padding:
                                const EdgeInsets.symmetric(vertical: 13),
                            decoration: BoxDecoration(
                              color: dark ? C.pfCardD : C.pfCardL,
                              borderRadius: BorderRadius.circular(17),
                              border: Border.all(color: p.pfCardBorder),
                            ),
                            child: Row(children: [
                              _statTap(p, _fmtCount(posts), s.postsLabel,
                                  null),
                              _divider(p),
                              _statTap(p, _fmtCount(followers),
                                  s.followersOf, () => _openFollowList(true)),
                              _divider(p),
                              _statTap(p, _fmtCount(following),
                                  s.followingOf, () => _openFollowList(false)),
                            ]),
                          ),
                        ),
                      ),

                      // ================= bio (v1.0.8 — breathing room + icon)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: dark ? C.pfCardD : C.pfCardL,
                            borderRadius: BorderRadius.circular(17),
                            border: Border.all(color: p.pfCardBorder),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // bio SVG icon in a soft accent tile
                              Container(
                                width: 32,
                                height: 32,
                                margin: const EdgeInsetsDirectional.only(end: 11),
                                decoration: BoxDecoration(
                                  color: p.accent.withValues(alpha: .12),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(6.5),
                                  child: CustomPaint(
                                      painter: _BioIconPainter(
                                          color: p.accent)),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  bio.isEmpty ? s.bioEmptyHint : bio,
                                  style: TextStyle(
                                      fontSize: 13.5,
                                      height: 1.65,
                                      fontStyle: bio.isEmpty
                                          ? FontStyle.italic
                                          : FontStyle.normal,
                                      color: bio.isEmpty ? p.text3 : p.text),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      // ================= self: customize =================
                      if (_isSelf) ...[
                        const SizedBox(height: 14),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: ListRow(
                            icon: Icons.style_outlined,
                            title: s.customizeProfile,
                            sub: s.customizeProfileSub,
                            trailing: Icon(Icons.chevron_right_rounded,
                                size: 17, color: p.text3),
                            onTap: () => CustomizeProfileSheet.show(context)
                                .then((_) {
                              // v1.0.7: always reload — the sheet stays open
                              // while applying, close = refresh whatever set.
                              if (mounted) _load();
                            }),
                          ),
                        ),
                      ],
                    ],
                  ),
      ),
    );
  }

  int _asInt(dynamic v) => v is int ? v : int.tryParse('$v') ?? 0;

  String _fmtCount(int n) {
    if (n >= 1000) {
      final v = n / 1000;
      return '${v.toStringAsFixed(v < 10 ? 1 : 0)}K';
    }
    return '$n';
  }

  // ---------------- actions ----------------

  Future<void> _toggleFollow() async {
    setState(() => _busyFollow = true);
    // optimistic UI first (feels instant) — the API call confirms it
    final next = !_isFollowing;
    setState(() {
      _isFollowing = next;
      final f = _asInt(_prof?['followers']) + (next ? 1 : -1);
      if (f >= 0) _prof?['followers'] = f;
    });
    final r = await ApiService.I.setFollowing(_u, next);
    if (!mounted) return;
    setState(() => _busyFollow = false);
    final s = AppState.I.str;
    if (r.ok) {
      showGlassToast(context, next ? s.followedToast : s.unfollowedToast,
          icon: next
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded);
    } else {
      // rollback
      setState(() {
        _isFollowing = !next;
        final f = _asInt(_prof?['followers']) + (next ? -1 : 1);
        if (f >= 0) _prof?['followers'] = f;
      });
      showGlassToast(context, s.error,
          icon: Icons.error_outline_rounded, color: const Color(0xFFEF4444));
    }
  }

  Future<void> _openPv() async {
    final s = AppState.I.str;
    if (_iBlocked) {
      final ok = await showRaviModal(
        context,
        icon: Icons.lock_open_rounded,
        title: s.unblockUser,
        okText: s.unblock,
        cancelText: s.cancel,
      );
      if (ok == true) {
        await ApiService.I.unblockUser(_u);
        if (!mounted) return;
        setState(() => _iBlocked = false);
        showGlassToast(context, s.unblockedToast);
      }
      return;
    }
    final r = await ApiService.I.startPv(_u);
    if (!mounted) return;
    if (r.ok && (r.data ?? 0) > 0) {
      final chatId = r.data!;
      SocketService.I.joinPv(chatId);
      await Navigator.of(context, rootNavigator: true).push(ChatScreen.route(
        kind: ChatKind.pv,
        title: '${_prof?['name'] ?? ''}'.isNotEmpty ? '${_prof?['name']}' : _u,
        avatarPath: '${_prof?['avatar'] ?? ''}',
        chatId: chatId,
        peerUsername: _u,
      ));
      _load();
    } else {
      showGlassToast(context,
          r.message != null && r.message!.contains('مسدود')
              ? s.dmClosedBanner
              : s.userNotFound,
          icon: Icons.error_outline_rounded, color: const Color(0xFFEF4444));
    }
  }

  Future<void> _userMenu(BuildContext btnCtx) async {
    final s = AppState.I.str;
    // v1.0.8 — Telegram-style FLOATING glass panel instead of a bottom
    // sheet: Block / Report / Ravi AI, spring-in under the ⋮ button.
    final dark = Theme.of(context).brightness == Brightness.dark;
    final box = btnCtx.findRenderObject() as RenderBox?;
    final anchor = box != null
        ? box.localToGlobal(Offset.zero)
        : Offset(MediaQuery.of(context).size.width - 46,
            MediaQuery.of(context).padding.top + 46);
    showFloatingMenu(
      context,
      dark: dark,
      alignEnd: true,
      anchor: anchor,
      items: [
        MenuItem(Icons.block_rounded, _iBlocked ? s.unblock : s.block,
            const Color(0xFFEF4444), () {
          _toggleBlock();
        }),
        MenuItem(Icons.flag_outlined, s.reportUser, const Color(0xFFF59E0B),
            () async {
          final ok = await showRaviModal(
            context,
            icon: Icons.flag_outlined,
            iconColor: const Color(0xFFF59E0B),
            title: s.reportUser,
            body: s.confirmReport,
            okText: s.reportUser,
            cancelText: s.cancel,
          );
          if (ok && mounted) {
            showGlassToast(context, s.reportSent,
                icon: Icons.flag_rounded, color: const Color(0xFFF59E0B));
          }
        }),
        MenuItem(Icons.auto_awesome_rounded, s.chatMenuAI,
            const Color(0xFF8B5CF6), () {
          showGlassToast(context, s.aiComingSoon,
              icon: Icons.auto_awesome_rounded, color: const Color(0xFF8B5CF6));
        }),
      ],
    );
  }

  Future<void> _toggleBlock() async {
    final s = AppState.I.str;
    if (_iBlocked) {
      final r = await ApiService.I.unblockUser(_u);
      if (!mounted) return;
      if (r.ok) {
        setState(() => _iBlocked = false);
        showGlassToast(context, s.unblockedToast);
      }
      return;
    }
    final ok = await showRaviModal(
      context,
      icon: Icons.block_rounded,
      iconColor: const Color(0xFFEF4444),
      title: s.block,
      body: s.blockedBanner,
      okText: s.block,
      cancelText: s.cancel,
      danger: true,
    );
    if (!ok) return;
    final r = await ApiService.I.blockUser(_u);
    if (!mounted) return;
    if (r.ok) {
      setState(() => _iBlocked = true);
      showGlassToast(context, s.blockedToast,
          icon: Icons.block_rounded, color: const Color(0xFFEF4444));
    } else {
      showGlassToast(context, s.error,
          icon: Icons.error_outline_rounded, color: const Color(0xFFEF4444));
    }
  }

  Future<void> _openFollowList(bool followers) async {
    await showGlassSheet(
      context,
      heightFactor: 0.78,
      builder: (_) => FollowListSheet(username: _u, followers: followers),
    );
  }

  Widget _statTap(Palette p, String value, String label, VoidCallback? onTap) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              Text(value,
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: p.text)),
              const SizedBox(height: 3),
              Text(label,
                  style: TextStyle(
                      fontSize: 10,
                      color: p.text3,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _divider(Palette p) =>
      Container(width: 1, height: 28, color: p.pfDivider);

  Widget _roundBtn(BuildContext context, IconData icon, VoidCallback onTap,
      [Color? bg]) {
    return ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: bg ?? Colors.black.withValues(alpha: .28),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withValues(alpha: .18)),
            ),
            child: Icon(icon, color: Colors.white, size: 19),
          ),
        ),
      ),
    );
  }

  Widget _letterAvatar(String name, double size) {
    final initial = name.isEmpty
        ? 'R'
        : String.fromCharCode(name.runes.first).toUpperCase();
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF4DB2E8), Color(0xFF1686C7)]),
      ),
      alignment: Alignment.center,
      child: Text(initial,
          style: TextStyle(
              color: Colors.white,
              fontSize: size * 0.26,
              fontWeight: FontWeight.w800)),
    );
  }
}

// ==================== followers / following sheet ====================

class FollowListSheet extends StatefulWidget {
  final String username;
  final bool followers;
  const FollowListSheet(
      {super.key, required this.username, required this.followers});

  @override
  State<FollowListSheet> createState() => _FollowListSheetState();
}

class _FollowListSheetState extends State<FollowListSheet> {
  List<Map<String, dynamic>> _list = [];
  bool _loading = true;
  String _tab = '';
  String _query = '';

  @override
  void initState() {
    super.initState();
    _tab = widget.followers ? 'followers' : 'following';
    _load();
  }

  Future<void> _load() async {
    final r = await ApiService.I
        .followList(widget.username, followers: _tab == 'followers');
    if (!mounted) return;
    setState(() {
      _list = r.ok ? (r.data ?? []) : [];
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final filtered = _query.isEmpty
        ? _list
        : _list
            .where((e) =>
                '${e['username']}'.toLowerCase().contains(_query) ||
                '${e['name']}'.toLowerCase().contains(_query))
            .toList();

    return Column(
      children: [
        const SizedBox(height: 12),
        Container(
            width: 44,
            height: 4,
            decoration: BoxDecoration(
                color: p.border, borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            _tabBtn(p, s.followersOf, 'followers'),
            const SizedBox(width: 8),
            _tabBtn(p, s.followingOf, 'following'),
          ]),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Container(
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: p.bgSoft,
              borderRadius: BorderRadius.circular(21),
            ),
            alignment: Alignment.center,
            child: TextField(
              onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
              style: TextStyle(fontSize: 13.5, color: p.text),
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: s.searchChats,
                hintStyle: TextStyle(fontSize: 13, color: p.text3),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _loading
              ? Center(
                  child: CircularProgressIndicator(strokeWidth: 2, color: p.accent))
              : filtered.isEmpty
                  ? Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.people_outline_rounded,
                            size: 36, color: p.text3),
                        const SizedBox(height: 10),
                        Text(s.emptyFollowers,
                            style: TextStyle(fontSize: 13.5, color: p.text2)),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
                      itemCount: filtered.length,
                      itemBuilder: (context, i) {
                        final e = filtered[i];
                        final uname = '${e['username'] ?? ''}';
                        return InkWell(
                          onTap: () {
                            Navigator.of(context).pop();
                            Navigator.of(context, rootNavigator: true)
                                .push(UserProfileScreen.route(uname));
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 9),
                            decoration: BoxDecoration(
                              border: Border(
                                  bottom: BorderSide(color: p.border)),
                            ),
                            child: Row(children: [
                              CircleAvatar(
                                radius: 21,
                                backgroundColor: const Color(0xFF1686C7),
                                backgroundImage: ApiService.I
                                        .avatarUrl('${e['avatar'] ?? ''}')
                                        .isNotEmpty
                                    ? NetworkImage(
                                        ApiService.I
                                            .avatarUrl('${e['avatar'] ?? ''}'),
                                      )
                                    : null,
                                child: ApiService.I
                                        .avatarUrl('${e['avatar'] ?? ''}')
                                        .isEmpty
                                    ? Text(
                                        uname.isEmpty
                                            ? '?'
                                            : uname[0].toUpperCase(),
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w800))
                                    : null,
                              ),
                              const SizedBox(width: 11),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                        '${e['name'] ?? ''}'.isNotEmpty
                                            ? '${e['name']}'
                                            : uname,
                                        style: TextStyle(
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.w700,
                                            color: p.text)),
                                    Text('@$uname',
                                        textDirection: TextDirection.ltr,
                                        style: TextStyle(
                                            fontSize: 11, color: p.text3)),
                                  ],
                                ),
                              ),
                              // v1.0.9 — Follow / Follow-back / Unfollow pill
                              _FollowToggle(
                                username: uname,
                                initialFollowing: e['i_follow'] == true,
                                p: p,
                              ),
                              if (dark)
                                Icon(Icons.chevron_left_rounded,
                                    size: 18, color: p.text3),
                            ]),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  Widget _tabBtn(Palette p, String label, String key) {
    final active = _tab == key;
    return GestureDetector(
      onTap: () {
        if (_tab == key) return;
        setState(() {
          _tab = key;
          _loading = true;
          _list = [];
        });
        _load();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
        decoration: BoxDecoration(
          color: active ? p.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(13),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                color: active ? p.accent : p.text2)),
      ),
    );
  }
}

class CustomizeProfileSheet extends StatefulWidget {
  const CustomizeProfileSheet({super.key});

  static Future<bool?> show(BuildContext context) =>
      showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => const CustomizeProfileSheet(),
      );

  @override
  State<CustomizeProfileSheet> createState() => _CustomizeProfileSheetState();
}

class _CustomizeProfileSheetState extends State<CustomizeProfileSheet> {
  Map<String, dynamic>? _prof;
  bool _loading = true;
  bool _busy = false;

  String _frame = '';
  String _theme = 'default';
  String _card = 'default';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final me = ApiService.I.cachedUsername;
    final r = await ApiService.I.userProfile(me);
    if (!mounted) return;
    if (r.ok && r.data != null) {
      final d = r.data!;
      final frameUrl = '${d['avatar_frame_url'] ?? ''}';
      _frame = '';
      if (frameUrl.isNotEmpty) {
        for (final f in ProPresets.avatarFrames) {
          if (frameUrl.contains('frame_${f.$1}.png')) {
            _frame = f.$1;
            break;
          }
        }
      }
      _theme = ProPresets.cssToKey['${d['cover_theme_css'] ?? ''}'] ?? 'default';
    }
    setState(() {
      _prof = r.ok ? r.data : null;
      _loading = false;
    });
  }

  bool get _isPro => _prof?['is_pro'] == true;

  Future<void> _guardPro() async {
    final s = AppState.I.str;
    showGlassToast(context, s.mustBePro,
        icon: Icons.lock_rounded, color: const Color(0xFFF59E0B));
  }

  Future<void> _apply(Future<ApiResult<bool>> Function() task,
      {VoidCallback? onSuccess}) async {
    final s = AppState.I.str;
    if (!_isPro) {
      await _guardPro();
      return;
    }
    setState(() => _busy = true);
    final r = await task();
    if (!mounted) return;
    setState(() => _busy = false);
    if (r.ok) {
      onSuccess?.call();
      showGlassToast(context, s.applied);
      // v1.0.6: stay open so the user can apply several items at once;
      // the profile reloads when the sheet is dismissed.
    } else if (r.message == 'pro_only') {
      await _guardPro();
    } else {
      showGlassToast(context, s.error,
          icon: Icons.error_outline_rounded, color: const Color(0xFFEF4444));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;
    final fa = AppState.I.lang.value.isFa;
    final h = MediaQuery.of(context).size.height;

    return Container(
      height: h * 0.86,
      decoration: BoxDecoration(
        color: p.bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 12),
          Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                  color: p.border, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 10),
          Text(s.customizeProfile,
              style: TextStyle(
                  fontSize: 16.5, fontWeight: FontWeight.w800, color: p.text)),
          if (!_isPro && !_loading)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock_rounded, size: 13, color: const Color(0xFFF59E0B)),
                  const SizedBox(width: 5),
                  Text(s.proOnlyTitle,
                      style: TextStyle(
                          fontSize: 11.5,
                          color: const Color(0xFFF59E0B),
                          fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Expanded(
            child: _loading
                ? Center(
                    child: CircularProgressIndicator(strokeWidth: 2, color: p.accent))
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 30),
                    children: [
                      // ---- Pro lock card ----
                      if (!_isPro)
                        Container(
                          margin: const EdgeInsets.only(bottom: 16),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(colors: [
                              Color(0xFF3B2A6B),
                              Color(0xFF241A45)
                            ]),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Row(children: [
                            const Icon(Icons.workspace_premium_rounded,
                                color: Color(0xFFFBBF24), size: 30),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(s.proOnlyBody,
                                  style: const TextStyle(
                                      fontSize: 12,
                                      height: 1.5,
                                      color: Colors.white)),
                            ),
                          ]),
                        ),

                      _sectionTitle(p, s.avatarFrameTitle, locked: !_isPro),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 108,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          physics: const BouncingScrollPhysics(),
                          children: [
                            _frameCell(p, '', s.noFrame, Icons.not_interested),
                            for (final f in ProPresets.avatarFrames)
                              _frameCell(p, f.$1, f.$2, null),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      _sectionTitle(p, s.themeTitle, locked: !_isPro),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 76,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          physics: const BouncingScrollPhysics(),
                          children: [
                            for (final t in ProPresets.profileThemes.entries)
                              _themeCell(p, t.key, t.value, fa),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      _sectionTitle(p, s.cardColorTitle, locked: !_isPro),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 44,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          physics: const BouncingScrollPhysics(),
                          children: [
                            for (final c in ProPresets.cardBgThemes.entries)
                              _cardCell(p, c.key, c.value),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),

                      _sectionTitle(p, s.coverTitle, locked: !_isPro),
                      const SizedBox(height: 8),
                      Row(children: [
                        Expanded(
                          child: _bigBtn(
                            p,
                            Icons.upload_rounded,
                            s.uploadCover,
                            enabled: _isPro && !_busy,
                            onTap: _uploadCover,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _bigBtn(
                            p,
                            Icons.delete_outline_rounded,
                            s.removeCover,
                            enabled: _isPro && !_busy,
                            danger: true,
                            onTap: () => _apply(() => ApiService.I.removeProfileCover()),
                          ),
                        ),
                      ]),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(Palette p, String label, {bool locked = false}) {
    return Row(children: [
      Text(label,
          style: TextStyle(
              fontSize: 12.5, fontWeight: FontWeight.w800, color: p.text)),
      const SizedBox(width: 6),
      if (locked)
        Icon(Icons.lock_outline_rounded, size: 13, color: const Color(0xFFF59E0B)),
    ]);
  }

  Widget _selectRing(bool selected, {Color? color}) => selected
      ? Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color ?? const Color(0xFF8B5CF6), width: 2),
          ),
          padding: const EdgeInsets.all(2),
          child: const SizedBox.expand(),
        )
      : const SizedBox.shrink();

  Widget _frameCell(Palette p, String key, String label, IconData? icon) {
    final selected = _frame == key;
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 10),
      child: GestureDetector(
        onTap: _busy
            ? null
            : () => _apply(() => ApiService.I.saveAvatarFrame(key),
                onSuccess: () => _frame = key),
        child: Opacity(
          opacity: _isPro || key.isEmpty ? 1 : 0.45,
          child: SizedBox(
            width: 84,
            child: Column(children: [
              Stack(children: [
                Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(
                    color: p.bgSoft,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  alignment: Alignment.center,
                  child: icon != null
                      ? Icon(icon, size: 24, color: p.text3)
                      : Padding(
                          padding: const EdgeInsets.all(6),
                          child: CachedNetworkImage(
                            imageUrl: ApiService.I
                                .absoluteUrl(ProPresets.frameUrl(key)),
                            fit: BoxFit.contain,
                            httpHeaders: {'Cookie': ApiService.I.cookieHeader},
                          ),
                        ),
                ),
                Positioned.fill(child: _selectRing(selected)),
                if (selected)
                  PositionedDirectional(
                    top: 4,
                    end: 4,
                    child: CircleAvatar(
                      radius: 8,
                      backgroundColor: Colors.white,
                      child: Icon(Icons.check_rounded,
                          size: 11, color: const Color(0xFF8B5CF6)),
                    ),
                  ),
              ]),
              const SizedBox(height: 5),
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 9.5, color: p.text2)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _themeCell(Palette p, String key, List<Color> colors, bool fa) {
    final selected = _theme == key;
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 10),
      child: GestureDetector(
        onTap: _busy
            ? null
            : () => _apply(() => ApiService.I.saveProfileTheme(key),
                onSuccess: () => _theme = key),
        child: Opacity(
          opacity: _isPro ? 1 : 0.45,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(children: [
                Container(
                  width: 110,
                  height: 44,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: colors),
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                Positioned.fill(child: _selectRing(selected, color: Colors.white)),
                if (selected)
                  PositionedDirectional(
                    top: 4,
                    end: 4,
                    child: CircleAvatar(
                        radius: 8,
                        backgroundColor: Colors.white,
                        child: Icon(Icons.check_rounded,
                            size: 11, color: Colors.black87)),
                  ),
              ]),
              const SizedBox(height: 4),
              Text(ProPresets.themeLabel(key, fa),
                  style: TextStyle(fontSize: 9.5, color: p.text2)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cardCell(Palette p, String key, Color color) {
    final selected = _card == key;
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 10),
      child: GestureDetector(
        onTap: _busy
            ? null
            : () => _apply(() => ApiService.I.saveCardColor(key),
                onSuccess: () => _card = key),
        child: Opacity(
          opacity: _isPro ? 1 : 0.45,
          child: Stack(children: [
            Container(
              width: 64,
              height: 44,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: p.border),
              ),
              alignment: Alignment.center,
              child: selected
                  ? const Icon(Icons.check_rounded,
                      color: Colors.white, size: 18)
                  : null,
            ),
            Positioned.fill(
                child:
                    _selectRing(selected, color: const Color(0xFF8B5CF6))),
          ]),
        ),
      ),
    );
  }

  Future<void> _uploadCover() async {
    final s = AppState.I.str;
    if (!_isPro) return _guardPro();
    try {
      final x = await ip.ImagePicker().pickImage(
          source: ip.ImageSource.gallery, maxWidth: 1600, imageQuality: 88);
      if (x == null) return;
      await _apply(() => ApiService.I.uploadProfileCover(x.path));
    } catch (_) {
      if (mounted) showRaviToast(context, s.error, icon: Icons.error_outline_rounded);
    }
  }

  Widget _bigBtn(Palette p, IconData icon, String label,
      {required bool enabled, bool danger = false, VoidCallback? onTap}) {
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          color: danger
              ? const Color(0xFFEF4444).withValues(alpha: .1)
              : p.accentSoft,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: danger
                  ? const Color(0xFFEF4444).withValues(alpha: .35)
                  : p.accent.withValues(alpha: .25)),
        ),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(14),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon,
                size: 18,
                color: danger ? const Color(0xFFEF4444) : p.accent),
            const SizedBox(width: 8),
            Text(label,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: danger ? const Color(0xFFEF4444) : p.accent)),
          ]),
        ),
      ),
    );
  }
}

/// Bio "document with lines" SVG-style icon (drawn, no asset needed).
class _BioIconPainter extends CustomPainter {
  final Color color;
  _BioIconPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.09
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    final r = Rect.fromLTWH(s * .12, s * .08, s * .76, s * .84);
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(r, Radius.circular(s * .14)));
    canvas.drawPath(path, stroke);
    // lines
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.09
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: .85);
    canvas.drawLine(Offset(s * .28, s * .38), Offset(s * .72, s * .38), line);
    canvas.drawLine(Offset(s * .28, s * .56), Offset(s * .72, s * .56), line);
    canvas.drawLine(Offset(s * .28, s * .74), Offset(s * .52, s * .74), line);
  }

  @override
  bool shouldRepaint(covariant _BioIconPainter old) => old.color != color;
}

/// v1.0.9 — Follow / Following / Follow-back pill used inside the followers
/// panel. Optimistic like the profile screen; toasts confirm the action.
class _FollowToggle extends StatefulWidget {
  final String username;
  final bool initialFollowing;
  final Palette p;
  const _FollowToggle({
    required this.username,
    required this.initialFollowing,
    required this.p,
  });

  @override
  State<_FollowToggle> createState() => _FollowToggleState();
}

class _FollowToggleState extends State<_FollowToggle> {
  late bool _following = widget.initialFollowing;
  bool _busy = false;

  Future<void> _toggle() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _following = !_following; // optimistic
    });
    final s = AppState.I.str;
    final r = await ApiService.I.setFollowing(widget.username, _following);
    if (!mounted) return;
    setState(() => _busy = false);
    if (r.ok) {
      showGlassToast(context,
          _following ? s.followedToast : s.unfollowedToast,
          icon: Icons.person_add_alt_rounded);
    } else {
      setState(() => _following = !_following); // roll back
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    return GestureDetector(
      onTap: _toggle,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: _following ? p.bgSoft : p.accent,
          borderRadius: BorderRadius.circular(12),
          border: _following
              ? Border.all(color: p.border)
              : null,
        ),
        child: _busy
            ? SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    color: _following ? p.text2 : Colors.white))
            : Text(
                _following
                    ? AppState.I.str.unfollow
                    : AppState.I.str.follow,
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    color: _following ? p.text2 : Colors.white),
              ),
      ),
    );
  }
}
