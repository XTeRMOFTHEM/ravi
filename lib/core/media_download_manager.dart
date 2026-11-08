import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:saver_gallery/saver_gallery.dart';

import 'api_service.dart';
import 'app_state.dart';
import 'constants.dart';

/// v1.5.0 — سرویس مدیای ماندگار روی دیسک (مثل تلگرام):
///  • هر عکس/ویدئو/فایلی که یک بار دانلود می‌شود برای همیشه در پوشه‌ی
///    اختصاصی اپ می‌ماند؛ دفعات بعد مستقیم از دیسک لود می‌شود (بدون اینترنت).
///  • همه‌ی حباب‌ها وضعیت یک دانلود را از همین‌جا می‌خوانند (ChangeNotifier).
///  • دانلود عکس‌های دریافتی خودکار است — «حتما دانلود شن و توی دیسک بمونن».
class MediaDownloadTask {
  final String key; // normalized url
  double progress; // 0..1
  String state; // 'running' | 'done' | 'error' | 'cancelled'
  int received; // bytes
  int total; // bytes (0 = unknown)
  double speed; // bytes / second (smoothed)
  final TransferCancelToken cancel = TransferCancelToken();
  DateTime _lastTick = DateTime.now();
  int _lastBytes = 0;
  MediaDownloadTask(
      {required this.key,
      this.progress = 0,
      this.state = 'running',
      this.received = 0,
      this.total = 0,
      this.speed = 0});

  /// ثانیه‌های باقی‌مانده (null = نامشخص)
  int? get etaSeconds {
    if (total <= 0 || speed < 1) return null;
    return ((total - received) / speed).ceil().clamp(0, 86400);
  }

  void _onBytes(int r, int t) {
    final now = DateTime.now();
    final dt = now.difference(_lastTick).inMilliseconds;
    if (dt >= 250) {
      final inst = (r - _lastBytes) * 1000 / dt;
      speed = speed <= 0 ? inst : speed * 0.6 + inst * 0.4;
      _lastTick = now;
      _lastBytes = r;
    }
    received = r;
    if (t > 0) {
      total = t;
      progress = (r / t).clamp(0.0, 1.0);
    }
  }
}

/// «۳.۲ MB» / «۴۱۲ KB» — یک فرمت واحد برای همه‌ی ردیف‌های انتقال.
String fmtBytes(int b) {
  if (b <= 0) return '0 KB';
  const kb = 1024, mb = 1024 * 1024, gb = 1024 * 1024 * 1024;
  if (b >= gb) return '${(b / gb).toStringAsFixed(2)} GB';
  if (b >= mb) {
    final v = b / mb;
    return '${v.toStringAsFixed(v < 10 ? 1 : 0)} MB';
  }
  if (b >= kb) return '${(b / kb).round()} KB';
  return '$b B';
}

/// «3.2 / 12.5 MB» (واحد فقط یک‌بار، مثل تلگرام)
String fmtTransfer(int done, int total) {
  if (total <= 0) return fmtBytes(done);
  const mb = 1024 * 1024;
  if (total >= mb) {
    final d = (done / mb).toStringAsFixed(done / mb < 10 ? 1 : 0);
    return '$d / ${fmtBytes(total)}';
  }
  return '${fmtBytes(done)} / ${fmtBytes(total)}';
}

String fmtSpeed(double bps) => bps < 1 ? '' : '${fmtBytes(bps.round())}/s';

class MediaDownloadManager extends ChangeNotifier {
  MediaDownloadManager._();
  static final MediaDownloadManager I = MediaDownloadManager._();

  static const _kMediaDir = 'ravi_media';

  Directory? _dir;
  bool _ready = false;
  final Map<String, MediaDownloadTask> _tasks = {};
  // in-flight downloads so parallel bubbles share ONE request
  final Map<String, Future<String?>> _inflight = {};

  MediaDownloadTask? taskFor(String fileUrl) => _tasks[norm(fileUrl)];

  bool get isBusy => _tasks.values.any((t) => t.state == 'running');

  /// Normalize server paths so every bubble refers to the SAME cache key.
  static String norm(String urlOrPath) {
    var u = urlOrPath.trim();
    if (u.startsWith(kBaseUrl)) u = u.substring(kBaseUrl.length);
    if (!u.startsWith('/')) u = '/$u';
    return u;
  }

  Future<void> _ensureDir() async {
    if (_ready) return;
    try {
      final base = await getApplicationDocumentsDirectory();
      _dir = Directory('${base.path}/$_kMediaDir');
      if (!await _dir!.exists()) await _dir!.create(recursive: true);
    } catch (_) {
      try {
        final tmp = await getTemporaryDirectory();
        _dir = Directory('${tmp.path}/$_kMediaDir');
        if (!await _dir!.exists()) await _dir!.create(recursive: true);
      } catch (_) {
        _dir = Directory.systemTemp.createTempSync('ravi_media');
      }
    }
    _ready = true;
  }

  /// Stable, collision-free local file name for a URL.
  Future<String> _pathFor(String fileUrl) async {
    await _ensureDir();
    final key = norm(fileUrl);
    var ext = '';
    final dot = key.lastIndexOf('.');
    if (dot > 0 && dot > key.lastIndexOf('/')) {
      ext = key.substring(dot + 1).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    }
    if (ext.isEmpty) ext = 'bin';
    var h = 0x811c9dc5;
    for (final c in key.codeUnits) {
      h ^= c & 0xff;
      h = (h * 0x01000193) & 0x7fffffff;
      h ^= (c >> 8) & 0xff;
      h = (h * 0x01000193) & 0x7fffffff;
    }
    return '${_dir!.path}/m_${h.toRadixString(36)}.$ext';
  }

