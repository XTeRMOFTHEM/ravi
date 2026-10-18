import 'dart:io';
import 'dart:ui' as ui;
import 'dart:ui';

import 'package:file_picker/file_picker.dart' as fp;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image_picker/image_picker.dart' as ip;
import 'package:video_player/video_player.dart';

import '../../core/app_state.dart';
import '../../core/constants.dart';
import '../../core/i18n.dart';

/// Telegram-style send flow:
///  1. pick (gallery/camera/music/file)
///  2. optional crop for photos
///  3. full preview with caption
///  4. onSend(path, kind, caption)
Future<void> showAttachSheet(
  BuildContext context, {
  required Future<bool> Function(String path, String fileType, String caption)
      onSend,
}) async {
  await showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => _AttachSheet(onSend: onSend),
  );
}

class _AttachSheet extends StatelessWidget {
  final Future<bool> Function(String, String, String) onSend;
  const _AttachSheet({required this.onSend});

  void _pick(BuildContext ctx, _Source src) async {
    final s = AppState.I.str;
    try {
      if (src == _Source.music || src == _Source.file) {
        final type =
            src == _Source.music ? fp.FileType.audio : fp.FileType.media;
        final files = await fp.FilePicker.pickFiles(type: type);
        if (files.isEmpty || files.first.path == null) return;
        final path = files.first.path!;
        final ext = path.split('.').last.toLowerCase();
        final kind = (ext == 'mp4' || ext == 'webm') ? 'video' : 'audio';
        final ok = await _openPreview(ctx, path, kind);
        if (!ok) {
          showRaviToastTop(ctx, s.unsupportedFile);
        }
        return;
      }
      // ---- gallery / camera: images AND videos (v1.0.6) ----
      final picker = ip.ImagePicker();
      if (src == _Source.camera) {
        // ask which one the user wants via a tiny glass sheet
        final choice = await showModalBottomSheet<String>(
          context: ctx,
          backgroundColor: Colors.transparent,
          builder: (_) => _CameraChoiceSheet(),
        );
        if (choice == null) return;
        if (choice == 'video') {
          final x = await picker.pickVideo(source: ip.ImageSource.camera);
          if (x == null) return;
          final ok = await _openPreview(ctx, x.path, 'video');
          if (!ok) showRaviToastTop(ctx, s.unsupportedFile);
          return;
        }
        final x = await picker.pickImage(
            source: ip.ImageSource.camera,
            maxWidth: 2400,
            imageQuality: 90);
        if (x == null) return;
        final ok = await _openPreview(ctx, x.path, 'image');
        if (!ok) showRaviToastTop(ctx, s.unsupportedFile);
        return;
      }
      // gallery: try a combined media pick first (image or video)
      final media = await picker.pickMedia();
      if (media == null) return;
      final isVideo = _isVideoPath(media.path);
      String path = media.path;
      // Telegram-like crop step for PHOTOS ONLY — video skips cropping.
      if (!isVideo) {
        try {
          final cropped = await ImageCropper().cropImage(
            sourcePath: path,
            uiSettings: [
              AndroidUiSettings(
                toolbarTitle: AppState.I.str.cropPhoto,
                toolbarColor: const Color(0xFF141A1F),
                toolbarWidgetColor: Colors.white,
                backgroundColor: Colors.black,
                activeControlsWidgetColor: const Color(0xFF8B5CF6),
                lockAspectRatio: false,
                hideBottomControls: false,
              ),
            ],
          );
          if (cropped != null) path = cropped.path;
        } catch (_) {
          // v1.0.6 CRASH FIX: if the cropper activity is unavailable on some
          // OEM ROMs we simply keep the original photo instead of crashing.
        }
      }
      final ok = await _openPreview(ctx, path, isVideo ? 'video' : 'image');
      if (!ok) {
        showRaviToastTop(ctx, AppState.I.str.unsupportedFile);
      }
    } catch (_) {}
  }

  static bool _isVideoPath(String p) {
    final ext = p.split('.').last.toLowerCase();
    return ext == 'mp4' || ext == 'webm' || ext == 'mov' || ext == 'm4v' || ext == '3gp';
  }

