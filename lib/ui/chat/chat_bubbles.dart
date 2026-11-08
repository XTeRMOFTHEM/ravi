import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/api_service.dart';
import '../../core/app_state.dart';
import '../../core/chat_bg.dart';
import '../../core/constants.dart';
import '../../core/media_dims_cache.dart';
import '../../core/media_download_manager.dart';
import '../../core/models.dart';
import '../widgets/common.dart';
import '../widgets/disk_image.dart';
import '../widgets/ravi_alerts.dart';
import 'audio_bubble.dart';
import 'message_action_panel.dart';
import 'package:flutter/services.dart';

/// Telegram-style entrance for newly appended bubbles — v1.2.1 REWRITE.
/// The row GROWS from zero height to its full height (Telegram's actual
/// mechanism): a reverse ListView then slides the older content up smoothly
/// frame-by-frame while the new bubble fades/slides in. Works identically
/// for own sends, incoming messages and every media type — no post-frame
/// scroll corrections, no 1-frame flash, no jump.
class BubbleAppear extends StatefulWidget {
  final Widget child;
  final bool animate;

  const BubbleAppear({super.key, required this.child, required this.animate});

  @override
  State<BubbleAppear> createState() => _BubbleAppearState();
}

class _BubbleAppearState extends State<BubbleAppear>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 240));

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      _c.forward();
    } else {
      _c.value = 1;
    }
  }

  @override
  void didUpdateWidget(covariant BubbleAppear old) {
    super.didUpdateWidget(old);
    if (!old.animate && widget.animate) _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.animate) return widget.child;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_c.value);
        return ClipRect(
          child: Align(
            alignment: Alignment.bottomCenter,
            heightFactor: (0.04 + 0.96 * t).clamp(0.0, 1.0),
            child: Opacity(
              opacity: t.clamp(0.0, 1.0),
              child: Transform.translate(
                offset: Offset(0, 8 * (1 - t)),
                child: child,
              ),
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// Collapse + fade wrapper for smoothly deleted messages.
class BubbleRemover extends StatelessWidget {
  final bool removing;
  final Widget child;
  const BubbleRemover({super.key, required this.removing, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: removing ? 0.6 : 1.0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInCubic,
      alignment: Alignment.center,
      child: AnimatedOpacity(
        opacity: removing ? 0 : 1,
        duration: const Duration(milliseconds: 200),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeInCubic,
          alignment: Alignment.bottomCenter,
          child: child,
        ),
      ),
    );
  }
}

/// The full message bubble — v1.0.6:
///  • borderless media when there is no caption (photo/video/GIF)
///  • GIF badge + overflow menu (download / save)
///  • Telegram upload ring + size while sending media
///  • emoji-only messages float WITHOUT a bubble
///  • sender avatar next to other users' bubbles (group/general)
///  • tappable reply quote (jumps to the original message)
class MessageBubble extends StatelessWidget {
  final Message msg;
  final ChatKind kind;
  final bool showAvatar; // others' avatar next to the bubble
  // v1.0.9 — CHANNEL mode: every post (even MINE) renders on the LEFT like
  // Telegram channels; author name + views instead of delivery ticks.
  final bool channelMode;
  // v1.1.0 — album group (first message + the rest of its photos)
  final List<Message>? album;
  final void Function(Message) onReply;
  final void Function(Message, String) onReact;
  final void Function(Message) onOpenProfile;
  final void Function(Message) onOpenMedia;
  final void Function(Message)? onJumpToReply;
  final void Function(Message)? onForward;
  final void Function(Message)? onDelete;
  final void Function(Message)? onSaveGif;
  final void Function(Message)? onDownload;
  final void Function(String token)? onTokenTap; // @mention / URL tap
  // v1.2.1 — long-press a SINGLE photo inside an album → its own action
  // panel (this is how reply-on-every-photo works, Telegram-style).
  final void Function(BuildContext ctx, Message item)? onAlbumItemLongPress;

  const MessageBubble({
    super.key,
    required this.msg,
    required this.kind,
    required this.onReply,
    required this.onReact,
    required this.onOpenProfile,
    required this.onOpenMedia,
    this.showAvatar = false,
    this.channelMode = false,
    this.album,
    this.onJumpToReply,
    this.onForward,
    this.onDelete,
    this.onSaveGif,
    this.onDownload,
    this.onTokenTap,
    this.onAlbumItemLongPress,
  });

  static final RegExp _emojiRe = RegExp(
      r'^[\s\u200d\uFE0F\u200B]*(?:\uD83C[\uDF00-\uDFFF]|\uD83D[\uDC00-\uDFFF]|\uD83E[\uDC00-\uDFFF]|[\u2190-\u2BFF\u2600-\u27BF])[\s\u200d\uFE0F\u200B]*$');

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    // v1.0.9 — channel posts NEVER render as "mine" (all left, like Telegram).
    final own = msg.isMe && !channelMode;

    // ---- floating emoji (no bubble) ----
    // v1.5.0 — آواتار کنار ایموجی هم‌اندازه‌ی حباب‌های دیگر (۲۶) — قبلاً ۳۴
    // بود و در گروه‌ها «پشت ایموجی بزرگ‌تر» دیده می‌شد؛ و برای پیام ایموجیِ
    // بقیه هم ساعتِ زیرش می‌آید (مثل ایموجی خودمان).
    final mediaNoCaption = msg.isImage && !msg.isAudio && msg.text.trim().isEmpty ||
        (msg.isVideo && msg.text.trim().isEmpty);
    final borderless = mediaNoCaption || msg.fileType == 'gif';

    if (msg.isEmojiOnly && msg.fileUrl.isEmpty) {
      // v1.1.1 — Telegram-style floating emoji, REPOSITIONED per feedback:
      //  • the sender's avatar now sits BESIDE the emoji (start side), like
      //    every normal message — NOT blurred behind it
      //  • own messages keep a tiny delivery-tick + time footer
      //  • glass reply quote still shows when this emoji is a reply
      //  • tap/long-press still open the action panel (reply works!)
      final fs = msg.emojiFontSize;
      final Widget emoji = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Text(
          msg.text,
          textDirection: bidiDirectionOf(msg.text),
          style: TextStyle(fontSize: fs, height: 1.12),
        ),
      );
      return Align(
        alignment: own ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 10),
          child: Column(
            crossAxisAlignment: own
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              if (msg.replyToId != null && msg.replyToId!.isNotEmpty)
                _ReplyQuote(
                  msg: msg,
                  palette: p,
                  own: own,
                  glassy: true,
                  onTap: onJumpToReply == null
                      ? null
                      : () => onJumpToReply!(msg),
                ),
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // avatar BESIDE the emoji (only for other people, and only
                  // in chats that show avatars at all) — SAME SIZE as normal
                  // message avatars (26) so groups look consistent
                  if (!own && showAvatar) ...[
                    GestureDetector(
                      onTap: () => onOpenProfile(msg),
                      child: _SenderAvatar(msg: msg, size: 26),
                    ),
                    const SizedBox(width: 7),
                  ],
                  emoji,
                ],
              ),
              // v1.5.0 — ساعت زیر ایموجی برای «همه» (خودی و غیرخودی) مثل واتساپ
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!own && showAvatar == false) const SizedBox(width: 0),
                    if (msg.pending)
                      const PendingClock(failed: false)
                    else if (msg.failed)
                      const PendingClock(failed: true)
                    else if (own && kind == ChatKind.pv)
                      Icon(
                          msg.isRead
                              ? Icons.done_all_rounded
                              : Icons.done_rounded,
                          size: 12,
                          color: msg.isRead
                              ? const Color(0xFF7DD3FC)
                              : p.chatText3.withValues(alpha: .8))
                    else if (own)
                      Icon(Icons.done_all_rounded,
                          size: 12, color: p.chatText3.withValues(alpha: .8)),
                    if (own) const SizedBox(width: 4),
                    Text(msg.time,
                        style: TextStyle(
                            fontSize: 9.5,
                            color: p.chatText3.withValues(alpha: .8))),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    final Widget bubbleCore = Container(
      constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.74),
      child: album != null && album!.length > 1
          ? _AlbumBubble(
              items: album!,
              palette: p,
              own: own,
              onOpenMedia: onOpenMedia,
              onItemLongPress: onAlbumItemLongPress,
            )
          : borderless
              ? _borderlessMedia(context, p)
              : _bubbled(context, p, own),
    );

    return Align(
      alignment: own ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
      child: Padding(
        // small breathing gap between consecutive bubbles (v1.0.7: a bit airier)
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: showAvatar && !own
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  GestureDetector(
                    onTap: () => onOpenProfile(msg),
                    child: _SenderAvatar(msg: msg),
                  ),
                  const SizedBox(width: 6),
                  Flexible(child: bubbleCore),
                ],
              )
            : bubbleCore,
      ),
    );
  }

  // ================= bordered bubble (text / caption / audio) =================
  Widget _bubbled(BuildContext context, Palette p, bool own) {
    final hasMedia = msg.isImage && msg.fileUrl.isNotEmpty && !msg.isAudio;
    final hasVideo = msg.isVideo && msg.fileUrl.isNotEmpty;
    final hasAudio = msg.isAudio && msg.fileUrl.isNotEmpty;
    // v1.5.0 — حباب «فایل» برای هر فرمتی (zip / pdf / apk / …): کارت تمیز با
    // آیکون نوع فایل، اسم، حجم و دکمه‌ی دانلود دایره‌ای با حلقه‌ی پیشرفت.
    final hasFile = msg.isFile &&
        (msg.fileUrl.isNotEmpty ||
            (msg.pending && msg.localPath.isNotEmpty));

    return Container(
      padding: EdgeInsets.fromLTRB(12.5, 8, 12.5, hasFile ? 4.5 : 4),
      decoration: BoxDecoration(
        // v1.0.9 — bubble color follows the user's picked preset
        // (Settings → Chat background → Bubble color)
        // v1.3.2 — WhatsApp-style: solid fill + soft shadow, no border
        // stroke (the old 1px outline read "heavy" next to WhatsApp's clean
        // bubbles; the tail corner keeps the identity).
        gradient: own ? BubbleColorStore.I.gradient : null,
        color: own ? null : p.bubOther,
        borderRadius: BorderRadiusDirectional.only(
          topStart: const Radius.circular(17),
          topEnd: const Radius.circular(17),
          bottomStart: Radius.circular(own ? 17 : 5),
          bottomEnd: Radius.circular(own ? 5 : 17),
        ),
        boxShadow: const [
          BoxShadow(color: Color(0x1014283C), blurRadius: 4, offset: Offset(0, 1)),
        ],
      ),
      child: _fitWidth(
        plain: !hasMedia && !hasVideo && !hasAudio && !hasFile,
        child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (msg.forwardFromUsername.isNotEmpty)
            _forwardedBanner(p, own),
          // v1.0.9 — author row also in CHANNELS… until v1.5.0: توی کانال
          // «فقط پیام» دیده می‌شود — اسم/تگ/لوگوِ نویسنده هیچ‌کدام نه.
          if (!own &&
              (kind == ChatKind.general || kind == ChatKind.group))
            _authorRow(p),
          if (msg.replyToId != null && msg.replyToId!.isNotEmpty)
            _ReplyQuote(
                msg: msg, palette: p, own: own, onTap: onJumpToReply == null
                    ? null
                    : () => onJumpToReply!(msg)),
          if (hasFile) FileBubble(msg: msg),
          if (hasMedia)
            GestureDetector(
              onTap: () => onOpenMedia(msg),
              // v1.3.2 — url AND localPath both flow into _media so the
              // optimistic→confirmed swap is a crossfade, never a flash.
              child: _media(
                  msg.fileUrl.isEmpty
                      ? null
                      : ApiService.I.absoluteUrl(msg.fileUrl),
                  p,
                  uploading: msg.pending && msg.localPath.isNotEmpty,
                  ring: msg),
            ),
          if (hasVideo)
            GestureDetector(
              onTap: () => onOpenMedia(msg),
              child: _videoTile(p,
                  uploading: msg.pending && msg.localPath.isNotEmpty,
                  ring: msg),
            ),
          if (hasAudio)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: AudioBubble(
                fileUrl: msg.fileUrl,
                own: own,
                title: msg.text.isEmpty ? null : msg.text,
                senderAvatar: msg.avatar,
                senderName: msg.authorLabel,
                // v1.3.1 — TRUE music detection: parsed tags OR the server's
                // kind:music flag make a song a song (dedicated player);
                // everything else stays a voice note.
                isVoice: !(msg.isMusic ||
                    (msg.isAudio && !msg.isVoiceNote && msg.mediaTitle.isNotEmpty)),
                // v1.3.1 — songs without embedded tags show the file name
                // (never an empty bar) — the title always survives reloads.
                mediaTitle: msg.mediaTitle.isNotEmpty
                    ? msg.mediaTitle
                    : (msg.isMusic ? msg.musicTitleFallback : ''),
                mediaArtist: msg.mediaArtist,
                mediaCover: msg.mediaCover,
                mediaDurMs: msg.mediaDurMs,
              ),
            ),
          if (msg.text.isNotEmpty && !msg.isAudio)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: _RichTextMessage(
                  text: msg.text, own: own, palette: p,
                  onMentionTap: onTokenTap),
            ),
          ReactionChips(
            reactions: msg.reactions,
            onTap: (e) => onReact(msg, e),
            // v1.0.9 — channels: emoji + number only, no mini avatar stack
            hideAvatars: channelMode,
          ),
          // v1.5.0 — ساعت «چسبیده» به ته حباب: فاصله‌ی اضافی حذف شد و
          // ردیف ساعت همیشه در گوشه‌ی انتهاییِ حباب می‌نشیند.
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: _footer(p, own, insideBubble: true),
          ),
        ],
      ),
      ),
    );
  }

  /// حباب متنیِ کوتاه به اندازه‌ی محتوا جمع می‌شود (قبلاً ردیف ساعت با Align
  /// کل عرض مجاز را می‌گرفت و حباب‌ها «کشیده» می‌شدند). حباب‌های مدیا/فایل/
  /// آهنگ دست‌نخورده می‌مانند.
  Widget _fitWidth({required bool plain, required Widget child}) =>
      plain ? IntrinsicWidth(child: child) : child;

  // v1.3.1 — one probe per URL per session; the resolved stream shares the
  // image cache with the bubble's own CachedNetworkImage (no extra decode).
  static final Set<String> _dimsProbed = {};
  static void _probeMediaDims(String key, String url) {
    if (_dimsProbed.contains(key)) return;
    _dimsProbed.add(key);
    try {
      final provider = CachedNetworkImageProvider(
          ApiService.I.absoluteUrl(url),
          headers: {'Cookie': ApiService.I.cookieHeader});
      final stream =
          provider.resolve(const ImageConfiguration(size: Size(1, 1)));
      late final ImageStreamListener listener;
      listener = ImageStreamListener((ImageInfo info, _) {
        MediaDimsCache.I.put(key, info.image.width, info.image.height);
        stream.removeListener(listener);
      }, onError: (Object e, StackTrace? st) {
        stream.removeListener(listener);
      });
      stream.addListener(listener);
    } catch (_) {}
  }

  // ============== borderless media (photo/video/GIF, no caption) ==============
  Widget _borderlessMedia(BuildContext context, Palette p) {
    final isGif = msg.fileType == 'gif';
    final Widget media;
    if (msg.isVideo) {
      media = _videoTile(p, uploading: msg.pending && msg.localPath.isNotEmpty, ring: msg,
          compactScrim: true);
    } else {
      media = _media(
          msg.fileUrl.isEmpty ? null : ApiService.I.absoluteUrl(msg.fileUrl),
          p,
          uploading: msg.pending && msg.localPath.isNotEmpty,
          ring: msg,
          round: 16);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (msg.forwardFromUsername.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: _forwardedBanner(p, msg.isMe && !channelMode),
          ),
        if (msg.replyToId != null && msg.replyToId!.isNotEmpty)
          _ReplyQuote(
              msg: msg, palette: p, own: msg.isMe && !channelMode,
              onTap: onJumpToReply == null ? null : () => onJumpToReply!(msg)),
        Stack(
          children: [
            GestureDetector(
              onTap: () => onOpenMedia(msg),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: media,
              ),
            ),
            // GIF badge (top-start) + overflow (top-end)
            if (isGif) ...[
              PositionedDirectional(
                top: 8, start: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .45),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white.withValues(alpha: .25), width: .8),
                  ),
                  child: const Text('GIF',
                      textDirection: TextDirection.ltr,
                      style: TextStyle(
                          fontSize: 9.5, fontWeight: FontWeight.w800,
                          letterSpacing: .8, color: Colors.white)),
                ),
              ),
              PositionedDirectional(
                top: 4, end: 4,
                child: _GifMenuButton(
                  msg: msg,
                  onSaveGif: onSaveGif,
                  onDownload: onDownload,
                ),
              ),
            ],
            // media-open hint (bottom-end)
            PositionedDirectional(
              bottom: 6, end: 8,
              child: Icon(Icons.open_in_new_rounded,
                  size: 13, color: Colors.white.withValues(alpha: .85)),
            ),
            // time scrim
            PositionedDirectional(
              bottom: 0, start: 0, end: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(10, 14, 10, 5),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: .35),
                    ],
                  ),
                ),
                child: _footer(p, msg.isMe && !channelMode, insideBubble: false),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ============================ sub-widgets ============================

  Widget _forwardedBanner(Palette p, bool own) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.shortcut_rounded,
            size: 12, color: own ? Colors.white70 : p.accent),
        const SizedBox(width: 3),
        Flexible(
          child: Text('${AppState.I.str.forwardedMsg}: ${msg.forwardFrom}',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 10,
                  fontStyle: FontStyle.italic,
                  color: own ? Colors.white70 : p.accent)),
        ),
      ]),
    );
  }

  Widget _authorRow(Palette p) {
    // v1.2.1 — ALL badges render TOGETHER (the old else-if chain made the
    // owner crown hide the pro star / verified tick and vice-versa), and
    // admins now get a proper Telegram-2026 tag: their custom admin title,
    // or a neutral "admin" chip when no title was set.
    final isOwner = msg.isOwner;
    final isAdmin = !isOwner &&
        (msg.adminTitle.isNotEmpty ||
            msg.adminTitle.toLowerCase() == 'admin');
    return GestureDetector(
      onTap: () => onOpenProfile(msg),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
            child: Text(msg.authorLabel,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: _nameColor(msg.username))),
          ),
          if (isOwner) ...[
            const SizedBox(width: 4),
            // the room OWNER gets a distinct GOLD tag
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [
                  Color(0xFFF59E0B),
                  Color(0xFFD97706),
                ]),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                  AppState.I.lang.value.isFa ? 'مالک' : 'Owner',
                  style: const TextStyle(
                      fontSize: 7.5,
                      fontWeight: FontWeight.w900,
                      color: Colors.white)),
            ),
          ] else if (isAdmin) ...[
            const SizedBox(width: 4),
            // v1.2.1 — ADMIN tag (newest Telegram look): a shield glyph +
            // the custom rank when the owner set one, else a clean chip.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
              decoration: BoxDecoration(
                color: const Color(0xFF38BDF8).withValues(alpha: .18),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                    color: const Color(0xFF38BDF8).withValues(alpha: .35),
                    width: .7),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.shield_rounded,
                    size: 8.5, color: Color(0xFF38BDF8)),
                const SizedBox(width: 2.5),
                Text(
                    msg.adminTitle.isNotEmpty &&
                            msg.adminTitle.toLowerCase() != 'admin'
                        ? msg.adminTitle
                        : (AppState.I.lang.value.isFa ? 'ادمین' : 'Admin'),
                    style: const TextStyle(
                        fontSize: 7.5,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF38BDF8))),
              ]),
            ),
          ],
          // v1.2.1 — pro star + verified tick ALWAYS show, alongside any role
          if (msg.isOfficial) ...[
            const SizedBox(width: 3),
            const Icon(Icons.verified_rounded,
                size: 12, color: Color(0xFF38BDF8)),
          ],
          if (msg.isPro) ...[
            const SizedBox(width: 3),
            const ProStarBadge(size: 13, animate: false),
          ],
        ]),
      ),
    );
  }

  Widget _footer(Palette p, bool own, {required bool insideBubble}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      textDirection: TextDirection.ltr,
      children: [
        if (msg.pending && msg.localPath.isNotEmpty && msg.uploadPct < 1)
          Text('${(msg.uploadPct * 100).round()}%',
              style: const TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w800,
                  color: Colors.white))
        else if (msg.pending)
          const PendingClock(failed: false)
        else if (msg.failed)
          const PendingClock(failed: true)
        else if (kind == ChatKind.pv && msg.isMe)
          Icon(msg.isRead ? Icons.done_all_rounded : Icons.done_rounded,
              size: 12,
              color: msg.isRead
                  ? const Color(0xFF7DD3FC)
                  : Colors.white.withValues(alpha: .55))
        else if (msg.isMe)
          Icon(Icons.done_all_rounded,
              size: 12, color: Colors.white.withValues(alpha: .55)),
        if (msg.seenCount > 0) ...[
          const SizedBox(width: 4),
          Icon(Icons.visibility_outlined,
              size: 10, color: Colors.white.withValues(alpha: .7)),
          const SizedBox(width: 2),
          Text('${msg.seenCount}',
              style: TextStyle(
                  fontSize: 9,
                  color: Colors.white.withValues(alpha: .7))),
        ],
        const SizedBox(width: 4),
        if (msg.isEdited) ...[
          Text(AppState.I.str.editedTag,
              style: TextStyle(
                  fontSize: 8.5,
                  fontStyle: FontStyle.italic,
                  color: insideBubble
                      ? (own
                          ? Colors.white.withValues(alpha: .6)
                          : p.chatText3)
                      : Colors.white.withValues(alpha: .75))),
          const SizedBox(width: 3),
        ],
        Text(msg.time,
            style: TextStyle(
                fontSize: 9.5,
                color: insideBubble
                    ? (own
                        ? Colors.white.withValues(alpha: .65)
                        : p.chatText3)
                    : Colors.white.withValues(alpha: .9))),
      ],
    );
  }

  Color _nameColor(String username) {
    final idx = username.hashCode.abs() % C.avatarGradients.length;
    return C.avatarGradients[idx].first;
  }

  Widget _media(String? url, Palette p,
      {bool uploading = false, Message? ring, double round = 14}) {
    // v1.3.2 — [smoothConfirm] while a SENT photo/GIF swaps from its local
    // file to the uploaded remote URL, the local file stays painted as the
    // base layer and the network copy is only revealed once its FIRST frame
    // is decoded (frameBuilder) — the optimistic → confirmed hand-over is
    // a seamless crossfade instead of a placeholder flash/jump.
    // v1.2.1 — TELEGRAM-SIZE ENVELOPE: when the pixel dims are known (we
    // decode them at send time; the backend now relays them via media_meta)
    // the bubble reserves the EXACT aspect from frame one — the image never
    // reflows when it finishes loading, so there is no "small jump" when
    // sending photos.
    // v1.3.1 — GIFs / old photos without metadata now ALSO reserve their
    // aspect: the persistent MediaDimsCache remembers the decoded size per
    // URL across sessions, so nothing jumps on arrival OR after re-entering.
    var aspect = msg.mediaAspect;
    if (aspect <= 0 && !uploading && msg.fileUrl.isNotEmpty) {
      final cached = MediaDimsCache.I.aspectOf(msg.fileUrl);
      if (cached != null) aspect = cached;
    }
    const maxW = 250.0, maxH = 300.0;
    double? envW, envH;
    if (aspect > 0) {
      if (aspect >= maxW / maxH) {
        envW = maxW;
        envH = maxW / aspect;
      } else {
        envH = maxH;
        envW = maxH * aspect;
      }
    }

    Widget inner;
    if (uploading && msg.localPath.isNotEmpty) {
      inner = Image.file(
        File(msg.localPath),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => Container(
          width: envW ?? 220,
          height: envH ?? 150,
          color: Colors.grey.withValues(alpha: .15)),
      );
    } else if (url != null &&
        url.isNotEmpty &&
        msg.localPath.isNotEmpty &&
        !uploading &&
        envW != null &&
        envH != null) {
      // v1.3.2 — confirmed-but-still-local: crossfade (see [smoothConfirm]).
      // Only when the aspect envelope is reserved — a StackFit.expand inside
      // an unconstrained bubble would collapse.
      final localPath = msg.localPath;
      inner = Stack(
        fit: StackFit.expand,
        children: [
          Image.file(File(localPath),
              fit: BoxFit.cover, gaplessPlayback: true),
          Image(
            image: CachedNetworkImageProvider(url,
                headers: {'Cookie': ApiService.I.cookieHeader}),
            fit: BoxFit.cover,
            gaplessPlayback: true,
            frameBuilder: (c, child, frame, _) =>
                frame == null ? const SizedBox.shrink() : child,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        ],
      );
    } else if (url != null && url.isNotEmpty) {
      // v1.5.0 — دانلود مثل تلگرام: تصویر یک بار روی دیسکِ اپ ذخیره می‌شود
      // و برای همیشه از همان‌جا لود می‌شود؛ وسطِ تصویر دکمه‌ی دایره‌ایِ
      // تیره با فلش سفید و حلقه‌ی پیشرفت زنده می‌چرخد (شکل عکس مرجع).
      inner = DiskCachedImage(
        fileUrl: msg.fileUrl,
        width: envW ?? 220,
        height: envH ?? 150,
        round: round,
        memCacheWidth: 720,
      );
      // v1.3.1 — async dims probe: once the image decodes, its natural size
      // lands in the PERSISTENT MediaDimsCache → from the next rebuild (and
      // every future session) the bubble reserves the exact aspect = GIFs
      // and old photos never jump again.
      if (msg.mediaW <= 0 && msg.fileUrl.isNotEmpty) {
        _probeMediaDims(msg.fileUrl, url);
      }
    } else {
      inner = Container(
          width: envW ?? 220,
          height: envH ?? 120,
          color: Colors.grey.withValues(alpha: .15));
    }

    // aspect-locked content when dims are known
    Widget sized = envW != null && envH != null
        ? SizedBox(
            width: envW,
            height: envH,
            child: ClipRRect(
                borderRadius: BorderRadius.circular(round), child: inner),
          )
        : ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 250),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(round),
              child: SizedBox(
                width: uploading ? 230 : null,
                child: inner,
              ),
            ),
          );

    if (uploading) {
      sized = Stack(alignment: Alignment.center, children: [
        sized,
        UploadRing(
            pct: msg.uploadPct,
            sizeLabel: msg.fileSizeLabel,
            sentBytes: msg.uploadSent,
            totalBytes: msg.fileSize,
            cancelId: msg.clientMsgId),
      ]);
    }
    // v1.2.1 — remote images without known dims glide (never jump) to their
    // real size once decoded.
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      alignment: AlignmentDirectional.centerStart,
      child: sized,
    );
  }

  Widget _videoTile(Palette p,
      {bool uploading = false, Message? ring, bool compactScrim = false}) {
    final w = compactScrim ? 236.0 : 230.0;
    final h = compactScrim ? 150.0 : 140.0;
    final isLocal = msg.localPath.isNotEmpty;
    final src = isLocal
        ? msg.localPath
        : (msg.fileUrl.isNotEmpty ? ApiService.I.absoluteUrl(msg.fileUrl) : '');
    return Stack(
      alignment: Alignment.center,
      children: [
        // v1.0.9 — REAL video frame thumbnail (blurred "alive" backdrop +
        // sharp frame behind the play button) instead of the old flat box.
        Container(
          width: w,
          height: h,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(compactScrim ? 16 : 14),
            gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF232B36), Color(0xFF141A21)]),
          ),
          child: src.isEmpty
              ? Center(
                  child: Icon(Icons.play_circle_fill_rounded,
                      size: 44, color: Colors.white.withValues(alpha: .8)))
              : VideoThumbTile(
                  src: src,
                  isLocal: isLocal,
                  width: w,
                  height: h,
                ),
        ),
        // v1.5.0 — «نوار بالا» مثل تلگرام: نوار پیشرفتِ باریک روی لبه‌ی بالای
        // ویدئو که همزمان با دانلود پر می‌شود (و می‌شود در همین حالت ویدئو را دید)
        if (!uploading && !isLocal && msg.fileUrl.isNotEmpty)
          PositionedDirectional(
            top: 0, start: 0, end: 0,
            child: ClipRRect(
              borderRadius: BorderRadius.vertical(
                  top: Radius.circular(compactScrim ? 16 : 14)),
              child: AnimatedBuilder(
                animation: MediaDownloadManager.I,
                builder: (context, _) {
                  final t = MediaDownloadManager.I.taskFor(msg.fileUrl);
                  final running = t?.state == 'running';
                  final pct = t?.progress ?? 0;
                  return Container(
                    height: running ? 3.4 : 0,
                    alignment: AlignmentDirectional.centerStart,
                    color: Colors.black26,
                    child: FractionallySizedBox(
                      widthFactor: (pct <= 0 ? 0.06 : pct).clamp(0.0, 1.0),
                      child: Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(colors: [
                            Color(0xFF7DD3FC),
                            Color(0xFF38BDF8),
                          ]),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        // size chip (top-left, Telegram-like)
        if (msg.fileSizeLabel.isNotEmpty && !uploading)
          PositionedDirectional(
            top: 10, end: 8,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: .45),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(msg.fileSizeLabel,
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.white)),
            ),
          ),
        if (uploading) UploadRing(
            pct: msg.uploadPct,
            sizeLabel: msg.fileSizeLabel,
            sentBytes: msg.uploadSent,
            totalBytes: msg.fileSize,
            cancelId: msg.clientMsgId),
        // v1.5.0 — دانلود مثل تلگرام: دکمه‌ی دایره‌ای بالا-شروع (شکل عکس مرجع)،
        // حلقه‌ی چرخان زنده؛ پایان = تیک سبز. لمسِ خودِ ویدئو = پخشِ استریم
        // (در حین دانلود هم می‌شود ویدئو را دید).
        if (!uploading && msg.fileUrl.isNotEmpty && !isLocal)
          PositionedDirectional(
            top: 8, start: 8,
            child: _VideoDownloadChip(fileUrl: msg.fileUrl, p: p),
          ),
        if (!compactScrim)
          PositionedDirectional(
            bottom: 6, start: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.videocam_rounded, size: 10, color: Colors.white),
                const SizedBox(width: 4),
                Text(AppState.I.str.videoFile,
                    style: const TextStyle(fontSize: 9, color: Colors.white)),
              ]),
            ),
          ),
      ],
    );
  }
}

