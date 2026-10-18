import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api_service.dart';
import '../../core/app_state.dart';
import '../../core/chat_controller.dart';
import '../../core/constants.dart';
import '../../core/i18n.dart';
import '../../core/models.dart';
import '../../core/socket_service.dart';
import '../widgets/common.dart';
import '../widgets/ravi_alerts.dart';
import 'user_profile_screen.dart';

/// v1.0.9 — Telegram-style group/channel info, rebuilt around the reference
/// screenshots:
///  • the ROOM PHOTO fills the top cover; scroll-up / pull-down stretches it
///    (zoom like Telegram) with the name + "N members, M online" on a glass
///    overlay pinned to the photo's bottom edge
///  • description card with an (i) icon + @handle + link chips
///  • Notifications row with a switch
///  • TABS: Members / Media / Links / Music — real content per tab
///  • member rows with OWNER / ADMIN (+custom title) tags on the trailing side
///  • promote panel with PERMISSION CHECKBOXES (change info, delete messages,
///    ban members, restrict members, add admins) + custom admin title
///  • slow mode picker + member permissions (only admins / media / gifs)
///  • NO "you are the owner" line (user hated it)
class GroupInfoScreen extends StatefulWidget {
  final String roomId;
  const GroupInfoScreen({super.key, required this.roomId});

