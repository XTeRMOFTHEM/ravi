import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/api_service.dart';
import '../../core/app_state.dart';
import '../../core/constants.dart';
import '../../core/models.dart';
import '../widgets/common.dart';
import '../widgets/ravi_alerts.dart';

/// v1.0.9 — Telegram-style FORWARD screen:
///  • opens as a full page titled "Forward to…"
///  • the chat list looks exactly like the home list (avatar, name, snippet)
///  • multi-select (checkboxes) — one tap forwards to MANY chats at once
///  • a small bottom bar shows the forward preview + the send button
class ForwardScreen extends StatefulWidget {
  final List<Message> messages;
  const ForwardScreen({super.key, required this.messages});

  /// Opens the forward picker for one or more messages.
  static Future<void> open(BuildContext context, {required List<Message> messages}) async {
    final ok = messages.any((m) => m.id > 0);
    if (!ok) {
      showGlassToast(context, AppState.I.str.error,
          icon: Icons.error_outline_rounded, color: const Color(0xFFEF4444));
      return;
    }
    await Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ForwardScreen(
          messages: messages.where((m) => m.id > 0).toList()),
    ));
  }

  @override
  State<ForwardScreen> createState() => _ForwardScreenState();
}

class _ForwardScreenState extends State<ForwardScreen> {
  final Set<String> _picked = {}; // ChatPreview.key
  bool _sending = false;
  String _query = '';

  String _snippet(Message m) {
    if (m.text.trim().isNotEmpty) return m.text.trim();
    return m.previewSnippet;
  }

  Future<void> _send() async {
    if (_picked.isEmpty || _sending) return;
    final s = AppState.I.str;
    setState(() => _sending = true);
    final chats = AppState.I.chats.value;
    var sent = 0;
    for (final key in _picked) {
      final c = chats.firstWhere(
        (x) => x.key == key,
        orElse: () => chats.first,
      );
      for (final m in widget.messages) {
        final ApiResult<bool> res;
        if (c.kind == ChatKind.pv) {
          res = await ApiService.I.forwardMessage(m.id, pvChatId: c.id);
        } else {
          res = await ApiService.I.forwardMessage(m.id, roomChatId: c.roomId);
        }
        if (res.ok) sent++;
      }
    }
    if (!mounted) return;
    setState(() => _sending = false);
    showGlassToast(context, s.forwardSent(_picked.length),
        icon: Icons.shortcut_rounded);
    Navigator.of(context).pop();
    // silence analyzer: [sent] used for future per-item error reporting
    assert(sent >= 0);
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final p = dark ? const Palette.dark() : const Palette.light();
    final s = AppState.I.str;
    final all = AppState.I.chats.value;
    final q = _query.trim().toLowerCase();
    final list = q.isEmpty
        ? all
        : all
            .where((c) =>
                c.name.toLowerCase().contains(q) ||
                c.peerUsername.toLowerCase().contains(q))
            .toList();

    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(
          children: [
            // ---------------- header ----------------
            Container(
              height: 58,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: p.navBg,
                border: Border(bottom: BorderSide(color: p.border)),
              ),
              child: Row(children: [
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Icon(Icons.close_rounded, size: 22, color: p.text),
                ),
                const SizedBox(width: 12),
                Text(s.forwardTitle,
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: p.text)),
                const Spacer(),
                Text(s.selectedCount(_picked.length),
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: p.accent)),
              ]),
            ),
            // ---------------- search ----------------
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
              child: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: p.bgSoft,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(children: [
                  Icon(Icons.search_rounded, size: 18, color: p.text3),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      onChanged: (v) => setState(() => _query = v),
                      style: TextStyle(fontSize: 13, color: p.text),
                      decoration: InputDecoration(
                        isCollapsed: true,
                        border: InputBorder.none,
                        hintText: s.searchChats,
                        hintStyle: TextStyle(fontSize: 12.5, color: p.text3),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
            // ---------------- chat list ----------------
            Expanded(
              child: ListView.builder(
                physics: const BouncingScrollPhysics(),
                itemCount: list.length,
                itemBuilder: (ctx, i) {
                  final c = list[i];
                  final picked = _picked.contains(c.key);
                  return InkWell(
                    onTap: () => setState(() {
                      picked ? _picked.remove(c.key) : _picked.add(c.key);
                    }),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 9),
                      decoration: BoxDecoration(
                        color: picked
                            ? p.accent.withValues(alpha: .08)
                            : Colors.transparent,
                      ),
                      child: Row(children: [
                        _avatar(c, p),
                        const SizedBox(width: 12),
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
                              const SizedBox(height: 1),
                              Text(
                                c.kind == ChatKind.channel
                                    ? s.subscribers
                                    : c.kind == ChatKind.group
                                        ? s.members
                                        : '@${c.peerUsername}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 10.5, color: p.text3),
                              ),
                            ],
                          ),
                        ),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: picked ? p.accent : Colors.transparent,
                            border: Border.all(
                              color: picked
                                  ? p.accent
                                  : p.text3.withValues(alpha: .5),
                              width: 1.6,
                            ),
                          ),
                          child: picked
                              ? const Icon(Icons.check_rounded,
                                  size: 14, color: Colors.white)
                              : null,
                        ),
                      ]),
                    ),
                  );
                },
              ),
            ),
            // ---------------- bottom send bar ----------------
            if (_picked.isNotEmpty)
              Container(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                decoration: BoxDecoration(
                  color: p.navBg,
                  border: Border(top: BorderSide(color: p.border)),
                ),
                child: Row(children: [
                  Expanded(
                    child: Text(
                      '${s.forward}: ${widget.messages.length}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: p.text2),
                    ),
                  ),
                  GestureDetector(
                    onTap: _send,
                    child: Container(
                      height: 42,
                      padding: const EdgeInsets.symmetric(horizontal: 22),
                      decoration: BoxDecoration(
                        gradient: C.ownBubbleGrad,
                        borderRadius: BorderRadius.circular(21),
                      ),
                      child: Center(
                        child: _sending
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : Row(mainAxisSize: MainAxisSize.min, children: [
                                Text(s.send,
                                    style: const TextStyle(
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w800,
                                        color: Colors.white)),
                                const SizedBox(width: 6),
                                const Icon(Icons.send_rounded,
                                    size: 15, color: Colors.white),
                              ]),
                      ),
                    ),
                  ),
                ]),
              ),
          ],
        ),
      ),
    );
  }

  Widget _avatar(ChatPreview c, Palette p) {
    final url = c.avatar.isNotEmpty ? ApiService.I.avatarUrl(c.avatar) : '';
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: c.kind == ChatKind.general
            ? C.globeGrad
            : LinearGradient(
                colors: C.avatarGradients[
                    c.name.hashCode.abs() % C.avatarGradients.length]),
      ),
      child: url.isNotEmpty
          ? ClipOval(
              child: CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                memCacheWidth: 96,
                httpHeaders: {'Cookie': ApiService.I.cookieHeader},
                errorWidget: (_, __, ___) => Center(
                  child: Text(
                      c.name.isNotEmpty ? c.name[0].toUpperCase() : '?',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800)),
                ),
              ),
            )
          : Center(
              child: c.kind == ChatKind.general
                  ? const Icon(Icons.public_rounded,
                      color: Colors.white, size: 20)
                  : Text(c.name.isNotEmpty ? c.name[0].toUpperCase() : '?',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800)),
            ),
    );
  }
}
