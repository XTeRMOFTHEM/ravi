import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'api_service.dart';

/// v1.2.1 — TELEGRAM-STYLE MEDIA DOWNLOAD ENGINE for audio messages.
///
/// Telegram never streams an audio file blind: the file is downloaded to the
/// cache with a live progress indicator (the sweeping ring around the
/// bubble), then played from disk. This service does exactly that:
///
///  • one download per URL (concurrent callers await the same job)
///  • live progress via ValueNotifier (0..1) — the UI subscribes
///  • instant no-op when the file is already cached
class AudioCacheService {
  AudioCacheService._();
  static final AudioCacheService I = AudioCacheService._();

  final Map<String, ValueNotifier<double>> _progress = {};
  final Map<String, String> _paths = {};
  final Map<String, Future<String?>> _jobs = {};
  Directory? _dir;

  Future<Directory> _cacheDir() async {
    if (_dir != null) return _dir!;
    final base = await getTemporaryDirectory();
    final d = Directory('${base.path}/ravi_audio_cache');
    if (!await d.exists()) await d.create(recursive: true);
    _dir = d;
    return d;
  }

  bool isCached(String url) {
    final p = _paths[url];
    if (p != null && _okFile(p)) return true;
    // accept a previous session's file on disk too
    if (_dir != null) {
      final guess = '${_dir!.path}/${_fileName(url)}';
      if (_okFile(guess)) {
        _paths[url] = guess;
        return true;
      }
    }
    return false;
  }

  // فایل خالی/نیمه‌کاره «کش‌شده» حساب نمی‌شود (باگ پخش‌نشدن آهنگ بعد از دانلود ناقص)
  bool _okFile(String path) {
    try {
      final f = File(path);
      return f.existsSync() && f.lengthSync() > 0;
    } catch (_) {
      return false;
    }
  }

  String? cachedPath(String url) {
    if (!isCached(url)) return null;
    return _paths[url];
  }

  ValueNotifier<double> progressOf(String url) =>
      _progress.putIfAbsent(url, () => ValueNotifier(0));

  /// (بایت‌های دریافت‌شده، کل بایت‌ها) — برای «3.2 / 12.5 MB»
  final Map<String, ValueNotifier<(int, int)>> _bytes = {};
  ValueNotifier<(int, int)> bytesOf(String url) =>
      _bytes.putIfAbsent(url, () => ValueNotifier((0, 0)));

  final Map<String, TransferCancelToken> _tokens = {};

  /// لغو دانلودِ در حال انجام (✕ روی دکمه‌ی پخش)
  void cancel(String url) => _tokens[url]?.cancel();

  bool wasCancelled(String url) => _tokens[url]?.isCancelled ?? false;

  /// Download [url] (a /static/... path or absolute) into the cache.
  /// Returns the local file path, or null on failure.
  Future<String?> ensureDownloaded(String url) async {
    if (isCached(url)) return _paths[url];
    final existing = _jobs[url];
    if (existing != null) return existing;
    final job = _download(url);
    _jobs[url] = job;
    try {
      return await job;
    } finally {
      _jobs.remove(url);
    }
  }

  Future<String?> _download(String url) async {
    http.Client? client;
    IOSink? sink;
    File? tmp;
    final token = TransferCancelToken();
    _tokens[url] = token;
    final notifier = progressOf(url);
    final bytes = bytesOf(url);
    try {
      final abs = ApiService.I.absoluteUrl(url);
      final dir = await _cacheDir();
      final path = '${dir.path}/${_fileName(url)}';
      // اول در فایل .part نوشته می‌شود؛ فقط بعد از دانلود کامل rename می‌شود
      tmp = File('$path.part');
      notifier.value = 0;
      bytes.value = (0, 0);
      client = http.Client();
      final req = http.Request('GET', Uri.parse(abs));
      req.headers['Cookie'] = ApiService.I.cookieHeader;
      req.followRedirects = true;
      final res =
          await client.send(req).timeout(const Duration(seconds: 60));
      if (res.statusCode != 200) return null;
      final total = res.contentLength ?? 0;
      sink = tmp.openWrite();
      var received = 0;
      var last = DateTime.fromMillisecondsSinceEpoch(0);
      await for (final chunk in res.stream) {
        if (token.isCancelled) throw const TransferCancelled();
        received += chunk.length;
        sink.add(chunk);
        final now = DateTime.now();
        if (now.difference(last).inMilliseconds >= 100) {
          last = now;
          if (total > 0) notifier.value = (received / total).clamp(0.0, 0.99);
          bytes.value = (received, total);
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (received == 0) return null;
      final f = File(path);
      if (await f.exists()) await f.delete();
      await tmp.rename(path);
      bytes.value = (received, total > 0 ? total : received);
      notifier.value = 1;
      _paths[url] = path;
      return path;
    } catch (_) {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (tmp != null && await tmp.exists()) await tmp.delete();
      } catch (_) {}
      notifier.value = 0;
      return null;
    } finally {
      client?.close();
      // توکن تا خوانده‌شدنِ wasCancelled نگه داشته می‌شود و دانلود بعدی عوضش می‌کند
    }
  }

  String _fileName(String url) {
    final clean = url.split('?').first;
    final last = clean.split('/').last;
    return last.isEmpty
        ? 'audio_${clean.hashCode}'
        : 'a_${clean.hashCode}_$last';
  }
}
