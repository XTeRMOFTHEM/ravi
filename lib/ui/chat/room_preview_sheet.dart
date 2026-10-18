import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/api_service.dart';
import '../../core/app_state.dart';
import '../../core/constants.dart';
import '../../core/i18n.dart';
import '../../core/models.dart';
import '../../core/socket_service.dart';
import '../widgets/ravi_alerts.dart';
import 'chat_screen.dart';

/// v1.0.6 — room preview / join panel (exactly like index `RoomPreview`):
/// opens with a skeleton, resolves by @username or room id, then shows
/// avatar / type badge / name / member count / bio + a Join button that
/// slides the sheet away and opens the chat.
class RoomPreviewSheet {
  RoomPreviewSheet._();

  /// Resolve a token that can be a @username or an invite id.
  static void openFromToken(BuildContext context, String token) {
    final u = token.trim().replaceFirst(RegExp(r'^@'), '');
    if (u.isEmpty) return;
    _open(context, resolver: () => ApiService.I.roomResolve(u));
  }

  static void openById(BuildContext context, String roomId) {
    _open(context, resolver: () => ApiService.I.roomPreview(roomId));
  }

  static void _open(
    BuildContext context, {
    required Future<ApiResult<Map<String, dynamic>>> Function() resolver,
  }) {
    // v1.0.7 — COMPACT join panel: a tight card that hugs its content
    // (the old 52%-height sheet felt like a full-screen page).
    showGlassSheet(
      context,
      heightFactor: 0.40,
      builder: (ctx) => _RoomPreviewBody(resolver: resolver),
    );
  }
}

class _RoomPreviewBody extends StatefulWidget {
  final Future<ApiResult<Map<String, dynamic>>> Function() resolver;
  const _RoomPreviewBody({required this.resolver});

  @override
  State<_RoomPreviewBody> createState() => _RoomPreviewBodyState();
}

