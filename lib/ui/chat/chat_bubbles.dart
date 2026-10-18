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
import '../../core/models.dart';
import '../widgets/common.dart';
import '../widgets/ravi_alerts.dart';
import 'audio_bubble.dart';
import 'message_action_panel.dart';
import 'package:flutter/services.dart';

/// Telegram-style entrance animation for newly appended bubbles — soft
/// rise + fade (v1.0.6: shorter distance, smoother curve).
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
      vsync: this, duration: const Duration(milliseconds: 220));

  @override
  void initState() {
    super.initState();
    if (widget.animate) _c.forward();
    else _c.value = 1;
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
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 10 * (1 - t)),
            child: Transform.scale(
              scale: 0.985 + 0.015 * t,
              alignment: Alignment.bottomCenter,
              child: child,
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
    this.onJumpToReply,
    this.onForward,
    this.onDelete,
    this.onSaveGif,
    this.onDownload,
    this.onTokenTap,
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
    final mediaNoCaption = msg.isImage && !msg.isAudio && msg.text.trim().isEmpty ||
        (msg.isVideo && msg.text.trim().isEmpty);
    final borderless = mediaNoCaption || msg.fileType == 'gif';

    if (msg.isEmojiOnly && msg.fileUrl.isEmpty) {
      // v1.0.7 — floating emoji with the SENDER'S PROFILE behind it
      // (soft blurred circle, like the web floating-emoji layer).
      final av = ApiService.I.avatarUrl(msg.avatar);
      return Align(
        alignment: own ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              if (av.isNotEmpty)
                Opacity(
                  opacity: .42,
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                    child: Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: .35),
                          width: 1.4,
                        ),
                      ),
                      child: ClipOval(
                        child: CachedNetworkImage(
                          imageUrl: av,
                          fit: BoxFit.cover,
                          memCacheWidth: 120,
                          httpHeaders: {'Cookie': ApiService.I.cookieHeader},
                          errorWidget: (_, __, ___) => const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(msg.text,
                    style: const TextStyle(fontSize: 42, height: 1.1)),
              ),
            ],
          ),
        ),
      );
    }

    final Widget bubbleCore = Container(
      constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78),
      child: borderless
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

    return Container(
      padding: EdgeInsets.fromLTRB(12.5, 8, 12.5, 6.5),
      decoration: BoxDecoration(
        // v1.0.9 — bubble color follows the user's picked preset
        // (Settings → Chat background → Bubble color)
        gradient: own ? BubbleColorStore.I.gradient : null,
        color: own ? null : p.bubOther,
        borderRadius: BorderRadiusDirectional.only(
          topStart: const Radius.circular(18),
          topEnd: const Radius.circular(18),
          bottomStart: Radius.circular(own ? 18 : 5),
          bottomEnd: Radius.circular(own ? 5 : 18),
        ),
        border: own
            ? null
            : Border.all(color: p.bubOtherBorder, width: 1),
        boxShadow: const [
          BoxShadow(color: Color(0x1414283C), blurRadius: 3, offset: Offset(0, 1)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (msg.forwardFromUsername.isNotEmpty)
            _forwardedBanner(p, own),
          // v1.0.9 — author row also in CHANNELS (post author, like Telegram)
          if (!own &&
              (kind == ChatKind.general ||
                  kind == ChatKind.group ||
                  channelMode))
            _authorRow(p),
          if (msg.replyToId != null && msg.replyToId!.isNotEmpty)
            _ReplyQuote(
                msg: msg, palette: p, own: own, onTap: onJumpToReply == null
                    ? null
                    : () => onJumpToReply!(msg)),
          if (hasMedia)
            GestureDetector(
              onTap: () => onOpenMedia(msg),
              child: _media(msg.localPath.isNotEmpty ? null : ApiService.I.absoluteUrl(msg.fileUrl), p,
                  uploading: msg.localPath.isNotEmpty, ring: msg),
            ),
          if (hasVideo)
            GestureDetector(
              onTap: () => onOpenMedia(msg),
              child: _videoTile(p, uploading: msg.localPath.isNotEmpty, ring: msg),
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
                isVoice: msg.text.isEmpty,
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
          const SizedBox(height: 2),
          _footer(p, own, insideBubble: true),
        ],
      ),
    );
  }

  // ============== borderless media (photo/video/GIF, no caption) ==============
  Widget _borderlessMedia(BuildContext context, Palette p) {
    final isGif = msg.fileType == 'gif';
    final Widget media;
    if (msg.isVideo) {
      media = _videoTile(p, uploading: msg.localPath.isNotEmpty, ring: msg,
          compactScrim: true);
    } else {
      media = _media(msg.localPath.isNotEmpty ? null : ApiService.I.absoluteUrl(msg.fileUrl),
          p, uploading: msg.localPath.isNotEmpty, ring: msg, round: 16);
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
          if (msg.isOfficial) ...[
            const SizedBox(width: 4),
            const Icon(Icons.verified_rounded,
                size: 12, color: Color(0xFF38BDF8)),
          ] else if (msg.isPro) ...[
            const SizedBox(width: 4),
            // v1.0.8 — the animated Index PRO star (static 12px in rows,
            // exactly like .nb-star in the web list rows)
            const ProStarBadge(size: 13, animate: false),
          ] else if (msg.adminTitle.isNotEmpty) ...[
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xFFF59E0B).withValues(alpha: .18),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(msg.adminTitle,
                  style: const TextStyle(
                      fontSize: 6.5,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFFF59E0B))),
            ),
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
    final size = const BoxConstraints(maxWidth: 250);
    Widget inner;
    if (uploading && msg.localPath.isNotEmpty) {
      // LOCAL preview while uploading
      inner = Image.file(
        File(msg.localPath),
        fit: BoxFit.cover,
        width: 230,
        height: 170,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => Container(
          width: 220, height: 150, color: Colors.grey.withValues(alpha: .15)),
      );
    } else if (url != null && url.isNotEmpty) {
      inner = CachedNetworkImage(
        imageUrl: url,
        memCacheWidth: 720,
        maxWidthDiskCache: 1440,
        httpHeaders: {'Cookie': ApiService.I.cookieHeader},
        fadeInDuration: const Duration(milliseconds: 140),
        placeholder: (_, __) => Container(
          width: 220, height: 150,
          color: Colors.grey.withValues(alpha: .15),
          child: const Center(child: SizedBox(
              width: 20, height: 20,
              child: CircularProgressIndicator(strokeWidth: 2,
                  color: Colors.white54)))),
        errorWidget: (_, __, ___) => Container(
          width: 220, height: 120,
          color: Colors.grey.withValues(alpha: .15),
          child: Icon(Icons.broken_image_outlined,
              size: 30, color: p.chatText3)),
      );
    } else {
      inner = Container(
          width: 220, height: 120, color: Colors.grey.withValues(alpha: .15));
    }

    return ConstrainedBox(
      constraints: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(round),
        child: SizedBox(
          width: uploading ? 230 : null,
          child: uploading
              ? Stack(alignment: Alignment.center, children: [
                  inner,
                  UploadRing(pct: msg.uploadPct, sizeLabel: msg.fileSizeLabel),
                ])
              : inner,
        ),
      ),
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
        // size chip (top-left, Telegram-like)
        if (msg.fileSizeLabel.isNotEmpty && !uploading)
          PositionedDirectional(
            top: 8, start: 8,
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
        if (uploading) UploadRing(pct: msg.uploadPct, sizeLabel: msg.fileSizeLabel),
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

/// v1.0.9 — video thumbnail with a soft blurred copy of the frame behind the
/// play glyph (the "empty/dry" box is gone). Caches by message id.
class VideoThumbTile extends StatefulWidget {
  final String src;
  final bool isLocal;
  final double width;
  final double height;
  const VideoThumbTile({
    super.key,
    required this.src,
    required this.isLocal,
    required this.width,
    required this.height,
  });

  @override
  State<VideoThumbTile> createState() => _VideoThumbTileState();
}

class _VideoThumbTileState extends State<VideoThumbTile> {
  Uint8List? _bytes;
  static final Map<String, Uint8List> _cache = {};
  static const MethodChannel _ch = MethodChannel('ravi/video_frame');

  @override
  void initState() {
    super.initState();
    final cached = _cache[widget.src];
    if (cached != null) {
      _bytes = cached;
    } else {
      _grab();
    }
  }

  /// v1.0.9 — native MediaMetadataRetriever bridge (the video_thumbnail
  /// plugin is incompatible with AGP 9 and was dropped).
  Future<void> _grab() async {
    try {
      final b = await _ch.invokeMethod<Uint8List>('getFrame', {
        'path': widget.src,
        'isUrl': !widget.isLocal,
        'maxWidth': 480,
        'cookie': ApiService.I.cookieHeader,
      });
      if (b != null && mounted) {
        _cache[widget.src] = b;
        setState(() => _bytes = b);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final img = _bytes != null
        ? Image.memory(_bytes!, fit: BoxFit.cover,
            width: widget.width, height: widget.height, gaplessPlayback: true)
        : const SizedBox.shrink();
    return Stack(fit: StackFit.expand, children: [
      if (_bytes != null) ...[
        // blurred alive backdrop
        ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Transform.scale(scale: 1.25, child: img),
        ),
        // sharp frame in the middle (16:9 letterbox feel)
        Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: widget.width * 0.62,
              height: widget.height * 0.72,
              child: img,
            ),
          ),
        ),
      ] else
        const Center(
          child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2,
                  color: Colors.white54)),
        ),
      // play glyph on top
      Center(
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black.withValues(alpha: .35),
            border: Border.all(
                color: Colors.white.withValues(alpha: .5), width: 1.4),
          ),
          child: const Icon(Icons.play_arrow_rounded,
              size: 30, color: Colors.white),
        ),
      ),
    ]);
  }
}

