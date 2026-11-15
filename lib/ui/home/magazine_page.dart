import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart' as ip;

import '../../core/api_service.dart';
import '../../core/app_state.dart';
import '../../core/constants.dart';
import '../../core/models.dart';
import '../chat/photo_viewer.dart';
import '../widgets/common.dart';
import '../widgets/ravi_alerts.dart';
import 'user_profile_screen.dart';

/// Real backend-backed Magazine feed (`/api/magazine/posts`):
/// • Live search, pull-to-refresh, likes, replies bottom sheet, post composer
///   with optional image upload, share-to-clipboard, and delete own posts.
class MagazinePage extends StatefulWidget {
  const MagazinePage({super.key});

  @override
  State<MagazinePage> createState() => _MagazinePageState();
}

class _MagazinePageState extends State<MagazinePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final TextEditingController _search = TextEditingController();
  Timer? _debounce;
  List<MagazinePost> _posts = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final q = _search.text.trim();
    final res = await ApiService.I.magazinePosts(query: q);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (res.ok && res.data != null) {
        _posts = res.data!;
        _error = null;
      } else {
        _error = res.message ?? 'error';
      }
    });
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 380), () {
      if (mounted) _load();
    });
  }

  Future<void> _toggleLike(MagazinePost post) async {
    final idx = _posts.indexWhere((x) => x.id == post.id);
    if (idx < 0) return;
    final optimisticLiked = !post.likedByMe;
    final optimisticCount = (post.likesCount + (optimisticLiked ? 1 : -1)).clamp(0, 1 << 30);
    setState(() {
      _posts[idx] = post.copyWith(
        likedByMe: optimisticLiked,
        likesCount: optimisticCount,
      );
    });
    final res = await ApiService.I.toggleMagazineLike(post.id);
    if (!mounted) return;
    final i2 = _posts.indexWhere((x) => x.id == post.id);
    if (i2 < 0) return;
    if (res.ok && res.data != null) {
      setState(() {
        _posts[i2] = _posts[i2].copyWith(
          likedByMe: res.data!['liked'] == true,
          likesCount: res.data!['likes_count'] is int
              ? res.data!['likes_count'] as int
              : _posts[i2].likesCount,
        );
      });
    } else {
      setState(() => _posts[i2] = post);
    }
  }

  Future<void> _deletePost(MagazinePost post) async {
    final s = AppState.I.str;
    final ok = await showRaviModal(
      context,
      icon: Icons.delete_outline_rounded,
      iconColor: const Color(0xFFEF4444),
      danger: true,
      title: s.delete,
      body: post.content.length > 90
          ? '${post.content.substring(0, 90)}…'
          : post.content,
      okText: s.delete,
      cancelText: s.cancel,
    );
    if (!ok || !mounted) return;
    final res = await ApiService.I.deleteMagazinePost(post.id);
    if (!mounted) return;
    if (res.ok) {
      setState(() => _posts.removeWhere((p) => p.id == post.id));
      showGlassToast(context, s.postDeleted, icon: Icons.delete_outline_rounded);
    } else {
      showGlassToast(context, s.error,
          icon: Icons.error_outline_rounded, color: const Color(0xFFEF4444));
    }
  }

  Future<void> _openComposer() async {
    final created = await MagazineComposerSheet.show(context);
    if (created != null && mounted) {
      setState(() => _posts.insert(0, created));
    }
  }

  Future<void> _openReplies(MagazinePost post) async {
    final delta = await MagazineRepliesSheet.show(context, post: post);
    if (delta != null && delta > 0 && mounted) {
      final idx = _posts.indexWhere((x) => x.id == post.id);
      if (idx >= 0) {
        setState(() {
          _posts[idx] = _posts[idx].copyWith(
            repliesCount: _posts[idx].repliesCount + delta,
          );
        });
      }
    }
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
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: p.bg,
                border: Border(bottom: BorderSide(color: p.border)),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(25),
                child: Container(
                  height: 48,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: p.bgSoft,
                    borderRadius: BorderRadius.circular(25),
                    border: Border.all(color: p.borderSoft),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _search,
                          onChanged: _onSearchChanged,
                          style: TextStyle(fontSize: 14.5, color: p.text),
                          decoration: InputDecoration(
                            isCollapsed: true,
                            border: InputBorder.none,
                            hintText: s.magSearchPh,
                            hintStyle: TextStyle(fontSize: 14.5, color: p.text3),
                          ),
                        ),
                      ),
                      if (_search.text.isNotEmpty)
                        GestureDetector(
                          onTap: () {
                            _search.clear();
                            _load();
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Icon(Icons.close_rounded, size: 18, color: p.text3),
                          ),
                        ),
                      Icon(Icons.search_rounded, size: 22, color: p.text2),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                color: p.accent,
                onRefresh: _load,
                child: _loading
                    ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                    : _posts.isEmpty
                        ? ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(24, 72, 24, 110),
                            children: [
                              Icon(Icons.auto_stories_outlined, size: 42, color: p.text3),
                              const SizedBox(height: 12),
                              Text(
                                _error != null ? s.serverUnreachable : s.noPostsYet,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w700,
                                  color: p.text2,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                s.shareFirstPost,
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 12, color: p.text3),
                              ),
                            ],
                          )
                        : Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 760),
                              child: ListView.builder(
                                physics: const BouncingScrollPhysics(
                                  parent: AlwaysScrollableScrollPhysics(),
                                ),
                                padding: const EdgeInsets.fromLTRB(12, 10, 12, 108),
                                itemCount: _posts.length,
                                itemBuilder: (context, i) => MagazinePostCard(
                                  post: _posts[i],
                                  onLike: () => _toggleLike(_posts[i]),
                                  onReplies: () => _openReplies(_posts[i]),
                                  onDelete: _posts[i].isOwn ? () => _deletePost(_posts[i]) : null,
                                ),
                              ),
                            ),
                          ),
              ),
            ),
          ],
        ),
        PositionedDirectional(
          end: 16,
          bottom: 18,
          child: FloatingActionButton.extended(
            heroTag: 'magazine_compose',
            backgroundColor: p.accent,
            foregroundColor: Colors.white,
            onPressed: _openComposer,
            icon: const Icon(Icons.edit_rounded, size: 19),
            label: Text(
              s.newPost,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
            ),
          ),
        ),
      ],
    );
  }
}