  Future<bool> _openPreview(
      BuildContext ctx, String path, String kind) async {
    final ext = path.split('.').last.toLowerCase();
    const allowed = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'mp4', 'webm', 'mp3', 'ogg', 'm4a'];
    if (!allowed.contains(ext)) return false;
    final res = await Navigator.of(ctx).push<bool>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _MediaPreviewScreen(path: path, kind: kind, onSend: onSend),
    ));
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: p.bg,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: p.borderSoft),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            _attachCell(p, Icons.photo_library_outlined, s.photoVideo,
                () => _pick(context, _Source.gallery)),
            _attachCell(p, Icons.photo_camera_outlined, s.camera,
                () => _pick(context, _Source.camera)),
            _attachCell(p, Icons.music_note_rounded, s.music,
                () => _pick(context, _Source.music)),
          ]),
        ],
      ),
    );
  }

  Widget _attachCell(Palette p, IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Column(children: [
        Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            color: p.accentSoft,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: p.accent, size: 24),
        ),
        const SizedBox(height: 7),
        Text(label, style: TextStyle(fontSize: 11, color: p.text2)),
      ]),
    );
  }
}

enum _Source { gallery, camera, music, file }

/// Camera choice: photo or video (glass mini-sheet).
class _CameraChoiceSheet extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final s = AppState.I.str;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          decoration: BoxDecoration(
            color: dark ? const Color(0xF3161C23) : const Color(0xFAFFFFFF),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const SizedBox(height: 16),
              _item(context, Icons.photo_camera_rounded, s.photo, 'photo', dark),
              _item(context, Icons.videocam_rounded, s.videoFile, 'video', dark),
              const SizedBox(height: 14),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _item(BuildContext ctx, IconData icon, String label, String val, bool dark) {
    return InkWell(
      onTap: () => Navigator.pop(ctx, val),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        child: Row(children: [
          Icon(icon, size: 21, color: const Color(0xFF8B5CF6)),
          const SizedBox(width: 13),
          Text(label,
              style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: dark ? Colors.white : C.textL)),
        ]),
      ),
    );
  }
}