  static Route route(String roomId) => PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 240),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (_, __, ___) => GroupInfoScreen(roomId: roomId),
        transitionsBuilder: (_, anim, __, child) => SlideTransition(
          position: Tween(begin: const Offset(0, 0.04), end: Offset.zero)
              .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
          child: FadeTransition(opacity: anim, child: child),
        ),
      );

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen>
    with SingleTickerProviderStateMixin {
  RoomInfo? _info;
  Map<String, dynamic>? _settings; // slow_mode / only_admins / perm_*
  List<String> _myPerms = const [];
  bool _loading = true;
  double _stretch = 0; // overscroll amount (0..1) for the photo zoom
  bool _muted = false;

  // tabs
  late final TabController _tabs =
      TabController(length: _isChannel ? 3 : 4, vsync: this);
  bool get _isChannel => (_info?.roomType ?? 'group') == 'channel';

  // derived content (from room history)
  List<Message> _media = [];
  List<Message> _music = [];
  List<String> _links = [];
  bool _contentLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final r = await ApiService.I.roomInfo(widget.roomId);
    if (!mounted) return;
    setState(() {
      _info = r.ok ? RoomInfo.fromJson(r.data!) : null;
      _settings = (r.data?['settings'] as Map?) == null
          ? null
          : Map<String, dynamic>.from(r.data!['settings']);
      _myPerms = ((r.data?['my_perms'] as List?) ?? const [])
          .map((e) => '$e')
          .toList();
      _muted = r.data?['is_muted'] == true;
      _loading = false;
    });
    _loadContent();
  }

  /// Derive media / music / links from the room history (2 pages).
  Future<void> _loadContent() async {
    setState(() => _contentLoading = true);
    final msgs = <Message>[];
    final first = await ApiService.I.roomMessages(widget.roomId, limit: 100);
    if (first.ok && first.data != null) msgs.addAll(first.data!);
    if (msgs.length >= 100) {
      final second =
          await ApiService.I.roomMessages(widget.roomId, before: msgs.first.id, limit: 100);
      if (second.ok && second.data != null) msgs.addAll(second.data!);
    }
    final media = <Message>[];
    final music = <Message>[];
    final links = <String>[];
    final linkRe = RegExp(r'https?://\S+|www\.\S+|t\.me/\S+');
    for (final m in msgs) {
      if ((m.fileType == 'image' || m.fileType == 'video' || m.fileType == 'gif') &&
          m.fileUrl.isNotEmpty) {
        media.add(m);
      } else if (m.fileType == 'audio' && m.fileUrl.isNotEmpty) {
        music.add(m);
      }
      for (final match in linkRe.allMatches(m.text)) {
        final l = match.group(0)!;
        if (!links.contains(l)) links.add(l);
      }
    }
    if (!mounted) return;
    setState(() {
      _media = media.reversed.toList();
      _music = music.reversed.toList();
      _links = links;
      _contentLoading = false;
    });
  }

  bool get _canManage {
    final role = _info?.myRole ?? 'member';
    return role == 'owner' || role == 'admin';
  }

  bool get _isOwner => _info?.myRole == 'owner';

  bool _hasPerm(String p) =>
      _isOwner || _myPerms.contains(p) || _myPerms.contains('all');

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;

    return Scaffold(
      backgroundColor: p.bg,
      body: _loading
          ? Center(
              child: CircularProgressIndicator(strokeWidth: 2, color: p.accent))
          : _info == null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.group_off_outlined, size: 40, color: p.text3),
                      const SizedBox(height: 12),
                      Text(s.serverUnreachable,
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12.5, color: p.text2)),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: () {
                          setState(() => _loading = true);
                          _load();
                        },
                        child: Text(s.retry),
                      ),
                    ],
                  ),
                )
              : NotificationListener<OverscrollNotification>(
                  onNotification: (n) {
                    // v1.0.9 — pull down => the cover photo ZOOMS (Telegram)
                    if (n.overscroll < 0) {
                      setState(() {
                        _stretch = (_stretch - n.overscroll / 200).clamp(0.0, 1.0);
                      });
                      return true;
                    }
                    if (_stretch > 0) setState(() => _stretch = 0);
                    return false;
                  },
                  child: DefaultTabController(
                    length: _tabs.length,
                    child: NestedScrollView(
                      headerSliverBuilder: (ctx, innerBoxScrolled) => [
                        _coverBar(p, s),
                        SliverPersistentHeader(
                          pinned: true,
                          delegate: _TabsDelegate(
                            bg: p.bg,
                            tabs: [
                              Tab(text: _isChannel ? s.subscribers : s.tabMembers),
                              const Tab(text: ''),
                              const Tab(text: ''),
                              if (!_isChannel) const Tab(text: ''),
                            ],
                            child: TabBar(
                              controller: _tabs,
                              isScrollable: true,
                              tabAlignment: TabAlignment.start,
                              labelColor: p.accent,
                              unselectedLabelColor: p.text2,
                              indicatorColor: p.accent,
                              dividerColor: Colors.transparent,
                              labelStyle: const TextStyle(
                                  fontSize: 12.5, fontWeight: FontWeight.w800),
                              unselectedLabelStyle: const TextStyle(
                                  fontSize: 12.5, fontWeight: FontWeight.w600),
                              tabs: [
                                Tab(text: _isChannel ? s.subscribers : s.tabMembers),
                                Tab(text: s.tabMedia),
                                Tab(text: s.tabLinks),
                                if (!_isChannel) Tab(text: s.tabMusic),
                              ],
                            ),
                          ),
                        ),
                      ],
                      body: TabBarView(
                        controller: _tabs,
                        children: [
                          _membersTab(p, s),
                          _mediaTab(p, s),
                          _linksTab(p, s),
                          if (!_isChannel) _musicTab(p, s),
                        ],
                      ),
                    ),
                  ),
                ),
    );
  }

  // ================= stretching cover =================
  Widget _coverBar(Palette p, S s) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final zoom = 1.0 + 0.8 * _stretch;
    final online = _info!.members.where((m) => _onlineNow(m.username)).length;
    return SliverAppBar(
      expandedHeight: 250 + 40 * _stretch,
      pinned: true,
      stretch: true,
      stretchTriggerOffset: 90,
      backgroundColor: dark ? C.pfBgD : C.bgL,
      surfaceTintColor: Colors.transparent,
      leadingWidth: 54,
      leading: Padding(
        padding: const EdgeInsetsDirectional.only(start: 8),
        child: Center(child: _glassBtn(context, Icons.close_rounded,
            () => Navigator.of(context).pop())),
      ),
      actions: [
        if (_canManage)
          _glassBtn(context, Icons.settings_rounded, () => _manageSheet(p, s)),
        const SizedBox(width: 8),
      ],
      flexibleSpace: LayoutBuilder(
        builder: (ctx, cons) {
          return FlexibleSpaceBar(
            stretchModes: const [
              StretchMode.zoomBackground,
              StretchMode.blurBackground,
            ],
            background: Stack(
              fit: StackFit.expand,
              children: [
                // the photo — fills the whole cover and zooms on stretch
                Transform.scale(
                  scale: zoom,
                  child: _avatarImg(p, full: true),
                ),
                // bottom readability scrim
                Positioned(
                  left: 0, right: 0, bottom: 0,
                  child: Container(
                    height: 120,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: .45),
                        ],
                      ),
                    ),
                  ),
                ),
                // name + counts on a glass pill pinned near the photo bottom
                Positioned(
                  left: 0, right: 0, bottom: 42,
                  child: Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 9),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: .30),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                                color: Colors.white.withValues(alpha: .28)),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_info!.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 16 + 4 * _stretch,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.white)),
                              const SizedBox(height: 2),
                              Text(
                                _isChannel
                                    ? s.subscribersCount(_info!.memberCount)
                                    : s.membersWithOnline(
                                        _info!.memberCount, online),
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white.withValues(alpha: .85)),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  final Set<String> _liveOnline = {};

  bool _onlineNow(String username) {
    SocketService.I;
    return _liveOnline.contains(username) ||
        _info!.members
            .where((m) => m.username == username)
            .any((m) => m.online);
  }

  // ================= tabs =================

  Widget _membersTab(Palette p, S s) {
    if (_info!.membersHidden) {
      return Center(
          child: Text(
              AppState.I.lang.value.isFa ? 'اعضا مخفی شده‌اند' : 'Members are hidden',
              style: TextStyle(fontSize: 12, color: p.text3)));
    }
    return RefreshIndicator(
      color: p.accent,
      onRefresh: _load,
      child: ListView.builder(
        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        padding: const EdgeInsets.only(top: 4, bottom: 40),
        itemCount: _info!.members.length,
        itemBuilder: (ctx, i) => _memberRow(p, s, _info!.members[i]),
      ),
    );
  }

  Widget _mediaTab(Palette p, S s) {
    if (_contentLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_media.isEmpty) {
      return _emptyTab(p, Icons.photo_outlined, s.noMediaYet);
    }
    return GridView.builder(
      physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      padding: const EdgeInsets.all(3),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 3,
        crossAxisSpacing: 3,
      ),
      itemCount: _media.length,
      itemBuilder: (ctx, i) {
        final m = _media[i];
        final url = ApiService.I.absoluteUrl(m.fileUrl);
        return GestureDetector(
          onTap: () {},
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Stack(fit: StackFit.expand, children: [
              CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                memCacheWidth: 240,
                httpHeaders: {'Cookie': ApiService.I.cookieHeader},
                errorWidget: (_, __, ___) =>
                    ColoredBox(color: p.bgSoft, child:
                        Icon(m.fileType == 'video'
                            ? Icons.play_circle_outline_rounded
                            : Icons.image_outlined,
                            color: p.text3)),
              ),
              if (m.fileType == 'video' || m.fileType == 'gif')
                const Center(
                  child: Icon(Icons.play_arrow_rounded,
                      size: 30, color: Colors.white70),
                ),
            ]),
          ),
        );
      },
    );
  }

  Widget _linksTab(Palette p, S s) {
    if (_contentLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_links.isEmpty) {
      return _emptyTab(p, Icons.link_rounded, s.noLinksYet);
    }
    return ListView.builder(
      physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      padding: const EdgeInsets.only(top: 6, bottom: 40),
      itemCount: _links.length,
      itemBuilder: (ctx, i) => ListTile(
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: p.accentSoft,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(Icons.link_rounded, size: 18, color: p.accent),
        ),
        title: Text(_links[i],
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: p.accent)),
        subtitle: Text(s.linkLabel,
            style: TextStyle(fontSize: 10.5, color: p.text3)),
        onTap: () async {
          await Clipboard.setData(ClipboardData(text: _links[i]));
          if (mounted) showGlassToast(context, AppState.I.str.copied);
        },
      ),
    );
  }

  Widget _musicTab(Palette p, S s) {
    if (_contentLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_music.isEmpty) {
      return _emptyTab(p, Icons.music_note_rounded, s.noMusicYet);
    }
    return ListView.builder(
      physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      padding: const EdgeInsets.only(top: 6, bottom: 40),
      itemCount: _music.length,
      itemBuilder: (ctx, i) {
        final m = _music[i];
        return ListTile(
          leading: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              gradient: C.ownBubbleGrad,
              borderRadius: BorderRadius.circular(11),
            ),
            child: const Icon(Icons.music_note_rounded,
                size: 19, color: Colors.white),
          ),
          title: Text(m.text.isEmpty ? s.voiceMessageLabel : m.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: p.text)),
          subtitle: Text('${m.authorLabel} · ${m.time}',
              style: TextStyle(fontSize: 10.5, color: p.text3)),
        );
      },
    );
  }

  Widget _emptyTab(Palette p, IconData icon, String label) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 34, color: p.text3),
          const SizedBox(height: 10),
          Text(label, style: TextStyle(fontSize: 12, color: p.text3)),
        ],
      ),
    );
  }

  // ================= member row =================
  Widget _memberRow(Palette p, S s, RoomMember m) {
    final online = _onlineNow(m.username);
    return InkWell(
      onTap: () => Navigator.of(context, rootNavigator: true)
          .push(UserProfileScreen.route(m.username)),
      onLongPress: _canManage && !m.isOwner && m.id > 0
          ? () => _memberMenu(p, s, m)
          : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(children: [
          Stack(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: ApiService.I.avatarUrl(m.avatar).isNotEmpty
                    ? null
                    : LinearGradient(colors: C
                        .avatarGradients[
                            m.username.hashCode.abs() % C.avatarGradients.length]
                        .toList()),
              ),
              child: ApiService.I.avatarUrl(m.avatar).isNotEmpty
                  ? ClipOval(
                      child: CachedNetworkImage(
                        imageUrl: ApiService.I.avatarUrl(m.avatar),
                        fit: BoxFit.cover,
                        memCacheWidth: 96,
                        httpHeaders: {'Cookie': ApiService.I.cookieHeader},
                        errorWidget: (_, __, ___) => Center(
                          child: Text(
                              m.username.isNotEmpty
                                  ? m.username[0].toUpperCase()
                                  : '?',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800)),
                        ),
                      ),
                    )
                  : Center(
                      child: Text(
                          m.username.isNotEmpty
                              ? m.username[0].toUpperCase()
                              : '?',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800)),
                    ),
            ),
            if (online)
              PositionedDirectional(
                bottom: 0,
                end: 0,
                child: Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                    color: C.onlinePurple,
                    shape: BoxShape.circle,
                    border: Border.all(color: p.bg, width: 2),
                  ),
                ),
              ),
          ]),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(
                      m.name.isNotEmpty ? m.name : m.username,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: p.text),
                    ),
                  ),
                  // v1.0.9 — Pro star ON THE NAME (like the blue check)
                  if (m.isPro) ...[
                    const SizedBox(width: 4),
                    const ProStarBadge(size: 12, animate: false),
                  ],
                ]),
                const SizedBox(height: 1),
                Text(
                  online
                      ? s.online
                      : '@${m.username}',
                  textDirection: TextDirection.ltr,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 10.5,
                      color: online ? C.onlinePurple : p.text3),
                ),
              ],
            ),
          ),
          // v1.0.9 — trailing role tag (OWNER / ADMIN / custom title) exactly
          // like the reference screenshot ("HEAD DEV ★" on the right side)
          if (m.isOwner)
            _roleTag(p, s.owner.toUpperCase(), const Color(0xFFF59E0B), star: true)
          else if (m.isRoomAdmin)
            _roleTag(p,
                (m.adminTitle.isNotEmpty ? m.adminTitle : s.roomAdmin).toUpperCase(),
                p.accent,
                star: true),
          if (_canManage && !m.isOwner && m.id > 0)
            GestureDetector(
              onTap: () => _memberMenu(p, s, m),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(Icons.more_vert_rounded,
                    size: 17, color: p.text3),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _roleTag(Palette p, String label, Color color, {bool star = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (star) ...[
          Icon(Icons.star_rounded, size: 11, color: color),
          const SizedBox(width: 2),
        ],
        Flexible(
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 8.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: .4,
                  color: color)),
        ),
      ]),
    );
  }

  // ================= manage sheet (owner/admin) =================
  void _manageSheet(Palette p, S s) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _ManageSheet(
        info: _info!,
        settings: _settings ?? const {},
        p: p,
        onSaved: _load,
      ),
    );
  }

  // ================= member admin panel =================
  void _memberMenu(Palette p, S s, RoomMember m) {
    HapticFeedback.mediumImpact();
    final dark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _MemberAdminSheet(
        member: m,
        roomId: widget.roomId,
        p: p,
        dark: dark,
        isOwner: _isOwner,
        existingTitle: m.adminTitle,
        onDone: _load,
      ),
    );
  }

  // ================================================================ widgets

  Widget _avatarImg(Palette p, {bool full = false}) {
    final url = ApiService.I.avatarUrl(_info!.avatar);
    if (url.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: url,
        fit: full ? BoxFit.cover : BoxFit.cover,
        memCacheWidth: full ? 720 : 300,
        httpHeaders: {'Cookie': ApiService.I.cookieHeader},
      );
    }
    return Container(
      decoration: const BoxDecoration(gradient: C.crAvatarGrad),
      alignment: Alignment.center,
      child: Text(
          _info!.name.isEmpty ? 'R' : _info!.name[0].toUpperCase(),
          style: const TextStyle(
              color: Colors.white,
              fontSize: 46,
              fontWeight: FontWeight.w800)),
    );
  }

  Widget _glassBtn(BuildContext context, IconData icon, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.all(4),
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: .24),
                shape: BoxShape.circle,
                border: Border.all(
                    color: Colors.white.withValues(alpha: .2)),
              ),
              child: Icon(icon, size: 18, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

// ================= tab-bar pin delegate =================
class _TabsDelegate extends SliverPersistentHeaderDelegate {
  final Color bg;
  final List<Tab> tabs;
  final TabBar child;
  _TabsDelegate({required this.bg, required this.tabs, required this.child});

  @override
  double get minExtent => 44;
  @override
  double get maxExtent => 44;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return ColoredBox(color: bg, child: SizedBox(height: 44, child: child));
  }

  @override
  bool shouldRebuild(covariant _TabsDelegate old) => old.bg != bg;
}

