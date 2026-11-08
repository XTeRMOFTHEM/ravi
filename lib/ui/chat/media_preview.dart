import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:audio_metadata_reader/audio_metadata_reader.dart' as amr;
import 'package:file_picker/file_picker.dart' as fp;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:image_picker/image_picker.dart' as ip;
import 'package:video_player/video_player.dart';

import '../../core/api_service.dart';
import '../../core/app_state.dart';
import '../../core/constants.dart';
import '../../core/i18n.dart';
import '../widgets/common.dart';

/// v1.1.0 — one attachment the user picked in the gallery sheet.
/// v1.2.1 — music files carry their parsed metadata (title / artist /
/// duration / cover art) so the chat can render a DEDICATED music bubble
/// instead of mistaking songs for voice notes.
class AttachItem {
  final String path;
  final String fileType; // image | video | audio | file
  final bool isVoice; // audio: recorded voice note vs music file
  final int durationMs;
  final String title;
  final String artist;
  final String coverPath; // local cover art file (uploaded on send)
  const AttachItem(this.path, this.fileType,
      {this.isVoice = false,
      this.durationMs = 0,
      this.title = '',
      this.artist = '',
      this.coverPath = ''});
}

/// Telegram-style send flow (v1.1.0 FULL REWORK):
///  1. IN-APP gallery sheet (photo_manager): grid of device photos/videos,
///     multi-select with check badges — no system picker hop
///  2. single photo → CROP/DRAW editor FIRST (send-as-is button included)
///  3. caption preview (clean glass composer, album thumbnail strip)
///  4. onSend(items, caption) — the caller sends the batch (album grouping)
Future<void> showAttachSheet(
  BuildContext context, {
  required Future<bool> Function(List<AttachItem> items, String caption)
      onSend,
}) async {
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _AttachSheet(onSend: onSend),
  );
}

class _AttachSheet extends StatefulWidget {
  final Future<bool> Function(List<AttachItem>, String) onSend;
  const _AttachSheet({required this.onSend});

  @override
  State<_AttachSheet> createState() => _AttachSheetState();
}

class _AttachSheetState extends State<_AttachSheet> {
  final Set<String> _picked = {}; // asset id
  List<AssetEntity>? _recent;
  bool _denied = false;
  int _page = 0;
  bool _loadingMore = false;
  AssetPathEntity? _path;

  static const _pageSize = 120;

  @override
  void initState() {
    super.initState();
    _loadGallery();
  }

