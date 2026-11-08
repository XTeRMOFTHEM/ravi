/// Data models mirroring the RAVI backend JSON.
import 'dart:convert';

/// v1.3.2 — Persian labels for media snippets (reply previews / forwards).
/// models.dart cannot import AppState (import cycle), so the UI layer pushes
/// the language flag here once at startup.
bool kSnippetFa = true;

class RaviUser {
  final int id;
  final String username;
  final String name;
  final String avatar;
  final String bio;
  final bool isOfficial;
  final bool isPro;
  final int followers;
  final int following;

  const RaviUser({
    required this.id,
    required this.username,
    required this.name,
    this.avatar = '',
    this.bio = '',
    this.isOfficial = false,
    this.isPro = false,
    this.followers = 0,
    this.following = 0,
  });

  factory RaviUser.fromJson(Map<String, dynamic> j) => RaviUser(
        id: (j['id'] ?? 0) is int ? j['id'] as int : int.tryParse('${j['id']}') ?? 0,
        username: '${j['username'] ?? ''}',
        name: ((j['name'] ?? '') as String).trim().isEmpty
            ? '${j['username'] ?? ''}'
            : '${j['name'] ?? ''}',
        avatar: '${j['avatar'] ?? ''}',
        bio: '${j['bio'] ?? ''}',
        isOfficial: j['is_official'] == true || j['is_admin'] == true,
        isPro: j['is_pro'] == true,
        followers: _toInt(j['followers'] ?? j['follower_count'] ?? 0),
        following: _toInt(j['following'] ?? j['following_count'] ?? 0),
      );

  static int _toInt(dynamic v) => v is int ? v : int.tryParse('$v') ?? 0;
}

/// A row in the chats list: Global / group / channel / PV.
class ChatPreview {
  static const idGlobal = -1;
  final int id; // PV chat id (rooms use [roomId])
  final ChatKind kind;
  final String name;
  final String peerUsername; // PV only: the other side's @username
  final String roomId; // v1.0.7: group/channel room_id is a HEX STRING.
  /// CRITICAL v1.0.7 FIX: room_id arrives as a hex string like "d2b1d904";
  /// int.tryParse() returned null and EVERY room collapsed to id 0 → all
  /// rooms looked identical, room info 404'd and the message cache collided.
  final String avatar;
  final String lastMessage;
  final String lastTime; // display "HH:MM"
  final String lastTs; // v1.0.7 raw sortable timestamp ("YYYY-MM-DD HH:MM:SS")
  final String lastFileType;
  final String lastUser;
  final int unread;
  final bool canPost;
  final bool pinned;
  // v1.3.2 — PV peer badges (pro star / verified) shown in the chats list.
  final bool isPro;
  final bool isOfficial;
  // v1.4.0 — سیو مسیج: چت با خودمان (sender == receiver)
  final bool isSelf;

  const ChatPreview({
    required this.id,
    required this.kind,
    required this.name,
    this.peerUsername = '',
    this.roomId = '',
    this.avatar = '',
    this.lastMessage = '',
    this.lastTime = '',
    this.lastTs = '',
    this.lastFileType = 'text',
    this.lastUser = '',
    this.unread = 0,
    this.canPost = true,
    this.pinned = false,
    this.isPro = false,
    this.isOfficial = false,
    this.isSelf = false,
  });

  /// Stable identity for lists / sockets / pinning.
  String get key => kind == ChatKind.pv ? 'pv-$id' : 'room-$roomId';

  /// Normalized sortable timestamp — socket updates arrive as "HH:MM" only,
  /// so we anchor those to today; full datetimes sort as-is.
  String get sortTs {
    final s = lastTs.trim();
    if (s.length >= 10) return s;
    if (s.length == 5) {
      final n = DateTime.now();
      return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')} $s:00';
    }
    return s;
  }

  factory ChatPreview.global() => const ChatPreview(
        id: idGlobal,
        kind: ChatKind.general,
        name: 'Global',
        roomId: 'general',
        lastMessage: 'Public chat for everyone',
      );

  factory ChatPreview.fromRoom(Map<String, dynamic> j) => ChatPreview(
        id: 0,
        roomId: '${j['room_id'] ?? ''}',
        kind: '${j['room_type']}' == 'channel' ? ChatKind.channel : ChatKind.group,
        name: '${j['name'] ?? ''}',
        avatar: '${j['avatar'] ?? ''}',
        lastMessage: '${j['last_message'] ?? ''}',
        lastTime: _fmtTime(j['last_time']),
        lastTs: '${j['last_time'] ?? ''}',
        lastFileType: '${j['last_file_type'] ?? 'text'}',
        lastUser: '${j['last_user'] ?? ''}',
        unread: (j['unread'] ?? 0) is int ? j['unread'] as int : int.tryParse('${j['unread']}') ?? 0,
        canPost: j['can_post'] != false,
      );