/// v1.4.0 — چیپ دانلود ویدئو (مثل تلگرام): لمس = دانلود با حلقه‌ی درصد؛
/// پایان = تیک سبز. وضعیت از MediaDownloadManager سراسری می‌آید.
class _VideoDownloadChip extends StatelessWidget {
  final String fileUrl;
  final Palette p;
  const _VideoDownloadChip({required this.fileUrl, required this.p});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: MediaDownloadManager.I,
      builder: (context, _) {
        final t = MediaDownloadManager.I.taskFor(fileUrl);
        final running = t?.state == 'running';
        final done = t?.state == 'done';
        final chip = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (running) {
              MediaDownloadManager.I.cancel(fileUrl);
            } else {
              MediaDownloadManager.I.downloadAndSave(fileUrl);
            }
          },
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: .5),
              shape: BoxShape.circle,
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (running)
                  SizedBox(
                    width: 30,
                    height: 30,
                    child: CircularProgressIndicator(
                      value: (t!.progress <= 0 ? null : t.progress.clamp(0.03, 1.0)),
                      strokeWidth: 2.4,
                      valueColor: const AlwaysStoppedAnimation(Colors.white),
                      backgroundColor: Colors.white24,
                      strokeCap: StrokeCap.round,
                    ),
                  ),
                Icon(
                  running
                      ? Icons.close_rounded
                      : (done ? Icons.check_rounded : Icons.download_rounded),
                  size: running ? 16 : 19,
                  color: done && !running ? const Color(0xFF4ADE80) : Colors.white,
                ),
              ],
            ),
          ),
        );
        if (!running || t == null || t.received <= 0) return chip;
        return Row(mainAxisSize: MainAxisSize.min, children: [
          chip,
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: .55),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(fmtTransfer(t.received, t.total),
                textDirection: TextDirection.ltr,
                style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: Colors.white)),
          ),
        ]);
      },
    );
  }
}