  Future<void> _loadGallery() async {
    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.hasAccess) {
      if (mounted) setState(() => _denied = true);
      return;
    }
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: true,
      filterOption: FilterOptionGroup(
        orders: const [OrderOption(type: OrderOptionType.createDate)],
      ),
    );
    if (paths.isEmpty) {
      if (mounted) setState(() => _recent = []);
      return;
    }
    _path = paths.first;
    final assets = await _path!.getAssetListRange(start: 0, end: _pageSize);
    if (mounted) setState(() => _recent = assets);
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _path == null || _recent == null) return;
    _loadingMore = true;
    _page++;
    final more = await _path!
        .getAssetListRange(start: _page * _pageSize, end: (_page + 1) * _pageSize);
    if (mounted) {
      setState(() {
        _recent!.addAll(more);
      });
    }
    _loadingMore = false;
  }

  // ---------- pickers outside the gallery ----------
  // v1.2.1 — MUSIC: parse ID3/metadata exactly like Telegram — title,
  // artist, duration and the embedded cover art become part of the message,
  // and the receiving side gets a real music player (NOT a voice bar).
  Future<void> _pickFile(bool music) async {
    final s = AppState.I.str;
    try {
      final files =
          await fp.FilePicker.pickFiles(type: music ? fp.FileType.audio : fp.FileType.any);
      if (files.isEmpty || files.first.path == null) return;
      final path = files.first.path!;
      final ext = path.split('.').last.toLowerCase();
      final kind = music
          ? 'audio'
          : (ext == 'mp4' || ext == 'webm' || ext == 'mov' || ext == 'm4v'
              ? 'video'
              : 'file');
      if (kind != 'audio') {
        // v1.5.0 — اسم اصلی فایل همراه پیام می‌رود (media_meta.title) تا
        // حباب فایلِ گیرنده اسم واقعی را نشان دهد، نه اسم تولیدیِ سرور.
        await _openPreview([AttachItem(path, kind, title: files.first.name)], '');
        return;
      }
      var title = files.first.name;
      var artist = '';
      var durMs = 0;
      var coverPath = '';
      try {
        final meta = amr.readMetadata(File(path), getImage: true);
        final t = (meta.title ?? '').trim();
        if (t.isNotEmpty) title = t;
        final a = (meta.artist ?? '').trim();
        if (a.isNotEmpty) artist = a;
        durMs = meta.duration?.inMilliseconds ?? 0;
        for (final pic in meta.pictures) {
          final bytes = pic.bytes;
          if (bytes == null || bytes.isEmpty) continue;
          final dir = await getTemporaryDirectory();
          final f = File(
              '${dir.path}/cover_${DateTime.now().millisecondsSinceEpoch}.jpg');
          await f.writeAsBytes(bytes);
          coverPath = f.path;
          break;
        }
      } catch (_) {
        // unreadable tags → fall back to the filename (still a MUSIC send)
      }
      // upload the cover art once (small file) so receivers see it too
      var coverUrl = '';
      if (coverPath.isNotEmpty) {
        final up = await ApiService.I.uploadImage(coverPath);
        if (up.ok) coverUrl = '${up.data?['file_url'] ?? ''}';
      }
      await _openPreview(
        [
          AttachItem(path, 'audio',
              isVoice: false,
              durationMs: durMs,
              title: title,
              artist: artist,
              coverPath: coverUrl.isNotEmpty ? coverUrl : coverPath),
        ],
        '',
      );
    } catch (_) {
      if (mounted) showRaviToastTop(context, s.unsupportedFile);
    }
  }

  Future<void> _pickCamera() async {
    final s = AppState.I.str;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _CameraChoiceSheet(),
    );
    if (choice == null) return;
    final picker = ip.ImagePicker();
    try {
      if (choice == 'video') {
        final x = await picker.pickVideo(source: ip.ImageSource.camera);
        if (x == null) return;
        await _openPreview([AttachItem(x.path, 'video')], '');
        return;
      }
      final x = await picker.pickImage(
          source: ip.ImageSource.camera, maxWidth: 2400, imageQuality: 92);
      if (x == null) return;
      final edited = await _editPhoto(x.path);
      if (edited == null) return; // user backed out
      await _openPreview([AttachItem(edited, 'image')], '');
    } catch (_) {
      if (mounted) showRaviToastTop(context, s.unsupportedFile);
    }
  }

  /// v1.1.0 — the CROP/DRAW editor comes FIRST (Telegram order):
  /// crop → draw → "send as-is" → null (user cancelled).
  Future<String?> _editPhoto(String path) async {
    final res = await Navigator.of(context).push<String>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _EditFirstScreen(path: path),
    ));
    return res;
  }

  Future<void> _openPreview(List<AttachItem> items, String caption) async {
    if (items.isEmpty) return;
    final allowed = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'mp4', 'webm', 'mp3', 'ogg', 'm4a', 'pdf', 'zip', 'doc', 'docx', 'txt', 'mov', 'm4v', '3gp'];
    for (final it in items) {
      final ext = it.path.split('.').last.toLowerCase();
      if (it.fileType == 'file' || it.fileType == 'audio' || it.fileType == 'video') {
        continue; // non-image files pass without extension checks
      }
      if (!allowed.contains(ext)) {
        if (mounted) showRaviToastTop(context, AppState.I.str.unsupportedFile);
        return;
      }
    }
    await Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _MediaPreviewScreen(
          items: items, caption: caption, onSend: widget.onSend),
    ));
  }

  Future<void> _confirmSelection() async {
    if (_picked.isEmpty || _recent == null) return;
    final s = AppState.I.str;
    final items = <AttachItem>[];
    for (final a in _recent!) {
      if (!_picked.contains(a.id)) continue;
      final file = await a.originFile.timeout(const Duration(seconds: 8),
          onTimeout: () => null);
      if (file == null) continue;
      final kind = a.type == AssetType.video ? 'video' : 'image';
      items.add(AttachItem(file.path, kind));
    }
    if (items.isEmpty) return;
    // single photo → straight into the crop-first editor
    if (items.length == 1 && items.first.fileType == 'image') {
      final edited = await _editPhoto(items.first.path);
      if (edited == null) return; // cancelled
      items[0] = AttachItem(edited, 'image');
    }
    await _openPreview(items, '');
  }

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;
    final height = MediaQuery.sizeOf(context).height * 0.82;

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
        child: Container(
          height: height,
          color: p.bg.withValues(alpha: .97),
          child: Column(children: [
            const SizedBox(height: 10),
            Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                    color: p.border,
                    borderRadius: BorderRadius.circular(3))),
            // ---- header row ----
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 10, 8),
              child: Row(children: [
                Icon(Icons.photo_library_rounded, size: 20, color: p.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(s.galleryTitle,
                      style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w800,
                          color: p.text)),
                ),
                if (_picked.isNotEmpty)
                  GestureDetector(
                    onTap: _confirmSelection,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        gradient: C.ownBubbleGrad,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(s.sendCount(_picked.length),
                            style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w800,
                                color: Colors.white)),
                      ]),
                    ),
                  ),
                const SizedBox(width: 8),
                _roundTool(p, Icons.music_note_rounded, () => _pickFile(true)),
                const SizedBox(width: 6),
                _roundTool(p, Icons.folder_outlined, () => _pickFile(false)),
                const SizedBox(width: 6),
                _roundTool(p, Icons.photo_camera_outlined, _pickCamera),
              ]),
            ),
            Divider(height: 1, color: p.border),
            // ---- gallery grid ----
            Expanded(child: _gridBody(p, s)),
            // ---- action bar ----
            SafeArea(
              top: false,
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
                decoration: BoxDecoration(
                  color: p.bg,
                  border: Border(top: BorderSide(color: p.border)),
                ),
                child: Row(children: [
                  Icon(Icons.info_outline_rounded,
                      size: 15, color: p.text3),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      _picked.isEmpty
                          ? s.galleryHintMulti
                          : s.gallerySelectedHint(_picked.length),
                      style: TextStyle(fontSize: 11, color: p.text3),
                    ),
                  ),
                  GestureDetector(
                    onTap: _picked.isEmpty
                        ? null
                        : () => setState(() => _picked.clear()),
                    child: Text(s.clearSelection,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: _picked.isEmpty
                                ? p.text3
                                : const Color(0xFFEF4444))),
                  ),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _roundTool(Palette p, IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: p.accentSoft,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 19, color: p.accent),
      ),
    );
  }

  Widget _gridBody(Palette p, S s) {
    if (_denied) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.photo_library_outlined, size: 40, color: p.text3),
            const SizedBox(height: 12),
            Text(s.galleryPermission,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: p.text2)),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () async {
                await PhotoManager.openSetting();
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                decoration: BoxDecoration(
                  color: p.accentSoft,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(s.openSettings,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: p.accent)),
              ),
            ),
          ],
        ),
      );
    }
    if (_recent == null) {
      return const Center(
          child: SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 2.2)));
    }
    if (_recent!.isEmpty) {
      return Center(
          child: Text(s.galleryEmpty,
              style: TextStyle(fontSize: 12.5, color: p.text3)));
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(3, 3, 3, 10),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
      ),
      itemCount: _recent!.length,
      itemBuilder: (ctx, i) {
        final asset = _recent![i];
        final selectedIdx = _picked.toList().indexOf(asset.id);
        final picked = _picked.contains(asset.id);
        if (i == _recent!.length - 12) {
          Future.microtask(_loadMore);
        }
        return GestureDetector(
          onTap: () {
            HapticFeedback.selectionClick();
            setState(() {
              if (picked) {
                _picked.remove(asset.id);
              } else {
                if (_picked.length >= 10) return; // album cap (Telegram-ish)
                _picked.add(asset.id);
              }
            });
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(picked ? 8 : 2),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // v1.2.1 — BULLETPROOF thumbnail loader. The old
                // AssetEntityImage silently failed on several devices
                // (blank tiles = "gallery doesn't load images"); this one
                // decodes the thumbnail manually with a file fallback +
                // explicit error tile + retry.
                _GalleryTile(asset: asset),
                if (asset.type == AssetType.video)
                  PositionedDirectional(
                    bottom: 4,
                    start: 5,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.videocam_rounded,
                          size: 12, color: Colors.white),
                      const SizedBox(width: 3),
                      Text(_fmtDur(asset.videoDuration.inSeconds),
                          textDirection: TextDirection.ltr,
                          style: const TextStyle(
                              fontSize: 9.5,
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              shadows: [
                                Shadow(color: Colors.black45, blurRadius: 3)
                              ])),
                    ]),
                  ),
                if (picked)
                  PositionedDirectional(
                    top: 5,
                    end: 5,
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: p.accent,
                        border: Border.all(color: Colors.white, width: 1.6),
                      ),
                      child: Center(
                        child: Text('${selectedIdx + 1}',
                            textDirection: TextDirection.ltr,
                            style: const TextStyle(
                                fontSize: 10.5,
                                color: Colors.white,
                                fontWeight: FontWeight.w900)),
                      ),
                    ),
                  )
                else
                  PositionedDirectional(
                    top: 5,
                    end: 5,
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black.withValues(alpha: .25),
                        border: Border.all(
                            color: Colors.white.withValues(alpha: .85),
                            width: 1.6),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _fmtDur(int secs) {
    final m = (secs ~/ 60).toString().padLeft(1, '0');
    final s = (secs % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

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
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(24)),
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

// ==================== v1.1.0 — EDIT-FIRST screen ====================
// The crop/draw editor opens BEFORE the caption preview. The user can crop,
// draw on, or send the photo exactly as it is.
class _EditFirstScreen extends StatefulWidget {
  final String path;
  const _EditFirstScreen({required this.path});

  @override
  State<_EditFirstScreen> createState() => _EditFirstScreenState();
}

class _EditFirstScreenState extends State<_EditFirstScreen> {
  late String _current;

  @override
  void initState() {
    super.initState();
    _current = widget.path;
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.I.str;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(children: [
          // top bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(children: [
              IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
              Text(s.editPhotoTitle,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w800)),
              const Spacer(),
            ]),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Center(
                child: InteractiveViewer(
                  maxScale: 5,
                  child: Image.file(File(_current), fit: BoxFit.contain),
                ),
              ),
            ),
          ),
          // editor tools: crop / draw / reset
          Container(
            color: Colors.black,
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              _toolBtn(Icons.crop_rounded, s.cropPhoto, _crop),
              const SizedBox(width: 26),
              _toolBtn(Icons.edit_rounded, s.drawOn, _draw),
              const SizedBox(width: 26),
              if (_current != widget.path)
                _toolBtn(Icons.restart_alt_rounded, s.resetEdit, _reset)
              else
                const SizedBox(width: 64),
            ]),
          ),
          // bottom actions
          SafeArea(
            top: false,
            child: Container(
              color: Colors.black,
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
              child: Row(children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Container(
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: .08),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                            color: Colors.white.withValues(alpha: .16)),
                      ),
                      child: Text(s.sendAsIs,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: GestureDetector(
                    onTap: () => Navigator.of(context).pop(_current),
                    child: Container(
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        gradient: C.ownBubbleGrad,
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.arrow_forward_rounded,
                              size: 18, color: Colors.white),
                          const SizedBox(width: 6),
                          Text(s.nextStep,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w800)),
                        ],
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _toolBtn(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 72,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 22, color: Colors.white),
          const SizedBox(height: 3),
          Text(label,
              style: TextStyle(
                  fontSize: 10, color: Colors.white.withValues(alpha: .8))),
        ]),
      ),
    );
  }

  Future<void> _crop() async {
    try {
      final cropped = await ImageCropper().cropImage(
        sourcePath: _current,
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
        setState(() => _current = cropped.path);
      }
    } catch (_) {
      // some OEM ROMs lack the cropper activity — keep the original
    }
  }

  Future<void> _draw() async {
    final out = await Navigator.of(context).push<String>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _DrawScreen(imagePath: _current),
    ));
    if (out != null && mounted) {
      setState(() => _current = out);
    }
  }

  void _reset() {
    if (_current != widget.path) {
      setState(() => _current = widget.path);
    }
  }
}