  factory ChatPreview.fromPv(Map<String, dynamic> j) => ChatPreview(
        id: (j['id'] ?? 0) is int ? j['id'] as int : int.tryParse('${j['id']}') ?? 0,
        kind: ChatKind.pv,
        name: ((j['other_name'] ?? '') as String).trim().isEmpty
            ? '${j['other_user'] ?? ''}'
            : (j['other_name'] as String).trim(),
        peerUsername: '${j['other_user'] ?? ''}',
        avatar: '${j['other_avatar'] ?? ''}',
        lastMessage: '${j['last_message'] ?? ''}',
        lastTime: _fmtTime(j['last_time']),
        lastTs: '${j['last_time'] ?? ''}',
        // v1.3.2 — the file type of the LAST message (was dropped here, so
        // PV previews always showed raw text and never GIF/music/video labels)
        lastFileType: '${j['last_file_type'] ?? 'text'}',
        lastUser: '${j['last_user'] ?? ''}',
        unread: (j['unread_count'] ?? 0) is int
            ? j['unread_count'] as int
            : int.tryParse('${j['unread_count']}') ?? 0,
        // v1.3.2 — pro star / blue tick of the peer
        isPro: j['other_pro'] == true,
        isOfficial: j['other_official'] == true,
        // v1.4.0 — چت سیو مسیج (با خودمان)
        isSelf: j['is_self'] == true,
      );

  ChatPreview copyWith({
    String? lastMessage,
    String? lastTime,
    String? lastTs,
    int? unread,
    String? lastFileType,
    String? lastUser,
    bool? pinned,
    bool? isPro,
    bool? isOfficial,
    bool? isSelf,
  }) =>
      ChatPreview(
        id: id,
        kind: kind,
        name: name,
        peerUsername: peerUsername,
        roomId: roomId,
        avatar: avatar,
        lastMessage: lastMessage ?? this.lastMessage,
        lastTime: lastTime ?? this.lastTime,
        lastTs: lastTs ?? this.lastTs,
        lastFileType: lastFileType ?? this.lastFileType,
        lastUser: lastUser ?? this.lastUser,
        unread: unread ?? this.unread,
        canPost: canPost,
        pinned: pinned ?? this.pinned,
        isPro: isPro ?? this.isPro,
        isOfficial: isOfficial ?? this.isOfficial,
        isSelf: isSelf ?? this.isSelf,
      );

  static String _fmtTime(dynamic t) {
    final s = '$t';
    if (s.isEmpty || s == 'None' || s == 'null') return '';
    final p = s.split(' ');
    var clock = (p.length > 1 ? p[1] : p[0]);
    // v1.5.0 — همیشه «HH:MM» خالص: ثانیه/میلی‌ثانیه و بقایای datetime قدیمی
    // («09:23:45.123456») هرگز در سطر لیست چت‌ها دیده نمی‌شوند.
    final m = RegExp(r'^(\d{1,2}:\d{2})').firstMatch(clock);
    if (m != null) {
      final parts = m.group(1)!.split(':');
      return '${parts[0].padLeft(2, '0')}:${parts[1]}';
    }
    return clock;
  }
}

enum ChatKind { general, group, channel, pv }

/// v1.0.6 — result of `/api/room/<id>/messages` (Map payload with room meta).
class RoomHistory {
  final List<Message> messages;
  final bool canPost;
  final String roomType; // 'group' | 'channel'
  final bool isMuted;
  final String bio;
  final bool isPublic;
  final String roomUsername;
  final String myRole;

  const RoomHistory({
    this.messages = const [],
    this.canPost = true,
    this.roomType = 'group',
    this.isMuted = false,
    this.bio = '',
    this.isPublic = false,
    this.roomUsername = '',
    this.myRole = 'member',
  });
}

/// One reacting user (v1.0.7: for the mini avatar stack on reaction chips).
class ReactionUser {
  final String username;
  final String avatar;
  const ReactionUser({required this.username, this.avatar = ''});

  factory ReactionUser.fromMap(Map<String, dynamic> j) => ReactionUser(
        username: '${j['username'] ?? ''}',
        avatar: '${j['avatar'] ?? ''}',
      );
}

/// One emoji reaction summary for a message
/// (backend: {emoji, count, usernames: [...], reactors: [{username, avatar}]}).
class ReactionSummary {
  final String emoji;
  final int count;
  final List<String> usernames;
  final List<ReactionUser> reactors;

  const ReactionSummary({
    required this.emoji,
    required this.count,
    this.usernames = const [],
    this.reactors = const [],
  });

