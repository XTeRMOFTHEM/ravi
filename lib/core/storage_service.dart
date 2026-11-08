import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// v1.1.0 — Data & Storage engine.
///
/// • [NetStats] counts real API traffic (sent/received) for the session via a
///   wrapping http client (see ApiService.init).
/// • [StorageService] inspects the image/media cache on disk, classifies every
///   cached file by MAGIC BYTES (photos / videos / gifs / music / other) so
///   the Data & Storage panel can show a Telegram-style breakdown, list and
///   delete individual files, or wipe a category.
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

  /// flutter_cache_manager's image cache dir (CachedNetworkImage writes here —
  /// avatars, chat photos, gifs, everything).
  static final _cm = DefaultCacheManager();

  /// The actual directory backing the DefaultCacheManager.
  Future<Directory> imageCacheDir() async {
    final base = (await getTemporaryDirectory()).path;
    final dir = Directory('$base/libCachedImageData');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Classify a cached file by its magic bytes.
  static String sniffType(File f) {
    try {
      final raf = f.openSync();
      final bytes = raf.readSync(16);
      raf.closeSync();
      if (bytes.length < 6) return 'file';
      // GIF87a / GIF89a
      if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
        return 'gif';
      }
      // JPEG
      if (bytes[0] == 0xFF && bytes[1] == 0xD8) return 'image';
      // PNG
      if (bytes[0] == 0x89 && bytes[1] == 0x50) return 'image';
      // WEBP (RIFF....WEBP)
      if (bytes[0] == 0x52 && bytes[8] == 0x57 && bytes[9] == 0x45) {
        return 'image';
      }
      // MP4 / M4A (ftyp)
      if (bytes.length >= 12 &&
          bytes[4] == 0x66 &&
          bytes[5] == 0x74 &&
          bytes[6] == 0x79 &&
          bytes[7] == 0x70) {
        // ftypM4A
        final brand = String.fromCharCodes(bytes.sublist(8, 12));
        return brand.contains('M4A') ? 'audio' : 'video';
      }
      // MP3 (ID3 or frame sync)
      if ((bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) ||
          (bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0)) {
        return 'audio';
      }
      return 'file';
    } catch (_) {
      return 'file';
    }
  }

  Future<List<CachedMediaFile>> listCachedMedia({int limit = 500}) async {
    final out = <CachedMediaFile>[];
    try {
      final dir = await imageCacheDir();
      final files = dir.listSync().whereType<File>().toList();
      files.sort((a, b) => (b.lastModifiedSync().millisecondsSinceEpoch)
          .compareTo(a.lastModifiedSync().millisecondsSinceEpoch));
      for (final f in files.take(limit)) {
        try {
          final st = f.statSync();
          if (st.size <= 0) continue;
          out.add(CachedMediaFile(
              f, st.size, st.modified, sniffType(f)));
        } catch (_) {}
      }
    } catch (_) {}
    return out;
  }

  Future<StorageBreakdown> breakdown() async {
    var images = 0, videos = 0, gifs = 0, audio = 0, other = 0, count = 0;
    try {
      final dir = await imageCacheDir();
      await for (final e in dir.list()) {
        if (e is! File) continue;
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
    return StorageBreakdown(
        images: images,
        videos: videos,
        gifs: gifs,
        audio: audio,
        other: other,
        count: count);
  }

  /// Wipe everything: memory image cache + disk files.
  Future<void> clearAll() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    try {
      final dir = await imageCacheDir();
      if (dir.existsSync()) {
        await for (final e in dir.list()) {
          try {
            if (e is File) {
              await e.delete();
            } else if (e is Directory) {
              await e.delete(recursive: true);
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
    try {
      await _cm.emptyCache();
    } catch (_) {}
  }

  /// Wipe one category (magic-byte classified).
  Future<int> clearType(String type) async {
    var freed = 0;
    try {
      final dir = await imageCacheDir();
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
    PaintingBinding.instance.imageCache.clear();
    return freed;
  }

  Future<void> deleteFile(File f) async {
    try {
      await f.delete();
    } catch (_) {}
    PaintingBinding.instance.imageCache.evict(FileImage(f));
  }

  // ---------- temp downloads (voice notes, exported files) ----------
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