// ================= bottom sheet: room management =================
class _ManageSheet extends StatefulWidget {
  final RoomInfo info;
  final Map<String, dynamic> settings;
  final Palette p;
  final VoidCallback onSaved;
  const _ManageSheet({
    required this.info,
    required this.settings,
    required this.p,
    required this.onSaved,
  });

  @override
  State<_ManageSheet> createState() => _ManageSheetState();
}

class _ManageSheetState extends State<_ManageSheet> {
  late bool _onlyAdmins = widget.settings['only_admins'] == true;
  late bool _sendMedia = widget.settings['perm_send_media'] != false;
  late bool _sendGifs = widget.settings['perm_send_gifs'] != false;
  late int _slow = (widget.settings['slow_mode'] ?? 0) is int
      ? widget.settings['slow_mode'] as int
      : int.tryParse('${widget.settings['slow_mode']}') ?? 0;
  bool _busy = false;

  static const List<(int, String)> _slowChoices = [
    (0, 'off'), (10, '10s'), (30, '30s'), (60, '1m'), (300, '5m'),
    (900, '15m'), (3600, '1h'),
  ];

  Future<void> _save() async {
    if (widget.info.roomType == 'channel') return;
    setState(() => _busy = true);
    final s = AppState.I.str;
    await ApiService.I.setSlowMode(widget.info.roomId, _slow);
    await ApiService.I.setRoomPerms(widget.info.roomId,
        onlyAdmins: _onlyAdmins, sendMedia: _sendMedia, sendGifs: _sendGifs);
    if (!mounted) return;
    setState(() => _busy = false);
    showGlassToast(context, s.saved, icon: Icons.check_circle_rounded);
    widget.onSaved();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.I.str;
    final p = widget.p;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
      child: Container(
        color: p.bgCard,
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: p.border,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(s.adminRights,
                style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w800,
                    color: p.text)),
            const SizedBox(height: 16),
            // slow mode
            Text(s.slowMode,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: p.text2)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                for (final c in _slowChoices)
                  GestureDetector(
                    onTap: () => setState(() => _slow = c.$1),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        color: _slow == c.$1
                            ? p.accent.withValues(alpha: .16)
                            : p.bgSoft,
                        borderRadius: BorderRadius.circular(11),
                        border: Border.all(
                            color: _slow == c.$1
                                ? p.accent
                                : Colors.transparent,
                            width: 1.3),
                      ),
                      child: Text(
                        c.$2 == 'off'
                            ? s.slowModeOff
                            : c.$2 == 'off'
                                ? ''
                                : c.$2,
                        style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: _slow == c.$1 ? p.accent : p.text2),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            _switchRow(p, s.onlyAdminsPost, _onlyAdmins, (v) {
              setState(() => _onlyAdmins = v);
              if (v) {
                setState(() {
                  _sendMedia = true;
                  _sendGifs = true;
                });
              }
            }),
            if (!_onlyAdmins) ...[
              _switchRow(p, s.permsSendMedia, _sendMedia,
                  (v) => setState(() => _sendMedia = v)),
              _switchRow(p, s.permsSendGifs, _sendGifs,
                  (v) => setState(() => _sendGifs = v)),
            ],
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: p.accent,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: _busy ? null : _save,
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text(s.saveChanges,
                        style: const TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w800)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _switchRow(Palette p, String label, bool v, ValueChanged<bool> on) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Expanded(
          child: Text(label,
              style: TextStyle(
                  fontSize: 12.8,
                  fontWeight: FontWeight.w600,
                  color: p.text)),
        ),
        Switch(
          value: v,
          activeColor: p.accent,
          onChanged: on,
        ),
      ]),
    );
  }
}

