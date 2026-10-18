import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api_service.dart';
import '../../core/player_service.dart';
import '../widgets/common.dart';

/// v1.0.8 — Telegram-style audio bubble:
///  • the play button sits on the SENDER'S AVATAR when this is a voice
///    message (plain gradient circle when they have no photo)
///  • music files keep a clean music-note tile
///  • a DOWNLOAD/PLAY PROGRESS RING wraps the button while loading/playing
///    (the Telegram visual the user asked for)
///  • playback runs through the GLOBAL PlayerService — the glass mini-bar
///    under the header controls the same stream from anywhere in the app
///  • tappable waveform for seeking, speed chip (1x/1.5x/2x…)
class AudioBubble extends StatefulWidget {
  final String fileUrl; // /static/uploads/x.m4a
  final bool own; // inside own purple bubble
  final String? title;
  final String senderAvatar; // sender avatar (voice → behind play button)
  final String senderName;
  final bool isVoice; // voice note vs music file
  final double width;

  const AudioBubble({
    super.key,
    required this.fileUrl,
    required this.own,
    this.title,
    this.senderAvatar = '',
    this.senderName = '',
    this.isVoice = true,
    this.width = 220,
  });

  @override
  State<AudioBubble> createState() => _AudioBubbleState();
}

class _AudioBubbleState extends State<AudioBubble>
    with SingleTickerProviderStateMixin {
  late final PlayerService _svc = PlayerService.I;

  bool get _isCurrent => _svc.isCurrent(widget.fileUrl);
  bool get _playing => _isCurrent && _svc.playing;
  Duration get _pos => _isCurrent ? _svc.position : Duration.zero;
  Duration get _dur {
    if (_isCurrent && _svc.duration > Duration.zero) return _svc.duration;
    return _cachedDur;
  }

  Duration _cachedDur = Duration.zero;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _svc.addListener(_onService);
  }

  void _onService() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _svc.removeListener(_onService);
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_failed) return;
    HapticFeedback.lightImpact();
    await _svc.playOrToggle(PlayingItem(
      url: widget.fileUrl,
      title: widget.title?.isNotEmpty == true
          ? widget.title!
          : (widget.isVoice
              ? (widget.senderName.isNotEmpty
                  ? widget.senderName
                  : AppStateVoice.nameFallback)
              : AppStateVoice.musicFallback),
      subtitle: '',
      isVoice: widget.isVoice,
      avatarPath: widget.isVoice ? widget.senderAvatar : '',
      messageIdTag: widget.fileUrl,
    ));
    // learn duration once for the "not current" render
    if (_svc.isCurrent(widget.fileUrl) && _svc.duration > Duration.zero) {
      _cachedDur = _svc.duration;
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Color get _fg => Colors.white;
  Color get _fgSoft => Colors.white.withValues(alpha: .72);

  @override
  Widget build(BuildContext context) {
    final playing = _playing;
    final total = _dur > Duration.zero ? _dur : const Duration(seconds: 1);
    final progress = (_pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);

    return SizedBox(
      width: widget.width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.title != null && widget.title!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(widget.title!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11.5, color: _fg, fontWeight: FontWeight.w700)),
            ),
          Row(
            children: [
              // ---- play button with avatar behind (Telegram) + progress ring
              GestureDetector(
                onTap: _toggle,
                child: RingProgress(
                  size: 42,
                  progress: _isCurrent && _dur > Duration.zero
                      ? progress
                      : -1, // -1 → ring hidden (not the active item)
                  strokeWidth: 2.2,
                  color: Colors.white,
                  track: Colors.white.withValues(alpha: .22),
                  child: _PlayAvatar(
                    size: 42,
                    playing: playing,
                    avatarPath: widget.isVoice ? widget.senderAvatar : '',
                    fallbackInitial: widget.senderName.isNotEmpty
                        ? widget.senderName[0].toUpperCase()
                        : (widget.isVoice ? 'V' : '♪'),
                    showMusicTile: !widget.isVoice,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // waveform — drag to seek
                    GestureDetector(
                      onHorizontalDragUpdate: (d) {
                        if (!_isCurrent || _dur <= Duration.zero) return;
                        final box = context.findRenderObject() as RenderBox?;
                        if (box == null) return;
                        final local = box.globalToLocal(d.globalPosition);
                        // waveform starts after the 38px button + 8 gap
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
                        Text(
                          _dur > Duration.zero
                              ? '${_fmt(_pos)} / ${_fmt(_dur)}'
                              : _fmt(_pos),
                          textDirection: TextDirection.ltr,
                          style: TextStyle(fontSize: 9.5, color: _fgSoft),
                        ),
                        if (_isCurrent) ...[
                          const SizedBox(width: 6),
                          _SpeedChip(),
                        ],
                        if (!playing && !_isCurrent) ...[
                          const SizedBox(width: 6),
                          _SpeedChip(ghost: true),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Play button layered over the sender's avatar (or a music tile).
class _PlayAvatar extends StatelessWidget {
  final double size;
  final bool playing;
  final String avatarPath;
  final String fallbackInitial;
  final bool showMusicTile;

  const _PlayAvatar({
    required this.size,
    required this.playing,
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
    } else if (showMusicTile) {
      backdrop = ClipOval(
        child: Container(
          width: size,
          height: size,
          color: Colors.white.withValues(alpha: .16),
          alignment: Alignment.center,
          child: Icon(Icons.music_note_rounded,
              size: size * .42, color: Colors.white70),
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
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (backdrop != null) backdrop,
          // readable scrim over the avatar
          if (backdrop != null)
            Container(color: Colors.black.withValues(alpha: .30)),
          Center(
            child: Icon(
              playing
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
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
