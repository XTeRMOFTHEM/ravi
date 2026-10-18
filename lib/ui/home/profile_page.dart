import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart' as ip;

import '../../core/api_service.dart';
import '../../core/app_state.dart';
import '../../core/constants.dart';
import '../../core/i18n.dart';
import '../../core/models.dart';
import '../chat/photo_viewer.dart';
import '../widgets/common.dart';
import 'settings_page.dart';
import 'user_profile_screen.dart';

/// Profile page — 1:1 with index.html `page-profile` (pp-* classes):
/// 300px cover, avatar overlapping -70px, stats row, tabs, quick actions.
///
/// v1.0.2: now actually FETCHES /api/user_profile/<username> (bio, real
/// follower/following counts, pro/verified/admin badges, join date, custom
/// cover) and every quick action works: Edit profile (name/bio/avatar via
/// /edit_profile), Blocked users (/my_blocks + unblock), Logout.
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage>
    with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  @override
  bool get wantKeepAlive => true;

  late final TabController _tabs = TabController(length: 3, vsync: this);
  Map<String, dynamic>? _prof;
  bool _loading = true;
  int _avatarBust = 0;

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

  String get _username {
    final u = ApiService.I.cachedUsername;
    if (u.isNotEmpty) return u;
    return AppState.I.me.value.username;
  }

  Future<void> _load() async {
    final me = _username;
    if (me.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final r = await ApiService.I.userProfile(me);
    if (!mounted) return;
    setState(() {
      _prof = r.ok ? r.data : null;
      _loading = false;
    });
  }

  String _p(String key, [String fallback = '']) =>
      '${_prof?[key] ?? fallback}';

  int _asInt(dynamic v) {
    if (v is int) return v;
    return int.tryParse('$v') ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;
    final me = ApiService.I.me();
    final displayName = _p('name').isNotEmpty ? _p('name') : (me.name.isEmpty ? me.username : me.name);
    final followers = _asInt(_prof?['followers']);
    final following = _asInt(_prof?['following']);
    final isPro = _prof?['is_pro'] == true;
    final isVerified = _prof?['is_verified'] == true;
    final isAdmin = _prof?['is_admin'] == true;
    final bio = _p('bio');
    final hasCover = _prof?['has_cover'] == true && _p('profile_cover').isNotEmpty;
    final avatarName = _p('avatar').isNotEmpty ? _p('avatar') : me.avatar;
    final frameUrl = _p('avatar_frame_url');

    return RefreshIndicator(
      color: p.accent,
      onRefresh: () async {
        setState(() => _loading = true);
        await _load();
      },
      child: ListView(
        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        padding: const EdgeInsets.only(bottom: 110),
        children: [
          // ---------- cover ----------
          // v1.0.5: NO overlay shadow on the banner (user request) — the
          // cover renders clean in both light and dark mode.
          Container(
            height: 300,
            width: double.infinity,
            color: p.pfCard,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (hasCover)
                  GestureDetector(
                    onTap: () => openMediaViewer(context,
                        fileUrl: _p('profile_cover'), title: _username),
                    child: CachedNetworkImage(
                      imageUrl: ApiService.I.absoluteUrl(_p('profile_cover')),
                      fit: BoxFit.cover,
                      memCacheWidth: 720,
                      httpHeaders: {'Cookie': ApiService.I.cookieHeader},
                      errorWidget: (_, __, ___) => _defaultCover(p),
                    ),
                  )
                else
                  _defaultCover(p),
              ],
            ),
          ),

          // ---------- header (avatar + name) ----------
          Transform.translate(
            offset: const Offset(0, -70),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // avatar + Pro frame (v1.0.7: 2× like the web .pp-frame)
                  GestureDetector(
                    onTap: () {
                      final url = ApiService.I.avatarUrl(avatarName);
                      if (url.isNotEmpty) {
                        openMediaViewer(context, fileUrl: url, title: _username);
                      }
                    },
                    child: FrameAvatar(
                      key: ValueKey('fa-$_avatarBust'),
                      name: displayName,
                      avatarPath: avatarName,
                      frameUrl: frameUrl,
                      size: 120,
                    ),
                  ),
                  SizedBox(width: frameUrl.isNotEmpty ? 34 : 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Flexible(
                              child: Text(displayName,
                                  maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 20, fontWeight: FontWeight.w800,
                                      color: p.pfName)),
                            ),
                            if (isVerified) ...[
                              const SizedBox(width: 5),
                              Icon(Icons.verified_rounded,
                                  size: 17, color: const Color(0xFF38BDF8)),
                            ],
                            // v1.0.9 — the animated Pro star sits NEXT TO THE
                            // NAME (like the blue check), never in the tags.
                            if (isPro) ...[
                              const SizedBox(width: 5),
                              ProStarBadge(size: 19),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text('@$_username',
                            style: TextStyle(fontSize: 14,
                                fontWeight: FontWeight.w500, color: p.pfHandle)),
                        const SizedBox(height: 7),
                        if (isAdmin)
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              _chip(p, s.adminLabel, const Color(0xFFEF4444)),
                            ],
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ---------- stats (real values) ----------
          Transform.translate(
            offset: const Offset(0, -50),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  _stat(p, '0', s.posts),
                  _divider(p),
                  _statTap(p, '$followers', s.followers, () => _openFollowList(true)),
                  _divider(p),
                  _statTap(p, '$following', s.following, () => _openFollowList(false)),
                ],
              ),
            ),
          ),

          // ---------- bio card (real bio) ----------
          Transform.translate(
            offset: const Offset(0, -38),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: p.pfCard,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: p.pfCardBorder),
                ),
                child: _loading
                    ? Row(
                        children: [
                          SizedBox(width: 14, height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2, color: p.text3)),
                          const SizedBox(width: 10),
                          Text('…', style: TextStyle(fontSize: 14, color: p.text3)),
                        ],
                      )
                    : Text(bio.isEmpty ? s.noBio : bio,
                        style: TextStyle(fontSize: 14, height: 1.6, color: p.text)),
              ),
            ),
          ),

          // ---------- tabs ----------
          Transform.translate(
            offset: const Offset(0, -26),
            child: Column(
              children: [
                TabBar(
                  controller: _tabs,
                  indicatorColor: Colors.transparent,
                  dividerColor: Colors.transparent,
                  labelColor: p.text,
                  unselectedLabelColor: p.pfMeta,
                  labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                  unselectedLabelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  indicatorSize: TabBarIndicatorSize.tab,
                  tabs: [
                    Tab(text: s.tabPosts, height: 44),
                    Tab(text: s.tabAbout, height: 44),
                    Tab(text: s.tabProjects, height: 44),
                  ],
                ),
                SizedBox(
                  height: 190,
                  child: TabBarView(
                    controller: _tabs,
                    children: [
                      _empty(p, Icons.auto_awesome_outlined, s.nothingHere, s.shareFirstPost),
                      _about(p, s),
                      _empty(p, Icons.folder_outlined, s.nothingHere, s.stayTuned),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // ---------- quick actions (all wired) ----------
          Transform.translate(
            offset: const Offset(0, -26),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                children: [
                  ListRow(
                    icon: Icons.edit_outlined,
                    title: s.editProfile,
                    sub: s.editProfileSub,
                    trailing: Icon(Icons.chevron_right_rounded, size: 17, color: p.text3),
                    onTap: _openEditSheet,
                  ),
                  ListRow(
                    icon: Icons.style_outlined,
                    title: s.customizeProfile,
                    sub: s.customizeProfileSub,
                    trailing: Icon(Icons.chevron_right_rounded, size: 17, color: p.text3),
                    onTap: () => CustomizeProfileSheet.show(context).then((_) {
                      // v1.0.7: reload on EVERY close — the sheet no longer
                      // pops with a value, so "applied but unchanged UI" is
                      // impossible now.
                      if (mounted) {
                        AppState.I.refreshIdentity();
                        _load();
                        setState(() => _avatarBust++);
                      }
                    }),
                  ),
                  ListRow(
                    icon: Icons.block_outlined,
                    title: s.blockedUsers,
                    sub: s.blockedUsersSub,
                    trailing: Icon(Icons.chevron_right_rounded, size: 17, color: p.text3),
                    onTap: _openBlockedSheet,
                  ),
                  ListRow(
                    icon: Icons.logout_rounded,
                    title: s.logout,
                    sub: s.logoutSub,
                    danger: true,
                    trailing: Icon(Icons.chevron_right_rounded, size: 17, color: p.text3),
                    onTap: () => confirmLogout(context),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- actions ----------

  Future<void> _openEditSheet() async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _EditProfileSheet(current: _prof ?? const {}),
    );
    if (changed == true && mounted) {
      AppState.I.refreshIdentity();
      await _load();
      setState(() => _avatarBust++);
    }
  }

  Future<void> _openBlockedSheet() async {
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _BlockedSheet(),
    );
  }

  // ---------- helpers ----------

  Widget _defaultCover(Palette p) {
    // v1.0.9 — no banner => NO purple gradient. The cover area is simply the
    // card color (black in dark mode / white in light mode), like the web
    // profile card without a custom cover.
    return ColoredBox(color: p.pfCard);
  }

  Widget _chip(Palette p, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: color.withValues(alpha: .4)),
      ),
      child: Text(label,
          textDirection: TextDirection.ltr,
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800,
              letterSpacing: .5, color: color)),
    );
  }

  Widget _letterAvatar(RaviUser user, double size) {
    final initial = user.username.isEmpty
        ? 'R'
        : String.fromCharCode(user.username.runes.first).toUpperCase();
    return Container(
      width: size, height: size,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF4DB2E8), Color(0xFF1686C7)],
        ),
      ),
      alignment: Alignment.center,
      child: Text(initial,
          style: TextStyle(color: Colors.white, fontSize: size * 0.26,
              fontWeight: FontWeight.w800)),
    );
  }

  Widget _stat(Palette p, String value, String label) {
    return Expanded(
      child: Column(
        children: [
          Text(value,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800,
                  color: p.text)),
          const SizedBox(height: 3),
          Text(label,
              style: TextStyle(fontSize: 9, color: p.text3,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _statTap(Palette p, String value, String label, VoidCallback onTap) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Column(
          children: [
            Text(value,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800,
                    color: p.text)),
            const SizedBox(height: 3),
            Text(label,
                style: TextStyle(fontSize: 9, color: p.text3,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Future<void> _openFollowList(bool followers) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FollowListSheet(username: _username, followers: followers),
    );
  }

  Widget _divider(Palette p) => Container(width: 1, height: 26, color: p.pfDivider);

  Widget _empty(Palette p, IconData icon, String title, String sub) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 30, color: p.text3),
          const SizedBox(height: 10),
          Text(title, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: p.text)),
          const SizedBox(height: 4),
          Text(sub, style: TextStyle(fontSize: 11, color: p.text2)),
        ],
      ),
    );
  }

  Widget _about(Palette p, S s) {
    final me = ApiService.I.me();
    final joined = _p('created_at', '—');
    final bio = _p('bio');
    final rows = [
      (s.name, _p('name').isNotEmpty ? _p('name') : (me.name.isEmpty ? me.username : me.name)),
      (s.username, '@$_username'),
      (s.bioLabel, bio.isEmpty ? '—' : bio),
      (s.joinedLabel, joined),
    ];
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
      children: [
        for (final r in rows)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: p.pfCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: p.pfCardBorder),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              textDirection: TextDirection.ltr,
              children: [
                SizedBox(
                  width: 86,
                  child: Text(r.$1,
                      style: TextStyle(fontSize: 11, color: p.pfMeta,
                          fontWeight: FontWeight.w600)),
                ),
                Expanded(
                  child: Text(r.$2,
                      textAlign: TextAlign.right,
                      style: TextStyle(fontSize: 12.5, color: p.text,
                          fontWeight: FontWeight.w500)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ==================== Edit profile bottom sheet ====================

class _EditProfileSheet extends StatefulWidget {
  final Map<String, dynamic> current;
  const _EditProfileSheet({required this.current});

  @override
  State<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends State<_EditProfileSheet> {
  late final TextEditingController _name =
      TextEditingController(text: '${widget.current['name'] ?? ''}');
  late final TextEditingController _bio =
      TextEditingController(text: '${widget.current['bio'] ?? ''}');
  late final TextEditingController _username =
      TextEditingController(text: '${widget.current['username'] ?? ''}');
  String _avatarPath = '';
  bool _busy = false;

  // v1.0.5: live username availability check
  Timer? _checkDebounce;
  String _checkState = ''; // '' | 'checking' | 'ok' | 'taken' | 'invalid'

  bool get _dark => Theme.of(context).brightness == Brightness.dark;

  @override
  void dispose() {
    _checkDebounce?.cancel();
    super.dispose();
  }

  void _onUsernameChanged(String v) {
    _checkDebounce?.cancel();
    final u = v.trim();
    if (u.isEmpty || u == ApiService.I.cachedUsername) {
      setState(() => _checkState = '');
      return;
    }
    if (!RegExp(r'^[A-Za-z0-9_]{3,20}$').hasMatch(u)) {
      setState(() => _checkState = 'invalid');
      return;
    }
    setState(() => _checkState = 'checking');
    _checkDebounce = Timer(const Duration(milliseconds: 450), () async {
      final r = await ApiService.I.userExists(u);
      if (!mounted) return;
      if (u != _username.text.trim()) return; // stale
      setState(() => _checkState = (r.ok && r.data == true) ? 'taken' : 'ok');
    });
  }

  Future<void> _pickAvatar() async {
    try {
      final picker = ip.ImagePicker();
      final x = await picker.pickImage(
          source: ip.ImageSource.gallery, maxWidth: 1024, imageQuality: 85);
      if (x == null) return;
      setState(() => _avatarPath = x.path);
    } catch (_) {}
  }

  Future<void> _save() async {
    final s = AppState.I.str;
    final newUsername = _username.text.trim();
    // Same rule as the backend (USERNAME_RE): 3–20 chars, a-z 0-9 _.
    if (newUsername.isNotEmpty &&
        newUsername != ApiService.I.cachedUsername &&
        !RegExp(r'^[A-Za-z0-9_]{3,20}$').hasMatch(newUsername)) {
      showRaviToast(context, s.usernameRule,
          icon: Icons.error_outline_rounded);
      return;
    }
    setState(() => _busy = true);
    final res = await ApiService.I.editProfile(
      name: _name.text.trim(),
      bio: _bio.text.trim(),
      username: newUsername,
      avatarPath: _avatarPath.isEmpty ? null : _avatarPath,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (res.ok) {
      Navigator.of(context).pop(true);
    } else {
      showRaviToast(context,
          res.status == ApiStatus.networkError ? s.serverUnreachable : s.editFailed(res.message ?? ''),
          icon: Icons.error_outline_rounded);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _dark ? const Palette.dark() : const Palette.light();
    final s = AppState.I.str;
    final me = ApiService.I.me();
    final avatarName = '${widget.current['avatar'] ?? me.avatar}';

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: p.bg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 44, height: 4,
                  decoration: BoxDecoration(
                      color: p.border, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: GestureDetector(
                  onTap: _busy ? null : _pickAvatar,
                  child: Stack(
                    children: [
                      Container(
                        width: 92, height: 92,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: p.border, width: 2),
                        ),
                        child: ClipOval(
                          child: _avatarPath.isNotEmpty
                              ? Image.file(
                                  File(_avatarPath),
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) =>
                                      _letter(context, me),
                                )
                              : (ApiService.I.avatarUrl(avatarName).isNotEmpty
                                  ? CachedNetworkImage(
                                      imageUrl: ApiService.I.avatarUrl(avatarName),
                                      fit: BoxFit.cover,
                                      errorWidget: (_, __, ___) =>
                                          _letter(context, me))
                                  : _letter(context, me)),
                        ),
                      ),
                      PositionedDirectional(
                        bottom: 0,
                        end: 0,
                        child: Container(
                          width: 30, height: 30,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: p.accent,
                            border: Border.all(color: p.bg, width: 2),
                          ),
                          child: const Icon(Icons.camera_alt_rounded,
                              size: 14, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Center(
                child: Text(s.changePhoto,
                    style: TextStyle(fontSize: 11.5, color: p.text3)),
              ),
              const SizedBox(height: 18),
              Text(s.name,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: p.text2)),
              const SizedBox(height: 7),
              TextField(
                controller: _name,
                cursorColor: p.accent,
                style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: p.text),
                decoration: _deco(p),
              ),
              const SizedBox(height: 14),
              Text(s.username,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: p.text2)),
              const SizedBox(height: 7),
              TextField(
                controller: _username,
                onChanged: _onUsernameChanged,
                cursorColor: p.accent,
                textInputAction: TextInputAction.done,
                textDirection: TextDirection.ltr,
                textAlign: TextAlign.start,
                style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: p.text),
                decoration: _deco(p).copyWith(
                  prefixText: '@',
                  prefixStyle: TextStyle(
                      fontSize: 14.5, fontWeight: FontWeight.w700,
                      color: p.pfHandle),
                  hintText: s.usernameRule,
                  hintStyle: TextStyle(fontSize: 11.5, color: p.text3),
                ),
              ),
              _checkLine(p, s),
              const SizedBox(height: 14),
              Text(s.bioLabel,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: p.text2)),
              const SizedBox(height: 7),
              TextField(
                controller: _bio,
                cursorColor: p.accent,
                maxLines: 3,
                maxLength: 180,
                style: TextStyle(fontSize: 14, color: p.text),
                decoration: _deco(p).copyWith(hintText: s.bioHint),
              ),
              const SizedBox(height: 18),
              SizedBox(
                height: 50,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: p.accent,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(15)),
                  ),
                  onPressed: _busy ? null : _save,
                  child: _busy
                      ? const SizedBox(width: 20, height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.2, color: Colors.white))
                      : Text(s.save,
                          style: const TextStyle(
                              fontSize: 14.5, fontWeight: FontWeight.w800)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _checkLine(Palette p, S s) {
    if (_checkState.isEmpty) return const SizedBox.shrink();
    final (icon, text, color) = switch (_checkState) {
      'checking' => (Icons.hourglass_top_rounded, s.checkingHandle, p.text3),
      'ok' => (Icons.check_circle_rounded, s.usernameAvailable, const Color(0xFF16A34A)),
      'taken' => (Icons.cancel_rounded, s.usernameTaken, const Color(0xFFEF4444)),
      'invalid' => (Icons.info_outline_rounded, s.handleInvalid, const Color(0xFFF59E0B)),
      _ => (null, '', p.text3),
    };
    if (icon == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 5),
        Text(text,
            style: TextStyle(
                fontSize: 11.5, fontWeight: FontWeight.w600, color: color)),
      ]),
    );
  }

  InputDecoration _deco(Palette p) {
    return InputDecoration(
      filled: true,
      fillColor: p.bgSoft,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: p.border.withValues(alpha: .5))),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: p.accent.withValues(alpha: .65), width: 1.4)),
    );
  }

  Widget _letter(BuildContext context, RaviUser me) {
    final initial = me.username.isEmpty
        ? 'R'
        : String.fromCharCode(me.username.runes.first).toUpperCase();
    return Container(
      color: const Color(0xFF1686C7),
      alignment: Alignment.center,
      child: Text(initial,
          style: const TextStyle(
              color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)),
    );
  }
}

