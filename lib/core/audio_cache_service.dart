import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'api_service.dart';
import 'storage_service.dart';

/// Telegram-style audio download & disk cache engine:
/// • Stable FNV-1a file naming (survives Dart isolate restarts)
/// • Stored in persistent Application Documents (`ravi_audio_cache`) and
///   integrated with [StorageService] breakdown & clearing
/// • Same-origin cookie gating via `ApiService.I.authHeadersFor`
/// • Tracks downloaded bytes in [NetStats]
class AudioCacheService {
  AudioCacheService._() {
    StorageService.registerClearHook(evictAll);
  }
  static final AudioCacheService I = AudioCacheService._();

  final Map<String, ValueNotifier<double>> _progress = {};
  final Map<String, String> _paths = {};
  final Map<String, Future<String?>> _jobs = {};
  Directory? _dir;

  void evictAll() {
    _paths.clear();
    for (final n in _progress.values) {
      n.value = 0;
    }
  }

  Future<Directory> _cacheDir() async {
    if (_dir != null) return _dir!;
    try {
      final base = await getApplicationDocumentsDirectory();
      final d = Directory('${base.path}/ravi_audio_cache');
      if (!await d.exists()) await d.create(recursive: true);
      _dir = d;
      return d;
    } catch (_) {
      final base = await getTemporaryDirectory();
      final d = Directory('${base.path}/ravi_audio_cache');
      if (!await d.exists()) await d.create(recursive: true);
      _dir = d;
      return d;
    }
  }

  bool isCached(String url) {
    final p = _paths[url];
    if (p != null && _okFile(p)) return true;
    if (_dir != null) {
      final guess = '${_dir!.path}/${_fileName(url)}';
      if (_okFile(guess)) {
        _paths[url] = guess;
        return true;
      }
    }
    return false;
  }

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

  final Map<String, ValueNotifier<(int, int)>> _bytes = {};
  ValueNotifier<(int, int)> bytesOf(String url) =>
      _bytes.putIfAbsent(url, () => ValueNotifier((0, 0)));

  final Map<String, TransferCancelToken> _tokens = {};

  void cancel(String url) => _tokens[url]?.cancel();

  bool wasCancelled(String url) => _tokens[url]?.isCancelled ?? false;

  Future<String?> ensureDownloaded(String url) async {
    await _cacheDir();
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
      tmp = File('$path.part');
      notifier.value = 0;
      bytes.value = (0, 0);
      client = http.Client();
      final req = http.Request('GET', Uri.parse(abs));
      req.headers.addAll(ApiService.I.authHeadersFor(abs));
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
        NetStats.I.addReceived(chunk.length);
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
    }
  }

  /// Deterministic FNV-1a 32-bit hash (unlike Dart's salted `hashCode`).
  static String _stableHash(String input) {
    var h = 0x811c9dc5;
    for (final c in input.codeUnits) {
      h ^= c & 0xff;
      h = (h * 0x01000193) & 0x7fffffff;
      h ^= (c >> 8) & 0xff;
      h = (h * 0x01000193) & 0x7fffffff;
    }
    return h.toRadixString(36);
  }

  String _fileName(String url) {
    final clean = url.split('?').first;
    final rawLast = clean.split('/').last.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final h = _stableHash(clean);
    return rawLast.isEmpty ? 'audio_$h.m4a' : 'a_${h}_$rawLast';
  }
}