/// Small circular avatar next to other users' messages (group/general).
class _SenderAvatar extends StatelessWidget {
  final Message msg;
  const _SenderAvatar({required this.msg});

  @override
  Widget build(BuildContext context) {
    final url = ApiService.I.avatarUrl(msg.avatar);
    return Container(
      width: 26, height: 26,
      margin: const EdgeInsets.only(bottom: 2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: C.avatarGradients[
              msg.username.hashCode.abs() % C.avatarGradients.length],
        ),
      ),
      child: ClipOval(
        child: url.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                memCacheWidth: 64,
                httpHeaders: {'Cookie': ApiService.I.cookieHeader},
                errorWidget: (_, __, ___) => Center(
                  child: Text(
                    msg.username.isEmpty
                        ? '?'
                        : msg.username[0].toUpperCase(),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800),
                  ),
                ),
              )
            : Center(
                child: Text(
                  msg.username.isEmpty ? '?' : msg.username[0].toUpperCase(),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800),
                ),
              ),
      ),
    );
  }
}

/// Telegram-style circular upload progress with % + size.
class UploadRing extends StatelessWidget {
  final double pct; // 0..1
  final String sizeLabel;
  final double size;
  const UploadRing({super.key, required this.pct, this.sizeLabel = '', this.size = 52});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size, height: size,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .45),
        shape: BoxShape.circle,
      ),
      child: Stack(alignment: Alignment.center, children: [
        SizedBox(
          width: size, height: size,
          child: CircularProgressIndicator(
            value: pct <= 0 ? null : pct.clamp(0.02, 1.0),
            strokeWidth: 3,
            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFB79CF8)),
            backgroundColor: Colors.white24,
            strokeCap: StrokeCap.round,
          ),
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${(pct * 100).round()}%',
                textDirection: TextDirection.ltr,
                style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    color: Colors.white)),
            if (sizeLabel.isNotEmpty)
              Text(sizeLabel,
                  textDirection: TextDirection.ltr,
                  style: TextStyle(
                      fontSize: 7.5,
                      color: Colors.white.withValues(alpha: .85))),
          ],
        ),
      ]),
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
          Icon(icon, size: 20, color: const Color(0xFF8B5CF6)),
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
class _ReplyQuote extends StatelessWidget {
  final Message msg;
  final Palette palette;
  final bool own;
  final VoidCallback? onTap;

  const _ReplyQuote(
      {required this.msg, required this.palette, required this.own, this.onTap});

  @override
  Widget build(BuildContext context) {
    final accent = own ? Colors.white : palette.accent;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 5),
        padding: const EdgeInsets.fromLTRB(8, 5.5, 8, 6),
        decoration: BoxDecoration(
          color: own
              ? Colors.white.withValues(alpha: .13)
              : palette.accent.withValues(alpha: .07),
          borderRadius: BorderRadius.circular(9),
        ),
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
                        msg.replyAuthor?.isNotEmpty == true
                            ? msg.replyAuthor!
                            : '',
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 10.8,
                            fontWeight: FontWeight.w800,
                            height: 1.15,
                            color: accent)),
                    if (msg.replyText?.isNotEmpty == true)
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Text(msg.replyText!,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 11,
                                height: 1.3,
                                color: own
                                    ? Colors.white.withValues(alpha: .82)
                                    : palette.chatText2)),
                      ),
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
    );
  }
}
