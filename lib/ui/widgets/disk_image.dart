import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/media_download_manager.dart';
import '../home/data_storage_screen.dart';

/// Disk-first image widget for chat bubbles (Telegram-style):
/// • Loads immediately from disk via `Image.file` with `cacheWidth` cap
/// • Respects `MediaPrefs.autoLoad`: auto-downloads when enabled, or shows a
///   tap-to-download button when disabled
/// • Resets cleanly on URL changes and allows tap-to-retry on download failure
class DiskCachedImage extends StatefulWidget {
  final String fileUrl;
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
  bool _waitingUserTap = false;
  String? _error;
  double _netProgress = 0;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  @override
  void didUpdateWidget(covariant DiskCachedImage old) {
    super.didUpdateWidget(old);
    if (old.fileUrl != widget.fileUrl) {
      _localPath = null;
      _probed = false;
      _waitingUserTap = false;
      _error = null;
      _netProgress = 0;
      _probe();
    }
  }

  Future<void> _probe() async {
    final targetUrl = widget.fileUrl;
    final mgr = MediaDownloadManager.I;
    if (mgr.maybeOnDisk(targetUrl)) {
      final p = await mgr.cachedPath(targetUrl);
      if (!mounted || widget.fileUrl != targetUrl) return;
      if (p != null) {
        setState(() {
          _localPath = p;
          _probed = true;
          _error = null;
          _waitingUserTap = false;
        });
        return;
      }
    }
    final p = await mgr.cachedPath(targetUrl);
    if (!mounted || widget.fileUrl != targetUrl) return;
    setState(() {
      _localPath = p;
      _probed = true;
      _error = null;
      _waitingUserTap = p == null && !MediaPrefs.autoLoad.value;
    });
    if (p == null && targetUrl.isNotEmpty && MediaPrefs.autoLoad.value) {
      _startDownload(targetUrl);
    }
  }

  void _startDownload(String targetUrl) {
    if (targetUrl.isEmpty) return;
    setState(() {
      _waitingUserTap = false;
      _error = null;
      _netProgress = 0;
    });
    MediaDownloadManager.I.ensureDownloaded(targetUrl, onProgress: (pct) {
      if (mounted && widget.fileUrl == targetUrl && pct > _netProgress) {
        setState(() => _netProgress = pct);
      }
    }).then((path) {
      if (!mounted || widget.fileUrl != targetUrl) return;
      if (path != null) {
        setState(() {
          _localPath = path;
          _error = null;
        });
      } else {
        setState(() => _error = 'failed');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_probed) {
      return _placeholder(const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
      ));
    }
    final p = _localPath;
    if (p != null && File(p).existsSync()) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(widget.round),
        child: Image.file(
          File(p),
          fit: widget.fit,
          width: widget.width,
          height: widget.height,
          cacheWidth: widget.memCacheWidth ?? 720,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => _netFallback(),
        ),
      );
    }
    return _netFallback();
  }

  Widget _netFallback() {
    final hasDims = widget.width != null && widget.height != null;
    final canTap = _waitingUserTap || _error != null;
    Widget child = GestureDetector(
      onTap: canTap ? () => _startDownload(widget.fileUrl) : null,
      child: Stack(
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
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.refresh_rounded, size: 28, color: Colors.white70),
                      const SizedBox(height: 4),
                      Text(
                        AppState.I.str.retry,
                        style: const TextStyle(fontSize: 11, color: Colors.white70),
                      ),
                    ],
                  )
                : _waitingUserTap
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.black.withValues(alpha: .55),
                            ),
                            child: const Icon(
                              Icons.arrow_downward_rounded,
                              size: 20,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            AppState.I.str.tapToDownload,
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: Colors.white70,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      )
                    : _DownloadRing(widget.fileUrl),
          ),
          if (_error == null && !_waitingUserTap && _netProgress > 0 && _netProgress < 1)
            Positioned(
              bottom: 8,
              left: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .45),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${(_netProgress * 100).round()}%',
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.round),
      child: child,
    );
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
              const Icon(Icons.arrow_downward_rounded, size: 18, color: Colors.white),
            ],
          ),
        );
      },
    );
  }
}
