import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ravi/core/api_service.dart';
import 'package:ravi/core/i18n.dart';
import 'package:ravi/core/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('ApiService.authHeadersFor host-scoping', () {
    test('never leaks Cookie header to third-party or protocol-relative origins', () async {
      await ApiService.I.jar.setRaw('session=super_secret_token');
      expect(ApiService.I.authHeadersFor('https://evil.example.com/a.jpg'), isEmpty);
      expect(ApiService.I.authHeadersFor('http://127.0.0.1:9999/steal'), isEmpty);
      expect(ApiService.I.authHeadersFor('//evil.example.com/steal.png'), isEmpty);
      expect(ApiService.I.authHeadersFor(''), isEmpty);
      await ApiService.I.jar.clear();
    });

    test('returns Cookie for relative backend paths when logged in', () async {
      await ApiService.I.jar.setRaw('session=abc123');
      final hdrs = ApiService.I.authHeadersFor('/uploads/pic.jpg');
      expect(hdrs['Cookie'], 'session=abc123');
      await ApiService.I.jar.clear();
      expect(ApiService.I.authHeadersFor('/uploads/pic.jpg'), isEmpty);
    });
  });

  group('MagazinePost & MagazineReply models', () {
    test('parses server JSON payload cleanly', () {
      final post = MagazinePost.fromJson({
        'id': 42,
        'user_id': 7,
        'username': 'alice',
        'author_name': 'Alice',
        'author_avatar': '/uploads/a.png',
        'author_is_pro': true,
        'author_is_official': false,
        'channel': 'RAVI Tech',
        'category': 'tech',
        'content': 'Hello RAVI Magazine!',
        'media_url': '/uploads/cover.jpg',
        'likes_count': 7,
        'replies_count': 2,
        'views_count': 15,
        'liked_by_me': true,
        'is_own': true,
        'created_at': '2026-11-15T10:00:00',
      });
      expect(post.id, 42);
      expect(post.userId, 7);
      expect(post.username, 'alice');
      expect(post.authorName, 'Alice');
      expect(post.authorIsPro, isTrue);
      expect(post.channel, 'RAVI Tech');
      expect(post.category, 'tech');
      expect(post.content, 'Hello RAVI Magazine!');
      expect(post.mediaUrl, '/uploads/cover.jpg');
      expect(post.likesCount, 7);
      expect(post.repliesCount, 2);
      expect(post.viewsCount, 15);
      expect(post.likedByMe, isTrue);
      expect(post.isOwn, isTrue);

      final updated = post.copyWith(likedByMe: false, likesCount: 6);
      expect(updated.likedByMe, isFalse);
      expect(updated.likesCount, 6);
      expect(updated.content, 'Hello RAVI Magazine!');
    });

    test('parses MagazineReply cleanly', () {
      final reply = MagazineReply.fromJson({
        'id': 9,
        'post_id': 42,
        'username': 'bob',
        'author_name': 'Bob',
        'author_avatar': 'default.png',
        'content': 'Nice post!',
        'created_at': '2026-11-15T10:05:00',
      });
      expect(reply.id, 9);
      expect(reply.postId, 42);
      expect(reply.username, 'bob');
      expect(reply.authorName, 'Bob');
      expect(reply.content, 'Nice post!');
    });
  });

  group('Localization parity (Fa / En)', () {
    test('all Magazine, AI, and Report strings are non-empty in both languages', () {
      for (final lang in [Lang.fa, Lang.en]) {
        final s = S(lang);
        expect(s.navMagazine, isNotEmpty);
        expect(s.newPost, isNotEmpty);
        expect(s.publishPost, isNotEmpty);
        expect(s.postTitleHint, isNotEmpty);
        expect(s.postContentHint, isNotEmpty);
        expect(s.postPublished, isNotEmpty);
        expect(s.postDeleted, isNotEmpty);
        expect(s.repliesTitle, isNotEmpty);
        expect(s.writeReplyHint, isNotEmpty);
        expect(s.noPostsYet, isNotEmpty);
        expect(s.noRepliesYet, isNotEmpty);
        expect(s.copiedToClipboard, isNotEmpty);
        expect(s.reportReasonHint, isNotEmpty);
        expect(s.aiAssistantTitle, isNotEmpty);
        expect(s.aiAssistantSub, isNotEmpty);
        expect(s.aiAskHint, isNotEmpty);
        expect(s.aiProBadge, isNotEmpty);
        expect(s.tapToDownload, isNotEmpty);
        expect(s.cancel, isNotEmpty);
      }
    });
  });
}
