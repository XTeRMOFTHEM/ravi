import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import 'api_service.dart';

/// One playing item for the whole app (voice note or music file).
class PlayingItem {
  final String url; // absolute or /static/... path
  final String title;
  final String subtitle;
  final bool isVoice;
  /// Voice → sender avatar path; music → '' (artwork unsupported server-side)
  final String avatarPath;
  final String messageIdTag; // dedupe key (fileUrl)

  const PlayingItem({
    required this.url,
    required this.title,
    this.subtitle = '',
    required this.isVoice,
    this.avatarPath = '',
    required this.messageIdTag,
  });

  @override
  bool operator ==(Object other) =>
      other is PlayingItem && other.messageIdTag == messageIdTag;

  @override
  int get hashCode => messageIdTag.hashCode;
}

/// v1.0.7 — GLOBAL audio player (Telegram-style):
///  • one AudioPlayer for the entire app → playback never stops when you
///    navigate between chats / pages
///  • a glass mini-bar under the chat header manages play / speed / close
///  • voice messages put the sender's avatar behind the play button
class PlayerService extends ChangeNotifier {
  PlayerService._();
  static final PlayerService I = PlayerService._();

  AudioPlayer? _player;
  PlayingItem? _current;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  bool _playing = false;
  double _speed = 1.0;
  static const List<double> _speeds = [1.0, 1.25, 1.5, 2.0, 0.75];

  PlayingItem? get current => _current;
  Duration get position => _pos;
  Duration get duration => _dur;
  bool get playing => _playing;
  double get speed => _speed;
  String get speedLabel => _speed == 1.0 ? '1x' : '${_speed}x'.replaceAll('.0', 'x');

  bool isCurrent(String url) =>
      _current != null &&
      _current!.messageIdTag == url &&
      ApiService.I.absoluteUrl(_current!.url) == ApiService.I.absoluteUrl(url);

  void _ensurePlayer() {
    if (_player != null) return;
    final p = AudioPlayer();
    _player = p;
    p.onPositionChanged.listen((d) {
      _pos = d;
      notifyListeners();
    });
    p.onDurationChanged.listen((d) {
      _dur = d;
      notifyListeners();
    });
    p.onPlayerStateChanged.listen((s) {
      _playing = s == PlayerState.playing;
      notifyListeners();
    });
    p.onPlayerComplete.listen((_) {
      _playing = false;
      _pos = _dur;
      notifyListeners();
    });
  }

  /// Start (or restart) playback of [item]. Tapping the same item that is
  /// already current just toggles pause/resume — Telegram behaviour.
  Future<void> playOrToggle(PlayingItem item) async {
    if (isCurrent(item.url)) {
      await toggle();
      return;
    }
    _ensurePlayer();
    _current = item;
    _pos = Duration.zero;
    _dur = Duration.zero;
    notifyListeners();
    try {
      await _player!.play(UrlSource(ApiService.I.absoluteUrl(item.url)));
      await _player!.setReleaseMode(ReleaseMode.stop);
      await _player!.setPlaybackRate(_speed);
      _playing = true;
    } catch (_) {
      _playing = false;
    }
    notifyListeners();
  }

  Future<void> toggle() async {
    final p = _player;
    if (p == null || _current == null) return;
    try {
      if (p.state == PlayerState.playing) {
        await p.pause();
      } else {
        if (_dur > Duration.zero && _pos >= _dur) {
          await p.seek(Duration.zero);
        }
        await p.resume();
        if (p.state == PlayerState.stopped) {
          await p.play(UrlSource(ApiService.I.absoluteUrl(_current!.url)));
        }
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> seekTo(Duration d) async {
    try {
      await _player?.seek(d);
      _pos = d;
      notifyListeners();
    } catch (_) {}
  }

  /// Cycle playback speed 1x → 1.25x → 1.5x → 2x → 0.75x → 1x
  Future<void> cycleSpeed() async {
    final i = _speeds.indexOf(_speed);
    _speed = _speeds[(i + 1) % _speeds.length];
    try {
      await _player?.setPlaybackRate(_speed);
    } catch (_) {}
    notifyListeners();
  }

  /// The ✕ on the mini-bar — stops everything and removes the bar.
  Future<void> close() async {
    try {
      await _player?.stop();
    } catch (_) {}
    _current = null;
    _pos = Duration.zero;
    _dur = Duration.zero;
    _playing = false;
    notifyListeners();
  }
}