  factory ReactionSummary.fromMap(Map<String, dynamic> j) {
    final reactors = (j['reactors'] as List?)
        ?.whereType<Map>()
        .map((e) => ReactionUser.fromMap(Map<String, dynamic>.from(e)))
        .toList();
    final names = (j['usernames'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
    return ReactionSummary(
      emoji: '${j['emoji'] ?? ''}',
      count: (j['count'] ?? 0) is int ? j['count'] as int : int.tryParse('${j['count']}') ?? 0,
      usernames: names,
      // fall back to names when the payload has no avatar list
      reactors: reactors ??
          (j['reactors'] == null
              ? names.map((u) => ReactionUser(username: u)).toList()
              : const []),
    );
  }

  static List<ReactionSummary> listFrom(dynamic v) {
    if (v is! List) return const [];
    return v
        .whereType<Map>()
        .map((e) => ReactionSummary.fromMap(Map<String, dynamic>.from(e)))
        .toList();
  }
}

/// Header info of a PV chat (/api/pv/<id>/info) — drives the last-seen line.
class PvInfo {
  final String otherUser;
  final String otherAvatar;
  final String name;
  final bool online;
  final String? lastSeen; // ISO or null
  final bool lastSeenVisible;
  final bool isBlocked;
  final bool iBlockedThem;
  final bool dmClosed;
  final bool isPro;
  final bool isAdmin;

  const PvInfo({
    required this.otherUser,
    this.otherAvatar = '',
    this.name = '',
    this.online = false,
    this.lastSeen,
    this.lastSeenVisible = true,
    this.isBlocked = false,
    this.iBlockedThem = false,
    this.dmClosed = false,
    this.isPro = false,
    this.isAdmin = false,
  });

  factory PvInfo.fromJson(Map<String, dynamic> j) => PvInfo(
        otherUser: '${j['other_user'] ?? ''}',
        otherAvatar: '${j['other_avatar'] ?? ''}',
        name: '${j['name'] ?? ''}',
        online: j['online'] == true,
        lastSeen: j['last_seen'] == null ? null : '${j['last_seen']}',
        lastSeenVisible: j['last_seen_visible'] != false,
        isBlocked: j['is_blocked'] == true,
        iBlockedThem: j['i_blocked_them'] == true,
        dmClosed: j['dm_closed'] == true,
        isPro: j['is_pro'] == true,
        isAdmin: j['is_admin'] == true,
      );

  /// "online" / "last seen recently" / "last seen 14:32" …
  String lastSeenLabel(bool fa) {
    if (online) return fa ? 'آنلاین' : 'online';
    if (!lastSeenVisible || lastSeen == null) return '';
    final dt = DateTime.tryParse(lastSeen!);
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 5) return fa ? 'آخرین بازدید به‌تازگی' : 'last seen recently';
    if (diff.inMinutes < 60) {
      return fa
          ? 'آخرین بازدید ${diff.inMinutes} دقیقه پیش'
          : 'last seen ${diff.inMinutes} minutes ago';
    }
    if (diff.inHours < 24) {
      return fa
          ? 'آخرین بازدید ${diff.inHours} ساعت پیش'
          : 'last seen ${diff.inHours} hours ago';
    }
    final d = diff.inDays;
    if (d == 1) return fa ? 'آخرین بازدید دیروز' : 'last seen yesterday';
    if (d < 30) {
      return fa ? 'آخرین بازدید $d روز پیش' : 'last seen $d days ago';
    }
    final mm = '${dt.month}'.padLeft(2, '0');
    final dd = '${dt.day}'.padLeft(2, '0');
    return fa
        ? 'آخرین بازدید $dd/$mm/${dt.year}'
        : 'last seen $dd/$mm/${dt.year}';
  }
}

/// Group/channel info (/room/<room_id>/members).
class RoomInfo {
  final String roomId;
  final String name;
  final String avatar;
  final String roomType; // group | channel
  final String bio;
  final String username;
  final bool isPublic;
  final int memberCount;
  final String inviteLink;
  final List<RoomMember> members;
  final String myRole;
  final bool membersHidden;
  final List<RoomBannedUser> banned;

  const RoomInfo({
    required this.roomId,
    this.name = '',
    this.avatar = '',
    this.roomType = 'group',
    this.bio = '',
    this.username = '',
    this.isPublic = false,
    this.memberCount = 0,
    this.inviteLink = '',
    this.members = const [],
    this.myRole = 'member',
    this.membersHidden = false,
    this.banned = const [],
  });