/// Telegram-style circular upload progress: ring + ✕ (cancel) + «3.2 / 12.5 MB».
class UploadRing extends StatelessWidget {
  final double pct; // 0..1
  final String sizeLabel;
  final double size;
  final int sentBytes;
  final int totalBytes;
  final String cancelId; // clientMsgId → ✕ cancels this upload
  const UploadRing({
    super.key,
    required this.pct,
    this.sizeLabel = '',
    this.size = 52,
    this.sentBytes = 0,
    this.totalBytes = 0,
    this.cancelId = '',
  });

  @override
  Widget build(BuildContext context) {
    final compact = size < 46;
    final label = (totalBytes > 0 && sentBytes > 0)
        ? fmtTransfer(sentBytes, totalBytes)
        : sizeLabel;
    final ring = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: cancelId.isEmpty ? null : () => UploadRegistry.cancel(cancelId),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .5),
          shape: BoxShape.circle,
        ),
        child: Stack(alignment: Alignment.center, children: [
          SizedBox(
            width: size - 6,
            height: size - 6,
            child: CircularProgressIndicator(
              value: pct <= 0 ? null : pct.clamp(0.03, 1.0),
              strokeWidth: 2.8,
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
              backgroundColor: Colors.white24,
              strokeCap: StrokeCap.round,
            ),
          ),
          Icon(Icons.close_rounded,
              size: compact ? 16 : 22, color: Colors.white),
        ]),
      ),
    );
    if (compact || label.isEmpty) return ring;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ring,
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .55),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(label,
              textDirection: TextDirection.ltr,
              style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: Colors.white)),
        ),
      ],
    );
  }
}

