import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:saver_gallery/saver_gallery.dart';
import 'package:video_player/video_player.dart';

import '../../core/api_service.dart';
import '../../core/app_state.dart';

/// Telegram-style full-screen media viewer:
///  • images: pinch zoom / pan / double-tap zoom, swipe-down to dismiss
///  • videos: exoplayer with play/pause + seek + mute
///  • Save button → downloads to gallery (MediaStore)
class PhotoViewerScreen extends StatefulWidget {
  final String fileUrl; // /static/uploads/... (server path or absolute)
  final bool isVideo;
  final String title;
  final String subtitle;
  final String heroTag;

  const PhotoViewerScreen({
    super.key,
    required this.fileUrl,
    this.isVideo = false,
    this.title = '',
    this.subtitle = '',
    this.heroTag = '',
  });

  static Route route({
    required String fileUrl,
    bool isVideo = false,
    String title = '',
    String subtitle = '',
  }) {    return PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black,
      transitionDuration: const Duration(milliseconds: 240),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, __, ___) => PhotoViewerScreen(
          fileUrl: fileUrl, isVideo: isVideo, title: title, subtitle: subtitle),
      transitionsBuilder: (_, anim, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
        child: ScaleTransition(
          scale: Tween(begin: 0.94, end: 1.0).animate(
              CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
          child: child,
        ),
      ),
    );
  }

  @override
  State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen> {
  VideoPlayerController? _vc;
  bool _saving = false;
  Offset _dragOffset = Offset.zero;

  String get _url => ApiService.I.absoluteUrl(widget.fileUrl);

  @override
  void initState() {
    super.initState();
    if (widget.isVideo) {
      _vc = VideoPlayerController.networkUrl(Uri.parse(_url))
        ..initialize().then((_) {
          if (mounted) {
            setState(() {});
            _vc!.play();
          }
        });
    }
  }

  @override
  void dispose() {
    _vc?.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final s = AppState.I.str;
    setState(() => _saving = true);
    try {
      final dir = await getTemporaryDirectory();
      final ext = _url.contains('.mp4')
          ? 'mp4'
          : _url.contains('.webm')
              ? 'webm'
              : _url.contains('.gif')
                  ? 'gif'
                  : _url.contains('.png')
                      ? 'png'
                      : _url.contains('.webp')
                          ? 'webp'
                          : 'jpg';
      final path =
          '${dir.path}/ravi_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final ok = await ApiService.I.downloadToFile(widget.fileUrl, path);
      if (!ok) throw 'download';
      final res = await SaverGallery.saveFile(
        filePath: path,
        fileName: 'RAVI_${DateTime.now().millisecondsSinceEpoch}.$ext',
        skipIfExists: false,
      );
      if (!mounted) return;
      showRaviToastHere(
          res.isSuccess ? s.savedToGallery : s.saveFailed);
    } catch (_) {
      if (mounted) showRaviToastHere(s.saveFailed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void showRaviToastHere(String msg) {
    final overlay = Overlay.of(context, rootOverlay: true);
    final entry = OverlayEntry(
      builder: (_) => Positioned(
        bottom: 90,
        left: 0, right: 0,
        child: IgnorePointer(
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(30),
              ),
              child: Text(msg,
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Future.delayed(const Duration(milliseconds: 1800), () => entry.remove());
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.I.str;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onVerticalDragUpdate: (d) {
          if (d.delta.dy > 0) {
            setState(() => _dragOffset = Offset(0, _dragOffset.dy + d.delta.dy));
          }
        },
        onVerticalDragEnd: (d) {
          if (_dragOffset.distance > 110) {
            Navigator.of(context).pop();
          } else {
            setState(() => _dragOffset = Offset.zero);
          }
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ---- media ----
            Transform.translate(
              offset: _dragOffset,
              child: widget.isVideo
                    ? _videoArea()
                    : Center(
                        child: GestureDetector(
                          onDoubleTap: () {}, // handled by InteractiveViewer
                          child: InteractiveViewer(
                            maxScale: 6,
                            minScale: 0.7,
                            child: CachedNetworkImage(
                              imageUrl: _url,
                              fit: BoxFit.contain,
                              httpHeaders: {
                                'Cookie': ApiService.I.cookieHeader,
                              },
                              placeholder: (_, __) => const Center(
                                child: SizedBox(
                                    width: 34,
                                    height: 34,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white54))),
                              errorWidget: (_, __, ___) => const Center(
                                child: Icon(Icons.broken_image_outlined,
                                    size: 60, color: Colors.white38),
                              ),
                            ),
                          ),
                        ),
                      ),
            ),

            // ---- top bar ----
            SafeArea(
              child: Column(
                children: [
                  Row(
                    children: [
                      const SizedBox(width: 6),
                      IconButton(
                        icon: const Icon(Icons.arrow_back_rounded,
                            color: Colors.white, size: 24),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (widget.title.isNotEmpty)
                              Text(widget.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14.5,
                                      fontWeight: FontWeight.w800)),
                            if (widget.subtitle.isNotEmpty)
                              Text(widget.subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: Colors.white.withValues(alpha: .65),
                                      fontSize: 11)),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: _saving
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.save_alt_rounded,
                                color: Colors.white, size: 22),
                        onPressed: _save,
                      ),
                      const SizedBox(width: 6),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _videoArea() {
    final vc = _vc;
    if (vc == null || !vc.value.isInitialized) {
      // While the player initializes we can't show the first frame yet —
      // keep it dark + spinner (never a jarring empty box).
      return const Center(
          child: SizedBox(
              width: 34,
              height: 34,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white54)));
    }

    // v1.0.7 — Telegram-style: the video's CURRENT FRAME, blurred + zoomed,
    // fills the whole screen as the backdrop, while the crisp video floats
    // centered on top. Buffering hiccups look intentional instead of ugly.
    final crisp = AspectRatio(
      aspectRatio: vc.value.aspectRatio == 0 ? 16 / 9 : vc.value.aspectRatio,
      child: GestureDetector(
        onTap: () {
          vc.value.isPlaying ? vc.pause() : vc.play();
        },
        child: VideoPlayer(vc),
      ),
    );

    return Stack(
      alignment: Alignment.center,
      children: [
        // blurred self-backdrop (cover the screen)
        Positioned.fill(
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: Transform.scale(
              scale: 1.4,
              child: Center(
                child: AspectRatio(
                  aspectRatio:
                      vc.value.aspectRatio == 0 ? 16 / 9 : vc.value.aspectRatio,
                  child: VideoPlayer(vc),
                ),
              ),
            ),
          ),
        ),
        // dark veil so the crisp video pops
        Positioned.fill(
          child: ColoredBox(
              color: Colors.black.withValues(alpha: .35)),
        ),
        // crisp video on top
        crisp,
        // buffering ring while the stream catches up
        ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: vc,
          builder: (context, v, _) => v.isBuffering && !v.isPlaying
              ? const SizedBox(
                  width: 34,
                  height: 34,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.2, color: Colors.white70))
              : const SizedBox.shrink(),
        ),
        const SizedBox(height: 0),
        // controls pinned under the crisp video
        PositionedDirectional(
          bottom: MediaQuery.of(context).size.height * 0.10,
          start: 0,
          end: 0,
          child: _VideoControls(vc: vc),
        ),
      ],
    );
  }
}

class _VideoControls extends StatelessWidget {
  final VideoPlayerController vc;
  const _VideoControls({required this.vc});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: vc,
      builder: (context, v, _) {
        String fmt(Duration d) {
          final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
          final sec = d.inSeconds.remainder(60).toString().padLeft(2, '0');
          return '$m:$sec';
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Column(
            children: [
              Row(
                children: [
                  Text(fmt(v.position),
                      style: const TextStyle(color: Colors.white70, fontSize: 11)),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                      ),
                      child: Slider(
                        activeColor: Colors.white,
                        inactiveColor: Colors.white24,
                        value: v.duration.inMilliseconds <= 0
                            ? 0
                            : v.position.inMilliseconds / v.duration.inMilliseconds,
                        onChanged: (t) {
                          vc.seekTo(v.duration * t);
                        },
                      ),
                    ),
                  ),
                  Text(fmt(v.duration),
                      style: const TextStyle(color: Colors.white70, fontSize: 11)),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: Icon(
                        v.volume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                        color: Colors.white),
                    onPressed: () {
                      vc.setVolume(v.volume == 0 ? 1.0 : 0.0);
                    },
                  ),
                  const SizedBox(width: 12),
                  Container(
                    decoration: const BoxDecoration(
                        color: Colors.white, shape: BoxShape.circle),
                    child: IconButton(
                      icon: Icon(
                          v.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                          color: Colors.black),
                      onPressed: () {
                        v.isPlaying ? vc.pause() : vc.play();
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  IconButton(
                    icon: const Icon(Icons.fullscreen_rounded, color: Colors.white),
                    onPressed: () {
                      v.isPlaying ? vc.pause() : vc.play();
                    },
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Save-to-gallery helper shared with other screens.
Future<bool> saveMediaToGallery(String urlOrPath) async {
  try {
    final dir = await getTemporaryDirectory();
    final isVideo = urlOrPath.contains('.mp4') || urlOrPath.contains('.webm');
    final ext = urlOrPath.endsWith('.gif')
        ? 'gif'
        : urlOrPath.endsWith('.png')
            ? 'png'
            : urlOrPath.endsWith('.webp')
                ? 'webp'
                : isVideo
                    ? 'mp4'
                    : 'jpg';
    final path = '${dir.path}/ravi_${DateTime.now().millisecondsSinceEpoch}.$ext';
    final ok = await ApiService.I.downloadToFile(urlOrPath, path);
    if (!ok) return false;
    final res = await SaverGallery.saveFile(
      filePath: path,
      fileName: 'RAVI_${DateTime.now().millisecondsSinceEpoch}.$ext',
      skipIfExists: false,
    );
    return res.isSuccess;
  } catch (_) {
    return false;
  }
}

/// Opens the full-screen viewer for a chat media file.
Future<void> openMediaViewer(
  BuildContext context, {
  required String fileUrl,
  bool isVideo = false,
  String title = '',
  String subtitle = '',
}) async {
  await Navigator.of(context, rootNavigator: true).push(PhotoViewerScreen.route(
    fileUrl: fileUrl,
    isVideo: isVideo,
    title: title,
    subtitle: subtitle,
  ));
}