  factory RoomInfo.fromJson(Map<String, dynamic> j) => RoomInfo(
        roomId: '${j['room_id'] ?? ''}',
        name: '${j['room_name'] ?? ''}',
        avatar: '${j['room_avatar'] ?? ''}',
        roomType: '${j['room_type'] ?? 'group'}',
        bio: '${j['bio'] ?? ''}',
        username: '${j['username'] ?? ''}',
        isPublic: j['is_public'] == true,
        memberCount: (j['member_count'] ?? 0) is int
            ? j['member_count'] as int
            : int.tryParse('${j['member_count']}') ?? 0,
        inviteLink: '${j['invite_link'] ?? ''}',
        myRole: '${j['my_role'] ?? 'member'}',
        membersHidden: j['members_hidden'] == true,
        members: ((j['members'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => RoomMember.fromMap(Map<String, dynamic>.from(e)))
            .toList(),
        banned: ((j['banned'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => RoomBannedUser.fromMap(Map<String, dynamic>.from(e)))
            .toList(),
      );
}

/// A banned (kicked) room member — shown to managers with an Unban action.
class RoomBannedUser {
  final int userId;
  final String username;
  final String avatar;
  final String reason;
  const RoomBannedUser({
    this.userId = 0,
    this.username = '',
    this.avatar = '',
    this.reason = '',
  });

  factory RoomBannedUser.fromMap(Map<String, dynamic> j) => RoomBannedUser(
        userId:
            j['id'] is int ? j['id'] as int : int.tryParse('${j['id']}') ?? 0,
        username: '${j['username'] ?? ''}',
        avatar: '${j['avatar'] ?? ''}',
        reason: '${j['reason'] ?? ''}',
      );
}

class RoomMember {
  final int id; // db user id — required for ban / promote / demote
  final String username;
  final String name;
  final String avatar;
  final bool isOwner;
  final bool isRoomAdmin;
  final String adminTitle;
  final bool isPro;
  final bool online;

  const RoomMember({
    this.id = 0,
    required this.username,
    this.name = '',
    this.avatar = '',
    this.isOwner = false,
    this.isRoomAdmin = false,
    this.adminTitle = '',
    this.isPro = false,
    this.online = false,
  });

  factory RoomMember.fromMap(Map<String, dynamic> j) => RoomMember(
        id: j['id'] is int ? j['id'] as int : int.tryParse('${j['id']}') ?? 0,
        username: '${j['username'] ?? ''}',
        name: '${j['name'] ?? ''}',
        avatar: '${j['avatar'] ?? ''}',
        isOwner: j['is_owner'] == true,
        isRoomAdmin: j['is_room_admin'] == true,
        adminTitle: '${j['admin_title'] ?? ''}',
        isPro: j['is_pro'] == true,
      );
}

/// One message in a conversation (general / pv / group).
class Message {
  final int id;
  final String clientMsgId;
  final String username;
  final String displayName;
  final String text;
  final String time; // 'HH:MM'
  final String dateKey; // 'YYYY-MM-DD'
  final String avatar;
  final String fileUrl;
  final String fileType;
  final bool isMe;
  final String? replyToId;
  final String? replyAuthor;
  final String? replyText;
  final bool pending;
  final bool failed;
  final List<ReactionSummary> reactions;
  final int seenCount; // channel post views (0 = unknown)
  final String forwardFrom;
  final String forwardFromUsername;
  final bool isRead; // pv: peer has seen
  final bool isPro;
  final bool isOfficial;
  final String adminTitle;
  // v1.1.1 — true when the author IS the group/channel owner (gold tag)
  final bool isOwner;
  // ---- v1.0.6: optimistic local media + upload progress (Telegram-style) ----
  final String localPath; // local file while uploading (image preview)
  final double uploadPct; // 0..1 (only while pending + localPath set)
  final int uploadSent; // bytes already sent (for «3.2 / 12.5 MB»)
  final int fileSize; // bytes (0 = unknown)
  final bool removing; // true during the delete animation
  final bool isEdited; // v1.0.7: message was edited ("edited" tag)
  final List<ReactionUser> reactors; // v1.0.7: avatar list for reaction chips
  // v1.1.0 — client-side album grouping: several photos sent together share
  // one albumId and render inside a single Telegram-style grouped bubble.
  final String albumId;
  // ---- v1.2.1 — Telegram-style media metadata ----
  //  • mediaW/mediaH : pixel dims of a photo/album item — the bubble reserves
  //    the exact aspect from frame ONE (no more layout shift when the image
  //    finishes decoding = the "small jump" on send)
  //  • music metadata: title / artist / cover / duration parsed from ID3 tags
  //  • isVoiceNote   : true for recorded voice notes, false for music files
  final int mediaW;
  final int mediaH;
  final String mediaTitle;
  final String mediaArtist;
  final String mediaCover;
  final int mediaDurMs;
  final bool isVoiceNote;
  // v1.3.1 — backend `media_meta.kind` ('voice'|'music'). When the server
  // explicitly says MUSIC (it also infers it from the file extension for old
  // rows), the bubble STAYS a music player after re-entering the chat — the
  // old "song turns into a voice note" bug.
  final bool isMusicKind;

  const Message({
    required this.id,
    this.clientMsgId = '',
    required this.username,
    this.displayName = '',
    required this.text,
    required this.time,
    this.dateKey = '',
    this.avatar = '',
    this.fileUrl = '',
    this.fileType = 'text',
    required this.isMe,
    this.replyToId,
    this.replyAuthor,
    this.replyText,
    this.pending = false,
    this.failed = false,
    this.reactions = const [],
    this.seenCount = 0,
    this.forwardFrom = '',
    this.forwardFromUsername = '',
    this.isRead = false,
    this.isPro = false,
    this.isOfficial = false,
    this.adminTitle = '',
    this.isOwner = false,
    this.localPath = '',
    this.uploadPct = 0,
    this.uploadSent = 0,
    this.fileSize = 0,
    this.removing = false,
    this.isEdited = false,
    this.reactors = const [],
    this.albumId = '',
    this.mediaW = 0,
    this.mediaH = 0,
    this.mediaTitle = '',
    this.mediaArtist = '',
    this.mediaCover = '',
    this.mediaDurMs = 0,
    this.isVoiceNote = false,
    this.isMusicKind = false,
  });

  Message copyWith({
    int? id,
    bool? pending,
    bool? failed,
    List<ReactionSummary>? reactions,
    List<ReactionUser>? reactors,
    bool? isRead,
    int? seenCount,
    String? text,
    String? fileUrl,
    String? localPath,
    double? uploadPct,
    int? uploadSent,
    int? fileSize,
    bool? removing,
    bool? isEdited,
    String? albumId,
    int? mediaW,
    int? mediaH,
    String? mediaTitle,
    String? mediaArtist,
    String? mediaCover,
    int? mediaDurMs,
    bool? isVoiceNote,
    bool? isMusicKind,
  }) =>
      Message(
        id: id ?? this.id,
        clientMsgId: clientMsgId,
        username: username,
        displayName: displayName,
        text: text ?? this.text,
        time: time,
        dateKey: dateKey,
        avatar: avatar,
        fileUrl: fileUrl ?? this.fileUrl,
        fileType: fileType,
        isMe: isMe,
        replyToId: replyToId,
        replyAuthor: replyAuthor,
        replyText: replyText,
        pending: pending ?? this.pending,
        failed: failed ?? this.failed,
        reactions: reactions ?? this.reactions,
        reactors: reactors ?? this.reactors,
        seenCount: seenCount ?? this.seenCount,
        forwardFrom: forwardFrom,
        forwardFromUsername: forwardFromUsername,
        isRead: isRead ?? this.isRead,
        isPro: isPro,
        isOfficial: isOfficial,
        adminTitle: adminTitle,
        isOwner: isOwner,
        localPath: localPath ?? this.localPath,
        uploadPct: uploadPct ?? this.uploadPct,
        uploadSent: uploadSent ?? this.uploadSent,
        fileSize: fileSize ?? this.fileSize,
        removing: removing ?? this.removing,
        isEdited: isEdited ?? this.isEdited,
        albumId: albumId ?? this.albumId,
        mediaW: mediaW ?? this.mediaW,
        mediaH: mediaH ?? this.mediaH,
        mediaTitle: mediaTitle ?? this.mediaTitle,
        mediaArtist: mediaArtist ?? this.mediaArtist,
        mediaCover: mediaCover ?? this.mediaCover,
        mediaDurMs: mediaDurMs ?? this.mediaDurMs,
        isVoiceNote: isVoiceNote ?? this.isVoiceNote,
        isMusicKind: isMusicKind ?? this.isMusicKind,
      );

  bool get isImage => fileType == 'image' || fileType == 'gif';
  bool get isVideo => fileType == 'video';
  bool get isAudio => fileType == 'audio';
  bool get isFile =>
      fileType != 'text' && !isImage && !isVideo && !isAudio;
  bool get isMedia => isImage || isVideo || isAudio;
  bool get mine => isMe;

  /// v1.2.1 — Telegram-style SERVICE messages (glass capsule, no bubble):
  /// backend tags them with a `sys_*` file_type (join / leave / ban …).
  bool get isService => fileType.startsWith('sys_');
  bool get isServiceJoin =>
      fileType == 'sys_join_link' || fileType == 'sys_join_username';
  bool get isServiceLeave => fileType == 'sys_leave';

  /// v1.2.1 — a true MUSIC file (not a recorded voice note): decided by the
  /// parsed metadata; v1.3.1 — the backend `kind:'music'` flag (inferred from
  /// the file extension for old rows) also counts, with or without a title.
  bool get isMusic =>
      isAudio && !isVoiceNote && (mediaTitle.isNotEmpty || isMusicKind);

  /// v1.3.1 — "Song 01" from "/static/uploads/12_..._ab/Song 01.mp3".
  String get musicTitleFallback {
    if (mediaTitle.isNotEmpty) return mediaTitle;
    if (fileUrl.isEmpty) return 'Music';
    var base = fileUrl.split('/').last;
    final dot = base.lastIndexOf('.');
    if (dot > 0) base = base.substring(0, dot);
    // server-generated names ("3_20261030194012_ab12cd") are noise for a
    // human — show a clean generic label instead of garbage digits.
    if (RegExp(r'^\d{1,6}_\d{10,}_[0-9a-f]{4,}$').hasMatch(base)) return 'Music';
    return base.isEmpty ? 'Music' : base;
  }

  /// Aspect ratio for photo/video envelopes (0 = unknown).
  double get mediaAspect =>
      (mediaW > 0 && mediaH > 0) ? mediaW / mediaH : 0;

  /// v1.1.0 — number of real emoji glyphs in an emoji-only message
  /// (variation selectors / ZWJ / spaces are not counted).
  int get emojiCount {
    if (!isEmojiOnly) return 1;
    var n = 0;
    for (final r in text.runes) {
      if (r == 0xFE0F || r == 0x200D || r == 0x200B || r == 0x20) continue;
      n++;
    }
    return n < 1 ? 1 : n;
  }

  /// Telegram emoji-only font size: one emoji big, multiples smaller.
  double get emojiFontSize {
    final c = emojiCount;
    if (c == 1) return 40;
    if (c == 2) return 32;
    if (c <= 4) return 26;
    return 21;
  }

  /// Telegram-style: a message that is ONLY emoji (no text) floats without a
  /// bubble. Allows up to 8 emoji with optional spaces/variation selectors.
  static final RegExp _emojiOnly = RegExp(
      r'^(?:[\s\u200d\uFE0F\u200B]|(?:\uD83C[\uDF00-\uDFFF]|\uD83D[\uDC00-\uDFFF]|\uD83E[\uDC00-\uDFFF]|[\u2190-\u2BFF\u2600-\u27BF\u2934\u2935\u3030\u303D\u3297\u3299\u00A9\u00AE\u2122])){1,24}$');

  bool get isEmojiOnly {
    final t = text.trim();
    if (t.isEmpty) return false;
    if (!_emojiOnly.hasMatch(t)) return false;
    return t.runes.length <= 12;
  }

  /// Human size like Telegram ("۲.۴ MB" / "2.4 MB").
  String get fileSizeLabel {
    if (fileSize <= 0) return '';
    const kb = 1024, mb = 1024 * 1024;
    if (fileSize >= mb) {
      final v = fileSize / mb;
      return '${v.toStringAsFixed(v < 10 ? 1 : 0)} MB';
    }
    if (fileSize >= kb) return '${(fileSize / kb).round()} KB';
    return '$fileSize B';
  }

  /// Snippet used by reply quotes / forward previews.
  /// v1.3.2 — clean WhatsApp-style labels, Persian-first like the app:
  /// GIF → "GIF", music → its clean song name, video → "ویدئو".
  String get previewSnippet {
    final fa = kSnippetFa;
    if (isEmojiOnly) return text;
    if (isServiceJoin) return '👥';
    if (isServiceLeave) return '👋';
    if (fileType == 'gif') return 'GIF';
    if (isMusic) {
      final t = musicTitleFallback;
      return t.isEmpty ? (fa ? '🎵 موزیک' : '🎵 Music') : '🎵 $t';
    }
    if (isImage) return fa ? '📷 عکس' : '📷 Photo';
    if (isVideo) return fa ? '🎥 ویدئو' : '🎥 Video';
    if (isAudio) return fa ? '🎤 پیام صوتی' : '🎤 Voice message';
    // v1.5.0 — پیش‌نمایش فایل: 📄 + اسم واقعی فایل (یا «فایل»)
    if (isFile) {
      final t = mediaTitle.trim();
      if (t.isNotEmpty) return '📄 $t';
      if (fileUrl.isNotEmpty) {
        var base = fileUrl.split('/').last;
        final dot = base.lastIndexOf('.');
        if (dot > 0) base = base.substring(0, dot);
        if (RegExp(r'^\d{1,6}_\d{10,}_[0-9a-f]{4,}$').hasMatch(base)) {
          return fa ? '📄 فایل' : '📄 File';
        }
        if (base.isNotEmpty) return '📄 $base';
      }
      return fa ? '📄 فایل' : '📄 File';
    }
    return text;
  }

  String get authorLabel {
    if (displayName.isNotEmpty) return displayName;
    return username;
  }

  Map<String, dynamic> _reactionsToCache() => {
        for (final r in reactions)
          r.emoji: {'emoji': r.emoji, 'count': r.count, 'usernames': r.usernames},
      };

  static List<ReactionSummary> _reactionsFromCache(dynamic v) {
    if (v is Map) {
      return v.values
          .whereType<Map>()
          .map((e) => ReactionSummary.fromMap(Map<String, dynamic>.from(e)))
          .toList();
    }
    return const [];
  }

  /// v1.1.0 — normalize any server timestamp to a clean "HH:MM".
  static String _normTime(String raw) {
    final s = raw.trim();
    if (s.isEmpty || s == 'None' || s == 'null') return '';
    // full datetime → take the clock part
    final space = s.indexOf(' ');
    final clock = space > 0 ? s.substring(space + 1) : s;
    final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(clock);
    if (m == null) return clock;
    return '${m.group(1)!.padLeft(2, '0')}:${m.group(2)}';
  }

  /// Build from /api/general_messages JSON row (also room messages).
  factory Message.fromGeneral(Map<String, dynamic> j, String myUsername) {
    final ts = '${j['timestamp'] ?? ''}';
    final mm = _parseMediaMeta(j['media_meta']);
    return Message(
      id: _i(j['message_id']),
      username: '${j['username'] ?? ''}',
      displayName: '${j['display_name'] ?? ''}',
      text: '${j['message'] ?? ''}',
      time: _normTime(ts),
      dateKey: '${j['date_key'] ?? ''}',
      avatar: '${j['avatar'] ?? ''}',
      fileUrl: '${j['file_url'] ?? ''}',
      fileType: '${j['file_type'] ?? 'text'}',
      isMe: '${j['username'] ?? ''}' == myUsername,
      replyToId: j['reply_to'] == null ? null : '${j['reply_to']}',
      replyAuthor: '${j['reply_display_name'] ?? j['reply_username'] ?? j['reply_author'] ?? ''}',
      replyText: '${j['reply_text'] ?? j['reply_message'] ?? ''}',
      reactions: ReactionSummary.listFrom(j['reactions']),
      seenCount: _i(j['seen_count'] ?? 0),
      forwardFrom: '${j['forward_from'] ?? ''}',
      forwardFromUsername: '${j['forward_from_username'] ?? ''}',
      isPro: j['is_pro'] == true,
      isOfficial: j['is_official'] == true,
      adminTitle: '${j['admin_title'] ?? ''}',
      isOwner: j['author_is_owner'] == true ||
          '${j['admin_title'] ?? ''}'.toLowerCase() == 'owner',
      isEdited: j['is_edited'] == true,
      mediaW: mm.w,
      mediaH: mm.h,
      mediaTitle: mm.title,
      mediaArtist: mm.artist,
      mediaCover: mm.cover,
      mediaDurMs: mm.durMs,
      isVoiceNote: mm.voice,
      isMusicKind: mm.music,
    );
  }

  /// Build from socket `new_message` payload.
  factory Message.fromSocket(Map<String, dynamic> j, String myUsername) {
    final mm = _parseMediaMeta(j['media_meta']);
    return Message(
      id: _i(j['message_id']),
      clientMsgId: '${j['client_msg_id'] ?? ''}',
      username: '${j['username'] ?? ''}',
      displayName: '${j['display_name'] ?? ''}',
      text: '${j['message'] ?? ''}',
      time: _normTime('${j['timestamp'] ?? ''}'),
      dateKey: _todayKey(),
      avatar: '${j['avatar'] ?? ''}',
      fileUrl: '${j['file_url'] ?? ''}',
      fileType: '${j['file_type'] ?? 'text'}',
      isMe: '${j['username'] ?? ''}' == myUsername,
      replyToId: j['reply_to'] == null ? null : '${j['reply_to']}',
      replyAuthor: '${j['reply_display_name'] ?? j['reply_username'] ?? j['reply_author'] ?? ''}',
      replyText: '${j['reply_text'] ?? j['reply_message'] ?? ''}',
      seenCount: _i(j['seen_count'] ?? 0),
      forwardFrom: '${j['forward_from'] ?? ''}',
      forwardFromUsername: '${j['forward_from_username'] ?? ''}',
      isPro: j['is_pro'] == true,
      isOfficial: j['is_official'] == true,
      adminTitle: '${j['admin_title'] ?? ''}',
      isOwner: j['sender_is_owner'] == true,
      isEdited: j['is_edited'] == true,
      mediaW: mm.w,
      mediaH: mm.h,
      mediaTitle: mm.title,
      mediaArtist: mm.artist,
      mediaCover: mm.cover,
      mediaDurMs: mm.durMs,
      isVoiceNote: mm.voice,
      isMusicKind: mm.music,
    );
  }

  /// v1.3.2 — public wrapper so controllers (confirmSent) can merge the
  /// send-echo's media_meta into the optimistic message the same way
  /// Message.fromSocket does.
  static ({int w, int h, String title, String artist, String cover, int durMs, bool voice, bool music})
      parseMediaMeta(dynamic v) => _parseMediaMeta(v);

  /// v1.2.1 — parse the backend `media_meta` payload (JSON string or map):
  /// {kind:'voice'|'music', title, artist, cover, dur(ms), w, h}
  static ({int w, int h, String title, String artist, String cover, int durMs, bool voice, bool music})
      _parseMediaMeta(dynamic v) {
    var m = v;
    if (m is String) {
      try {
        m = jsonDecode(m);
      } catch (_) {
        m = null;
      }
    }
    if (m is! Map) {
      return (w: 0, h: 0, title: '', artist: '', cover: '', durMs: 0, voice: false, music: false);
    }
    int ii(dynamic x) => x is int ? x : int.tryParse('$x') ?? 0;
    return (
      w: ii(m['w'] ?? m['width'] ?? 0),
      h: ii(m['h'] ?? m['height'] ?? 0),
      title: '${m['title'] ?? ''}',
      artist: '${m['artist'] ?? ''}',
      cover: '${m['cover'] ?? ''}',
      durMs: ii(m['dur'] ?? m['dur_ms'] ?? m['duration'] ?? 0),
      voice: '${m['kind'] ?? ''}' == 'voice' || m['voice'] == true,
      music: '${m['kind'] ?? ''}' == 'music',
    );
  }

  /// Build from /api/pv/<id>/messages JSON row.
  factory Message.fromPv(Map<String, dynamic> j, String myUsername) {
    final ts = '${j['timestamp'] ?? ''}';
    final parts = ts.split(' ');
    // v1.1.1 CRITICAL date-pill fix: the PV payload's `timestamp` is only
    // "HH:MM" — the REAL day separator must come from `date_key`.
    // Falling back to the clock part made dateKey differ on EVERY message,
    // which rendered a "Today" pill after every single bubble.
    final dkRaw = '${j['date_key'] ?? ''}'.trim();
    final dk = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(dkRaw)
        ? dkRaw
        : (RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(parts[0])
            ? parts[0].substring(0, 10)
            : '');
    final mm = _parseMediaMeta(j['media_meta']);
    return Message(
      id: _i(j['id']),
      username: '${j['username'] ?? ''}',
      displayName: '${j['display_name'] ?? ''}',
      text: '${j['message'] ?? ''}',
      time: _normTime(ts),
      dateKey: dk,
      avatar: '${j['avatar'] ?? ''}',
      fileUrl: '${j['file_url'] ?? ''}',
      fileType: '${j['file_type'] ?? 'text'}',
      isMe: '${j['username'] ?? ''}' == myUsername,
      replyToId: j['reply_to'] == null ? null : '${j['reply_to']}',
      replyAuthor: '${j['reply_display_name'] ?? j['reply_username'] ?? j['reply_author'] ?? ''}',
      replyText: '${j['reply_text'] ?? j['reply_message'] ?? ''}',
      reactions: ReactionSummary.listFrom(j['reactions']),
      forwardFrom: '${j['forward_from'] ?? ''}',
      forwardFromUsername: '${j['forward_from_username'] ?? ''}',
      isRead: j['is_read'] == true,
      mediaW: mm.w,
      mediaH: mm.h,
      mediaTitle: mm.title,
      mediaArtist: mm.artist,
      mediaCover: mm.cover,
      mediaDurMs: mm.durMs,
      isVoiceNote: mm.voice,
      isMusicKind: mm.music,
    );
  }

  static String _todayKey() {
    final n = DateTime.now();
    return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  static int _i(dynamic v) => v is int ? v : int.tryParse('$v') ?? 0;

  Map<String, dynamic> toCache() => {
        'id': id, 'cmid': clientMsgId, 'u': username, 'dn': displayName,
        't': text, 'tm': time, 'dk': dateKey, 'av': avatar,
        'fu': fileUrl, 'ft': fileType, 'me': isMe,
        'rt': replyToId, 'ra': replyAuthor, 'rx': replyText,
        'pg': pending, 'fl': failed,
        'rc': _reactionsToCache(), 'ir': isRead,
        'ff': forwardFrom, 'ffu': forwardFromUsername,
        'ie': isEdited, 'al': albumId,
        'mw': mediaW, 'mh': mediaH, 'mt': mediaTitle, 'ma': mediaArtist,
        'mc': mediaCover, 'md': mediaDurMs, 'iv': isVoiceNote,
        'im': isMusicKind,
      };

  factory Message.fromCache(Map<dynamic, dynamic> j) => Message(
        id: j['id'] is int ? j['id'] as int : int.tryParse('${j['id']}') ?? 0,
        clientMsgId: '${j['cmid'] ?? ''}',
        username: '${j['u'] ?? ''}',
        displayName: '${j['dn'] ?? ''}',
        text: '${j['t'] ?? ''}',
        time: '${j['tm'] ?? ''}',
        dateKey: '${j['dk'] ?? ''}',
        avatar: '${j['av'] ?? ''}',
        fileUrl: '${j['fu'] ?? ''}',
        fileType: '${j['ft'] ?? 'text'}',
        isMe: j['me'] == true,
        replyToId: j['rt'],
        replyAuthor: '${j['ra'] ?? ''}',
        replyText: '${j['rx'] ?? ''}',
        pending: j['pg'] == true,
        failed: j['fl'] == true,
        reactions: _reactionsFromCache(j['rc']),
        isRead: j['ir'] == true,
        forwardFrom: '${j['ff'] ?? ''}',
        forwardFromUsername: '${j['ffu'] ?? ''}',
        isEdited: j['ie'] == true,
        albumId: '${j['al'] ?? ''}',
        mediaW: j['mw'] is int ? j['mw'] as int : int.tryParse('${j['mw']}') ?? 0,
        mediaH: j['mh'] is int ? j['mh'] as int : int.tryParse('${j['mh']}') ?? 0,
        mediaTitle: '${j['mt'] ?? ''}',
        mediaArtist: '${j['ma'] ?? ''}',
        mediaCover: '${j['mc'] ?? ''}',
        mediaDurMs: j['md'] is int ? j['md'] as int : int.tryParse('${j['md']}') ?? 0,
        isVoiceNote: j['iv'] == true,
        isMusicKind: j['im'] == true,
      );
}

class MagazinePost {
  final String channel;
  final String meta;
  final String text;
  final int avatarIndex; // 0..3
  final bool sponsored;

  const MagazinePost(this.channel, this.meta, this.text, this.avatarIndex,
      {this.sponsored = false});
}
