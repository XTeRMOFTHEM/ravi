import 'dart:convert';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// v1.3.1 — PERSISTENT media dimensions cache.
///
/// Photos/GIFs received from older clients (or GIFs) carry no media_meta, so
/// their bubble could not reserve an aspect ratio and "jumped" the moment the
/// image finished decoding — and it did so AGAIN after every re-enter / app
/// restart. This cache remembers the decoded pixel size per URL (surviving
/// restarts), so the envelope is reserved from frame one on every session.
class MediaDimsCache {
  MediaDimsCache._();
  static final MediaDimsCache I = MediaDimsCache._();

  static const _kKey = 'ravi_media_dims_v1';
  final Map<String, List<int>> _map = {};
  bool _loaded = false;
  Timer? _saveTimer;

  /// True when a known aspect exists for [key] (message file_url).
  double? aspectOf(String key) {
    if (key.isEmpty) return null;
    _ensureLoaded();
    final v = _map[key];
    if (v == null || v.length < 2 || v[0] <= 0 || v[1] <= 0) return null;
    return v[0] / v[1];
  }

  /// Record the natural size of a decoded image and persist (debounced).
  void put(String key, int width, int height) {
    if (key.isEmpty || width <= 0 || height <= 0) return;
    _ensureLoaded();
    final cur = _map[key];
    if (cur != null && cur.length >= 2 && cur[0] == width && cur[1] == height) {
      return;
    }
    _map[key] = [width, height];
    // Trim: keep the newest 600 entries.
    if (_map.length > 600) {
      _map.remove(_map.keys.take(_map.length - 600).toList());
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 900), _save);
  }

  void _ensureLoaded() {
    if (_loaded) return;
    _loaded = true;
    // Fire-and-forget: the first lookups just miss, then the map fills.
    SharedPreferences.getInstance().then((p) {
      final raw = p.getString(_kKey);
      if (raw == null || raw.isEmpty) return;
      try {
        final j = jsonDecode(raw);
        if (j is Map) {
          j.forEach((k, v) {
            if (v is List && v.length >= 2) {
              final w = v[0] is int ? v[0] as int : int.tryParse('${v[0]}') ?? 0;
              final h = v[1] is int ? v[1] as int : int.tryParse('${v[1]}') ?? 0;
              if (w > 0 && h > 0) _map['$k'] = [w, h];
            }
          });
        }
      } catch (_) {}
    });
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kKey, jsonEncode(_map));
    } catch (_) {}
  }
}