// ================= bottom sheet: member admin (promote / edit / ban) ======
class _MemberAdminSheet extends StatefulWidget {
  final RoomMember member;
  final String roomId;
  final Palette p;
  final bool dark;
  final bool isOwner;
  final String existingTitle;
  final VoidCallback onDone;

  const _MemberAdminSheet({
    required this.member,
    required this.roomId,
    required this.p,
    required this.dark,
    required this.isOwner,
    required this.existingTitle,
    required this.onDone,
  });

  @override
  State<_MemberAdminSheet> createState() => _MemberAdminSheetState();
}

class _MemberAdminSheetState extends State<_MemberAdminSheet> {
  late final TextEditingController _title =
      TextEditingController(text: widget.existingTitle);
  late final Map<String, bool> _perms = {
    'change_info': true,
    'delete_messages': true,
    'ban_members': true,
    'restrict_members': false,
    'promote': false,
  };
  bool _busy = false;

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);
    final s = AppState.I.str;
    final chosen =
        _perms.entries.where((e) => e.value).map((e) => e.key).toList();
    final ApiResult<bool> res;
    if (widget.member.isRoomAdmin) {
      res = await ApiService.I.editAdmin(widget.roomId, widget.member.id,
          title: _title.text.trim(), permissions: chosen);
    } else {
      res = await ApiService.I.promoteAdvanced(widget.roomId, widget.member.id,
          title: _title.text.trim(), permissions: chosen);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (res.ok) {
      showGlassToast(context, s.adminSaved, icon: Icons.shield_rounded);
      widget.onDone();
      Navigator.of(context).pop();
    } else {
      showGlassToast(context, s.error,
          icon: Icons.error_outline_rounded, color: const Color(0xFFEF4444));
    }
  }

  Future<void> _ban() async {
    final s = AppState.I.str;
    final ok = await showRaviModal(
      context,
      icon: Icons.block_rounded,
      iconColor: const Color(0xFFEF4444),
      title: s.banMember,
      body: s.bannedMemberToast(
          widget.member.name.isNotEmpty ? widget.member.name : widget.member.username),
      okText: s.banMember,
      cancelText: s.cancel,
      danger: true,
    );
    if (!ok) return;
    final r =
        await ApiService.I.banRoomMember(widget.roomId, widget.member.id);
    if (!mounted) return;
    if (r.ok) {
      showGlassToast(context, s.bannedMemberToast(widget.member.username),
          icon: Icons.block_rounded, color: const Color(0xFFEF4444));
      widget.onDone();
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.I.str;
    final p = widget.p;
    final m = widget.member;
    final isEditing = m.isRoomAdmin;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
      child: Container(
        color: p.bgCard,
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: p.border,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: p.accentSoft,
                backgroundImage: ApiService.I.avatarUrl(m.avatar).isNotEmpty
                    ? CachedNetworkImageProvider(
                        ApiService.I.avatarUrl(m.avatar),
                        headers: {'Cookie': ApiService.I.cookieHeader})
                    : null,
                child: ApiService.I.avatarUrl(m.avatar).isNotEmpty
                    ? null
                    : Text(m.username.isNotEmpty ? m.username[0].toUpperCase() : '?',
                        style: TextStyle(
                            fontWeight: FontWeight.w800, color: p.accent)),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.name.isNotEmpty ? m.name : m.username,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: p.text)),
                    Text('@${m.username}',
                        textDirection: TextDirection.ltr,
                        style: TextStyle(fontSize: 11, color: p.text3)),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 14),
            Text(isEditing ? s.edit : s.promoteTitle,
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: p.text)),
            const SizedBox(height: 2),
            Text(s.promoteSub,
                style: TextStyle(fontSize: 11, color: p.text3)),
            const SizedBox(height: 12),
            // admin title
            TextField(
              controller: _title,
              style: TextStyle(fontSize: 13, color: p.text),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: p.bgSoft,
                hintText: s.adminTitleHint,
                hintStyle: TextStyle(fontSize: 12, color: p.text3),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 12),
            // permission checkboxes
            _permRow(p, s.permChangeInfo, 'change_info'),
            _permRow(p, s.permDeleteMessages, 'delete_messages'),
            _permRow(p, s.permBanMembers, 'ban_members'),
            _permRow(p, s.permRestrict, 'restrict_members'),
            _permRow(p, s.permPromote, 'promote'),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: SizedBox(
                  height: 46,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFEF4444)
                          .withValues(alpha: .12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: _ban,
                    child: Text(s.banMember,
                        style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFFEF4444))),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: SizedBox(
                  height: 46,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: p.accent,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: _busy ? null : _save,
                    child: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : Text(s.saveChanges,
                            style: const TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w800)),
                  ),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _permRow(Palette p, String label, String key) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _perms[key] = !_perms[key]!),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 130),
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              color: _perms[key]! ? p.accent : Colors.transparent,
              border: Border.all(
                  color: _perms[key]! ? p.accent : p.text3.withValues(alpha: .5),
                  width: 1.6),
            ),
            child: _perms[key]!
                ? const Icon(Icons.check_rounded,
                    size: 14, color: Colors.white)
                : null,
          ),
          const SizedBox(width: 11),
          Text(label,
              style: TextStyle(
                  fontSize: 12.6,
                  fontWeight: FontWeight.w600,
                  color: p.text)),
        ]),
      ),
    );
  }
}
