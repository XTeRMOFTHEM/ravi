import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';

/// Data & Storage engine:
/// • [NetStats] tracks session API + media bytes sent/received.
/// • [StorageService] unifies ALL on-disk media caches:
///   1) `temp/libCachedImageData` (CachedNetworkImage / avatars / frames)
///   2) `docs/ravi_media` (MediaDownloadManager persistent photos/videos/files)
///   3) `docs/ravi_audio_cache` & `temp/ravi_audio_cache` (AudioCacheService)
///   so breakdown sizes, Media Manager browsing, and Clear Cache are 100% real.
class NetStats {
  NetStats._();
  static final NetStats I = NetStats._();

  int sent = 0;
  int received = 0;

  void addSent(int n) => sent += n;
  void addReceived(int n) => received += n;

  void reset() {
    sent = 0;
    received = 0;
  }
}

class CachedMediaFile {
  final File file;
  final int size;
  final DateTime modified;
  final String type; // image | video | gif | audio | file
  const CachedMediaFile(this.file, this.size, this.modified, this.type);
}

class StorageBreakdown {
  final int images;
  final int videos;
  final int gifs;
  final int audio;
  final int other;
  final int count;
  const StorageBreakdown({
    required this.images,
    required this.videos,
    required this.gifs,
    required this.audio,
    required this.other,
    required this.count,
  });

  int get total => images + videos + gifs + audio + other;
}

class StorageService {
  StorageService._();
  static final StorageService I = StorageService._();

  static final _cm = DefaultCacheManager();

  /// Callbacks registered by media/audio cache services so clearing storage
  /// also drops their in-memory path maps.
  static final List<void Function()> _onClearedHooks = [];
  static void registerClearHook(void Function() cb) {
    if (!_onClearedHooks.contains(cb)) _onClearedHooks.add(cb);
  }

  /// All disk directories holding cached/downloaded media.
  Future<List<Directory>> allCacheDirs() async {
    final dirs = <Directory>[];
    try {
      final tmp = (await getTemporaryDirectory()).path;
      dirs.add(Directory('$tmp/libCachedImageData'));
      dirs.add(Directory('$tmp/ravi_audio_cache'));
    } catch (_) {}
    try {
      final docs = (await getApplicationDocumentsDirectory()).path;
      dirs.add(Directory('$docs/ravi_media'));
      dirs.add(Directory('$docs/ravi_audio_cache'));
    } catch (_) {}
    return dirs;
  }

  Future<Directory> imageCacheDir() async {
    final base = (await getTemporaryDirectory()).path;
    final dir = Directory('$base/libCachedImageData');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Classify a cached file by magic bytes (with extension fallback for OGG/OPUS/WAV).
  static String sniffType(File f) {
    try {
      final raf = f.openSync();
      final bytes = raf.readSync(16);
      raf.closeSync();
      if (bytes.length < 4) return 'file';
      // GIF87a / GIF89a
      if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
        return 'gif';
      }
      // JPEG
      if (bytes[0] == 0xFF && bytes[1] == 0xD8) return 'image';
      // PNG
      if (bytes[0] == 0x89 && bytes[1] == 0x50) return 'image';
      // WEBP (RIFF....WEBP)
      if (bytes.length >= 12 &&
          bytes[0] == 0x52 &&
          bytes[8] == 0x57 &&
          bytes[9] == 0x45) {
        return 'image';
      }
      // OGG / OPUS
      if (bytes[0] == 0x4F && bytes[1] == 0x67 && bytes[2] == 0x67 && bytes[3] == 0x53) {
        return 'audio';
      }
      // WAV (RIFF....WAVE)
      if (bytes.length >= 12 &&
          bytes[0] == 0x52 &&
          bytes[8] == 0x57 &&
          bytes[9] == 0x41) {
        return 'audio';
      }
      // MP4 / M4A (ftyp)
      if (bytes.length >= 12 &&
          bytes[4] == 0x66 &&
          bytes[5] == 0x74 &&
          bytes[6] == 0x79 &&
          bytes[7] == 0x70) {
        final brand = String.fromCharCodes(bytes.sublist(8, 12));
        return brand.contains('M4A') ? 'audio' : 'video';
      }
      // MP3 (ID3 or frame sync)
      if ((bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) ||
          (bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0)) {
        return 'audio';
      }
      final lower = f.path.toLowerCase();
      if (lower.endsWith('.m4a') || lower.endsWith('.mp3') || lower.endsWith('.ogg') || lower.endsWith('.aac') || lower.endsWith('.opus')) {
        return 'audio';
      }
      if (lower.endsWith('.mp4') || lower.endsWith('.mov') || lower.endsWith('.webm') || lower.endsWith('.mkv')) {
        return 'video';
      }
      return 'file';
    } catch (_) {
      return 'file';
    }
  }