/// Reusable Magazine/Profile post card.
class MagazinePostCard extends StatelessWidget {
  final MagazinePost post;
  final VoidCallback onLike;
  final VoidCallback onReplies;
  final VoidCallback? onDelete;

  const MagazinePostCard({
    super.key,
    required this.post,
    required this.onLike,
    required this.onReplies,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(13, 13, 13, 11),
      decoration: BoxDecoration(
        color: p.bgCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Theme.of(context).brightness == Brightness.light
              ? C.borderSoftL
              : C.borderSoftD,
        ),
        boxShadow: const [
          BoxShadow(color: Color(0x0B1E3246), blurRadius: 14, offset: Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: () {
                  if (post.username.isNotEmpty) {
                    Navigator.of(context, rootNavigator: true)
                        .push(UserProfileScreen.route(post.username));
                  }
                },
                child: RaviAvatar(
                  name: post.authorName,
                  avatarPath: post.authorAvatar,
                  size: 42,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    if (post.username.isNotEmpty) {
                      Navigator.of(context, rootNavigator: true)
                          .push(UserProfileScreen.route(post.username));
                    }
                  },
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              post.channel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w800,
                                color: p.text,
                              ),
                            ),
                          ),
                          if (post.authorIsOfficial) ...[
                            const SizedBox(width: 4),
                            const Icon(Icons.verified_rounded,
                                size: 15, color: Color(0xFF38BDF8)),
                          ],
                          if (post.authorIsPro) ...[
                            const SizedBox(width: 4),
                            const Icon(Icons.star_rounded,
                                size: 15, color: Color(0xFFF59E0B)),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '@${post.username}${post.createdAt.isNotEmpty ? ' · ${post.createdAt.length >= 16 ? post.createdAt.substring(0, 16) : post.createdAt}' : ''}',
                        style: TextStyle(fontSize: 10.5, color: p.text3),
                      ),
                    ],
                  ),
                ),
              ),
              if (onDelete != null)
                IconButton(
                  icon: Icon(Icons.delete_outline_rounded, size: 19, color: p.text3),
                  onPressed: onDelete,
                ),
            ],
          ),
          if (post.content.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 11, 2, 8),
              child: Text(
                post.content,
                style: TextStyle(fontSize: 14, height: 1.75, color: p.text),
              ),
            ),
          if (post.mediaUrl.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GestureDetector(
                onTap: () => openMediaViewer(
                  context,
                  fileUrl: post.mediaUrl,
                  title: post.channel,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: CachedNetworkImage(
                    imageUrl: ApiService.I.absoluteUrl(post.mediaUrl),
                    httpHeaders: ApiService.I.authHeadersFor(post.mediaUrl),
                    fit: BoxFit.cover,
                    width: double.infinity,
                    height: 210,
                    memCacheWidth: 720,
                  ),
                ),
              ),
            ),
          Container(
            padding: const EdgeInsets.only(top: 8),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: p.border))),
            child: Row(
              children: [
                _actionBtn(
                  p,
                  post.likedByMe ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  '${post.likesCount}',
                  color: post.likedByMe ? const Color(0xFFEF4444) : p.text2,
                  onTap: () {
                    HapticFeedback.lightImpact();
                    onLike();
                  },
                ),
                const SizedBox(width: 18),
                _actionBtn(
                  p,
                  Icons.chat_bubble_outline_rounded,
                  '${post.repliesCount}',
                  onTap: onReplies,
                ),
                const Spacer(),
                _actionBtn(
                  p,
                  Icons.ios_share_rounded,
                  s.share,
                  onTap: () {
                    Clipboard.setData(
                      ClipboardData(text: '${post.channel}\n${post.content}'),
                    );
                    showGlassToast(context, s.copiedToClipboard, icon: Icons.copy_rounded);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionBtn(
    Palette p,
    IconData icon,
    String label, {
    Color? color,
    required VoidCallback onTap,
  }) {
    final c = color ?? p.text2;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: c),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: c),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet composer for publishing real posts to Magazine & Profile.
class MagazineComposerSheet extends StatefulWidget {
  const MagazineComposerSheet({super.key});

  static Future<MagazinePost?> show(BuildContext context) {
    return showModalBottomSheet<MagazinePost>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const MagazineComposerSheet(),
    );
  }

  @override
  State<MagazineComposerSheet> createState() => _MagazineComposerSheetState();
}

class _MagazineComposerSheetState extends State<MagazineComposerSheet> {
  final TextEditingController _channel = TextEditingController();
  final TextEditingController _content = TextEditingController();
  String? _imagePath;
  bool _busy = false;

  @override
  void dispose() {
    _channel.dispose();
    _content.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    try {
      final f = await ip.ImagePicker().pickImage(
        source: ip.ImageSource.gallery,
        imageQuality: 85,
      );
      if (f != null && mounted) setState(() => _imagePath = f.path);
    } catch (_) {}
  }

  Future<void> _publish() async {
    final text = _content.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() => _busy = true);
    var mediaUrl = '';
    if (_imagePath != null) {
      final up = await ApiService.I.uploadImage(_imagePath!);
      if (up.ok && up.data != null) {
        mediaUrl = '${up.data!['file_url'] ?? ''}';
      }
    }
    final res = await ApiService.I.createMagazinePost(
      channel: _channel.text.trim(),
      content: text,
      mediaUrl: mediaUrl,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    final s = AppState.I.str;
    if (res.ok && res.data != null) {
      showGlassToast(context, s.postPublished, icon: Icons.check_circle_rounded);
      Navigator.of(context).pop(res.data);
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

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: p.bg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: p.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  s.newPost,
                  style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800, color: p.text),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _channel,
                  maxLength: 80,
                  style: TextStyle(fontSize: 13.5, color: p.text),
                  decoration: InputDecoration(
                    counterText: '',
                    filled: true,
                    fillColor: p.bgSoft,
                    hintText: s.postTitleHint,
                    hintStyle: TextStyle(fontSize: 13, color: p.text3),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _content,
                  maxLines: 5,
                  minLines: 3,
                  maxLength: 2000,
                  style: TextStyle(fontSize: 14, color: p.text, height: 1.5),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: p.bgSoft,
                    hintText: s.postContentHint,
                    hintStyle: TextStyle(fontSize: 13.5, color: p.text3),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                if (_imagePath != null) ...[
                  const SizedBox(height: 8),
                  Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.file(
                          File(_imagePath!),
                          height: 120,
                          width: double.infinity,
                          fit: BoxFit.cover,
                        ),
                      ),
                      PositionedDirectional(
                        top: 6,
                        end: 6,
                        child: GestureDetector(
                          onTap: () => setState(() => _imagePath = null),
                          child: Container(
                            padding: const EdgeInsets.all(5),
                            decoration: const BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.close_rounded, color: Colors.white, size: 16),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    IconButton(
                      onPressed: _busy ? null : _pickImage,
                      icon: Icon(Icons.photo_outlined, color: p.accent),
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: _busy ? null : _publish,
                      style: FilledButton.styleFrom(
                        backgroundColor: p.accent,
                        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              s.publishPost,
                              style: const TextStyle(fontWeight: FontWeight.w800),
                            ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet displaying and posting real replies on a Magazine post.
class MagazineRepliesSheet extends StatefulWidget {
  final MagazinePost post;
  const MagazineRepliesSheet({super.key, required this.post});

  static Future<int?> show(BuildContext context, {required MagazinePost post}) {
    return showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MagazineRepliesSheet(post: post),
    );
  }

  @override
  State<MagazineRepliesSheet> createState() => _MagazineRepliesSheetState();
}

class _MagazineRepliesSheetState extends State<MagazineRepliesSheet> {
  final TextEditingController _input = TextEditingController();
  List<MagazineReply> _replies = [];
  bool _loading = true;
  bool _sending = false;
  int _addedCount = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final res = await ApiService.I.magazineReplies(widget.post.id);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (res.ok && res.data != null) _replies = res.data!;
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    final res = await ApiService.I.addMagazineReply(widget.post.id, text);
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (res.ok && res.data != null) {
        _input.clear();
        _replies.add(res.data!);
        _addedCount++;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_addedCount);
      },
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Container(
          height: MediaQuery.of(context).size.height * 0.65,
          decoration: BoxDecoration(
            color: p.bg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: p.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Row(
                    children: [
                      Text(
                        '${s.repliesTitle} (${_replies.length})',
                        style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w800,
                          color: p.text,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: Icon(Icons.close_rounded, color: p.text2),
                        onPressed: () => Navigator.of(context).pop(_addedCount),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: p.border),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                      : _replies.isEmpty
                          ? Center(
                              child: Text(
                                s.noRepliesYet,
                                style: TextStyle(fontSize: 13, color: p.text3),
                              ),
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.all(14),
                              itemCount: _replies.length,
                              separatorBuilder: (_, __) => const SizedBox(height: 10),
                              itemBuilder: (context, i) {
                                final r = _replies[i];
                                return Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    RaviAvatar(
                                      name: r.authorName,
                                      avatarPath: r.authorAvatar,
                                      size: 34,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Container(
                                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 9),
                                        decoration: BoxDecoration(
                                          color: p.bgSoft,
                                          borderRadius: BorderRadius.circular(14),
                                        ),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              r.authorName,
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w800,
                                                color: p.accent,
                                              ),
                                            ),
                                            const SizedBox(height: 3),
                                            Text(
                                              r.content,
                                              style: TextStyle(
                                                fontSize: 13.5,
                                                height: 1.5,
                                                color: p.text,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                ),
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: p.border)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          decoration: BoxDecoration(
                            color: p.bgSoft,
                            borderRadius: BorderRadius.circular(22),
                          ),
                          child: TextField(
                            controller: _input,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _send(),
                            style: TextStyle(fontSize: 14, color: p.text),
                            decoration: InputDecoration(
                              border: InputBorder.none,
                              hintText: s.writeReplyHint,
                              hintStyle: TextStyle(fontSize: 13, color: p.text3),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: _sending ? null : _send,
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: p.accent,
                          ),
                          child: _sending
                              ? const Padding(
                                  padding: EdgeInsets.all(10),
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.send_rounded, color: Colors.white, size: 18),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