// ==================== caption preview (album aware) ====================

class _MediaPreviewScreen extends StatefulWidget {
  final List<AttachItem> items;
  final String caption;
  final Future<bool> Function(List<AttachItem>, String) onSend;

  const _MediaPreviewScreen({
    required this.items,
    required this.caption,
    required this.onSend,
  });

  @override
  State<_MediaPreviewScreen> createState() => _MediaPreviewScreenState();
}

class _MediaPreviewScreenState extends State<_MediaPreviewScreen> {
  VideoPlayerController? _vc;
  final _captionCtrl = TextEditingController();
  final _focus = FocusNode();
  bool _sending = false;
  bool _videoError = false;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _captionCtrl.text = widget.caption;
    _initVideo();
  }

  Future<void> _initVideo() async {
    if (widget.items[_index].fileType != 'video') return;
    _vc?.dispose();
    _vc = null;
    try {
      final c = VideoPlayerController.file(File(widget.items[_index].path));
      _vc = c;
      await c.initialize();
      if (!mounted) {
        c.dispose();
        return;
      }
      setState(() {});
      c.play();
    } catch (_) {
      if (mounted) setState(() => _videoError = true);
    }
  }

  @override
  void dispose() {
    _vc?.dispose();
    _captionCtrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _selectIndex(int i) {
    if (i == _index) return;
    setState(() {
      _index = i;
      _videoError = false;
    });
    _initVideo();
  }

  Future<void> _send() async {
    if (_sending) return;
    setState(() => _sending = true);
    FocusManager.instance.primaryFocus?.unfocus();
    final ok = await widget.onSend(widget.items, _captionCtrl.text.trim());
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
      Navigator.of(context).pop();
    } else {
      setState(() => _sending = false);
      showRaviToastTop(context, AppState.I.str.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;
    final item = widget.items[_index];

    return Scaffold(
      resizeToAvoidBottomInset: true,
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
            if (widget.items.length > 1)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 14),
                child: Text(s.albumCount(widget.items.length),
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
              ),
          ]),
          // media
          Expanded(
            child: Center(
              child: item.fileType == 'image'
                  ? InteractiveViewer(
                      maxScale: 5,
                      child: Image.file(File(item.path), fit: BoxFit.contain),
                    )
                  : item.fileType == 'video' && _videoError
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.movie_outlined,
                                color: Colors.white54, size: 52),
                            const SizedBox(height: 10),
                            Text(item.path.split('/').last,
                                style: const TextStyle(
                                    color: Colors.white54, fontSize: 12)),
                          ],
                        )
                      : item.fileType == 'video' &&
                              _vc != null &&
                              _vc!.value.isInitialized
                          ? AspectRatio(
                              aspectRatio: _vc!.value.aspectRatio,
                              child: VideoPlayer(_vc!),
                            )
                          : item.fileType == 'video'
                              ? const SizedBox(
                                  width: 36,
                                  height: 36,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))
                              : Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.insert_drive_file_rounded,
                                        color: Colors.white70, size: 56),
                                    const SizedBox(height: 10),
                                    Text(item.path.split('/').last,
                                        style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 12),
                                        textAlign: TextAlign.center),
                                  ],
                                ),
            ),
          ),
          // album thumbnails
          if (widget.items.length > 1)
            Container(
              height: 74,
              color: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: widget.items.length,
                separatorBuilder: (_, __) => const SizedBox(width: 7),
                itemBuilder: (ctx, i) {
                  final it = widget.items[i];
                  final sel = i == _index;
                  return GestureDetector(
                    onTap: () => _selectIndex(i),
                    child: Container(
                      width: 58,
                      height: 58,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(
                            color: sel
                                ? const Color(0xFF8B5CF6)
                                : Colors.transparent,
                            width: 2),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(7),
                        child: it.fileType == 'image'
                            ? Image.file(File(it.path), fit: BoxFit.cover)
                            : Container(
                                color: Colors.white12,
                                child: Icon(
                                    it.fileType == 'video'
                                        ? Icons.videocam_rounded
                                        : Icons.insert_drive_file_rounded,
                                    size: 20,
                                    color: Colors.white70),
                              ),
                      ),
                    ),
                  );
                },
              ),
            ),
          // ---- v1.1.0 — clean glass caption composer ----
          Container(
            color: Colors.black,
            padding: EdgeInsets.fromLTRB(
                10, 6, 10, 8 + MediaQuery.of(context).padding.bottom * 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Container(
                    constraints: const BoxConstraints(maxHeight: 130),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: .08),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                          color: Colors.white.withValues(alpha: .14)),
                    ),
                    child: TextField(
                      controller: _captionCtrl,
                      focusNode: _focus,
                      maxLines: null,
                      minLines: 1,
                      textInputAction: TextInputAction.newline,
                      keyboardType: TextInputType.multiline,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14.5,
                          height: 1.3),
                      cursorColor: const Color(0xFFB79CF8),
                      decoration: InputDecoration(
                        isCollapsed: true,
                        border: InputBorder.none,
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 12),
                        hintText: s.captionHint,
                        hintStyle: TextStyle(
                            color: Colors.white.withValues(alpha: .38),
                            fontSize: 14),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _send,
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
                            size: 21, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

