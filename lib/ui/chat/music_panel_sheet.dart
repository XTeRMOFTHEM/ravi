import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/api_service.dart';
import '../../core/app_state.dart';
import '../../core/constants.dart';
import '../../core/player_service.dart';
import '../widgets/common.dart';

/// v1.0.8 — full Telegram-style music panel, opened by tapping the glass
/// mini-player:
///   ┌──────────────────────────┐
///   │        drag handle       │
///   │       [ big artwork ]    │  ← sender avatar / music-note gradient
///   │      title (bold)        │
///   │      01:24 ──●─── 03:10  │  ← draggable waveform-ish seek line
///   │  [⏮] [ ▶ big ring ] [⏭] │  ← play button wrapped in the progress ring
///   │        1.25x speed       │
///   └──────────────────────────┘
/// Playback stays on the global PlayerService — the panel is pure UI.
Future<void> openMusicPanel(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    builder: (ctx) => ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: Container(
          height: MediaQuery.of(ctx).size.height * 0.52,
          decoration: BoxDecoration(
            color: dark ? const Color(0xF3141A21) : const Color(0xFAFFFFFF),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(26)),
            border: Border(
              top: BorderSide(
                color: dark
                    ? Colors.white.withValues(alpha: .09)
                    : Colors.white,
              ),
            ),
          ),
          child: const MusicPanelBody(),
        ),
      ),
    ),
  );
}

class MusicPanelBody extends StatefulWidget {
  const MusicPanelBody({super.key});

  @override
  State<MusicPanelBody> createState() => _MusicPanelBodyState();
}

class _MusicPanelBodyState extends State<MusicPanelBody> {
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final p = dark ? const Palette.dark() : const Palette.light();
    final s = AppState.I.str;
    final svc = PlayerService.I;

    return AnimatedBuilder(
      animation: svc,
      builder: (context, _) {
        final item = svc.current;
        if (item == null) return const SizedBox.shrink();
        final playing = svc.playing;
        final total = svc.duration > Duration.zero
            ? svc.duration
            : const Duration(seconds: 1);
        final progress =
            (svc.position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
        final avatarUrl = ApiService.I.avatarUrl(item.avatarPath);

        return Padding(
          padding: const EdgeInsets.fromLTRB(22, 10, 22, 18),
          child: Column(children: [
            Container(
              width: 44, height: 4,
              decoration: BoxDecoration(
                  color: p.border, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(height: 8),
            Text(s.nowPlayingTitle,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: .4,
                    color: p.text3)),
            const SizedBox(height: 16),
            // ---- artwork ----
            Hero(
              tag: 'ravi-music-art-${item.messageIdTag}',
              child: Container(
                width: 132,
                height: 132,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      p.accent.withValues(alpha: .75),
                      p.accent.withValues(alpha: .25),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: p.accent.withValues(alpha: .35),
                      blurRadius: 30,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: ClipOval(
                  child: avatarUrl.isNotEmpty
                      ? Stack(fit: StackFit.expand, children: [
                          CachedNetworkImage(
                            imageUrl: avatarUrl,
                            fit: BoxFit.cover,
                            memCacheWidth: 280,
                            httpHeaders: {'Cookie': ApiService.I.cookieHeader},
                            errorWidget: (_, __, ___) => _noteIcon(),
                          ),
                          Container(
                              color: Colors.black.withValues(alpha: .18)),
                        ])
                      : _noteIcon(),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(item.title,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 15.5, fontWeight: FontWeight.w800,
                    color: p.text)),
            const SizedBox(height: 18),
            // ---- seek line ----
            Row(children: [
              Text(_fmt(svc.position),
                  textDirection: TextDirection.ltr,
                  style: TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w600,
                      color: p.text3)),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragUpdate: (d) {
                    if (svc.duration <= Duration.zero) return;
                    final box = context.findRenderObject() as RenderBox?;
                    if (box == null) return;
                    final local = box.globalToLocal(d.globalPosition);
                    final t =
                        ((local.dx - 22) / (box.size.width - 44)).clamp(0.0, 1.0);
                    PlayerService.I.seekTo(svc.duration * t);
                  },
                  onTapUp: (d) {
                    if (svc.duration <= Duration.zero) return;
                    final box = context.findRenderObject() as RenderBox?;
                    if (box == null) return;
                    final t = (d.localPosition.dx / (box.size.width - 44))
                        .clamp(0.0, 1.0);
                    PlayerService.I.seekTo(svc.duration * t);
                  },
                  child: SizedBox(
                    height: 18,
                    child: Center(
                      child: Stack(clipBehavior: Clip.none, children: [
                        Container(
                          height: 4,
                          decoration: BoxDecoration(
                            color: p.border,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        FractionallySizedBox(
                          widthFactor: progress,
                          child: Container(
                            height: 4,
                            decoration: BoxDecoration(
                              gradient: C.ownBubbleGrad,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          top: -3,
                          child: LayoutBuilder(builder: (ctx, cons) {
                            final w = cons.maxWidth;
                            return Align(
                              alignment: Alignment(-1 + 2 * progress, 0),
                              child: Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                      color: p.accent, width: 2),
                                  boxShadow: const [
                                    BoxShadow(
                                        color: Color(0x33000000),
                                        blurRadius: 6),
                                  ],
                                ),
                              ),
                            );
                          }),
                        ),
                      ]),
                    ),
                  ),
                ),
              ),
              Text(_fmt(svc.duration),
                  textDirection: TextDirection.ltr,
                  style: TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w600,
                      color: p.text3)),
            ]),
            const SizedBox(height: 18),
            // ---- controls ----
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              // speed
              GestureDetector(
                onTap: () => PlayerService.I.cycleSpeed(),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 11, vertical: 6),
                  decoration: BoxDecoration(
                    color: p.accentSoft,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Text(svc.speedLabel,
                      textDirection: TextDirection.ltr,
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          color: p.accent)),
                ),
              ),
              const SizedBox(width: 26),
              // big play wrapped in the ring
              GestureDetector(
                onTap: () => PlayerService.I.toggle(),
                child: RingProgress(
                  size: 74,
                  progress: progress,
                  strokeWidth: 3,
                  color: p.accent,
                  track: p.border,
                  child: Container(
                    width: 62,
                    height: 62,
                    decoration: BoxDecoration(
                      gradient: C.ownBubbleGrad,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                            color: p.accent.withValues(alpha: .4),
                            blurRadius: 18,
                            offset: const Offset(0, 6)),
                      ],
                    ),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 140),
                      transitionBuilder: (c, a) =>
                          ScaleTransition(scale: a, child: c),
                      child: Icon(
                        playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        key: ValueKey(playing),
                        size: 32,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 26),
              // stop / close playback
              GestureDetector(
                onTap: () {
                  PlayerService.I.close();
                  Navigator.of(context).pop();
                },
                child: Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: p.bgSoft,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.close_rounded,
                      size: 19, color: p.text2),
                ),
              ),
            ]),
          ]),
        );
      },
    );
  }

  Widget _noteIcon() => const Center(
        child: Icon(Icons.music_note_rounded,
            size: 54, color: Colors.white),
      );

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
