import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/constants.dart';
import '../../core/models.dart';

/// Magazine page — 1:1 with index.html `page-magazine`:
/// search panel on top, feed of posts below.
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

  /// The same static feed content as the web version.
  static const List<MagazinePost> _posts = [
    MagazinePost('Ravi | Tech', '2h ago · 12.4K views',
        '5 simple tips for building a better messaging experience — from search speed to chat screen design.',
        0),
    MagazinePost('CodeMentor', 'Just now',
        'Start learning to code with small projects. Short, practical learning paths to get you going.',
        1, sponsored: true),
    MagazinePost('Ravi News', 'Today · 8.7K views',
        'A new version of the Ravi interface is coming, focused on faster access to chats, magazine, and settings.',
        2),
    MagazinePost('Business Today', 'Yesterday · 5.2K views',
        'How can a content channel build a loyal audience without cluttering the page?',
        3),
    MagazinePost('SportView', '2 days ago · 3.1K views',
        "Catch today's top sports headlines in a few lines — results, key moments and upcoming fixtures.",
        0),
  ];

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;
    final q = _search.text.trim().toLowerCase();
    final posts = q.isEmpty
        ? _posts
        : _posts
            .where((m) =>
                m.channel.toLowerCase().contains(q) ||
                m.text.toLowerCase().contains(q))
            .toList();

    return Column(
      children: [
        // search panel (v1.0.8 — glass search bar like the web .mg-search)
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: p.bg,
            border: Border(bottom: BorderSide(color: p.border)),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(25),
            child: Container(
              height: 50,
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
                      onChanged: (_) => setState(() {}),
                      style: TextStyle(fontSize: 15, color: p.text),
                      decoration: InputDecoration(
                        isCollapsed: true,
                        border: InputBorder.none,
                        hintText: s.magSearchPh,
                        hintStyle: TextStyle(fontSize: 15, color: p.text3),
                      ),
                    ),
                  ),
                  Icon(Icons.search_rounded, size: 23, color: p.text2),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView.builder(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 96),
                itemCount: posts.length,
                itemBuilder: (context, i) => _PostCard(post: posts[i]),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PostCard extends StatelessWidget {
  final MagazinePost post;
  const _PostCard({required this.post});

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;
    final grad = C.avatarGradients[post.avatarIndex % 4];

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(13, 13, 13, 11),
      decoration: BoxDecoration(
        color: post.sponsored
            ? (Theme.of(context).brightness == Brightness.light
                ? const Color(0xFFFAFDFF)
                : p.bgCard)
            : p.bgCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: post.sponsored
              ? const Color(0xFFDCEEFA)
              : (Theme.of(context).brightness == Brightness.light
                  ? C.borderSoftL
                  : C.borderSoftD),
        ),
        boxShadow: const [BoxShadow(color: Color(0x0B1E3246), blurRadius: 14, offset: Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            textDirection: TextDirection.ltr,
            children: [
              // channel avatar with a soft gradient ring
              Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      grad.first.withValues(alpha: .8),
                      grad.last.withValues(alpha: .25),
                    ],
                  ),
                ),
                child: Container(
                  width: 41, height: 41,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: grad,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(post.channel[0].toUpperCase(),
                      style: const TextStyle(
                          color: Colors.white, fontSize: 17,
                          fontWeight: FontWeight.w800)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(post.channel,
                              style: TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w800,
                                  color: p.text)),
                        ),
                        if (post.sponsored) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              border: Border.all(color: const Color(0xFFBFE3F6)),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text('Ad',
                                style: TextStyle(fontSize: 8, color: C.accentL)),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(post.meta,
                        style: TextStyle(fontSize: 9, color: p.text3)),
                  ],
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 11, 2, 8),
            child: Text(post.text,
                style: TextStyle(fontSize: 14, height: 2, color: p.text)),
          ),
          Container(
            padding: const EdgeInsets.only(top: 8),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: p.border))),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              textDirection: TextDirection.ltr,
              children: [
                _action(p, Icons.ios_share_rounded, s.share),
                _action(p, Icons.chat_bubble_outline_rounded,
                    post.channel == 'Ravi News' ? '24 replies' : 'View'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _action(Palette p, IconData icon, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 17, color: p.text2),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(fontSize: 10, color: p.text2)),
      ],
    );
  }
}