Future<void> showRaviToastTop(BuildContext context, String msg) async {
  final overlay = Overlay.of(context, rootOverlay: true);
  final entry = OverlayEntry(
    builder: (_) => Positioned(
      top: 70,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(30),
            ),
            child: Text(msg,
                style: const TextStyle(color: Colors.white, fontSize: 12.5)),
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  await Future.delayed(const Duration(milliseconds: 2200), () => entry.remove());
}

// ==================== full preview with caption ====================

class _MediaPreviewScreen extends StatefulWidget {
  final String path;
  final String kind; // image | video | audio
  final Future<bool> Function(String, String, String) onSend;

  const _MediaPreviewScreen({
    required this.path,
    required this.kind,
    required this.onSend,
  });

  @override
  State<_MediaPreviewScreen> createState() => _MediaPreviewScreenState();
}

class _MediaPreviewScreenState extends State<_MediaPreviewScreen> {
  VideoPlayerController? _vc;
  final _caption = TextEditingController();
  bool _sending = false;
  bool _videoError = false;
  String _currentPath = '';
  late final String _originalPath;

  @override
  void initState() {
    super.initState();
    _originalPath = widget.path;
    _currentPath = widget.path;
    if (widget.kind == 'video') {
      _initVideo();
    }
  }

  // v1.0.6 crash-guard: unsupported/corrupt videos must never take the app down
  Future<void> _initVideo() async {
    try {
      _vc = VideoPlayerController.file(File(widget.path));
      await _vc!.initialize();
      if (!mounted) {
        _vc?.dispose();
        return;
      }
      setState(() {});
      _vc!.play();
    } catch (_) {
      if (mounted) setState(() => _videoError = true);
    }
  }

  @override
  void dispose() {
    _vc?.dispose();
    _caption.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending) return;
    setState(() => _sending = true);
    final ok = await widget.onSend(_currentPath, widget.kind, _caption.text.trim());
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() => _sending = false);
      showRaviToastTop(context, AppState.I.str.error);
    }
  }

  // ---------- v1.0.9 — editor toolbar: crop / draw / reset ----------
  Future<void> _crop() async {
    try {
      final cropped = await ImageCropper().cropImage(
        sourcePath: _currentPath,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: AppState.I.str.cropPhoto,
            toolbarColor: const Color(0xFF141A1F),
            toolbarWidgetColor: Colors.white,
            backgroundColor: Colors.black,
            activeControlsWidgetColor: const Color(0xFF8B5CF6),
            lockAspectRatio: false,
            hideBottomControls: false,
          ),
        ],
      );
      if (cropped != null && mounted) {
        setState(() => _currentPath = cropped.path);
      }
    } catch (_) {}
  }

  Future<void> _draw() async {
    final out = await Navigator.of(context).push<String>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _DrawScreen(imagePath: _currentPath),
    ));
    if (out != null && mounted) {
      setState(() => _currentPath = out);
    }
  }

  void _reset() {
    if (_currentPath != _originalPath) {
      setState(() => _currentPath = _originalPath);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(children: [
          // top bar
          Row(children: [
            IconButton(
              icon: const Icon(Icons.close_rounded, color: Colors.white),
              onPressed: () => Navigator.of(context).pop(),
            ),
            Text(s.previewLabel,
                style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
            const Spacer(),
          ]),
          // media
          Expanded(
            child: Center(
              child: widget.kind == 'image'
                  ? InteractiveViewer(
                      maxScale: 5,
                      child: Image.file(File(_currentPath), fit: BoxFit.contain),
                    )
                  : widget.kind == 'video' && _videoError
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.movie_outlined,
                                color: Colors.white54, size: 52),
                            const SizedBox(height: 10),
                            Text(widget.path.split('/').last,
                                style: const TextStyle(
                                    color: Colors.white54, fontSize: 12)),
                          ],
                        )
                      : widget.kind == 'video' && _vc != null && _vc!.value.isInitialized
                      ? AspectRatio(
                          aspectRatio: _vc!.value.aspectRatio,
                          child: VideoPlayer(_vc!),
                        )
                      : widget.kind == 'video'
                          ? const SizedBox(
                              width: 36,
                              height: 36,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.music_note_rounded,
                                    color: Colors.white70, size: 56),
                                const SizedBox(height: 10),
                                Text(
                                    widget.path.split('/').last,
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 12),
                                    textAlign: TextAlign.center),
                              ],
                            ),
            ),
          ),
          // v1.0.9 — editor toolbar (photos): Crop / Draw / Reset
          if (widget.kind == 'image')
            Container(
              color: Colors.black,
              padding: const EdgeInsets.fromLTRB(14, 2, 14, 4),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _toolBtn(Icons.crop_rounded, s.cropPhoto, _crop),
                const SizedBox(width: 26),
                _toolBtn(Icons.edit_rounded,
                    AppState.I.lang.value.isFa ? 'نقاشی' : 'Draw', _draw),
                const SizedBox(width: 26),
                _toolBtn(Icons.restart_alt_rounded,
                    AppState.I.lang.value.isFa ? 'ریست' : 'Reset', _reset),
              ]),
            ),
          // caption + send
          Container(
            color: Colors.black,
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
            child: Row(children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  alignment: Alignment.center,
                  child: TextField(
                    controller: _caption,
                    maxLines: 2,
                    minLines: 1,
                    style: const TextStyle(color: Colors.white, fontSize: 13.5),
                    decoration: InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                      hintText: s.addCaption,
                      hintStyle:
                          TextStyle(color: Colors.white.withValues(alpha: .4)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _sending ? null : _send,
                child: Container(
                  width: 46,
                  height: 46,
                  decoration: const BoxDecoration(
                    gradient: C.ownBubbleGrad,
                    shape: BoxShape.circle,
                  ),
                  child: _sending
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.send_rounded,
                          color: Colors.white, size: 20),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _toolBtn(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 20, color: Colors.white70),
        const SizedBox(height: 3),
        Text(label,
            style: const TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
                color: Colors.white70)),
      ]),
    );
  }
}

// ==================== v1.0.9 Draw screen (pencil on photo) ====================
/// Telegram-like paint layer: free-hand strokes with a color/width picker,
/// undo & reset, flattens onto the photo on save (pure Flutter, no FFI).
class _DrawScreen extends StatefulWidget {
  final String imagePath;
  const _DrawScreen({required this.imagePath});

  @override
  State<_DrawScreen> createState() => _DrawScreenState();
}

