import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api_service.dart';
import '../../core/audio_cache_service.dart';
import '../../core/media_download_manager.dart' show fmtTransfer;
import '../../core/player_service.dart';
import '../widgets/common.dart';

/// v1.2.1 — Telegram-style audio bubbles, REBUILT:
///
///  • VOICE NOTES: play button on the sender's avatar + waveform + timer,
///    exactly like before (the user liked it), PLUS a real download state:
///    a soft progress sweep travels around the bar while the file caches.
///  • MUSIC: a DEDICATED bubble — square cover art (from the song's ID3
///    tags, uploaded at send time), title + artist, slim seek bar, duration.
///    Songs are no longer mistaken for voice notes.
///  • Playback runs through the GLOBAL PlayerService (mini-bar anywhere),
///    and files play from the local cache after the first download.
class AudioBubble extends StatefulWidget {
  final String fileUrl; // /static/uploads/x.m4a
  final bool own; // inside own bubble
  final String? title; // fallback / caption title
  final String senderAvatar; // sender avatar (voice → behind play button)
  final String senderName;
  final bool isVoice; // voice note vs music file
  // v1.2.1 — music metadata (from media_meta)
  final String mediaTitle;
  final String mediaArtist;
  final String mediaCover;
  final int mediaDurMs;
  final double width;

  const AudioBubble({
    super.key,
    required this.fileUrl,
    required this.own,
    this.title,
    this.senderAvatar = '',
    this.senderName = '',
    this.isVoice = true,
    this.mediaTitle = '',
    this.mediaArtist = '',
    this.mediaCover = '',
    this.mediaDurMs = 0,
    this.width = 240,
  });

  @override
  State<AudioBubble> createState() => _AudioBubbleState();
}