/// Glass overflow button on GIF media → Download / Save GIF.
class _GifMenuButton extends StatelessWidget {
  final Message msg;
  final void Function(Message)? onSaveGif;
  final void Function(Message)? onDownload;
  const _GifMenuButton({required this.msg, this.onSaveGif, this.onDownload});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        final s = AppState.I.str;
        final res = await showGlassSheet<bool>(
          context,
          heightFactor: 0.32,
          builder: (ctx) => SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const SizedBox(height: 14),
              if (onDownload != null)
                _sheetItem(ctx, Icons.download_rounded, s.download, () {
                  Navigator.pop(ctx);
                  onDownload!(msg);
                }),
              if (onSaveGif != null)
                _sheetItem(ctx, Icons.save_alt_rounded, s.saveGif, () {
                  Navigator.pop(ctx);
                  onSaveGif!(msg);
                }),
              const SizedBox(height: 12),
            ]),
          ),
        );
      },
      child: Container(
        width: 30, height: 30,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .4),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: .2), width: .8),
        ),
        child: const Icon(Icons.more_vert_rounded,
            size: 16, color: Colors.white),
      ),
    );
  }

  Widget _sheetItem(BuildContext ctx, IconData icon, String label, VoidCallback onTap) {
    final dark = Theme.of(ctx).brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        child: Row(children: [
          Icon(icon, size: 20, color: Theme.of(ctx).colorScheme.primary),
          const SizedBox(width: 13),
          Text(label,
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: dark ? Colors.white : C.textL)),
        ]),
      ),
    );
  }
}

