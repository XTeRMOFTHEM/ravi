import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/api_service.dart';
import '../../core/app_state.dart';
import '../../core/constants.dart';
import '../../core/player_service.dart';
import '../widgets/common.dart';
import 'music_panel_sheet.dart';

/// v1.0.8 — the glass mini-player that appears right under the chat header
/// while an audio/voice item plays (Telegram-style):
///   [ring+▶/⏸] title …………… [1.5x] [✕]
///  • a PROGRESS RING wraps the play button (download / playback position)
///  • TAPPING the bar opens the full Telegram-like music panel
///  • voice → the sender's avatar blurred behind the bar
///  • playback continues wherever you navigate; this bar manages it
class PlayerBar extends StatelessWidget {
  final VoidCallback? onClose;
  const PlayerBar({super.key, this.onClose});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final p = dark ? const Palette.dark() : const Palette.light();
    final svc = PlayerService.I;

    return AnimatedBuilder(
      animation: svc,
      builder: (context, _) {
        final item = svc.current;
        if (item == null) return const SizedBox.shrink();
        final avatarUrl = ApiService.I.avatarUrl(item.avatarPath);
        final playing = svc.playing;
        final progress = (svc.position.inMilliseconds /
                (svc.duration > Duration.zero
                    ? svc.duration.inMilliseconds
                    : 1))
            .clamp(0.0, 1.0);
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: GestureDetector(
                // v1.0.8 — tap anywhere on the bar → full music panel
                onTap: () => openMusicPanel(context),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  height: 50,
                  decoration: BoxDecoration(
                    color: dark
                        ? const Color(0xB0101418)
                        : const Color(0xC8FFFFFF),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: dark
                          ? Colors.white.withValues(alpha: .10)
                          : Colors.white.withValues(alpha: .6),
                    ),
                    boxShadow: const [
                      BoxShadow(color: Color(0x33000000), blurRadius: 16),
                    ],
                  ),
                  child: Stack(children: [
                    // voice → sender avatar as the bar backdrop
                    if (avatarUrl.isNotEmpty)
                      Positioned.fill(
                        child: Opacity(
                          opacity: .30,
                          child: CachedNetworkImage(
                            imageUrl: avatarUrl,
                            fit: BoxFit.cover,
                            memCacheWidth: 220,
                            httpHeaders: {'Cookie': ApiService.I.cookieHeader},
                            errorWidget: (_, __, ___) =>
                                const SizedBox.shrink(),
                          ),
                        ),
                      ),
                    Row(children: [
                      const SizedBox(width: 6),
                      // play / pause wrapped in the progress ring
                      GestureDetector(
                        onTap: () => PlayerService.I.toggle(),
                        child: RingProgress(
                          size: 38,
                          progress: svc.duration > Duration.zero
                              ? progress
                              : 0, // 0 → indeterminate while buffering
                          strokeWidth: 2.2,
                          color: Colors.white,
                          track: Colors.white.withValues(alpha: .22),
                          child: Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              gradient: C.ownBubbleGrad,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              size: 19,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: dark ? Colors.white : C.textL),
                            ),
                            const SizedBox(height: 3),
                            // slim progress line (tap to seek)
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTapUp: (d) {
                                final box = context.findRenderObject()
                                    as RenderBox?;
                                if (box == null ||
                                    svc.duration <= Duration.zero) return;
                                final t = (d.localPosition.dx /
                                        (box.size.width - 120))
                                    .clamp(0.0, 1.0);
                                PlayerService.I.seekTo(svc.duration * t);
                              },
                              child: SizedBox(
                                height: 6,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(3),
                                  child: LinearProgressIndicator(
                                    value: progress <= 0 ? null : progress,
                                    minHeight: 3,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                        p.accent),
                                    backgroundColor:
                                        dark
                                            ? Colors.white24
                                            : Colors.black12,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // speed cycle
                      GestureDetector(
                        onTap: () => PlayerService.I.cycleSpeed(),
                        child: Container(
                          margin: const EdgeInsetsDirectional.only(end: 6),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: p.accent.withValues(alpha: .16),
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Text(
                            svc.speedLabel,
                            textDirection: TextDirection.ltr,
                            style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                color: p.accent),
                          ),
                        ),
                      ),
                      // expand hint + close ✕
                      GestureDetector(
                        onTap: () async {
                          await PlayerService.I.close();
                          onClose?.call();
                        },
                        child: Container(
                          width: 34,
                          height: 46,
                          margin: const EdgeInsetsDirectional.only(end: 4),
                          alignment: Alignment.center,
                          child: Icon(Icons.close_rounded,
                              size: 17,
                              color: dark ? Colors.white70 : C.text2L),
                        ),
                      ),
                    ]),
                  ]),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