class _DrawScreenState extends State<_DrawScreen> {
  final List<_Stroke> _strokes = [];
  final List<_Stroke> _undo = [];
  Color _color = const Color(0xFFE11D48);
  double _width = 4;
  final GlobalKey _areaKey = GlobalKey();

  static const _colors = [
    Color(0xFFE11D48), Color(0xFFF59E0B), Color(0xFF22C55E),
    Color(0xFF38BDF8), Color(0xFF8B5CF6), Color(0xFFFFFFFF),
  ];

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(children: [
          // top bar
          Row(children: [
            IconButton(
              icon: const Icon(Icons.close_rounded, color: Colors.white),
              onPressed: () => Navigator.of(context).pop(),
            ),
            Text(AppState.I.lang.value.isFa ? 'روی عکس نقاشی کنید' : 'Draw on photo',
                style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.undo_rounded, color: Colors.white70),
              onPressed: _strokes.isEmpty
                  ? null
                  : () => setState(() {
                        _undo.add(_strokes.removeLast());
                      }),
            ),
            IconButton(
              icon: const Icon(Icons.restart_alt_rounded, color: Colors.white70),
              onPressed: _strokes.isEmpty
                  ? null
                  : () => setState(() {
                        _undo.addAll(_strokes);
                        _strokes.clear();
                      }),
            ),
            GestureDetector(
              onTap: () => _save(size),
              child: Container(
                margin: const EdgeInsetsDirectional.only(end: 10),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  gradient: C.ownBubbleGrad,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(AppState.I.str.save,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800)),
              ),
            ),
          ]),
          // canvas
          Expanded(
            child: Center(
              child: RepaintBoundary(
                key: _areaKey,
                child: GestureDetector(
                  onPanStart: (d) {
                    setState(() {
                      _strokes.add(_Stroke(
                          color: _color,
                          width: _width,
                          points: [d.localPosition]));
                    });
                  },
                  onPanUpdate: (d) {
                    setState(() {
                      _strokes.last.points.add(d.localPosition);
                    });
                  },
                  onPanEnd: (_) => _undo.clear(),
                  child: Stack(fit: StackFit.loose, children: [
                    Image.file(File(widget.imagePath), fit: BoxFit.contain),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _StrokesPainter(strokes: _strokes),
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ),
          // color / width picker
          Container(
            color: Colors.black,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
            child: Column(children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final c in _colors)
                    GestureDetector(
                      onTap: () => setState(() => _color = c),
                      child: Container(
                        width: 30,
                        height: 30,
                        margin: const EdgeInsets.symmetric(horizontal: 6),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: c,
                          border: Border.all(
                            color: _color == c
                                ? Colors.white
                                : Colors.white24,
                            width: _color == c ? 2.6 : 1,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Row(children: [
                const Icon(Icons.brush_rounded,
                    size: 16, color: Colors.white54),
                Expanded(
                  child: Slider(
                    value: _width,
                    min: 2,
                    max: 14,
                    activeColor: _color,
                    inactiveColor: Colors.white24,
                    onChanged: (v) => setState(() => _width = v),
                  ),
                ),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }

  /// Flattens photo + strokes into a new PNG and returns its path.
  Future<void> _save(Size screen) async {
    try {
      final boundary = _areaKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) return;
      final ui.Image img = await boundary.toImage(pixelRatio: 2.0);
      final byteData =
          await img.toByteData(format: ui.ImageByteFormat.png);
      final png = byteData!.buffer.asUint8List();
      final dir = await getTemporaryDirectory();
      final out =
          '${dir.path}/drawn_${DateTime.now().millisecondsSinceEpoch}.png';
      await File(out).writeAsBytes(png);
      if (mounted) Navigator.of(context).pop(out);
    } catch (_) {
      if (mounted) Navigator.of(context).pop();
    }
  }
}

class _Stroke {
  final Color color;
  final double width;
  final List<Offset> points;
  _Stroke({required this.color, required this.width, required this.points});
}

class _StrokesPainter extends CustomPainter {
  final List<_Stroke> strokes;
  _StrokesPainter({required this.strokes});

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in strokes) {
      if (s.points.isEmpty) continue;
      final paint = Paint()
        ..color = s.color
        ..strokeWidth = s.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      final path = Path()..moveTo(s.points.first.dx, s.points.first.dy);
      for (final p in s.points.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _StrokesPainter old) => true;
}