// v1.0.8 — reply quote inside bubble, exactly Telegram's look: a slim
// rounded accent bar, the author name in BOLD accent, one soft snippet
// line. Tappable (jumps to the source message).
// v1.2.0 — tapping now plays a quick pulse ON THE TAG ITSELF first (the
// exact Telegram behaviour the user asked for), then the jump starts.
class _ReplyQuote extends StatefulWidget {
  final Message msg;
  final Palette palette;
  final bool own;
  final bool glassy; // v1.1.0 — floating glass variant (emoji-only replies)
  final VoidCallback? onTap;

  const _ReplyQuote({
    required this.msg,
    required this.palette,
    required this.own,
    this.glassy = false,
    this.onTap,
  });

  @override
  State<_ReplyQuote> createState() => _ReplyQuoteState();
}

class _ReplyQuoteState extends State<_ReplyQuote>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 340));

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  void _handleTap() {
    if (widget.onTap == null) return;
    HapticFeedback.selectionClick();
    _pulse.forward(from: 0).then((_) => widget.onTap?.call());
  }

  @override
  Widget build(BuildContext context) {
    final own = widget.own;
    final palette = widget.palette;
    final accent = own ? Colors.white : palette.accent;
    return GestureDetector(
      onTap: _handleTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        final t = _pulse.value;
        // soft glow that swells then fades — the "tag acknowledgement"
        final glow = t < 0.5 ? t * 2 : (1 - t) * 2;
        return Transform.scale(
          scale: 1 + 0.02 * glow,
          child: Container(
            margin: const EdgeInsets.only(bottom: 5),
            padding: const EdgeInsets.fromLTRB(8, 5.5, 8, 6),
            decoration: BoxDecoration(
              color: widget.glassy
                  ? (own
                      ? Colors.white.withValues(alpha: .10 + .10 * glow)
                      : palette.chatHeadBg.withValues(alpha: .55 + .15 * glow))
                  : (own
                      ? Colors.white.withValues(alpha: .13 + .12 * glow)
                      : palette.accent.withValues(alpha: .07 + .10 * glow)),
              borderRadius: BorderRadius.circular(9),
              border: widget.glassy
                  ? Border.all(color: palette.chatHeadBorder, width: .8)
                  : null,
            ),
            child: child,
          ),
        );
      },
      child: IntrinsicHeight(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // slim vertical accent bar — Telegram's signature quote line
            Container(
              width: 2.6,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: .9),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 7),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      widget.msg.replyAuthor?.isNotEmpty == true
                          ? widget.msg.replyAuthor!
                          : '',
                      textDirection: bidiDirectionOf(widget.msg.replyAuthor ?? ''),
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 10.8,
                          fontWeight: FontWeight.w800,
                          height: 1.15,
                          color: accent)),
                  // v1.3.1 — the quote NEVER renders as an empty strip: when
                  // the server has no snippet (deleted target / old cached
                  // row) a neutral label still tells the user what it was.
                  Text(
                      (widget.msg.replyText?.isNotEmpty == true)
                          ? widget.msg.replyText!
                          : (AppState.I.str.messageHint.isEmpty
                              ? 'پیام'
                              : AppState.I.str.messageHint),
                      textDirection: bidiDirectionOf(
                          (widget.msg.replyText?.isNotEmpty == true)
                              ? widget.msg.replyText!
                              : 'پیام'),
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11,
                          fontStyle: widget.msg.replyText?.isNotEmpty == true
                              ? FontStyle.normal
                              : FontStyle.italic,
                          height: 1.3,
                          color: own
                                  ? Colors.white.withValues(alpha: .82)
                                  : palette.chatText2)),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