class _AudioBubbleState extends State<AudioBubble>
    with SingleTickerProviderStateMixin {
  late final PlayerService _svc = PlayerService.I;

  /// soft pulse rings around the play button while playing
  late final AnimationController _pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400));

  /// v1.2.1 — slow sweeping ring while the file downloads (indeterminate)
  late final AnimationController _sweep = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2200));

  bool get _isVoice => widget.isVoice;
  String get _displayTitle => _isVoice
      ? (widget.title?.isNotEmpty == true
          ? widget.title!
          : (widget.senderName.isNotEmpty ? widget.senderName : 'Voice'))
      : (widget.mediaTitle.isNotEmpty ? widget.mediaTitle : 'Music');

  bool get _isCurrent => _svc.isCurrent(widget.fileUrl);
  bool get _playing => _isCurrent && _svc.playing;
  Duration get _pos => _isCurrent ? _svc.position : Duration.zero;
  Duration get _dur {
    if (_isCurrent && _svc.duration > Duration.zero) return _svc.duration;
    if (widget.mediaDurMs > 0) {
      return Duration(milliseconds: widget.mediaDurMs);
    }
    return _cachedDur;
  }

  Duration _cachedDur = Duration.zero;
  bool _downloading = false;
  double _dlPct = 0; // آخرین درصد دانلود (برای حلقه‌ی روی دکمه‌ی پخش)

  @override
  void initState() {
    super.initState();
    _svc.addListener(_onService);
  }

  void _onService() {
    if (!mounted) return;
    if (_playing) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else if (_pulse.isAnimating) {
      _pulse.stop();
    }
    setState(() {});
  }

  @override
  void dispose() {
    _pulse.dispose();
    _sweep.dispose();
    _svc.removeListener(_onService);
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_downloading) {
      // ✕ — لغو دانلود
      HapticFeedback.selectionClick();
      AudioCacheService.I.cancel(widget.fileUrl);
      return;
    }
    HapticFeedback.lightImpact();
    // v1.2.1 — Telegram: download to cache FIRST (progress sweep shows
    // around the bar), then play from disk. Already-cached files start
    // instantly.
    var localPath = AudioCacheService.I.cachedPath(widget.fileUrl) ?? '';
    if (localPath.isEmpty) {
      setState(() {
        _downloading = true;
      });
      _sweep.repeat();
      localPath =
          await AudioCacheService.I.ensureDownloaded(widget.fileUrl) ?? '';
      if (mounted) {
        setState(() => _downloading = false);
      }
      _sweep.stop();
      if (localPath.isEmpty && AudioCacheService.I.wasCancelled(widget.fileUrl)) {
        return; // کاربر لغو کرد: پخش نکن
      }
      if (localPath.isEmpty) {
        // fall back to streaming (old behaviour) rather than dying silently
        localPath = '';
      }
    }
    if (!mounted) return;
    await _svc.playOrToggle(PlayingItem(
      url: widget.fileUrl,
      title: _displayTitle,
      subtitle: widget.mediaArtist,
      isVoice: _isVoice,
      avatarPath: _isVoice ? widget.senderAvatar : '',
      artist: widget.mediaArtist,
      coverUrl: _isVoice ? '' : widget.mediaCover,
      localPath: localPath,
      messageIdTag: widget.fileUrl,
    ));
    if (_svc.isCurrent(widget.fileUrl) && _svc.duration > Duration.zero) {
      _cachedDur = _svc.duration;
    }
  }

  /// حین دانلود به‌جای زمان، «3.2 / 12.5 MB» نشان می‌دهد.
  Widget _infoText(String timeText) {
    final style = TextStyle(fontSize: 9.5, color: _fgSoft);
    if (!_downloading) {
      return Text(timeText, textDirection: TextDirection.ltr, style: style);
    }
    return ValueListenableBuilder<(int, int)>(
      valueListenable: AudioCacheService.I.bytesOf(widget.fileUrl),
      builder: (_, b, __) => Text(
        b.$1 > 0 ? fmtTransfer(b.$1, b.$2) : '…',
        textDirection: TextDirection.ltr,
        style: style,
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // v1.2.1 — own bubbles stay white-on-gradient; other people's music tiles
  // flip to dark-on-light so they are readable on the light bubble skin.
  Color get _fg => Colors.white;
  Color get _fgSoft => Colors.white.withValues(alpha: .72);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: AudioCacheService.I.progressOf(widget.fileUrl),
      builder: (context, dlPct, _) {
        final total = _dur > Duration.zero ? _dur : const Duration(seconds: 1);
        final progress =
            (_pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
        _dlPct = dlPct;
        final showSweep = _downloading || (dlPct > 0 && dlPct < 1);

        final content = _isVoice
            ? _voiceBody(progress)
            : _musicBody(progress, total);

        final body = SizedBox(
          width: widget.width,
          child: CustomPaint(
            // v1.2.1 — THE DOWNLOAD SWEEP: a light comet travels around the
            // bubble edge while the file downloads ("something slowly moves
            // around the bar" — exactly what the user asked for).
            foregroundPainter: showSweep
                ? _SweepBorderPainter(
                    progress: dlPct,
                    t: _sweep.value,
                    animate: _downloading,
                    color: Colors.white.withValues(alpha: .85),
                  )
                : null,
            child: content,
          ),
        );
        // the comet must re-paint on every sweep tick
        if (!showSweep) return body;
        return AnimatedBuilder(
          animation: _sweep,
          builder: (context, _) => body,
        );
      },
    );
  }

  // ---------------- VOICE body (play avatar + waveform) ----------------
  Widget _voiceBody(double progress) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AnimatedBuilder(
                animation: _pulse,
                builder: (context, child) {
                  final active = _playing;
                  final t = _pulse.value;
                  return SizedBox(
                    width: 56,
                    height: 56,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        if (active) ...[
                          Container(
                            width: 42 + 12 * t,
                            height: 42 + 12 * t,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white
                                    .withValues(alpha: .38 * (1 - t)),
                                width: 1.6,
                              ),
                            ),
                          ),
                          Container(
                            width: 42 + 24 * t,
                            height: 42 + 24 * t,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white
                                    .withValues(alpha: .22 * (1 - t)),
                                width: 1.2,
                              ),
                            ),
                          ),
                        ],
                        child!,
                      ],
                    ),
                  );
                },
                child: GestureDetector(
                  onTap: _toggle,
                  child: RingProgress(
                    size: 42,
                    progress: _isCurrent && _svc.duration > Duration.zero
                        ? (_pos.inMilliseconds /
                                (_svc.duration.inMilliseconds == 0
                                    ? 1
                                    : _svc.duration.inMilliseconds))
                            .clamp(0.0, 1.0)
                        : -1,
                    strokeWidth: 2.2,
                    color: Colors.white,
                    track: Colors.white.withValues(alpha: .22),
                    child: _PlayAvatar(
                      size: 42,
                      playing: _playing,
                      loading: _downloading,
                      dlProgress: _dlPct,
                      avatarPath: widget.senderAvatar,
                      fallbackInitial: widget.senderName.isNotEmpty
                          ? widget.senderName[0].toUpperCase()
                          : 'V',
                      showMusicTile: false,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      onHorizontalDragUpdate: (d) {
                        if (!_isCurrent || _dur <= Duration.zero) return;
                        final box = context.findRenderObject() as RenderBox?;
                        if (box == null) return;
                        final local = box.globalToLocal(d.globalPosition);
                        final waveStart = 46.0;
                        final waveW = box.size.width - waveStart;
                        if (waveW <= 0) return;
                        final t =
                            ((local.dx - waveStart) / waveW).clamp(0.0, 1.0);
                        _svc.seekTo(_dur * t);
                      },
                      child: SizedBox(
                        height: 24,
                        width: double.infinity,
                        child: CustomPaint(
                          size: const Size(double.infinity, 24),
                          painter: _WavePainter(
                            progress: progress,
                            played: _fg,
                            rest: Colors.white.withValues(alpha: .38),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        _infoText('${_fmt(_pos)} / ${_fmt(_dur)}'),
                        if (_isCurrent) ...[
                          const SizedBox(width: 6),
                          _SpeedChip(),
                        ] else ...[
                          const SizedBox(width: 6),
                          const _SpeedChip(ghost: true),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
]
)
    );
  }

  // ---------------- MUSIC body (cover + title + artist + seek) ----------------
  Widget _musicBody(double progress, Duration total) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _MusicCover(
                size: 48,
                coverUrl: widget.mediaCover,
                playing: _playing,
                loading: _downloading,
                dlProgress: _dlPct,
                onTap: _toggle,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            color: _fg)),
                    const SizedBox(height: 2),
                    Row(children: [
                      Flexible(
                        child: Text(
                          widget.mediaArtist.isNotEmpty
                              ? widget.mediaArtist
                              : AppStateVoice.musicFallback,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 10,
                              color: _fgSoft,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: .16),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('MUSIC',
                            textDirection: TextDirection.ltr,
                            style: TextStyle(
                                fontSize: 7,
                                fontWeight: FontWeight.w900,
                                letterSpacing: .6,
                                color: _fgSoft)),
                      ),
                    ]),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          // slim seek bar (Telegram music style)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (d) {
              if (!_isCurrent || _dur <= Duration.zero) return;
              final box = context.findRenderObject() as RenderBox?;
              if (box == null) return;
              final local = box.globalToLocal(d.globalPosition);
              final t = (local.dx / box.size.width).clamp(0.0, 1.0);
              _svc.seekTo(_dur * t);
            },
            child: SizedBox(
              height: 14,
              width: double.infinity,
              child: CustomPaint(
                painter: _SlimSeekPainter(
                  progress: progress,
                  played: _fg,
                  rest: Colors.white.withValues(alpha: .3),
                ),
              ),
            ),
          ),
          const SizedBox(height: 3),
          Row(
            children: [
              _infoText('${_fmt(_pos)} / ${_fmt(total)}'),
              if (_isCurrent) ...[
                const SizedBox(width: 6),
                _SpeedChip(),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// v1.2.1 — sweeping comet that travels around the bubble while downloading.
/// Determinate: the comet head sits at the true progress point and a fading
/// tail follows it; this is Telegram's download ring, moved onto the bar.
class _SweepBorderPainter extends CustomPainter {
  final double progress; // 0..1 (or <0 → pure spin)
  final double t; // sweep animation phase
  final bool animate;
  final Color color;

  _SweepBorderPainter({
    required this.progress,
    required this.t,
    required this.animate,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final r = 16.0;
    final rect = Rect.fromLTWH(0.5, 0.5, size.width - 1, size.height - 1);
    final rrect = RRect.fromRectAndRadius(
        rect.deflate(1.2), Radius.circular(r));
    final path = Path()..addRRect(rrect);
    final metrics = path.computeMetrics().toList();
    if (metrics.isEmpty) return;
    final m = metrics.first;
    final total = m.length;

    // head position: true download progress while animating, a slow orbit
    // when the total size is unknown
    final head = progress >= 0 ? progress * total : t * total;
    const tailFrac = 0.22;
    final tailStart = (head - total * tailFrac) % total;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;

    if (tailStart < head) {
      final p = m.extractPath(tailStart, head);
      paint.shader = LinearGradient(colors: [
        color.withValues(alpha: .05),
        color,
      ]).createShader(rect);
      canvas.drawPath(p, paint);
    } else {
      final p1 = m.extractPath(tailStart, total);
      final p2 = m.extractPath(0, head);
      paint.shader = LinearGradient(colors: [
        color.withValues(alpha: .05),
        color,
      ]).createShader(rect);
      canvas.drawPath(p1, paint);
      canvas.drawPath(p2, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SweepBorderPainter old) =>
      old.progress != progress || old.t != t;
}

/// v1.2.1 — square music cover tile (Telegram) with play overlay.
class _MusicCover extends StatelessWidget {
  final double size;
  final String coverUrl;
  final bool playing;
  final bool loading;
  final double dlProgress;
  final VoidCallback onTap;

  const _MusicCover({
    required this.size,
    required this.coverUrl,
    required this.playing,
    required this.loading,
    this.dlProgress = 0,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final url = coverUrl.startsWith('http')
        ? coverUrl
        : (coverUrl.isNotEmpty ? ApiService.I.absoluteUrl(coverUrl) : '');
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0x66FFFFFF), Color(0x33FFFFFF)],
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (url.isNotEmpty)
              CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                memCacheWidth: 128,
                httpHeaders: {'Cookie': ApiService.I.cookieHeader},
                errorWidget: (_, __, ___) => const _MusicGlyph(),
              )
            else
              const _MusicGlyph(),
            // play overlay (Telegram shows it on the artwork)
            Center(
              child: Container(
                width: size * .48,
                height: size * .48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withValues(alpha: .38),
                ),
                child: loading
                    ? _DlCancelRing(progress: dlProgress, size: size * .48)
                    : Icon(
                        playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: size * .34,
                        color: Colors.white,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MusicGlyph extends StatelessWidget {
  const _MusicGlyph();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white.withValues(alpha: .14),
      alignment: Alignment.center,
      child: const Icon(Icons.music_note_rounded,
          size: 24, color: Colors.white70),
    );
  }
}

/// Play button layered over the sender's avatar (voice) — the v1.2.0
/// clip fix (no square scrim) is preserved.
class _PlayAvatar extends StatelessWidget {
  final double size;
  final bool playing;
  final bool loading;
  final double dlProgress;
  final String avatarPath;
  final String fallbackInitial;
  final bool showMusicTile;

  const _PlayAvatar({
    required this.size,
    required this.playing,
    this.loading = false,
    this.dlProgress = 0,
    required this.avatarPath,
    required this.fallbackInitial,
    required this.showMusicTile,
  });

  @override
  Widget build(BuildContext context) {
    final url = ApiService.I.avatarUrl(avatarPath);
    Widget? backdrop;
    if (!showMusicTile && url.isNotEmpty) {
      backdrop = ClipOval(
        child: Image.network(
          url,
          fit: BoxFit.cover,
          width: size,
          height: size,
          headers: {'Cookie': ApiService.I.cookieHeader},
          errorBuilder: (_, __, ___) => const SizedBox.expand(),
        ),
      );
    }

    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Color(0x33FFFFFF),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (backdrop != null) backdrop,
          if (backdrop != null)
            Container(color: Colors.black.withValues(alpha: .30)),
          Center(
            child: loading
                ? _DlCancelRing(progress: dlProgress, size: size * .62)
                : Icon(
                    playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: playing ? size * .5 : size * .58,
                    color: Colors.white,
                  ),
          ),
        ],
      ),
    );
  }
}

/// Speed chip (1x → 1.25x → 1.5x → 2x → 0.75x). Ghost variant renders
/// inert before playback starts so the layout is stable.
class _SpeedChip extends StatelessWidget {
  final bool ghost;
  const _SpeedChip({this.ghost = false});

  @override
  Widget build(BuildContext context) {
    final svc = PlayerService.I;
    return GestureDetector(
      onTap: ghost
          ? null
          : () {
              HapticFeedback.selectionClick();
              svc.cycleSpeed();
            },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .16),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Text(
          ghost ? '1x' : svc.speedLabel,
          textDirection: TextDirection.ltr,
          style: const TextStyle(
              fontSize: 8.5,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              height: 1.2),
        ),
      ),
    );
  }
}

/// Labels used before we know the sender's name (kept tiny + static).
class AppStateVoice {
  static const nameFallback = 'Voice message';
  static const musicFallback = 'Music';
}

class _WavePainter extends CustomPainter {
  final double progress;
  final Color played;
  final Color rest;

  _WavePainter({required this.progress, required this.played, required this.rest});

  @override
  void paint(Canvas canvas, Size size) {
    const bars = 26;
    final w = size.width / (bars * 1.7);
    final paint = Paint()..strokeWidth = w..strokeCap = StrokeCap.round;
    for (int i = 0; i < bars; i++) {
      final x = i * w * 1.7 + w;
      final h = (i.isEven ? 0.45 : i % 3 == 0 ? 0.95 : 0.68) * size.height *
          (0.55 + 0.45 * ((i * 37) % 10) / 10);
      paint.color = (i / bars) <= progress ? played : rest;
      canvas.drawLine(
          Offset(x, (size.height - h) / 2), Offset(x, (size.height + h) / 2), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.progress != progress || old.played != played;
}

/// v1.2.1 — slim Telegram-music seek bar with a round knob.
class _SlimSeekPainter extends CustomPainter {
  final double progress;
  final Color played;
  final Color rest;

  _SlimSeekPainter({
    required this.progress,
    required this.played,
    required this.rest,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final track = Paint()
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = rest;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), track);
    final playedPaint = Paint()
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = played;
    canvas.drawLine(
        Offset(0, y), Offset(size.width * progress, y), playedPaint);
    canvas.drawCircle(
      Offset(size.width * progress, y),
      4.2,
      Paint()..color = played,
    );
  }

  @override
  bool shouldRepaint(covariant _SlimSeekPainter old) =>
      old.progress != progress || old.played != played;
}

/// حلقه‌ی دانلود با ✕ وسطش (لمس = لغو، چون لمسِ کل دکمه‌ی پخش _toggle را صدا می‌زند).
class _DlCancelRing extends StatelessWidget {
  final double progress; // 0..1 (0 → چرخش بی‌نهایت)
  final double size;
  const _DlCancelRing({required this.progress, required this.size});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              value: progress <= 0 ? null : progress.clamp(0.03, 1.0),
              strokeWidth: 2.4,
              color: Colors.white,
              backgroundColor: Colors.white24,
              strokeCap: StrokeCap.round,
            ),
          ),
          Icon(Icons.close_rounded, size: size * .52, color: Colors.white),
        ],
      ),
    );
  }
}
