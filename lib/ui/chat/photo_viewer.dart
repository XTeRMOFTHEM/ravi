import 'dart:io';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:saver_gallery/saver_gallery.dart';
import 'package:video_player/video_player.dart';

import '../../core/api_service.dart';
import '../../core/app_state.dart';
import '../../core/media_download_manager.dart';

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

  // عکس: اول از دیسکِ ماندگار اپ؛ اگر نبود با پیشرفت دانلود می‌شود
  final TransformationController _tc = TransformationController();
  Offset _dtPos = Offset.zero;
  String? _localPath;
  bool _imgFailed = false;

  String get _url => ApiService.I.absoluteUrl(widget.fileUrl);
  bool get _zoomed => _tc.value.getMaxScaleOnAxis() > 1.05;

  @override
  void initState() {
    super.initState();
    if (widget.isVideo) {
      _prepareVideo();
    } else {
      _prepareImage();
    }
  }

  Future<void> _prepareImage() async {
    if (mounted) setState(() => _imgFailed = false);
    final cached = await MediaDownloadManager.I.cachedPath(widget.fileUrl);
    if (!mounted) return;
    if (cached != null) {
      setState(() => _localPath = cached);
      return;
    }
    final path = await MediaDownloadManager.I.ensureDownloaded(widget.fileUrl);
    if (!mounted) return;
    setState(() {
      if (path != null) {
        _localPath = path;
      } else {
        _imgFailed = true;
      }
    });
  }

  Future<void> _prepareVideo() async {
    // اگر قبلاً دانلود شده از دیسک پخش می‌شود، وگرنه استریم (با کوکی نشست)
    final cached = await MediaDownloadManager.I.cachedPath(widget.fileUrl);
    if (!mounted) return;
    final vc = cached != null
        ? VideoPlayerController.file(File(cached))
        : VideoPlayerController.networkUrl(Uri.parse(_url),
            httpHeaders: {'Cookie': ApiService.I.cookieHeader});
    _vc = vc;
    setState(() {});
    try {
      await vc.initialize();
      if (!mounted) return;
      setState(() {});
      vc.play();
    } catch (_) {
      if (mounted) setState(() {});
    }
  }

  void _toggleZoom() {
    if (_zoomed) {
      _tc.value = Matrix4.identity();
    } else {
      const sc = 2.5;
      _tc.value = Matrix4.diagonal3Values(sc, sc, 1)
        ..setTranslationRaw(-_dtPos.dx * (sc - 1), -_dtPos.dy * (sc - 1), 0);
    }
  }

  @override
  void dispose() {
    _vc?.dispose();
    _tc.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final s = AppState.I.str;
    setState(() => _saving = true);
    try {
      // v1.5.0 — دانلود از دیسکِ ماندگار اپ (یک بار برای همیشه) + ذخیره
      final path = await MediaDownloadManager.I.ensureDownloaded(widget.fileUrl);
      if (path == null) {
        if (MediaDownloadManager.I.taskFor(widget.fileUrl)?.state == 'cancelled') {
          return; // لغو = بی‌صدا
        }
        throw 'download';
      }
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
      final res = await SaverGallery.saveFile(
        filePath: path,
        fileName: 'RAVI_${DateTime.now().millisecondsSinceEpoch}.$ext',
        albumPath: 'RAVI',
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
          if (_zoomed) return; // وقتی زوم است کشیدن = جابه‌جایی عکس، نه بستن
          if (d.delta.dy > 0) {
            setState(() => _dragOffset = Offset(0, _dragOffset.dy + d.delta.dy));
          }
        },
        onVerticalDragEnd: (d) {
          if (_zoomed) return;
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
                    : _imageArea(),
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
                            ? AnimatedBuilder(
                                animation: MediaDownloadManager.I,
                                builder: (_, __) {
                                  final t = MediaDownloadManager.I
                                      .taskFor(widget.fileUrl);
                                  final pr = t?.progress ?? 0;
                                  return SizedBox(
                                    width: 26,
                                    height: 26,
                                    child: Stack(
                                        alignment: Alignment.center,
                                        children: [
                                          CircularProgressIndicator(
                                            value: pr <= 0
                                                ? null
                                                : pr.clamp(0.03, 1.0),
                                            strokeWidth: 2.2,
                                            color: Colors.white,
                                            backgroundColor: Colors.white24,
                                            strokeCap: StrokeCap.round,
                                          ),
                                          const Icon(Icons.close_rounded,
                                              size: 13, color: Colors.white),
                                        ]),
                                  );
                                })
                            : const Icon(Icons.save_alt_rounded,
                                color: Colors.white, size: 22),
                        onPressed: _saving
                            ? () => MediaDownloadManager.I.cancel(widget.fileUrl)
                            : _save,
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

  Widget _imageArea() {
    if (_imgFailed) {
      return Center(
        child: GestureDetector(
          onTap: _prepareImage,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.broken_image_outlined,
                size: 60, color: Colors.white38),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.white12,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.refresh_rounded, size: 16, color: Colors.white),
                SizedBox(width: 6),
                Text('Retry',
                    style: TextStyle(color: Colors.white, fontSize: 12.5)),
              ]),
            ),
          ]),
        ),
      );
    }
    if (_localPath == null) {
      return Center(
        child: _ViewerProgress(
          fileUrl: widget.fileUrl,
          onCancel: () {
            MediaDownloadManager.I.cancel(widget.fileUrl);
          },
        ),
      );
    }
    return Center(
      child: GestureDetector(
        onDoubleTapDown: (d) => _dtPos = d.localPosition,
        onDoubleTap: _toggleZoom,
        child: InteractiveViewer(
          transformationController: _tc,
          maxScale: 6,
          minScale: 1,
          child: Image.file(
            File(_localPath!),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => const Center(
              child: Icon(Icons.broken_image_outlined,
                  size: 60, color: Colors.white38),
            ),
          ),
        ),
      ),
    );
  }

  Widget _videoArea() {
    final vc = _vc;
    if (vc != null && vc.value.hasError) {
      return const Center(
          child: Icon(Icons.error_outline_rounded,
              size: 56, color: Colors.white38));
    }
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
                            ? 0.0
                            : (v.position.inMilliseconds /
                                    v.duration.inMilliseconds)
                                .clamp(0.0, 1.0),
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
                  // کنار دکمه‌ی صدا برای تقارن (قبلاً دکمه‌ی «تمام‌صفحه» اینجا بود که
                  // فقط پخش/توقف می‌کرد)
                  const SizedBox(width: 48),
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

/// حلقه‌ی بزرگ دانلود وسط نمایشگر: ✕ برای لغو + «3.2 / 12.5 MB · 1.1 MB/s».
class _ViewerProgress extends StatelessWidget {
  final String fileUrl;
  final VoidCallback onCancel;
  const _ViewerProgress({required this.fileUrl, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: MediaDownloadManager.I,
      builder: (_, __) {
        final t = MediaDownloadManager.I.taskFor(fileUrl);
        final pr = t?.progress ?? 0;
        final label = (t != null && t.received > 0)
            ? [
                fmtTransfer(t.received, t.total),
                fmtSpeed(t.speed),
              ].where((e) => e.isNotEmpty).join(' · ')
            : '';
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onCancel,
              child: Container(
                width: 64,
                height: 64,
                decoration: const BoxDecoration(
                    color: Colors.white12, shape: BoxShape.circle),
                child: Stack(alignment: Alignment.center, children: [
                  SizedBox(
                    width: 58,
                    height: 58,
                    child: CircularProgressIndicator(
                      value: pr <= 0 ? null : pr.clamp(0.03, 1.0),
                      strokeWidth: 3,
                      color: Colors.white,
                      backgroundColor: Colors.white24,
                      strokeCap: StrokeCap.round,
                    ),
                  ),
                  const Icon(Icons.close_rounded,
                      size: 26, color: Colors.white),
                ]),
              ),
            ),
            if (label.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(label,
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ],
        );
      },
    );
  }
}