// message text with TAPPABLE @mentions & URLs (like index linkify/mentions)
class _RichTextMessage extends StatefulWidget {
  final String text;
  final bool own;
  final Palette palette;
  final void Function(String mention)? onMentionTap;

  const _RichTextMessage(
      {required this.text, required this.own, required this.palette,
       this.onMentionTap});

  @override
  State<_RichTextMessage> createState() => _RichTextMessageState();
}

class _RichTextMessageState extends State<_RichTextMessage> {
  final List<TapGestureRecognizer> _recs = [];

  @override
  void dispose() {
    for (final r in _recs) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.text;
    final own = widget.own;
    final palette = widget.palette;
    final spans = <InlineSpan>[];
    final re = RegExp(r'(@[A-Za-z0-9_\.]{3,32})|(https?://[^\s]+|www\.[^\s]+)');
    var last = 0;

    for (final m in re.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      final raw = m.group(0)!;
      if (raw.startsWith('@')) {
        final rec = TapGestureRecognizer()..onTap = () => widget.onMentionTap?.call(raw);
        _recs.add(rec);
        spans.add(TextSpan(
          text: raw,
          style: TextStyle(
            color: own ? Colors.white : palette.accent,
            fontWeight: FontWeight.w700,
          ),
          recognizer: rec,
        ));
      } else {
        final rec = TapGestureRecognizer()
          ..onTap = () => widget.onMentionTap?.call(raw);
        _recs.add(rec);
        spans.add(TextSpan(
          text: raw,
          style: TextStyle(
            color: own ? Colors.white : const Color(0xFF38BDF8),
            decoration: TextDecoration.underline,
            decorationColor: (own ? Colors.white : const Color(0xFF38BDF8))
                .withValues(alpha: .5),
          ),
          recognizer: rec,
        ));
      }
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));

    return Text.rich(
      TextSpan(
        style: TextStyle(
            fontSize: 13.8,
            height: 1.55,
            color: own ? Colors.white : palette.chatText),
        children: spans,
      ),
      // v1.1.0 — bidi: the paragraph follows the first strong character so a
      // trailing emoji/EN word never visually jumps "behind" Persian text.
      textDirection: bidiDirectionOf(text),
    );
  }
}

/// v1.1.0 — Telegram-style ALBUM bubble: 2..N photos in ONE clean rounded
/// container (2 → side by side, 3 → 1 big + 2 stacked, 4+ → grid), with a
/// "+N" badge when the group is larger than the grid shows.
class _AlbumBubble extends StatelessWidget {
  final List<Message> items;
  final Palette palette;
  final bool own;
  final void Function(Message) onOpenMedia;
  final void Function(BuildContext, Message)? onItemLongPress;