// ==================== draw (unchanged behaviour) ====================

class _DrawScreen extends StatefulWidget {
  final String imagePath;
  const _DrawScreen({required this.imagePath});

  @override
  State<_DrawScreen> createState() => _DrawScreenState();
}

class _DrawScreenState extends State<_DrawScreen> {
  final List<List<Offset>> _strokes = [];
  final List<Color> _colors = const [
    Color(0xFFEF4444),
    Color(0xFF22C55E),
    Color(0xFF38BDF8),
    Color(0xFFF59E0B),
    Colors.white,
    Colors.black,
  ];
  int _ci = 0;
  final _key = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final s = AppState.I.str;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(children: [
          Row(children: [
            IconButton(
              icon: const Icon(Icons.close_rounded, color: Colors.white),
              onPressed: () => Navigator.of(context).pop(),
            ),
            Text(s.drawOn,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w800)),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.undo_rounded, color: Colors.white70),
              onPressed: _strokes.isEmpty
                  ? null
                  : () => setState(() => _strokes.removeLast()),
            ),
          ]),
          Expanded(
            child: GestureDetector(
              onPanStart: (d) =>
                  setState(() => _strokes.add([d.localPosition])),
              onPanUpdate: (d) => setState(() {
                _strokes.last.add(d.localPosition);
              }),
              child: RepaintBoundary(
                key: _key,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.file(File(widget.imagePath), fit: BoxFit.contain),
                    CustomPaint(
                      painter: _StrokesPainter(
                          strokes: _strokes, color: _colors[_ci]),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.black,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (var i = 0; i < _colors.length; i++)
                  GestureDetector(
                    onTap: () => setState(() => _ci = i),
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _colors[i],
                        border: Border.all(
                            color: _ci == i
                                ? Colors.white
                                : Colors.white24,
                            width: _ci == i ? 3 : 1.4),
                      ),
                    ),
                  ),
                GestureDetector(
                  onTap: () async {
                    final out = await _export();
                    if (out != null && mounted) {
                      Navigator.of(context).pop(out);
                    }
                  },
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(
                      gradient: C.ownBubbleGrad,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.check_rounded,
                        color: Colors.white, size: 22),
                  ),
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  Future<String?> _export() async {
    try {
      final boundary = _key.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) return null;
      final image = await boundary.toImage(pixelRatio: 2.5);
      final bytes =
          (await image.toByteData(format: ImageByteFormat.png))
              ?.buffer
              .asUint8List();
      if (bytes == null) return null;
      final dir = await getTemporaryDirectory();
      final f = File(
          '${dir.path}/draw_${DateTime.now().millisecondsSinceEpoch}.png');
      await f.writeAsBytes(bytes);
      return f.path;
    } catch (_) {
      return null;
    }
  }
}