  /// Is this media already on disk? (instant, sync path used by bubbles)
  Future<String?> cachedPath(String fileUrl) async {
    final p = await _pathFor(fileUrl);
    final f = File(p);
    if (await f.exists() && await f.length() > 0) return p;
    return null;
  }

  /// The "already downloaded" flag for the synchronous fast-path in build().
  final Set<String> _knownOnDisk = {};

  bool maybeOnDisk(String fileUrl) => _knownOnDisk.contains(norm(fileUrl));

  /// دانلود فایل به حافظه‌ی دائمی اپ. اگر قبلاً دانلود شده همان مسیر برگردد.
  Future<String?> ensureDownloaded(String fileUrl,
      {void Function(double pct)? onProgress}) async {
    final key = norm(fileUrl);
    final cached = await cachedPath(key);
    if (cached != null) {
      _knownOnDisk.add(key);
      return cached;
    }
    final running = _inflight[key];
    if (running != null) return running;

    final t = MediaDownloadTask(key: key); // توکن لغوِ تازه برای هر دانلود
    _tasks[key] = t;
    notifyListeners();

    t.received = 0;
    t.total = 0;
    t.speed = 0;
    final fut = _downloadTo(key, t, onProgress: (pct) {
      t.progress = pct;
      onProgress?.call(pct);
    }).then((path) {
      _inflight.remove(key);
      if (path != null) {
        _knownOnDisk.add(key);
        t.state = 'done';
        t.progress = 1;
        if (t.total <= 0) t.total = t.received;
      } else {
        t.state = t.cancel.isCancelled ? 'cancelled' : 'error';
      }
      notifyListeners();
      _cleanupLater(key);
      return path;
    });
    _inflight[key] = fut;
    return fut;
  }

  /// لغو دانلود در حال انجام (دکمه‌ی ✕)
  void cancel(String fileUrl) {
    final t = _tasks[norm(fileUrl)];
    if (t != null && t.state == 'running') {
      t.cancel.cancel();
    }
  }

  Future<String?> _downloadTo(String key, MediaDownloadTask t,
      {void Function(double pct)? onProgress}) async {
    final path = await _pathFor(key);
    // temp file next to the target → atomic rename
    final tmp = '$path.part';
    var lastUi = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      final ok = await ApiService.I.downloadToFileWithProgress(key, tmp, (pct) {
        onProgress?.call(pct);
      }, cancel: t.cancel, onBytes: (r, tot) {
        t._onBytes(r, tot);
        final now = DateTime.now();
        if (now.difference(lastUi).inMilliseconds >= 100) {
          lastUi = now;
          notifyListeners();
        }
      });
      if (!ok) return null;
      final f = File(tmp);
      if (await f.exists() && await f.length() > 0) {
        try {
          await f.rename(path);
        } catch (_) {
          await f.copy(path);
          try { await f.delete(); } catch (_) {}
        }
        return path;
      }
      return null;
    } catch (_) {
      try { File(tmp).deleteSync(); } catch (_) {}
      return null;
    }
  }

  void _cleanupLater(String key) {
    Timer(const Duration(milliseconds: 2600), () {
      if (_tasks[key]?.state != 'running') {
        _tasks.remove(key);
        notifyListeners();
      }
    });
  }

  /// دانلود + ذخیره در گالری/Downloads. idempotent: اگر همین فایل در حال
  /// دانلود است، کاری نکن. برای فایل‌های عمومی (zip/pdf/apk/...) در پوشه‌ی
  /// Downloads ذخیره می‌شود، برای رسانه در گالری.
  Future<void> downloadAndSave(String fileUrl,
      {String? ext, String? fileNameHint}) async {
    final key = norm(fileUrl);
    final t0 = _tasks[key];
    if (t0 != null && t0.state == 'running') return;
    final s = AppState.I.str;
    try {
      final path = await ensureDownloaded(fileUrl, onProgress: (_) {});
      if (path == null) {
        if (_tasks[key]?.state == 'cancelled') return; // لغو = بی‌صدا
        throw 'download failed';
      }
      final e = (ext ??
              (key.contains('.') ? key.split('.').last.toLowerCase() : 'mp4'))
          .replaceAll(RegExp(r'[^a-z0-9]'), '');
      final name = fileNameHint ??
          'RAVI_${DateTime.now().millisecondsSinceEpoch}.$e';
      final isMedia = e == 'jpg' || e == 'jpeg' || e == 'png' || e == 'webp' ||
          e == 'gif' || e == 'mp4' || e == 'webm' || e == 'mov';
      final res = await SaverGallery.saveFile(
        filePath: path,
        fileName: name,
        // v1.5.0 — آلبوم اختصاصی RAVI در گالری/Downloads گوشی
        albumPath: 'RAVI',
        skipIfExists: false,
      );
      _toast(res.isSuccess ? s.savedToGallery : s.saveFailed);
    } catch (_) {
      _toast(s.saveFailed);
    }
    notifyListeners();
  }

  void _toast(String msg) {
    try {
      ToastBus.show(msg);
    } catch (_) {}
  }
}

/// پل سبک برای نمایش toast بدون context — رابط کاربری هنگام init ثبتش می‌کند.
class ToastBus {
  static void Function(String)? _handler;
  static void attach(void Function(String) handler) => _handler = handler;
  static void show(String msg) => _handler?.call(msg);
}

/// رجیستری سراسری توکن‌های لغوِ آپلود (clientMsgId → توکن) تا دکمه‌ی ✕ روی هر
/// حباب بدون پاس‌دادن کالبک از چند لایه، آپلود را لغو کند.
class UploadRegistry {
  static final Map<String, TransferCancelToken> tokens = {};
  static void cancel(String clientMsgId) => tokens[clientMsgId]?.cancel();
}