  const _AlbumBubble({
    required this.items,
    required this.palette,
    required this.own,
    required this.onOpenMedia,
    this.onItemLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final shown = items.take(6).toList();
    final hidden = items.length - shown.length;
    final radius = 16.0;
    final gap = 2.2;
    final maxW = MediaQuery.of(context).size.width * 0.62;

    Widget tile(Message m, {double? w, double? h, BorderRadius? br}) {
      // v1.3.2 — album tiles get the same smooth local→remote hand-over:
      // while pending the local file shows; after confirm the network copy
      // is revealed only once decoded (no placeholder flash inside albums).
      final uploading = m.pending && m.localPath.isNotEmpty;
      final handover = !uploading &&
          m.localPath.isNotEmpty &&
          m.fileUrl.isNotEmpty;
      final src = (uploading || handover)
          ? null
          : (m.fileUrl.isNotEmpty ? ApiService.I.absoluteUrl(m.fileUrl) : null);
      final img = uploading
          ? Image.file(File(m.localPath),
              fit: BoxFit.cover,
              width: w,
              height: h,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) =>
                  Container(width: w, height: h, color: Colors.grey.withValues(alpha: .15)))
          : handover
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.file(File(m.localPath),
                        fit: BoxFit.cover, gaplessPlayback: true),
                    Image(
                      image: CachedNetworkImageProvider(
                          ApiService.I.absoluteUrl(m.fileUrl),
                          headers: {'Cookie': ApiService.I.cookieHeader}),
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      frameBuilder: (c, child, frame, _) => frame == null
                          ? const SizedBox.shrink()
                          : child,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ],
                )
              : (src != null && src.isNotEmpty
              // v1.5.0 — آلبوم هم مثل بقیه: دانلود یک‌بار روی دیسک، لود همیشگی از دیسک
              ? DiskCachedImage(
                  fileUrl: m.fileUrl,
                  width: w,
                  height: h,
                  round: 0,
                  memCacheWidth: 720,
              )
              : Container(
                  width: w, height: h, color: Colors.grey.withValues(alpha: .15)));
      return GestureDetector(
        onTap: () => onOpenMedia(m),
        // v1.2.1 — REPLY ON EVERY PHOTO: long-press one tile → its own panel
        onLongPress: onItemLongPress == null
            ? null
            : () => onItemLongPress!(context, m),
        child: ClipRRect(
          borderRadius: br ?? BorderRadius.zero,
          child: Stack(
            fit: StackFit.expand,
            children: [
              img,
              if (uploading)
                UploadRing(
                    pct: m.uploadPct,
                    sizeLabel: m.fileSizeLabel,
                    size: 40,
                    cancelId: m.clientMsgId),
              PositionedDirectional(
                bottom: 5,
                end: 6,
                child: Text(m.time,
                    style: TextStyle(
                        fontSize: 8.5,
                        color: Colors.white.withValues(alpha: .9),
                        shadows: const [
                          Shadow(color: Colors.black54, blurRadius: 4),
                        ])),
              ),
            ],
          ),
        ),
      );
    }

    final Widget grid;
    if (shown.length == 2) {
      grid = SizedBox(
        width: maxW,
        child: Row(
          children: [
            Expanded(child: SizedBox(height: 132, child: tile(shown[0], br: BorderRadius.horizontal(left: Radius.circular(radius))))),
            SizedBox(width: gap),
            Expanded(child: SizedBox(height: 132, child: tile(shown[1], br: BorderRadius.horizontal(right: Radius.circular(radius))))),
          ],
        ),
      );
    } else if (shown.length == 3) {
      grid = SizedBox(
        width: maxW,
        height: 178,
        child: Row(
          children: [
            Expanded(child: tile(shown[0], br: BorderRadius.horizontal(left: Radius.circular(radius)))),
            SizedBox(width: gap),
            Expanded(
              child: Column(
                children: [
                  Expanded(child: tile(shown[1], br: const BorderRadius.vertical(top: Radius.circular(0)))),
                  SizedBox(height: gap),
                  Expanded(child: tile(shown[2])),
                ],
              ),
            ),
          ],
        ),
      );
    } else {
      // 4..6 → 2-column grid
      final rows = <Widget>[];
      for (var r = 0; r < shown.length; r += 2) {
        final a = shown[r];
        final b = r + 1 < shown.length ? shown[r + 1] : null;
        rows.add(Expanded(
          child: Row(
            children: [
              Expanded(child: tile(a,
                  br: BorderRadius.only(
                      topLeft: Radius.circular(r == 0 ? radius : 0),
                      bottomLeft: Radius.circular(
                          b == null && r + 2 >= shown.length ? radius : 0)))),
              if (b != null) ...[
                SizedBox(width: gap),
                Expanded(child: tile(b,
                    br: BorderRadius.only(
                        topRight: Radius.circular(r == 0 ? radius : 0),
                        bottomRight: Radius.circular(
                            r + 2 >= shown.length ? radius : 0)))),
              ],
            ],
          ),
        ));
        if (r + 2 < shown.length) rows.add(SizedBox(height: gap));
      }
      grid = SizedBox(
        width: maxW,
        height: shown.length <= 4 ? 190 : 224,
        child: Column(children: rows),
      );
    }

    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: grid,
        ),
        if (hidden > 0)
          Positioned.fill(
            child: Container(
              alignment: Alignment.center,
              color: Colors.black.withValues(alpha: .45),
              child: Text('+$hidden',
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w900)),
            ),
          ),
      ],
    );
  }
}

/// v1.5.0 — حباب تمیز «فایل» برای هر فرمتی (zip / rar / pdf / apk / docx / …):
///  • آیکون نوع فایل (رنگ اختصاصی هر فرمت)
///  • اسم فایل + حجم زیرش
///  • دکمه‌ی دانلود دایره‌ای با حلقه‌ی پیشرفت زنده؛ پایان = تیک سبز
///  • لمس دکمه = دانلود و ذخیره در Downloads/RAVI (قابل ارسال و باز کردن)
class FileBubble extends StatelessWidget {
  final Message msg;
  const FileBubble({super.key, required this.msg});

