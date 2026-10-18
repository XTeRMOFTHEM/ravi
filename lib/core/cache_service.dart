import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Lightweight append/replace JSON-file cache — the "Telegram-like" instant
/// open layer. Chats list and last N messages of each conversation are stored
/// on disk, so the app always paints real content immediately, then refreshes
/// from the network in the background.
class CacheService {
  CacheService._();
  static final CacheService I = CacheService._();

  late Directory _dir;
  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    try {
      final base = await getApplicationDocumentsDirectory();
      _dir = Directory('${base.path}/ravi_cache');
      if (!await _dir.exists()) await _dir.create(recursive: true);
      _ready = true;
    } catch (_) {
      _dir = Directory.systemTemp.createTempSync('ravi_cache');
      _ready = true;
    }
  }

  File _file(String key) => File('${_dir.path}/$key.json');

  /// Writes are atomic (tmp file + rename) so a kill mid-write never corrupts.
  Future<void> put(String key, List<Map<String, dynamic>> data) async {
    if (!_ready) return;
    try {
      final f = _file(key);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(data), flush: true);
      await tmp.rename(f.path);
    } catch (_) {}
  }

  List<Map<String, dynamic>>? getSync(String key) {
    if (!_ready) return null;
    try {
      final f = _file(key);
      if (!f.existsSync()) return null;
      final raw = f.readAsStringSync();
      final v = jsonDecode(raw);
      if (v is List) return v.cast<Map<String, dynamic>>();
    } catch (_) {}
    return null;
  }

  Future<void> remove(String key) async {
    if (!_ready) return;
    try {
      final f = _file(key);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  String chatsKey() => 'chats_list';
  String msgsKey(String kind, int id) => 'msgs_${kind}_$id';

  /// v1.0.7 — raw string key for rooms whose ids are HEX strings
  /// ("d2b1d904"); sanitized to a filesystem-safe name.
  String msgsKeyRaw(String kind, String id) {
    final safe = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return 'msgs_${kind}_$safe';
  }

  String get generalKey => 'msgs_general';
}
