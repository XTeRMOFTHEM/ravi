import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api_service.dart';
import '../../core/app_state.dart';
import '../../core/constants.dart';
import '../../core/i18n.dart';
import '../widgets/common.dart';
import '../widgets/ravi_alerts.dart';

/// v1.0.8 — GIF library, embeddable grid widget + sheet wrapper.
///  • grid of the user's saved GIFs (GET /my_gifs)
///  • upload a video → the backend converts it to a small looping GIF
///    (POST /upload_gif, field `video`)
///  • tap a gif → returns its url (sent as file_type 'gif')
///  • long-press → delete from MY gallery (POST /delete_gif/<id>)
/// The grid now lives INSIDE the combined emoji panel (bottom GIF tab);
/// the sheet wrapper stays for direct usage.
class GifPickerGrid extends StatefulWidget {
  final ValueChanged<String> onPicked;
  final bool compact; // embedded in the emoji panel → denser padding
  final bool showHeader; // upload button row (sheet mode)

  const GifPickerGrid({
    super.key,
    required this.onPicked,
    this.compact = false,
    this.showHeader = false,
  });

  @override
  State<GifPickerGrid> createState() => _GifPickerGridState();
}

class _GifPickerGridState extends State<GifPickerGrid> {
  List<Map<String, dynamic>>? _gifs;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final res = await ApiService.I.myGifs();
    if (!mounted) return;
    setState(() {
      _gifs = res.data;
    });
  }

  Future<void> _pickAndUpload() async {
    final s = AppState.I.str;
    try {
      final x = await ImagePicker().pickVideo(source: ImageSource.gallery);
      if (x == null) return;
      setState(() => _uploading = true);
      final res = await ApiService.I.uploadGif(x.path);
      if (!mounted) return;
      setState(() => _uploading = false);
      if (res.ok) {
        showRaviToast(context, s.gifReady, icon: Icons.check_circle_outline_rounded);
        await _load();
      } else {
        showRaviToast(context,
            s.gifUploadFailed(res.message ?? ''),
            icon: Icons.error_outline_rounded);
      }
    } catch (_) {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _confirmDelete(Map<String, dynamic> gif) async {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;
    final ok = await showRaviModal(
      context,
      icon: Icons.delete_outline_rounded,
      iconColor: const Color(0xFFEF4444),
      title: s.deleteGifTitle,
      body: s.deleteGifConfirm,
      okText: s.delete,
      cancelText: s.cancel,
      danger: true,
    );
    if (ok != true) return;
    final id = (gif['id'] is int) ? gif['id'] as int : int.tryParse('${gif['id']}') ?? 0;
    final res = await ApiService.I.deleteGif(id);
    if (!mounted) return;
    if (res.ok) {
      setState(() => _gifs?.removeWhere((g) => '${g['id']}' == '$id'));
      showRaviToast(context, AppState.I.str.gifDeleted);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;

    return Column(children: [
      if (widget.showHeader)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
          child: Row(
            children: [
              Icon(Icons.gif_rounded, size: 24, color: p.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(s.gifLibraryTitle,
                    style: TextStyle(
                        fontSize: 15.5, fontWeight: FontWeight.w800,
                        color: p.text)),
              ),
              _uploadButton(p, s),
            ],
          ),
        )
      else
        Padding(
          padding: const EdgeInsetsDirectional.only(end: 10, top: 6),
          child: Align(
            alignment: AlignmentDirectional.topEnd,
            child: _uploadButton(p, s, small: true),
          ),
        ),
      Expanded(child: _body(p, s)),
    ]);
  }

  Widget _uploadButton(Palette p, S s, {bool small = false}) {
    return GestureDetector(
      onTap: _uploading ? null : _pickAndUpload,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: EdgeInsets.symmetric(
            horizontal: small ? 10 : 13, vertical: small ? 5 : 8),
        decoration: BoxDecoration(
          gradient: _uploading ? null : C.ownBubbleGrad,
          color: _uploading ? p.bgSoft : null,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _uploading
                ? const SizedBox(
                    width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2,
                        color: Colors.white))
                : Icon(Icons.movie_creation_outlined,
                    size: small ? 14 : 16, color: Colors.white),
            if (!small) ...[
              const SizedBox(width: 6),
              Text(_uploading ? s.gifConverting : s.gifFromVideo,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Colors.white)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _body(Palette p, S s) {
    if (_gifs == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.2));
    }
    if (_gifs!.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.gif_box_outlined, size: 40, color: p.text3),
            const SizedBox(height: 10),
            Text(s.gifEmptyTitle,
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700,
                    color: p.text)),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 34),
              child: Text(s.gifEmptySub,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11.5, color: p.text2)),
            ),
          ],
        ),
      );
    }
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(widget.compact ? 10 : 12, 8,
          widget.compact ? 10 : 12, 14),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.92,
      ),
      itemCount: _gifs!.length,
      itemBuilder: (ctx, i) {
        final gif = _gifs![i];
        final url = ApiService.I.absoluteUrl('${gif['url'] ?? ''}');
        return GestureDetector(
          onTap: () => widget.onPicked('${gif['url']}'),
          onLongPress: () => _confirmDelete(gif),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Container(
                  color: p.bgSoft,
                  child: CachedNetworkImage(
                    imageUrl: url,
                    fit: BoxFit.cover,
                    memCacheWidth: 240,
                    placeholder: (_, __) => const Center(
                        child: SizedBox(
                            width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))),
                    errorWidget: (_, __, ___) => Icon(
                        Icons.broken_image_outlined,
                        size: 22, color: p.text3),
                  ),
                ),
                // delete affordance
                PositionedDirectional(
                  top: 4,
                  end: 4,
                  child: GestureDetector(
                    onTap: () => _confirmDelete(gif),
                    child: Container(
                      width: 22, height: 22,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: .45),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close_rounded,
                          size: 13, color: Colors.white),
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
}

/// Standalone sheet wrapper (kept for compatibility).
class GifPickerSheet extends StatelessWidget {
  const GifPickerSheet({super.key});

  static Future<String?> show(BuildContext context) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const GifPickerSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final height = MediaQuery.sizeOf(context).height * 0.72;
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: p.bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: GifPickerGrid(
        showHeader: true,
        onPicked: (url) => Navigator.pop(context, url),
      ),
    );
  }
}
