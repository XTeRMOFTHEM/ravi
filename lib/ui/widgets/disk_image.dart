import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/media_download_manager.dart';

/// v1.5.0 — عکسِ «همیشه از دیسک» برای حباب‌های چت (مثل تلگرام):
///  • اگر فایل روی دیسک است (یک بار دانلود شده) مستقیم Image.file
///  • اگر نیست، در پس‌زمینه دانلود می‌شود و روی تصویرِ خاکستری یک
///    دکمه‌ی دایره‌ای تیره با فلش سفید + حلقه‌ی پیشرفت (مثل تلگرام) می‌چرخد
///  • بعد از اولین دانلود، تا همیشه از دیسک لود می‌شود (بدون اینترنت)
class DiskCachedImage extends StatefulWidget {
  final String fileUrl; // server path like /static/uploads/x.jpg
  final double? width;
  final double? height;
  final BoxFit fit;
  final double round;
  final int? memCacheWidth;

  const DiskCachedImage({
    super.key,
    required this.fileUrl,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.round = 14,
    this.memCacheWidth,
  });

  @override
  State<DiskCachedImage> createState() => _DiskCachedImageState();
}

class _DiskCachedImageState extends State<DiskCachedImage> {
  String? _localPath;
  bool _probed = false;
  String? _error;
  double _netProgress = 0; // while the FIRST network download streams in

  @override
  void initState() {
    super.initState();
    _probe();
  }

  @override
  void didUpdateWidget(covariant DiskCachedImage old) {
    super.didUpdateWidget(old);
    if (old.fileUrl != widget.fileUrl) _probe();
  }

  Future<void> _probe() async {
    final mgr = MediaDownloadManager.I;
    // fast path: the manager already knows this file is on disk
    if (mgr.maybeOnDisk(widget.fileUrl)) {
      final p = await mgr.cachedPath(widget.fileUrl);
      if (!mounted) return;
      setState(() {
        _localPath = p;
        _probed = true;
      });
      return;
    }
    final p = await mgr.cachedPath(widget.fileUrl);
    if (!mounted) return;
    setState(() {
      _localPath = p;
      _probed = true;
      _error = null;
    });
    if (p == null && widget.fileUrl.isNotEmpty) {
      // AUTO-DOWNLOAD: عکس‌های دریافتی همیشه باید روی دیسک ذخیره شوند
      mgr.ensureDownloaded(widget.fileUrl, onProgress: (pct) {
        if (mounted && pct > _netProgress) setState(() => _netProgress = pct);
      }).then((path) {
        if (mounted && path != null) setState(() => _localPath = path);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_probed) {
      return _placeholder(const SizedBox(
          width: 22, height: 22,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54)));
    }
    final p = _localPath;
    if (p != null && File(p).existsSync()) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(widget.round),
        child: Image.file(File(p),
            fit: widget.fit,
            width: widget.width,
            height: widget.height,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => _netFallback()),
      );
    }
    return _netFallback();
  }

  /// While the file is NOT on disk yet: soft grey tile + the Telegram-style
  /// centered circular progress button (dark disc, white arrow, live ring).
  Widget _netFallback() {
    final hasDims = widget.width != null && widget.height != null;
    Widget child = Stack(
      fit: hasDims ? StackFit.expand : StackFit.loose,
      alignment: Alignment.center,
      children: [
        Container(
          width: widget.width ?? 220,
          height: widget.height ?? 160,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.round),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF3A424D), Color(0xFF232A32)],
            ),
          ),
          alignment: Alignment.center,
          child: _error != null
              ? Icon(Icons.broken_image_outlined, size: 30, color: Colors.white38)
              : _DownloadRing(widget.fileUrl),
        ),
        if (_error == null && _netProgress > 0 && _netProgress < 1)
          Positioned(
            bottom: 8,
            left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: .45),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('${(_netProgress * 100).round()}%',
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w800,
                      color: Colors.white)),
            ),
          ),
      ],
    );
    return ClipRRect(
        borderRadius: BorderRadius.circular(widget.round), child: child);
  }

  Widget _placeholder(Widget spinner) {
    return Container(
      width: widget.width ?? 220,
      height: widget.height ?? 160,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.round),
        color: Colors.grey.withValues(alpha: .15),
      ),
      alignment: Alignment.center,
      child: spinner,
    );
  }
}

/// دکمه‌ی دایره‌ای وسط تصویر: حلقه‌ی پیشرفت زنده + فلش پایین (شکل عکس مرجع)
class _DownloadRing extends StatelessWidget {
  final String fileUrl;
  const _DownloadRing(this.fileUrl);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: MediaDownloadManager.I,
      builder: (context, _) {
        final t = MediaDownloadManager.I.taskFor(fileUrl);
        final running = t?.state == 'running';
        return Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black.withValues(alpha: .55),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(
                  value: (running && t!.progress > 0) ? t.progress.clamp(0.02, 1.0) : null,
                  strokeWidth: 2.4,
                  valueColor: const AlwaysStoppedAnimation(Color(0xFF7DD3FC)),
                  backgroundColor: Colors.white24,
                  strokeCap: StrokeCap.round,
                ),
              ),
              const Icon(Icons.arrow_downward_rounded,
                  size: 18, color: Colors.white),
            ],
          ),
        );
      },
    );
  }
}