class _StrokesPainter extends CustomPainter {
  final List<List<Offset>> strokes;
  final Color color;
  _StrokesPainter({required this.strokes, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 4.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    for (final s in strokes) {
      if (s.isEmpty) continue;
      if (s.length == 1) {
        canvas.drawCircle(s.first, 2.4, Paint()..color = color);
        continue;
      }
      final path = Path()..moveTo(s.first.dx, s.first.dy);
      for (final p in s.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _StrokesPainter old) => true;
}

/// v1.2.1 — BULLETPROOF gallery tile. Decodes the MediaStore thumbnail
/// MANUALLY (thumbnailDataWithSize) with an original-file fallback, an
/// explicit error tile + one tap-to-retry. This is the fix for "the gallery
/// opens but images never load" — AssetEntityImage used to fail silently
/// and paint blank tiles.
class _GalleryTile extends StatefulWidget {
  final AssetEntity asset;
  const _GalleryTile({required this.asset});

  @override
  State<_GalleryTile> createState() => _GalleryTileState();
}

class _GalleryTileState extends State<_GalleryTile> {
  Uint8List? _bytes;
  bool _failed = false;
  int _attempt = 0;
  static final Map<String, Uint8List> _cache = {};

  @override
  void initState() {
    super.initState();
    _bytes = _cache[widget.asset.id];
    if (_bytes == null) _load();
  }

  Future<void> _load() async {
    _failed = false;
    if (mounted) setState(() {});
    try {
      final data = await widget.asset.thumbnailDataWithSize(
        const ThumbnailSize(360, 360),
        quality: 88,
      );
      if (data == null || data.isEmpty) throw 'no_thumb';
      _cache[widget.asset.id] = data;
      if (mounted) setState(() => _bytes = data);
      return;
    } catch (_) {}
    // fallback 1 — the original file (works even when the thumb cache is
    // broken, e.g. after a cloud-photo restore)
    try {
      final file = await widget.asset.file;
      if (file != null && await file.exists()) {
        // decode downscaled so we never OOM on 12MP shots
        final bytes = await _downscale(file);
        if (bytes != null && bytes.isNotEmpty) {
          _cache[widget.asset.id] = bytes;
          if (mounted) setState(() => _bytes = bytes);
          return;
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _failed = true);
  }

  static Future<Uint8List?> _downscale(File f) async {
    try {
      final raw = await f.readAsBytes();
      final codec = await instantiateImageCodec(raw, targetWidth: 360);
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ImageByteFormat.png);
      frame.image.dispose();
      codec.dispose();
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return Image.memory(_bytes!, fit: BoxFit.cover, gaplessPlayback: true);
    }
    if (_failed) {
      return GestureDetector(
        onTap: _attempt < 3 ? () { _attempt++; _load(); } : null,
        child: Container(
          color: Colors.white.withValues(alpha: .04),
          alignment: Alignment.center,
          child: Icon(_attempt < 3
              ? Icons.refresh_rounded
              : Icons.image_not_supported_outlined,
              size: 22, color: Colors.white38),
        ),
      );
    }
    return Container(color: Colors.white.withValues(alpha: .05));
  }
}
