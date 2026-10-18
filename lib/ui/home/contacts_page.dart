import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/api_service.dart';
import '../../core/app_state.dart';
import '../../core/constants.dart';
import '../../core/models.dart';
import '../widgets/common.dart';
import 'user_profile_screen.dart';

/// v1.0.8 — Contacts & Calls pages (Telegram-style glass cards):
///  • Contacts = people you actually chat with (from the local chat list),
///    one clean row per person, tap → profile
///  • Calls = empty state announcing that voice calls are coming
class ContactsPage extends StatelessWidget {
  const ContactsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;

    return ValueListenableBuilder<List<ChatPreview>>(
      valueListenable: AppState.I.chats,
      builder: (context, chats, _) {
        // unique people from pv chats
        final seen = <String>{};
        final people = <ChatPreview>[];
        for (final c in chats) {
          if (c.kind == ChatKind.pv &&
              c.peerUsername.isNotEmpty &&
              seen.add(c.peerUsername)) {
            people.add(c);
          }
        }

        return Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 4),
            child: Row(children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: p.accentSoft,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.people_outline_rounded,
                    size: 19, color: p.accent),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.contactsTitle,
                        style: TextStyle(
                            fontSize: 15.5, fontWeight: FontWeight.w800,
                            color: p.text)),
                    Text(s.contactsSub,
                        style: TextStyle(fontSize: 10.5, color: p.text3)),
                  ],
                ),
              ),
            ]),
          ),
          Expanded(
            child: people.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.person_search_rounded,
                            size: 44, color: p.text3),
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 40),
                          child: Text(s.noContacts,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 12.5, color: p.text2)),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
                    itemCount: people.length,
                    itemBuilder: (ctx, i) {
                      final u = people[i];
                      return _personRow(ctx, p, u);
                    },
                  ),
          ),
        ]);
      },
    );
  }

  Widget _personRow(BuildContext context, Palette p, ChatPreview u) {
    final url = ApiService.I.avatarUrl(u.avatar);
    return InkWell(
      onTap: () => Navigator.of(context, rootNavigator: true)
          .push(UserProfileScreen.route(u.peerUsername)),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        child: Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: url.isNotEmpty
                  ? null
                  : LinearGradient(colors: C.avatarGradients[
                      u.peerUsername.hashCode.abs() % C.avatarGradients.length]),
            ),
            child: url.isNotEmpty
                ? ClipOval(
                    child: CachedNetworkImage(
                      imageUrl: url,
                      fit: BoxFit.cover,
                      memCacheWidth: 100,
                      httpHeaders: {'Cookie': ApiService.I.cookieHeader},
                      errorWidget: (_, __, ___) => Center(
                        child: Text(u.peerUsername[0].toUpperCase(),
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w800)),
                      ),
                    ),
                  )
                : Center(
                    child: Text(u.peerUsername[0].toUpperCase(),
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800)),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(u.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w700,
                        color: p.text)),
                const SizedBox(height: 2),
                Text('@${u.peerUsername}',
                    textDirection: TextDirection.ltr,
                    style: TextStyle(fontSize: 10.5, color: p.text3)),
              ],
            ),
          ),
          Icon(Icons.chat_bubble_outline_rounded, size: 17, color: p.text3),
        ]),
      ),
    );
  }
}

class CallsPage extends StatelessWidget {
  const CallsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 84, height: 84,
            decoration: BoxDecoration(
              gradient: C.ownBubbleGrad,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                    color: p.accent.withValues(alpha: .35),
                    blurRadius: 30,
                    offset: const Offset(0, 10)),
              ],
            ),
            child: const Icon(Icons.call_rounded,
                size: 36, color: Colors.white),
          ),
          const SizedBox(height: 18),
          Text(s.callsTitle,
              style: TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w800, color: p.text)),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 44),
            child: Text(s.callsEmptySub,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, height: 1.6,
                    color: p.text2)),
          ),
        ],
      ),
    );
  }
}