class _RoomPreviewBodyState extends State<_RoomPreviewBody> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    final r = await widget.resolver();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (r.ok && r.data != null) {
        _data = r.data;
      } else {
        _error = 'not_found';
      }
    });
  }

  Future<void> _joinAction() async {
    if (_busy) return;
    final d = _data!;
    final isMember = d['is_member'] == true;
    if (isMember) {
      Navigator.pop(context);
      _openChat();
      return;
    }
    setState(() => _busy = true);
    final s = AppState.I.str;
    final username = '${d['username'] ?? ''}';
    final r = (d['is_public'] == true && username.isNotEmpty)
        ? await ApiService.I.joinByUsername(username)
        : await ApiService.I.joinRoom('${d['room_id'] ?? ''}');
    if (!mounted) return;
    if (r.ok) {
      showGlassToast(context, s.joinedRoomToast);
      Navigator.pop(context);
      _openChat();
    } else {
      setState(() => _busy = false);
      showGlassToast(context,
          (r.message != null && r.message!.isNotEmpty && r.message != 'fail')
              ? r.message!
              : s.error,
          icon: Icons.error_outline_rounded, color: const Color(0xFFEF4444));
    }
  }

  void _openChat() {
    final d = _data!;
    SocketService.I.joinGroup('${d['room_id'] ?? ''}');
    Navigator.of(context, rootNavigator: true).push(ChatScreen.route(
      kind: '${d['room_type'] ?? 'group'}' == 'channel'
          ? ChatKind.channel
          : ChatKind.group,
      title: '${d['name'] ?? ''}',
      avatarPath: '${d['avatar'] ?? ''}',
      roomId: '${d['room_id'] ?? ''}',
      canPost: true,
    ));
  }

  String _countLabel() {
    final s = AppState.I.str;
    final n = (d_int(_data?['member_count']));
    final isCh = '${_data?['room_type'] ?? ''}' == 'channel';
    final nStr = n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}K' : '$n';
    return '$nStr ${isCh ? s.subscribers : s.members}';
  }

  static int d_int(dynamic v) => v is int ? v : int.tryParse('$v') ?? 0;

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;
    final dark = Theme.of(context).brightness == Brightness.dark;

    return SafeArea(
      child: Column(children: [
        const SizedBox(height: 10),
        Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
                color: p.border, borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 12),
        Expanded(
          child: _loading
              ? _skeleton(p)
              : (_error != null || _data == null)
                  ? Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.search_off_rounded,
                            size: 36, color: p.text3),
                        const SizedBox(height: 8),
                        Text(s.roomNotFound,
                            style: TextStyle(
                                fontSize: 12.5, color: p.text2)),
                      ],
                    )
                  : _content(p, dark, s),
        ),
      ]),
    );
  }

  Widget _skeleton(Palette p) {
    Widget ln(double w, double h, {double r = 8}) => Container(
          width: w, height: h,
          decoration: BoxDecoration(
            color: p.bgSoft,
            borderRadius: BorderRadius.circular(r),
          ),
        );
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ln(64, 64, r: 32),
        const SizedBox(height: 10),
        ln(140, 15, r: 8),
        const SizedBox(height: 6),
        ln(96, 11, r: 6),
        const SizedBox(height: 14),
        ln(230, 44, r: 14),
      ],
    );
  }

  Widget _content(Palette p, bool dark, S s) {
    final d = _data!;
    final isChannel = '${d['room_type'] ?? ''}' == 'channel';
    final name = '${d['name'] ?? ''}';
    final avatar = '${d['avatar'] ?? ''}';
    final username = '${d['username'] ?? ''}';
    final bio = '${d['bio'] ?? ''}';
    final isMember = d['is_member'] == true;
    final avatarUrl = ApiService.I.avatarUrl(avatar);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 22),
      child: Column(
        children: [
          // avatar with glow ring (compact)
          Container(
            padding: const EdgeInsets.all(2.5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: [
                p.accent.withValues(alpha: .7),
                p.accent.withValues(alpha: .15),
              ]),
            ),
            child: Container(
              width: 62, height: 62,
              decoration: const BoxDecoration(
                  shape: BoxShape.circle, color: Color(0xFF2A3240)),
              child: ClipOval(
                child: avatarUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: avatarUrl,
                        fit: BoxFit.cover,
                        memCacheWidth: 160,
                        httpHeaders: {'Cookie': ApiService.I.cookieHeader},
                        errorWidget: (_, __, ___) => Center(
                          child: Text(name.isEmpty ? '?' : name[0].toUpperCase(),
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800)),
                        ),
                      )
                    : Center(
                        child: Text(name.isEmpty ? '?' : name[0].toUpperCase(),
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.w800)),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 9),
          // type badge + name on one line (compact)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: (isChannel ? const Color(0xFF38BDF8) : const Color(0xFF8B5CF6))
                      .withValues(alpha: .14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(isChannel ? s.catChannel : s.catGroup,
                    style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                        color: isChannel
                            ? const Color(0xFF38BDF8)
                            : const Color(0xFF8B5CF6))),
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Text(name,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w800, color: p.text)),
              ),
            ],
          ),
          if (username.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text('@$username',
                textDirection: TextDirection.ltr,
                style: TextStyle(fontSize: 11.5, color: p.text3)),
          ],
          const SizedBox(height: 4),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.people_outline_rounded, size: 13, color: p.text3),
            const SizedBox(width: 5),
            Text(_countLabel(),
                style: TextStyle(fontSize: 11.5, color: p.text2)),
          ]),
          if (bio.isNotEmpty) ...[
            const SizedBox(height: 8),
            Flexible(
              child: SingleChildScrollView(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: p.bgSoft.withValues(alpha: .7),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.roomBioLabel,
                          style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: p.text3)),
                      const SizedBox(height: 3),
                      Text(bio,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11.5, height: 1.5, color: p.text)),
                    ],
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          // Join / Open button
          GestureDetector(
            onTap: _busy ? null : _joinAction,
            child: Container(
              height: 44,
              width: double.infinity,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: isMember
                    ? null
                    : const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF9F7BF5), Color(0xFF7C5CE0)]),
                color: isMember ? p.accentSoft : null,
                borderRadius: BorderRadius.circular(14),
                boxShadow: isMember
                    ? null
                    : const [
                        BoxShadow(
                            color: Color(0x4D8B5CF6),
                            blurRadius: 18,
                            offset: Offset(0, 8)),
                      ],
              ),
              child: _busy
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(isMember ? s.openChat : s.join,
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          color: isMember ? p.accent : Colors.white)),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}