// ==================== Blocked users bottom sheet ====================

class _BlockedSheet extends StatefulWidget {
  const _BlockedSheet();

  @override
  State<_BlockedSheet> createState() => _BlockedSheetState();
}

class _BlockedSheetState extends State<_BlockedSheet> {
  List<dynamic> _list = [];
  bool _loading = true;
  final Set<String> _busyNames = {};

  bool get _dark => Theme.of(context).brightness == Brightness.dark;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await ApiService.I.myBlocks();
    if (!mounted) return;
    setState(() {
      _list = r.ok ? (r.data ?? []) : [];
      _loading = false;
    });
  }

  Future<void> _unblock(String username) async {
    setState(() => _busyNames.add(username));
    final r = await ApiService.I.unblockUser(username);
    if (!mounted) return;
    setState(() {
      _busyNames.remove(username);
      if (r.ok) _list.removeWhere((e) => '${e?['username'] ?? ''}' == username);
    });
    if (r.ok && mounted) {
      showRaviToast(context, AppState.I.str.unblock);
    }
  }

  String _name(Map e) => '${e['username'] ?? e['name'] ?? ''}';

  @override
  Widget build(BuildContext context) {
    final p = _dark ? const Palette.dark() : const Palette.light();
    final s = AppState.I.str;
    return Container(
      constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.65),
      decoration: BoxDecoration(
        color: p.bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 44, height: 4,
              decoration: BoxDecoration(
                  color: p.border, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 14),
          Text(s.blockedUsers,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: p.text)),
          const SizedBox(height: 12),
          if (_loading)
            Padding(
              padding: const EdgeInsets.all(28),
              child: Center(
                child: CircularProgressIndicator(strokeWidth: 2.2, color: p.accent),
              ),
            )
          else if (_list.isEmpty)
            Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                children: [
                  Icon(Icons.verified_user_outlined, size: 34, color: p.text3),
                  const SizedBox(height: 10),
                  Text(s.noBlocked,
                      style: TextStyle(fontSize: 13.5, color: p.text2)),
                ],
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _list.length,
                itemBuilder: (context, i) {
                  final e = _list[i];
                  if (e is! Map) return const SizedBox.shrink();
                  final uname = _name(e);
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 9),
                    decoration: BoxDecoration(
                      color: p.bgSoft,
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 17,
                          backgroundColor: const Color(0xFF1686C7),
                          backgroundImage:
                              ApiService.I.avatarUrl('${e['avatar'] ?? ''}')
                                      .isNotEmpty
                                  ? CachedNetworkImageProvider(
                                      ApiService.I.avatarUrl('${e['avatar'] ?? ''}'))
                                  : null,
                          child: ApiService.I
                                  .avatarUrl('${e['avatar'] ?? ''}')
                                  .isEmpty
                              ? Text(uname.isNotEmpty
                                  ? uname[0].toUpperCase()
                                  : '?')
                              : null,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${e['name'] ?? uname}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w700,
                                      color: p.text)),
                              Text('@$uname',
                                  style: TextStyle(
                                      fontSize: 11.5, color: p.text3)),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: _busyNames.contains(uname)
                              ? null
                              : () => _unblock(uname),
                          child: _busyNames.contains(uname)
                              ? SizedBox(width: 15, height: 15,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: p.accent))
                              : Text(s.unblock,
                                  style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w800,
                                      color: p.accent)),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