  Future<List<CachedMediaFile>> listCachedMedia({int limit = 500}) async {
    final files = <File>[];
    for (final dir in await allCacheDirs()) {
      try {
        if (!dir.existsSync()) continue;
        for (final e in dir.listSync()) {
          if (e is File && !e.path.endsWith('.part') && !e.path.endsWith('.tmp')) {
            files.add(e);
          }
        }
      } catch (_) {}
    }
    files.sort((a, b) {
      try {
        return b.lastModifiedSync().millisecondsSinceEpoch.compareTo(
              a.lastModifiedSync().millisecondsSinceEpoch,
            );
      } catch (_) {
        return 0;
      }
    });
    final out = <CachedMediaFile>[];
    for (final f in files.take(limit)) {
      try {
        final st = f.statSync();
        if (st.size <= 0) continue;
        out.add(CachedMediaFile(f, st.size, st.modified, sniffType(f)));
      } catch (_) {}
    }
    return out;
  }

  Future<StorageBreakdown> breakdown() async {
    var images = 0, videos = 0, gifs = 0, audio = 0, other = 0, count = 0;
    for (final dir in await allCacheDirs()) {
      try {
        if (!dir.existsSync()) continue;
        await for (final e in dir.list()) {
          if (e is! File || e.path.endsWith('.part') || e.path.endsWith('.tmp')) continue;
          try {
            final st = e.statSync();
            if (st.size <= 0) continue;
            count++;
            switch (sniffType(e)) {
              case 'image':
                images += st.size;
                break;
              case 'video':
                videos += st.size;
                break;
              case 'gif':
                gifs += st.size;
                break;
              case 'audio':
                audio += st.size;
                break;
              default:
                other += st.size;
            }
          } catch (_) {}
        }
      } catch (_) {}
    }
    return StorageBreakdown(
      images: images,
      videos: videos,
      gifs: gifs,
      audio: audio,
      other: other,
      count: count,
    );
  }

  /// Wipe memory image cache + all unified disk media caches.
  Future<void> clearAll() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    for (final dir in await allCacheDirs()) {
      try {
        if (!dir.existsSync()) continue;
        await for (final e in dir.list()) {
          try {
            if (e is File) {
              await e.delete();
            } else if (e is Directory) {
              await e.delete(recursive: true);
            }
          } catch (_) {}
        }
      } catch (_) {}
    }
    try {
      await _cm.emptyCache();
    } catch (_) {}
    for (final cb in _onClearedHooks) {
      try {
        cb();
      } catch (_) {}
    }
  }

  /// Wipe one media category across all cache directories.
  Future<int> clearType(String type) async {
    var freed = 0;
    for (final dir in await allCacheDirs()) {
      try {
        if (!dir.existsSync()) continue;
        await for (final e in dir.list()) {
          if (e is! File) continue;
          try {
            if (sniffType(e) == type) {
              freed += e.lengthSync();
              await e.delete();
            }
          } catch (_) {}
        }
      } catch (_) {}
    }
    PaintingBinding.instance.imageCache.clear();
    for (final cb in _onClearedHooks) {
      try {
        cb();
      } catch (_) {}
    }
    return freed;
  }

  Future<void> deleteFile(File f) async {
    try {
      await f.delete();
    } catch (_) {}
    PaintingBinding.instance.imageCache.evict(FileImage(f));
    for (final cb in _onClearedHooks) {
      try {
        cb();
      } catch (_) {}
    }
  }

  Future<int> tempDownloadsSize() async {
    try {
      final dir = await getTemporaryDirectory();
      var total = 0;
      await for (final e in dir.list()) {
        if (e is File) {
          try {
            total += e.lengthSync();
          } catch (_) {}
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  static String humanSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const kb = 1024, mb = 1024 * kb, gb = 1024 * mb;
    if (bytes >= gb) {
      return '${(bytes / gb).toStringAsFixed(1)} GB';
    }
    if (bytes >= mb) {
      return '${(bytes / mb).toStringAsFixed(bytes < 10 * mb ? 1 : 0)} MB';
    }
    if (bytes >= kb) return '${(bytes / kb).round()} KB';
    return '$bytes B';
  }
}