  static const Map<String, (IconData, Color)> _icons = {
    'pdf': (Icons.picture_as_pdf_rounded, Color(0xFFEF4444)),
    'doc': (Icons.description_rounded, Color(0xFF3B82F6)),
    'docx': (Icons.description_rounded, Color(0xFF3B82F6)),
    'txt': (Icons.article_rounded, Color(0xFF64748B)),
    'rtf': (Icons.article_rounded, Color(0xFF64748B)),
    'log': (Icons.article_rounded, Color(0xFF64748B)),
    'csv': (Icons.table_chart_rounded, Color(0xFF16A34A)),
    'xls': (Icons.table_chart_rounded, Color(0xFF16A34A)),
    'xlsx': (Icons.table_chart_rounded, Color(0xFF16A34A)),
    'ods': (Icons.table_chart_rounded, Color(0xFF16A34A)),
    'ppt': (Icons.slideshow_rounded, Color(0xFFF97316)),
    'pptx': (Icons.slideshow_rounded, Color(0xFFF97316)),
    'odp': (Icons.slideshow_rounded, Color(0xFFF97316)),
    'zip': (Icons.folder_zip_rounded, Color(0xFFA855F7)),
    'rar': (Icons.folder_zip_rounded, Color(0xFFA855F7)),
    '7z': (Icons.folder_zip_rounded, Color(0xFFA855F7)),
    'tar': (Icons.folder_zip_rounded, Color(0xFFA855F7)),
    'gz': (Icons.folder_zip_rounded, Color(0xFFA855F7)),
    'tgz': (Icons.folder_zip_rounded, Color(0xFFA855F7)),
    'bz2': (Icons.folder_zip_rounded, Color(0xFFA855F7)),
    'xz': (Icons.folder_zip_rounded, Color(0xFFA855F7)),
    'apk': (Icons.android_rounded, Color(0xFF22C55E)),
    'deb': (Icons.inventory_2_rounded, Color(0xFFE11D48)),
    'iso': (Icons.album_rounded, Color(0xFF64748B)),
    'mp3': (Icons.music_note_rounded, Color(0xFFEC4899)),
    'wav': (Icons.music_note_rounded, Color(0xFFEC4899)),
    'flac': (Icons.music_note_rounded, Color(0xFFEC4899)),
    'm4a': (Icons.music_note_rounded, Color(0xFFEC4899)),
    'ogg': (Icons.music_note_rounded, Color(0xFFEC4899)),
    'opus': (Icons.music_note_rounded, Color(0xFFEC4899)),
    'mp4': (Icons.videocam_rounded, Color(0xFF06B6D4)),
    'mkv': (Icons.videocam_rounded, Color(0xFF06B6D4)),
    'mov': (Icons.videocam_rounded, Color(0xFF06B6D4)),
    'avi': (Icons.videocam_rounded, Color(0xFF06B6D4)),
    'webm': (Icons.videocam_rounded, Color(0xFF06B6D4)),
    'json': (Icons.data_object_rounded, Color(0xFFF59E0B)),
    'sql': (Icons.storage_rounded, Color(0xFF0EA5E9)),
    'db': (Icons.storage_rounded, Color(0xFF0EA5E9)),
    'sqlite': (Icons.storage_rounded, Color(0xFF0EA5E9)),
    'ttf': (Icons.font_download_rounded, Color(0xFF8B5CF6)),
    'otf': (Icons.font_download_rounded, Color(0xFF8B5CF6)),
    'woff': (Icons.font_download_rounded, Color(0xFF8B5CF6)),
    'woff2': (Icons.font_download_rounded, Color(0xFF8B5CF6)),
    'srt': (Icons.subtitles_rounded, Color(0xFF14B8A6)),
    'psd': (Icons.image_rounded, Color(0xFF0EA5E9)),
    'epub': (Icons.menu_book_rounded, Color(0xFF8B5CF6)),
    'py': (Icons.code_rounded, Color(0xFF0EA5E9)),
    'java': (Icons.code_rounded, Color(0xFFF97316)),
    'kt': (Icons.code_rounded, Color(0xFFA855F7)),
    'dart': (Icons.code_rounded, Color(0xFF06B6D4)),
    'js': (Icons.code_rounded, Color(0xFFF59E0B)),
    'ts': (Icons.code_rounded, Color(0xFF3B82F6)),
  };

  String get _name {
    // v1.5.0 — اسم اصلی فایل (media_meta.title که موقع ارسال ذخیره شده)
    if (msg.mediaTitle.trim().isNotEmpty) return msg.mediaTitle.trim();
    if (msg.fileUrl.isEmpty) {
      if (msg.localPath.isNotEmpty) {
        final n = msg.localPath.split(RegExp(r'[\\/]')).last;
        if (n.isNotEmpty) return n;
      }
      return 'file';
    }
    var base = msg.fileUrl.split('/').last;
    final dot = base.lastIndexOf('.');
    if (dot > 0) base = base.substring(0, dot);
    // نام‌های تولیدی سرور (12_20261030..._ab12cd) برای کاربر بی‌معنا هستند
    if (RegExp(r'^\d{1,6}_\d{10,}_[0-9a-f]{4,}$').hasMatch(base)) return 'file';
    return base.isEmpty ? 'file' : base;
  }

  String get _ext {
    final src = msg.fileUrl.isNotEmpty ? msg.fileUrl : msg.localPath;
    if (src.contains('.')) {
      final e = src.split('.').last.toLowerCase();
      if (e.length <= 6 && !e.contains('/')) return e;
    }
    return 'file';
  }

  bool get _uploading =>
      msg.pending && msg.localPath.isNotEmpty && msg.fileUrl.isEmpty;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ext = _ext;
    final (icon, color) = _icons[ext] ??
        (Icons.insert_drive_file_rounded, const Color(0xFF64748B));
    return AnimatedBuilder(
      animation: MediaDownloadManager.I,
      builder: (context, _) {
        final t = MediaDownloadManager.I.taskFor(msg.fileUrl);
        final running = t?.state == 'running';
        final done = t?.state == 'done';
        final onDisk = MediaDownloadManager.I.maybeOnDisk(msg.fileUrl);
        return Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: dark
                ? Colors.white.withValues(alpha: .07)
                : Colors.black.withValues(alpha: .06),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .18),
                  borderRadius: BorderRadius.circular(11),
                ),
                alignment: Alignment.center,
                child: Icon(icon, size: 20, color: color),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: msg.isMe ? Colors.white : null,
                        height: 1.15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _uploading
                          ? fmtTransfer(msg.uploadSent, msg.fileSize)
                          : running && t != null
                          ? [
                              fmtTransfer(t.received,
                                  t.total > 0 ? t.total : msg.fileSize),
                              fmtSpeed(t.speed),
                            ].where((e) => e.isNotEmpty).join(' · ')
                          : (msg.fileSizeLabel.isEmpty
                              ? ext.toUpperCase()
                              : '${msg.fileSizeLabel} · ${ext.toUpperCase()}'),
                      textDirection: TextDirection.ltr,
                      style: TextStyle(
                        fontSize: 9.5,
                        color: msg.isMe
                            ? Colors.white.withValues(alpha: .75)
                            : (dark ? Colors.white54 : Colors.black45),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              // ---- دکمه‌ی دانلود دایره‌ای با حلقه‌ی پیشرفت ----
              GestureDetector(
                onTap: _uploading
                    ? () => UploadRegistry.cancel(msg.clientMsgId)
                    : running
                    ? () => MediaDownloadManager.I.cancel(msg.fileUrl)
                    : () {
                        MediaDownloadManager.I.downloadAndSave(msg.fileUrl);
                      },
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: (msg.isMe
                            ? Colors.white.withValues(alpha: .18)
                            : color.withValues(alpha: .16)),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (_uploading)
                        SizedBox(
                          width: 26,
                          height: 26,
                          child: Stack(alignment: Alignment.center, children: [
                            CircularProgressIndicator(
                              value: msg.uploadPct <= 0
                                  ? null
                                  : msg.uploadPct.clamp(0.03, 1.0),
                              strokeWidth: 2.4,
                              valueColor: AlwaysStoppedAnimation(
                                  msg.isMe ? Colors.white : color),
                              backgroundColor: Colors.white24,
                              strokeCap: StrokeCap.round,
                            ),
                            Icon(Icons.close_rounded,
                                size: 13,
                                color: msg.isMe ? Colors.white : color),
                          ]),
                        )
                      else if (running)
                        SizedBox(
                          width: 26,
                          height: 26,
                          child: Stack(alignment: Alignment.center, children: [
                            CircularProgressIndicator(
                              value: t!.progress <= 0 ? null : t.progress.clamp(0.03, 1.0),
                              strokeWidth: 2.4,
                              valueColor: AlwaysStoppedAnimation(
                                  msg.isMe ? Colors.white : color),
                              backgroundColor: Colors.white24,
                              strokeCap: StrokeCap.round,
                            ),
                            Icon(Icons.close_rounded,
                                size: 13,
                                color: msg.isMe ? Colors.white : color),
                          ]),
                        )
                      else
                        Icon(
                          (done || onDisk)
                              ? Icons.download_done_rounded
                              : Icons.download_rounded,
                          size: 18,
                          color: msg.isMe
                              ? Colors.white
                              : (done || onDisk
                                  ? const Color(0xFF4ADE80)
                                  : color),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
