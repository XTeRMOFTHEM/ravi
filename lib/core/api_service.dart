import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'constants.dart';
import 'identity_parser.dart';
import 'models.dart';

/// Persistent cookie jar — keeps the Flask session cookie across app restarts,
/// exactly like a browser session in the web version.
class CookieJar {
  static const _kKey = 'ravi.session.cookie';
  String _cookie = '';

  String get header => _cookie;

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _cookie = p.getString(_kKey) ?? '';
    } catch (_) {}
  }

  void absorb(HttpClientResponse? resp) {
    // handled via headers in ApiService
  }

  Future<void> absorbFromHeaders(Iterable<String>? setCookieValues) async {
    if (setCookieValues == null || setCookieValues.isEmpty) return;
    final parts = <String>[];
    for (final raw in setCookieValues) {
      final first = raw.split(';').first.trim(); // name=value only
      if (first.isNotEmpty) parts.add(first);
    }
    if (parts.isEmpty) return;
    final map = <String, String>{};
    for (final kv in _cookie.split('; ')) {
      if (kv.contains('=')) {
        final i = kv.indexOf('=');
        map[kv.substring(0, i)] = kv.substring(i + 1);
      }
    }
    for (final kv in parts) {
      if (kv.contains('=')) {
        final i = kv.indexOf('=');
        map[kv.substring(0, i)] = kv.substring(i + 1);
      }
    }
    _cookie = map.entries.map((e) => '${e.key}=${e.value}').join('; ');
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kKey, _cookie);
    } catch (_) {}
  }

  Future<void> clear() async {
    _cookie = '';
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_kKey);
    } catch (_) {}
  }
}

enum ApiStatus { ok, unauthorized, error, networkError }

class ApiResult<T> {
  final ApiStatus status;
  final T? data;
  final String? message;

  const ApiResult(this.status, {this.data, this.message});

  bool get ok => status == ApiStatus.ok;
  bool get isAuth => status == ApiStatus.unauthorized;
}

class ApiService {
  ApiService._();
  static final ApiService I = ApiService._();

  final CookieJar jar = CookieJar();
  late http.Client _client;

  Future<void> init() async {
    await jar.load();
    final inner = HttpClient();
    // v1.0.8 — 25s connect timeout: the backend's host can stall the first
    // TCP connect for 12-20s under load; 12s aborted healthy connects.
    inner.connectionTimeout = const Duration(seconds: 25);
    inner.badCertificateCallback = ((cert, host, port) => false);
    _client = IOClient(inner);
    try {
      final p = await SharedPreferences.getInstance();
      _cachedUsername = p.getString(_kUsernameKey) ?? '';
      _cachedUserId = p.getInt(_kUserIdKey) ?? 0;
      _cachedAvatar = p.getString(_kAvatarKey) ?? '';
      _cachedName = p.getString(_kNameKey) ?? '';
    } catch (_) {}
  }

  static const _kUsernameKey = 'ravi.me.username';
  static const _kUserIdKey = 'ravi.me.id';
  static const _kAvatarKey = 'ravi.me.avatar';
  static const _kNameKey = 'ravi.me.name';

  Map<String, String> get _headers => {
        'Cookie': jar.header,
        'X-Requested-With': 'XMLHttpRequest',
      };

  void _absorb(http.Response r) =>
      jar.absorbFromHeaders(r.headers['set-cookie']?.split(RegExp(r',(?=[^;]+?=)')));

  /// Log in with form data (exactly like the web login form: urlencoded).
  ///
  /// v1.0.3 CRITICAL FIXES:
  ///  1. followRedirects=false — the server answers a SUCCESSFUL login with
  ///     302 → / plus the **Set-Cookie session**. dart:io follows redirects
  ///     invisibly and intermediate Set-Cookie headers are LOST, so the app
  ///     was logged in on the server but cookie-less on the phone → the next
  ///     request bounced it straight back to the auth screen. We now capture
  ///     the cookie from the 302 ourselves, then GET / for the identity.
  ///  2. urlencoded body — identical to the HTML form (multipart is
  ///     unnecessarily heavy and proxied setups can treat it differently).
  ///  3. The CURRENT_USER block uses unquoted JS keys → jsonDecode threw →
  ///     every login looked "failed". Parsing now goes through
  ///     identity_parser.parseCurrentUser which handles both shapes.
  Future<ApiResult<bool>> login(String username, String password) async {
    try {
      final resp = await _postForm('/login', {
        'username': username,
        'password': password,
      });
      final redirected = resp.statusCode >= 300 && resp.statusCode < 400;
      if (redirected) {
        final idOk = await _fetchIdentityWithSession();
        if (idOk) return const ApiResult(ApiStatus.ok, data: true);
        final check = await verifySession();
        if (check.ok) {
          await ensureIdentity();
          return const ApiResult(ApiStatus.ok, data: true);
        }
        return const ApiResult(ApiStatus.error, message: 'invalid');
      }
      // Login page re-rendered with a flash error.
      final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      if (body.contains('مسدود')) {
        return const ApiResult(ApiStatus.error, message: 'banned');
      }
      if (body.contains('اطلاعات نادرست')) {
        return const ApiResult(ApiStatus.error, message: 'invalid');
      }
      final check = await verifySession();
      if (check.ok) {
        await ensureIdentity();
        return const ApiResult(ApiStatus.ok, data: true);
      }
      return const ApiResult(ApiStatus.error, message: 'invalid');
    } on TimeoutException {
      return const ApiResult(ApiStatus.networkError, message: 'timeout');
    } on SocketException {
      return const ApiResult(ApiStatus.networkError, message: 'socket');
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// POST urlencoded form without following redirects (so the Set-Cookie of
  /// the 302 lands in our jar) and returns the raw response.
  ///
  /// v1.0.8 CRITICAL FIX: the session cookie is now attached to EVERY form
  /// post. The old code sent Cookie-less requests → Flask bounced
  /// save_avatar_frame / save_profile_theme / save_card_color /
  /// create_private_room / join_private_room straight to /login with a 302,
  /// which the Pro helpers misread as "success". That is exactly why
  /// "Customize Profile" showed a green toast and changed NOTHING.
  Future<http.Response> _postForm(
      String path, Map<String, String> fields) async {
    final req = http.Request('POST', Uri.parse('$kBaseUrl$path'))
      ..followRedirects = false
      ..headers['Content-Type'] =
          'application/x-www-form-urlencoded; charset=utf-8'
      ..headers['X-Requested-With'] = 'XMLHttpRequest'
      ..body = fields.entries
          .map((e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
          .join('&');
    // v1.0.8 — attach the session cookie, but only when we have one: an
    // EMPTY Cookie header confused the register flow (the server answered
    // without the fresh Set-Cookie the identity fetch needed).
    if (jar.header.isNotEmpty) {
      req.headers['Cookie'] = jar.header;
    }
    final streamed = await _client.send(req).timeout(const Duration(seconds: 20));
    final resp = await http.Response.fromStream(streamed);
    _absorb(resp);
    return resp;
  }

  /// GET the index page with the (fresh) session cookie and parse
  /// CURRENT_USER. Returns true when the identity is now known.
  Future<bool> _fetchIdentityWithSession() async {
    final r = await _client
        .get(Uri.parse('$kBaseUrl/'), headers: _headers)
        .timeout(const Duration(seconds: 20));
    _absorb(r);
    if (r.statusCode != 200) return false;
    return _applyIdentity(utf8.decode(r.bodyBytes, allowMalformed: true));
  }

  bool _applyIdentity(String html) {
    final m = parseCurrentUser(html);
    if (m == null) return false;
    _cachedUserId = int.tryParse(m['id'] ?? '') ?? 0;
    _cachedUsername = m['username'] ?? '';
    _cachedAvatar = m['avatar'] ?? '';
    _cachedName = (m['name'] ?? '').isNotEmpty ? m['name']! : _cachedUsername;
    _cachedChatBg = m['chat_bg'] ?? '';
    _persistIdentity();
    return true;
  }

  /// Register with form data (same contract as the web register form:
  /// urlencoded, redirect-follow disabled so the session cookie sticks).
  /// The server auto-logs the fresh user in and 302s to /.
  /// v1.0.8 — one silent retry on socket/timeout (idle-gap drops).
  Future<ApiResult<bool>> register(
      String username, String password, String gender, String name) async {
    var res = await _registerOnce(username, password, gender, name);
    if (res.status == ApiStatus.networkError) {
      await Future.delayed(const Duration(milliseconds: 800));
      res = await _registerOnce(username, password, gender, name);
    }
    return res;
  }

  Future<ApiResult<bool>> _registerOnce(
      String username, String password, String gender, String name) async {
    try {
      final fields = <String, String>{
        'username': username,
        'gender': gender,
        'password': password,
      };
      if (name.trim().isNotEmpty) fields['name'] = name.trim();
      final resp = await _postForm('/register', fields);
      final redirected = resp.statusCode >= 300 && resp.statusCode < 400;
      if (redirected) {
        final idOk = await _fetchIdentityWithSession();
        if (idOk) return const ApiResult(ApiStatus.ok, data: true);
        final check = await verifySession();
        if (check.ok) {
          await ensureIdentity();
          return const ApiResult(ApiStatus.ok, data: true);
        }
        return const ApiResult(ApiStatus.error, message: 'taken');
      }
      // Register page re-rendered with a flash error (duplicate username).
      final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      if (body.contains('تکراری')) {
        return const ApiResult(ApiStatus.error, message: 'taken');
      }
      final check = await verifySession();
      if (check.ok) {
        await ensureIdentity();
        return const ApiResult(ApiStatus.ok, data: true);
      }
      return const ApiResult(ApiStatus.error, message: 'taken');
    } on TimeoutException {
      return const ApiResult(ApiStatus.networkError, message: 'timeout');
    } on SocketException catch (e) {
      return ApiResult(ApiStatus.networkError, message: 'socket: ${e.message} (${e.osError?.errorCode ?? ''})');
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// True when the stored session cookie is still valid.
  ///
  /// CRITICAL: the backend answers an unauthenticated /api/rooms with
  /// 302 → /login?next=... and the http package follows that redirect, so a
  /// logged-out probe arrives as **200 + login HTML**. We must only treat a
  /// JSON payload as authenticated; anything else (HTML, 302, 401) means
  /// "no session" — otherwise the app boots straight into an empty HomeShell
  /// and the register/login screen never appears.
  Future<ApiResult<bool>> verifySession() async {
    try {
      final req = http.Request('GET', Uri.parse('$kBaseUrl/api/rooms'))
        ..followRedirects = false
        ..headers.addAll(_headers);
      final streamed = await _client.send(req).timeout(const Duration(seconds: 12));
      final r = await http.Response.fromStream(streamed);
      _absorb(r);
      if (r.statusCode == 200 && _isJsonBody(r)) {
        return const ApiResult(ApiStatus.ok, data: true);
      }
      // 302 / 401 / 200-with-HTML → not logged in (or session died).
      return const ApiResult(ApiStatus.unauthorized);
    } on SocketException {
      return const ApiResult(ApiStatus.networkError);
    } on TimeoutException {
      return const ApiResult(ApiStatus.networkError);
    } catch (_) {
      return const ApiResult(ApiStatus.networkError);
    }
  }

  /// Sniffs whether the response body is JSON (not an HTML login page that
  /// we were silently redirected to).
  bool _isJsonBody(http.Response r) {
    final head = utf8.decode(r.bodyBytes.take(64).toList(), allowMalformed: true).trimLeft();
    return head.startsWith('[') || head.startsWith('{');
  }

  // ----------------------- data endpoints -----------------------

  /// Returns the locally cached identity (never blocks the UI).
  RaviUser me() => RaviUser(
        id: cachedUserId,
        username: cachedUsername,
        name: cachedName,
        avatar: cachedAvatar,
      );

  Future<ApiResult<List<ChatPreview>>> rooms() async {
    // v1.0.8 — one silent retry: the backend occasionally drops the first
    // request after an idle gap (observed socket timeouts); a single retry
    // turns that into a seamless load instead of a "network error" state.
    var res = await _roomsOnce();
    if (!res.ok) {
      await Future.delayed(const Duration(milliseconds: 700));
      res = await _roomsOnce();
    }
    return res;
  }

  Future<ApiResult<List<ChatPreview>>> _roomsOnce() async {
    try {
      final r = await _client
          .get(Uri.parse('$kBaseUrl/api/rooms'), headers: _headers)
          .timeout(const Duration(seconds: 12));
      _absorb(r);
      // 200 but HTML = we were redirected to the login page (session died).
      if (r.statusCode == 200 && _isJsonBody(r)) {
        final list = (jsonDecode(utf8.decode(r.bodyBytes)) as List)
            .map((e) => ChatPreview.fromRoom(e as Map<String, dynamic>))
            .toList();
        return ApiResult(ApiStatus.ok, data: list);
      }
      return const ApiResult(ApiStatus.unauthorized);
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  Future<ApiResult<List<ChatPreview>>> pvs() async {
    try {
      final r = await _client
          .get(Uri.parse('$kBaseUrl/my_pvs'), headers: _headers)
          .timeout(const Duration(seconds: 12));
      _absorb(r);
      if (r.statusCode == 200 && _isJsonBody(r)) {
        final list = (jsonDecode(utf8.decode(r.bodyBytes)) as List)
            .map((e) => ChatPreview.fromPv(e as Map<String, dynamic>))
            .toList();
        return ApiResult(ApiStatus.ok, data: list);
      }
      return const ApiResult(ApiStatus.unauthorized);
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// General chat history with pagination.
  Future<ApiResult<List<Message>>> generalMessages({int before = 0, int limit = 60}) async {
    try {
      final uri = Uri.parse('$kBaseUrl/api/general_messages?limit=$limit${before > 0 ? '&before=$before' : ''}');
      final r = await _client.get(uri, headers: _headers).timeout(const Duration(seconds: 15));
      _absorb(r);
      if (r.statusCode == 200 && _isJsonBody(r)) {
        final my = cachedUsername;
        final list = (jsonDecode(utf8.decode(r.bodyBytes)) as List)
            .map((e) => Message.fromGeneral(e as Map<String, dynamic>, my))
            .toList();
        return ApiResult(ApiStatus.ok, data: list);
      }
      return const ApiResult(ApiStatus.unauthorized);
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  Future<ApiResult<List<Message>>> pvMessages(int chatId, {int before = 0, int limit = 60}) async {
    try {
      final uri = Uri.parse(
          '$kBaseUrl/api/pv/$chatId/messages?limit=$limit${before > 0 ? '&before=$before' : ''}');
      final r = await _client.get(uri, headers: _headers).timeout(const Duration(seconds: 15));
      _absorb(r);
      if (r.statusCode == 200 && _isJsonBody(r)) {
        final my = cachedUsername;
        final list = (jsonDecode(utf8.decode(r.bodyBytes)) as List)
            .map((e) => Message.fromPv(e as Map<String, dynamic>, my))
            .toList();
        return ApiResult(ApiStatus.ok, data: list);
      }
      return const ApiResult(ApiStatus.unauthorized);
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  Future<ApiResult<List<Message>>> roomMessages(String roomId, {int before = 0, int limit = 60}) async {
    final res = await roomMessagesFull(roomId, before: before, limit: limit);
    if (res.ok && res.data != null) return ApiResult(ApiStatus.ok, data: res.data!.messages);
    if (res.isAuth) return const ApiResult(ApiStatus.unauthorized);
    return ApiResult(res.status, message: res.message);
  }

  /// v1.0.6 CRITICAL FIX: `/api/room/<id>/messages` returns a **MAP** —
  ///   {messages: [...], can_post, room_type, is_muted, bio, is_public,
  ///    room_username, my_role, my_perms, settings} — NOT a bare list.
  /// The old code did `jsonDecode(...) as List` → TypeError → the request
  /// surfaced as networkError → group/channel chats NEVER loaded.
  /// (The web client does: `Array.isArray(res) ? res : res.messages`.)
  Future<ApiResult<RoomHistory>> roomMessagesFull(String roomId, {int before = 0, int limit = 60}) async {
    try {
      final uri = Uri.parse(
          '$kBaseUrl/api/room/$roomId/messages?limit=$limit${before > 0 ? '&before=$before' : ''}');
      final r = await _client.get(uri, headers: _headers).timeout(const Duration(seconds: 15));
      _absorb(r);
      if (r.statusCode == 200 && _isJsonBody(r)) {
        final my = cachedUsername;
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is List) {
          // Backwards-compat: some servers return a bare array.
          return ApiResult(ApiStatus.ok, data: RoomHistory(messages: j
              .whereType<Map>()
              .map((e) => Message.fromGeneral(Map<String, dynamic>.from(e), my))
              .toList()));
        }
        if (j is Map) {
          final list = ((j['messages'] ?? j['data'] ?? const []) as List)
              .whereType<Map>()
              .map((e) => Message.fromGeneral(Map<String, dynamic>.from(e), my))
              .toList();
          return ApiResult(ApiStatus.ok, data: RoomHistory(
            messages: list,
            canPost: j['can_post'] != false,
            roomType: '${j['room_type'] ?? 'group'}',
            isMuted: j['is_muted'] == true,
            bio: '${j['bio'] ?? ''}',
            isPublic: j['is_public'] == true,
            roomUsername: '${j['room_username'] ?? ''}',
            myRole: '${j['my_role'] ?? 'member'}',
          ));
        }
      }
      return const ApiResult(ApiStatus.unauthorized);
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  Future<ApiResult<int>> startPv(String username) async {
    try {
      final r = await _client
          .get(Uri.parse('$kBaseUrl/api/start_pv/$username'), headers: _headers)
          .timeout(const Duration(seconds: 12));
      _absorb(r);
      if (r.statusCode == 200) {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is Map && j['chat_id'] != null) {
          return ApiResult(ApiStatus.ok, data: (j['chat_id'] is int) ? j['chat_id'] as int : int.tryParse('${j['chat_id']}') ?? 0);
        }
        if (j is Map && j['error'] != null) {
          return ApiResult(ApiStatus.error, message: '${j['error']}');
        }
      }
      return ApiResult(ApiStatus.error, message: 'not_found');
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  Future<ApiResult<Map<String, dynamic>>> createRoom(String name) async {
    try {
      final req = http.MultipartRequest('POST', Uri.parse('$kBaseUrl/create_private_room'))
        ..fields['name'] = name
        ..headers.addAll(_headers);
      final streamed = await _client.send(req).timeout(const Duration(seconds: 15));
      final resp = await http.Response.fromStream(streamed);
      _absorb(resp);
      if (resp.statusCode == 200 || resp.statusCode == 302) {
        return const ApiResult(ApiStatus.ok, data: {});
      }
      return const ApiResult(ApiStatus.error, message: 'fail');
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// Upload a chat media file. CRITICAL v1.0.5 FIX: the multipart field name
  /// MUST be `image` (backend: request.files['image']) — the old code sent
  /// `file`, so the server answered 400 "فایلی انتخاب نشده" and nothing
  /// could ever be sent. Allowed: jpg png gif webp mp4 webm mp3 ogg m4a.
  Future<ApiResult<Map<String, dynamic>>> uploadMedia(String filePath,
      {String fileType = 'image'}) async {
    try {
      final req = http.MultipartRequest('POST', Uri.parse('$kBaseUrl/upload_image'))
        ..files.add(await http.MultipartFile.fromPath('image', filePath))
        ..headers.addAll(_headers);
      final streamed = await _client.send(req).timeout(const Duration(seconds: 90));
      final resp = await http.Response.fromStream(streamed);
      _absorb(resp);
      if (resp.statusCode == 200) {
        final j = jsonDecode(utf8.decode(resp.bodyBytes));
        if (j is Map && (j['file_url'] ?? j['url']) != null) {
          return ApiResult(ApiStatus.ok, data: {
            'file_url': '${j['file_url'] ?? j['url']}',
            'file_type': fileType,
          });
        }
        if (j is Map && j['error'] != null) {
          return ApiResult(ApiStatus.error, message: '${j['error']}');
        }
      }
      return const ApiResult(ApiStatus.error, message: 'upload failed');
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// Legacy alias kept for compatibility.
  Future<ApiResult<Map<String, dynamic>>> uploadImage(String filePath) =>
      uploadMedia(filePath, fileType: 'image');

  /// v1.0.6: upload with **real progress** — mirrors the web client's
  /// xhr.upload.onprogress. We subclass MultipartRequest and wrap the
  /// finalized body stream with a byte counter (no new dependencies).
  Future<ApiResult<Map<String, dynamic>>> uploadMediaWithProgress(
      String filePath,
      {String fileType = 'image',
      void Function(double pct)? onProgress}) async {
    try {
      final req = _ProgressMultipartRequest('POST', Uri.parse('$kBaseUrl/upload_image'),
          onProgress: (sent, total) {
        if (total > 0 && onProgress != null) {
          onProgress((sent / total).clamp(0.0, 1.0));
        }
      })
        ..files.add(await http.MultipartFile.fromPath('image', filePath))
        ..headers.addAll(_headers);
      final streamed = await _client.send(req).timeout(const Duration(seconds: 120));
      final resp = await http.Response.fromStream(streamed);
      _absorb(resp);
      onProgress?.call(1.0);
      if (resp.statusCode == 200) {
        final j = jsonDecode(utf8.decode(resp.bodyBytes));
        if (j is Map && (j['file_url'] ?? j['url']) != null) {
          return ApiResult(ApiStatus.ok, data: {
            'file_url': '${j['file_url'] ?? j['url']}',
            'file_type': fileType,
          });
        }
        if (j is Map && j['error'] != null) {
          return ApiResult(ApiStatus.error, message: '${j['error']}');
        }
      }
      return const ApiResult(ApiStatus.error, message: 'upload failed');
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  // ----------------------- identity -----------------------

  String _cachedUsername = '';
  int _cachedUserId = 0;
  String _cachedAvatar = '';
  String _cachedName = '';
  String _cachedChatBg = '';

  Future<void> _persistIdentity() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kUsernameKey, _cachedUsername);
      if (_cachedUserId > 0) await p.setInt(_kUserIdKey, _cachedUserId);
      await p.setString(_kAvatarKey, _cachedAvatar);
      await p.setString(_kNameKey, _cachedName);
    } catch (_) {}
  }

  /// One-shot: fetch the app page and parse CURRENT_USER (used when we have a
  /// valid session but no cached identity, e.g. fresh install).
  Future<bool> fetchIdentity() async => _fetchIdentityWithSession();

  Future<bool> ensureIdentity() async {
    if (_cachedUsername.isNotEmpty) return true;
    return fetchIdentity();
  }

  String get cachedUsername => _cachedUsername;
  int get cachedUserId => _cachedUserId;
  String get cachedAvatar => _cachedAvatar;
  String get cachedName => _cachedName.isEmpty ? _cachedUsername : _cachedName;
  String get cachedChatBg => _cachedChatBg;
  String get cookieHeader => jar.header;
  void setIdentity({required String username, int id = 0, String avatar = '', String name = ''}) {
    if (username.isNotEmpty) _cachedUsername = username;
    if (id > 0) _cachedUserId = id;
    _cachedAvatar = avatar;
    _cachedName = name;
    _persistIdentity();
  }

  Future<void> logout() async {
    await jar.clear();
    _cachedUsername = '';
    _cachedUserId = 0;
    _cachedAvatar = '';
    _cachedName = '';
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_kUsernameKey);
      await p.remove(_kUserIdKey);
      await p.remove(_kAvatarKey);
      await p.remove(_kNameKey);
    } catch (_) {}
    try {
      await _client.get(Uri.parse('$kBaseUrl/logout'), headers: _headers).timeout(const Duration(seconds: 8));
    } catch (_) {}
  }

  String absoluteUrl(String path) {
    if (path.startsWith('http')) return path;
    if (path.startsWith('/')) return '$kBaseUrl$path';
    return '$kBaseUrl/$path';
  }

  /// Builds a resolvable URL for user/room avatars and uploaded images.
  /// The backend returns bare filenames (e.g. "default.png", "7_avatar_x.png")
  /// but serves them under /static/uploads/ — a bare absoluteUrl() 404s,
  /// which greyed out every avatar in the app.
  String avatarUrl(String name) {
    if (name.isEmpty || name == 'None' || name == 'null') return '';
    if (name.startsWith('http')) return name;
    if (name.startsWith('/static/')) return absoluteUrl(name);
    return absoluteUrl('/static/uploads/$name');
  }

  /// Raw authenticated GET returning parsed JSON (used by profile page).
  Future<Map<String, dynamic>?> rawGet(String path) async {
    try {
      final r = await _client
          .get(Uri.parse(absoluteUrl(path)), headers: _headers)
          .timeout(const Duration(seconds: 12));
      _absorb(r);
      if (r.statusCode == 200) {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is Map<String, dynamic>) return j;
      }
    } catch (_) {}
    return null;
  }

  // ----------------------- profile endpoints -----------------------

  /// GET /api/user_profile/<username> — rich profile payload (bio, followers,
  /// following, is_pro, is_verified, is_admin, created_at, cover...).
  /// v1.0.8 — one silent retry against the backend's idle-gap drops.
  Future<ApiResult<Map<String, dynamic>>> userProfile(String username) async {
    var res = await _userProfileOnce(username);
    if (!res.ok) {
      await Future.delayed(const Duration(milliseconds: 700));
      res = await _userProfileOnce(username);
    }
    return res;
  }

  Future<ApiResult<Map<String, dynamic>>> _userProfileOnce(
      String username) async {
    try {
      final r = await _client
          .get(Uri.parse('$kBaseUrl/api/user_profile/$username'), headers: _headers)
          .timeout(const Duration(seconds: 12));
      _absorb(r);
      if (r.statusCode == 200 && _isJsonBody(r)) {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is Map<String, dynamic>) return ApiResult(ApiStatus.ok, data: j);
      }
      return const ApiResult(ApiStatus.error, message: 'not_found');
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// POST /edit_profile — urlencoded form (name, bio, optional username,
  /// optional avatar multipart). ALWAYS sends name+bio together because the
  /// backend overwrites bio unconditionally (sending name-only wipes bio).
  /// Returns the updated identity on success.
  Future<ApiResult<Map<String, dynamic>>> editProfile({
    String? name,
    String? bio,
    String? username,
    String? avatarPath,
  }) async {
    try {
      final req = http.MultipartRequest('POST', Uri.parse('$kBaseUrl/edit_profile'))
        ..headers.addAll(_headers)
        ..headers['X-Requested-With'] = 'XMLHttpRequest';
      req.fields['name'] = (name ?? '').trim();
      req.fields['bio'] = (bio ?? '').trim();
      final newUsername = (username ?? '').trim();
      if (newUsername.isNotEmpty && newUsername != cachedUsername) {
        req.fields['username'] = newUsername;
      }
      if (avatarPath != null) {
        req.files.add(await http.MultipartFile.fromPath('avatar', avatarPath));
      }
      final streamed = await _client.send(req).timeout(const Duration(seconds: 60));
      final resp = await http.Response.fromStream(streamed);
      _absorb(resp);
      final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      if (resp.statusCode == 200) {
        try {
          final j = jsonDecode(body);
          if (j is Map && j['success'] == true) {
            // sync local identity
            if ('${j['username'] ?? ''}'.isNotEmpty) _cachedUsername = '${j['username']}';
            if ('${j['name'] ?? ''}'.isNotEmpty) _cachedName = '${j['name']}';
            if (j['avatar'] != null) _cachedAvatar = '${j['avatar']}';
            await _persistIdentity();
            return ApiResult(ApiStatus.ok,
                data: j is Map<String, dynamic> ? j : {});
          }
          if (j is Map && j['error'] != null) {
            return ApiResult(ApiStatus.error, message: '${j['error']}');
          }
        } catch (_) {}
      }
      return const ApiResult(ApiStatus.error, message: 'fail');
    } on TimeoutException {
      return const ApiResult(ApiStatus.networkError, message: 'timeout');
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  // ----------------------- GIF gallery -----------------------

  /// POST /upload_gif — multipart field `video` (mp4/webm/mov/avi/mkv/gif).
  /// The server converts it to a small looping GIF and saves it to the
  /// user's gallery. Returns the gif URL (`/static/uploads/x.gif`).
  Future<ApiResult<String>> uploadGif(String filePath) async {
    try {
      final req = http.MultipartRequest('POST', Uri.parse('$kBaseUrl/upload_gif'))
        ..files.add(await http.MultipartFile.fromPath('video', filePath))
        ..headers.addAll(_headers)
        ..headers['X-Requested-With'] = 'XMLHttpRequest';
      final streamed = await _client.send(req).timeout(const Duration(seconds: 90));
      final resp = await http.Response.fromStream(streamed);
      _absorb(resp);
      if (resp.statusCode == 200) {
        final j = jsonDecode(utf8.decode(resp.bodyBytes));
        if (j is Map && j['success'] == true && '${j['url'] ?? ''}'.isNotEmpty) {
          return ApiResult(ApiStatus.ok, data: '${j['url']}');
        }
        if (j is Map && j['error'] != null) {
          return ApiResult(ApiStatus.error, message: '${j['error']}');
        }
      }
      return const ApiResult(ApiStatus.error, message: 'upload failed');
    } on TimeoutException {
      return const ApiResult(ApiStatus.networkError, message: 'timeout');
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// GET /my_gifs — `{success, gifs: [{id, url, created_at}]}`.
  Future<ApiResult<List<Map<String, dynamic>>>> myGifs() async {
    try {
      final r = await _client
          .get(Uri.parse('$kBaseUrl/my_gifs'), headers: _headers)
          .timeout(const Duration(seconds: 12));
      _absorb(r);
      if (r.statusCode == 200 && _isJsonBody(r)) {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is Map && j['gifs'] is List) {
          return ApiResult(ApiStatus.ok,
              data: (j['gifs'] as List)
                  .whereType<Map>()
                  .map((e) => Map<String, dynamic>.from(e))
                  .toList());
        }
      }
      return const ApiResult(ApiStatus.error);
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// v1.0.7 — POST /edit_message/<id> — JSON `{new_text}`; only the author
  /// may edit, empty text is rejected server-side.
  Future<ApiResult<bool>> editMessage(int messageId, String newText) async {
    try {
      final r = await _client
          .post(Uri.parse('$kBaseUrl/edit_message/$messageId'),
              headers: {
                ..._headers,
                'Content-Type': 'application/json; charset=utf-8',
              },
              body: jsonEncode({'new_text': newText}))
          .timeout(const Duration(seconds: 12));
      _absorb(r);
      if (r.statusCode == 200 && _isJsonBody(r)) {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is Map && j['success'] == true) {
          return const ApiResult(ApiStatus.ok, data: true);
        }
        return ApiResult(ApiStatus.error,
            message: j is Map ? '${j['error'] ?? 'fail'}' : 'fail');
      }
      return const ApiResult(ApiStatus.error, message: 'fail');
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// POST /save_gif_from_chat — JSON `{url}` (must start with
  /// /static/uploads/ and end with .gif).
  Future<ApiResult<bool>> saveGifFromChat(String url) async {
    try {
      final r = await _client
          .post(Uri.parse('$kBaseUrl/save_gif_from_chat'),
              headers: {
                ..._headers,
                'X-Requested-With': 'XMLHttpRequest',
                'Content-Type': 'application/json; charset=utf-8',
              },
              body: jsonEncode({'url': url}))
          .timeout(const Duration(seconds: 12));
      _absorb(r);
      if (r.statusCode == 200 && _isJsonBody(r)) {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is Map && j['success'] == true) {
          return const ApiResult(ApiStatus.ok, data: true);
        }
      }
      return const ApiResult(ApiStatus.error);
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// POST /delete_gif/<id> — removes a gif from MY gallery
  /// (the file itself stays on the server for old messages).
  Future<ApiResult<bool>> deleteGif(int gifId) async {
    try {
      final r = await _client
          .post(Uri.parse('$kBaseUrl/delete_gif/$gifId'),
              headers: _headers..['X-Requested-With'] = 'XMLHttpRequest')
          .timeout(const Duration(seconds: 12));
      _absorb(r);
      if (r.statusCode == 200 && _isJsonBody(r)) {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is Map && j['success'] == true) {
          return const ApiResult(ApiStatus.ok, data: true);
        }
      }
      return const ApiResult(ApiStatus.error);
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// GET /my_blocks — list of blocked users.
  Future<ApiResult<List<dynamic>>> myBlocks() async {
    try {
      final r = await _client
          .get(Uri.parse('$kBaseUrl/my_blocks'), headers: _headers)
          .timeout(const Duration(seconds: 12));
      _absorb(r);
      if (r.statusCode == 200 && _isJsonBody(r)) {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is List) return ApiResult(ApiStatus.ok, data: j);
      }
      return const ApiResult(ApiStatus.error);
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// GET /unblock_user/<username> (XHR → {success:true}).
  Future<ApiResult<bool>> unblockUser(String username) async {
    try {
      final r = await _client
          .get(Uri.parse('$kBaseUrl/unblock_user/$username'), headers: _headers)
          .timeout(const Duration(seconds: 12));
      _absorb(r);
      if (r.statusCode == 200) {
        final body = utf8.decode(r.bodyBytes, allowMalformed: true);
        if (body.contains('true') || body.trim().startsWith('{')) {
          return const ApiResult(ApiStatus.ok, data: true);
        }
      }
      return const ApiResult(ApiStatus.error);
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// GET /block_user/<username> (server 302s back; any 2xx/3xx counts).
  Future<ApiResult<bool>> blockUser(String username) async {
    try {
      final req = http.Request('GET', Uri.parse('$kBaseUrl/block_user/$username'))
        ..followRedirects = false
        ..headers.addAll(_headers);
      final streamed = await _client.send(req).timeout(const Duration(seconds: 12));
      final r = await http.Response.fromStream(streamed);
      _absorb(r);
      if (r.statusCode >= 200 && r.statusCode < 400) {
        return const ApiResult(ApiStatus.ok, data: true);
      }
      return const ApiResult(ApiStatus.error);
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// POST /api/follow/<username> or /api/unfollow/<username>.
  Future<ApiResult<bool>> setFollowing(String username, bool follow) async {
    try {
      final r = await _client
          .post(Uri.parse('$kBaseUrl/api/${follow ? 'follow' : 'unfollow'}/$username'),
              headers: _headers)
          .timeout(const Duration(seconds: 12));
      _absorb(r);
      if (r.statusCode == 200 && _isJsonBody(r)) {
        return ApiResult(ApiStatus.ok, data: follow);
      }
      return const ApiResult(ApiStatus.error);
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  // ==================== v1.0.5 endpoints ====================

  /// GET /api/user_exists/<username> — live username availability.
  Future<ApiResult<bool>> userExists(String username) async {
    try {
      final r = await _client
          .get(Uri.parse('$kBaseUrl/api/user_exists/$username'), headers: _headers)
          .timeout(const Duration(seconds: 8));
      _absorb(r);
      if (r.statusCode == 200 && _isJsonBody(r)) {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is Map) return ApiResult(ApiStatus.ok, data: j['exists'] == true);
      }
      return const ApiResult(ApiStatus.error);
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// GET /api/room_username_check/<username> — live group/channel handle check.
  Future<ApiResult<bool>> roomUsernameCheck(String username) async {
    try {
      final u = username.trim().replaceFirst(RegExp(r'^@'), '');
      final r = await _client
          .get(Uri.parse('$kBaseUrl/api/room_username_check/$u'), headers: _headers)
          .timeout(const Duration(seconds: 8));
      _absorb(r);
      if (r.statusCode == 200 && _isJsonBody(r)) {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is Map) return ApiResult(ApiStatus.ok, data: j['available'] == true);
      }
      return const ApiResult(ApiStatus.error);
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// POST /create_private_room — full version (group/channel + public handle).
  Future<ApiResult<Map<String, dynamic>>> createRoomAdvanced({
    required String name,
    String type = 'group',
    bool isPublic = false,
    String username = '',
  }) async {
    try {
      final fields = <String, String>{
        'name': name,
        'type': type,
        if (isPublic) 'is_public': '1',
        if (isPublic && username.trim().isNotEmpty)
          'username': username.trim().replaceFirst(RegExp(r'^@'), ''),
      };
      final resp = await _postForm('/create_private_room', fields);
      final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      if (resp.statusCode == 200 && body.trimLeft().startsWith('{')) {
        final j = jsonDecode(body);
        if (j is Map<String, dynamic> && j['room_id'] != null) {
          return ApiResult(ApiStatus.ok, data: j);
        }
        if (j is Map && j['error'] != null) {
          return ApiResult(ApiStatus.error, message: '${j['error']}');
        }
      }
      return const ApiResult(ApiStatus.error, message: 'fail');
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// GET /api/pv/<chat_id>/info — other user, online state, real last seen.
  Future<ApiResult<Map<String, dynamic>>> pvInfo(int chatId) async {
    try {
      final r = await _client
          .get(Uri.parse('$kBaseUrl/api/pv/$chatId/info'), headers: _headers)
          .timeout(const Duration(seconds: 10));
      _absorb(r);
      if (r.statusCode == 200 && _isJsonBody(r)) {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is Map<String, dynamic>) return ApiResult(ApiStatus.ok, data: j);
      }
      return const ApiResult(ApiStatus.error, message: 'not_found');
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// GET /room/<room_id>/members — full group/channel info + member list.
  Future<ApiResult<Map<String, dynamic>>> roomInfo(String roomId) async {
    try {
      final r = await _client
          .get(Uri.parse('$kBaseUrl/room/$roomId/members'), headers: _headers)
          .timeout(const Duration(seconds: 12));
      _absorb(r);
      if (r.statusCode == 200 && _isJsonBody(r)) {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is Map<String, dynamic>) return ApiResult(ApiStatus.ok, data: j);
      }
      return const ApiResult(ApiStatus.error, message: 'not_found');
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// POST /upload_chat_bg — multipart field `bg` → {success, url}.
  Future<ApiResult<String>> uploadChatBg(String filePath) async {
    try {
      final req = http.MultipartRequest('POST', Uri.parse('$kBaseUrl/upload_chat_bg'))
        ..files.add(await http.MultipartFile.fromPath('bg', filePath))
        ..headers.addAll(_headers);
      final streamed = await _client.send(req).timeout(const Duration(seconds: 60));
      final resp = await http.Response.fromStream(streamed);
      _absorb(resp);
      if (resp.statusCode == 200) {
        final j = jsonDecode(utf8.decode(resp.bodyBytes));
        if (j is Map && j['success'] == true && '${j['url'] ?? ''}'.isNotEmpty) {
          return ApiResult(ApiStatus.ok, data: '${j['url']}');
        }
      }
      return const ApiResult(ApiStatus.error);
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// POST /remove_chat_bg — back to the default background.
  Future<ApiResult<bool>> removeChatBg() async {
    try {
      final r = await _client
          .post(Uri.parse('$kBaseUrl/remove_chat_bg'), headers: _headers)
          .timeout(const Duration(seconds: 12));
      _absorb(r);
      if (r.statusCode == 200 && _isJsonBody(r)) {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is Map && j['success'] == true) {
          return const ApiResult(ApiStatus.ok, data: true);
        }
      }
      return const ApiResult(ApiStatus.error);
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// Pro customization saves. All of these redirect (302) on success and
  /// redirect with a flash error when not Pro — so 302 == applied.
  Future<ApiResult<bool>> _postProForm(String path, Map<String, String> fields) async {
    try {
      final resp = await _postForm(path, fields);
      if (resp.statusCode >= 300 && resp.statusCode < 400) {
        return const ApiResult(ApiStatus.ok, data: true);
      }
      // 200 = re-rendered page (not Pro / invalid key).
      final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      if (body.contains('فقط برای کاربران Pro')) {
        return const ApiResult(ApiStatus.error, message: 'pro_only');
      }
      return const ApiResult(ApiStatus.error, message: 'fail');
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  Future<ApiResult<bool>> saveAvatarFrame(String frameKey) =>
      _postProForm('/save_avatar_frame', {'frame': frameKey});

  Future<ApiResult<bool>> saveProfileTheme(String themeKey) =>
      _postProForm('/save_profile_theme', {'theme': themeKey});

  Future<ApiResult<bool>> saveCardColor(String colorKey) =>
      _postProForm('/save_card_color', {'card_color': colorKey});

  Future<ApiResult<bool>> removeProfileCover() =>
      _postProForm('/remove_profile_cover', {});

  // ------------------------------------------------------------------
  // v1.0.8 — room management (Telegram-style group/channel controls)
  // ------------------------------------------------------------------

  /// POST /room/<id>/leave — leave a group/channel (owner must transfer first).
  Future<ApiResult<bool>> leaveRoom(String roomId) async {
    try {
      final resp = await _postForm('/room/$roomId/leave', {});
      if (resp.statusCode >= 300 && resp.statusCode < 400) {
        // legacy redirect-based success
        return const ApiResult(ApiStatus.ok, data: true);
      }
      final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      if (body.trimLeft().startsWith('{')) {
        final j = jsonDecode(body);
        if (j is Map && j['success'] == true) {
          return const ApiResult(ApiStatus.ok, data: true);
        }
        if (j is Map && j['error'] != null) {
          return ApiResult(ApiStatus.error, message: '${j['error']}');
        }
      }
      return const ApiResult(ApiStatus.error, message: 'fail');
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// POST /room/<id>/toggle_mute — personal mute switch.
  Future<ApiResult<bool>> toggleRoomMute(String roomId) async {
    try {
      final r = await _client
          .post(Uri.parse('$kBaseUrl/room/$roomId/toggle_mute'),
              headers: _headers)
          .timeout(const Duration(seconds: 12));
      _absorb(r);
      if (r.statusCode == 200 && _isJsonBody(r)) {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is Map && j['success'] == true) {
          return ApiResult(ApiStatus.ok, data: j['is_muted'] == true);
        }
      }
      return const ApiResult(ApiStatus.error);
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// POST /room/<id>/ban — kick+ban a member (admins / owner).
  Future<ApiResult<bool>> banRoomMember(String roomId, int userId) async {
    try {
      final resp = await _postForm('/room/$roomId/ban', {
        'user_id': '$userId',
      });
      if (resp.statusCode >= 300 && resp.statusCode < 400) {
        return const ApiResult(ApiStatus.ok, data: true);
      }
      final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      if (body.trimLeft().startsWith('{')) {
        final j = jsonDecode(body);
        if (j is Map && (j['success'] == true || j['banned'] == true)) {
          return const ApiResult(ApiStatus.ok, data: true);
        }
        if (j is Map && j['error'] != null) {
          return ApiResult(ApiStatus.error, message: '${j['error']}');
        }
      }
      return const ApiResult(ApiStatus.error, message: 'fail');
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// POST /room/<id>/unban — lift a member ban (owner).
  Future<ApiResult<bool>> unbanRoomMember(String roomId, int userId) async {
    try {
      final resp = await _postForm('/room/$roomId/unban', {
        'user_id': '$userId',
      });
      if (resp.statusCode >= 300 && resp.statusCode < 400) {
        return const ApiResult(ApiStatus.ok, data: true);
      }
      final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      if (body.trimLeft().startsWith('{')) {
        final j = jsonDecode(body);
        if (j is Map && j['success'] == true) {
          return const ApiResult(ApiStatus.ok, data: true);
        }
      }
      return const ApiResult(ApiStatus.error, message: 'fail');
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// POST /room/<id>/promote / demote — admin management (owner).
  Future<ApiResult<bool>> promoteMember(String roomId, int userId) =>
      _postRoomManager('/room/$roomId/promote', userId);
  Future<ApiResult<bool>> demoteMember(String roomId, int userId) =>
      _postRoomManager('/room/$roomId/demote', userId);

  Future<ApiResult<bool>> _postRoomManager(String path, int userId) async {
    try {
      final resp = await _postForm(path, {'user_id': '$userId'});
      if (resp.statusCode >= 300 && resp.statusCode < 400) {
        return const ApiResult(ApiStatus.ok, data: true);
      }
      final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      if (body.trimLeft().startsWith('{')) {
        final j = jsonDecode(body);
        if (j is Map && (j['success'] == true)) {
          return const ApiResult(ApiStatus.ok, data: true);
        }
        if (j is Map && j['error'] != null) {
          return ApiResult(ApiStatus.error, message: '${j['error']}');
        }
      }
      return const ApiResult(ApiStatus.error, message: 'fail');
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// POST /upload_profile_cover — multipart field `cover` (302 == success).
  Future<ApiResult<bool>> uploadProfileCover(String filePath) async {
    try {
      final req = http.MultipartRequest('POST', Uri.parse('$kBaseUrl/upload_profile_cover'))
        ..files.add(await http.MultipartFile.fromPath('cover', filePath))
        ..headers.addAll(_headers);
      final streamed = await _client.send(req).timeout(const Duration(seconds: 60));
      final resp = await http.Response.fromStream(streamed);
      _absorb(resp);
      if (resp.statusCode >= 300 && resp.statusCode < 400) {
        return const ApiResult(ApiStatus.ok, data: true);
      }
      final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      if (body.contains('فقط برای کاربران Pro')) {
        return const ApiResult(ApiStatus.error, message: 'pro_only');
      }
      return const ApiResult(ApiStatus.error, message: 'fail');
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// Followers / following list. The backend serves an HTML page
  /// (follow_list.html) — we parse the `.user-item` cards:
  ///   <div class="user-item" data-username="X"> <img src="/static/uploads/A">
  ///   <div class="user-name">N</div> <div class="user-meta">D</div>
  Future<ApiResult<List<Map<String, dynamic>>>> followList(String username,
      {required bool followers}) async {
    try {
      // v1.0.9 — the JSON endpoint carries `i_follow` so the followers panel
      // can render Follow / Follow-back / Unfollow states like Telegram.
      final kind = followers ? 'followers' : 'following';
      final r = await _client
          .get(Uri.parse('$kBaseUrl/api/follow_list/$username?type=$kind'),
              headers: _headers)
          .timeout(const Duration(seconds: 12));
      _absorb(r);
      if (r.statusCode == 200 && _isJsonBody(r)) {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is Map && j['users'] is List) {
          final out = (j['users'] as List)
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
          return ApiResult(ApiStatus.ok, data: out);
        }
      }
      // ---- legacy HTML fallback ----
      final path = followers ? '/followers/$username' : '/following/$username';
      final r2 = await _client
          .get(Uri.parse('$kBaseUrl$path'), headers: _headers)
          .timeout(const Duration(seconds: 12));
      _absorb(r2);
      if (r2.statusCode != 200) return const ApiResult(ApiStatus.error);
      final html = utf8.decode(r2.bodyBytes, allowMalformed: true);
      final itemRe = RegExp(
          r'<div class="user-item" data-username="([^"]+)"[\s\S]*?<img src="([^"]*)"[\s\S]*?<div class="user-name">([\s\S]*?)</div>[\s\S]*?<div class="user-meta">([\s\S]*?)</div>',
          multiLine: true);
      final out = <Map<String, dynamic>>[];
      for (final m in itemRe.allMatches(html)) {
        out.add({
          'username': m.group(1) ?? '',
          'avatar': (m.group(2) ?? '').split('/').last,
          'name': (m.group(3) ?? '').trim(),
          'meta': (m.group(4) ?? '').trim(),
          'i_follow': false,
        });
      }
      return ApiResult(ApiStatus.ok, data: out);
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// Streams a static media URL to [savePath] (used by the gallery saver).
  Future<bool> downloadToFile(String urlOrPath, String savePath) async {
    try {
      final r = await _client
          .get(Uri.parse(absoluteUrl(urlOrPath)), headers: _headers)
          .timeout(const Duration(seconds: 60));
      if (r.statusCode == 200 && r.bodyBytes.isNotEmpty) {
        final f = File(savePath);
        await f.writeAsBytes(r.bodyBytes, flush: true);
        return true;
      }
    } catch (_) {}
    return false;
  }

  // ==================== v1.0.6 endpoints ====================

  /// GET /api/room/resolve/<username> — public room preview by handle.
  Future<ApiResult<Map<String, dynamic>>> roomResolve(String username) async {
    try {
      final u = username.trim().replaceFirst(RegExp(r'^@'), '');
      final r = await _client
          .get(Uri.parse('$kBaseUrl/api/room/resolve/$u'), headers: _headers)
          .timeout(const Duration(seconds: 10));
      _absorb(r);
      if (r.statusCode == 200 && _isJsonBody(r)) {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is Map && j['room_id'] != null) {
          return ApiResult(ApiStatus.ok, data: Map<String, dynamic>.from(j));
        }
        if (j is Map && j['error'] != null) {
          return ApiResult(ApiStatus.error, message: '${j['error']}');
        }
      }
      return const ApiResult(ApiStatus.error, message: 'not_found');
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// GET /api/room/preview/<roomId> — public room preview by id.
  Future<ApiResult<Map<String, dynamic>>> roomPreview(String roomId) async {
    try {
      final r = await _client
          .get(Uri.parse('$kBaseUrl/api/room/preview/$roomId'), headers: _headers)
          .timeout(const Duration(seconds: 10));
      _absorb(r);
      if (r.statusCode == 200 && _isJsonBody(r)) {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is Map && j['room_id'] != null) {
          return ApiResult(ApiStatus.ok, data: Map<String, dynamic>.from(j));
        }
      }
      return const ApiResult(ApiStatus.error, message: 'not_found');
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// POST /join_by_username — JSON {username} → {success} (public rooms).
  Future<ApiResult<Map<String, dynamic>>> joinByUsername(String username) async {
    try {
      final r = await _client
          .post(Uri.parse('$kBaseUrl/join_by_username'),
              headers: {
                ..._headers,
                'Content-Type': 'application/json; charset=utf-8',
              },
              body: jsonEncode({'username': username.trim().replaceFirst(RegExp(r'^@'), '')}))
          .timeout(const Duration(seconds: 12));
      _absorb(r);
      if (r.statusCode == 200 && _isJsonBody(r)) {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is Map) {
          return ApiResult(ApiStatus.ok, data: Map<String, dynamic>.from(j));
        }
      }
      return const ApiResult(ApiStatus.error, message: 'fail');
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// POST /join_private_room — urlencoded {room_id} (invite-id rooms).
  Future<ApiResult<bool>> joinRoom(String roomId) async {
    try {
      final resp = await _postForm('/join_private_room', {'room_id': roomId});
      final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      final ok = (resp.statusCode == 200 && body.trimLeft().startsWith('{') &&
              body.contains('success')) ||
          (resp.statusCode >= 300 && resp.statusCode < 400);
      return ApiResult(ok ? ApiStatus.ok : ApiStatus.error, data: ok);
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// POST /forward_message/<msgId> — JSON {type:'pv',chat_id} or
  /// {type:'room',room_id}. The server re-saves with the ORIGINAL author
  /// identity (forward_from fields) exactly like Telegram.
  Future<ApiResult<bool>> forwardMessage(int msgId,
      {int? pvChatId, String? roomChatId}) async {
    try {
      final r = await _client
          .post(Uri.parse('$kBaseUrl/forward_message/$msgId'),
              headers: {
                ..._headers,
                'Content-Type': 'application/json; charset=utf-8',
              },
              body: jsonEncode(pvChatId != null
                  ? {'type': 'pv', 'chat_id': pvChatId}
                  : {'type': 'room', 'room_id': roomChatId}))
          .timeout(const Duration(seconds: 12));
      _absorb(r);
      if (r.statusCode == 200 && _isJsonBody(r)) {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is Map && j['success'] == true) {
          return const ApiResult(ApiStatus.ok, data: true);
        }
        if (j is Map && j['error'] != null) {
          return ApiResult(ApiStatus.error, message: '${j['error']}');
        }
      }
      return const ApiResult(ApiStatus.error, message: 'fail');
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  // ==================== v1.0.9 endpoints ====================

  /// GET /api/privacy — {privacy_last_seen, privacy_dm}
  Future<ApiResult<Map<String, dynamic>>> getPrivacy() async {
    try {
      final r = await _client
          .get(Uri.parse('$kBaseUrl/api/privacy'), headers: _headers)
          .timeout(const Duration(seconds: 12));
      _absorb(r);
      if (r.statusCode == 200 && _isJsonBody(r)) {
        return ApiResult(ApiStatus.ok,
            data: Map<String, dynamic>.from(jsonDecode(utf8.decode(r.bodyBytes))));
      }
      if (r.statusCode == 302) return const ApiResult(ApiStatus.unauthorized);
      return const ApiResult(ApiStatus.error);
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// POST /api/privacy — {privacy_last_seen: all|contacts|nobody, privacy_dm: …}
  Future<ApiResult<bool>> setPrivacy(
      {String? lastSeen, String? dm}) async {
    try {
      final r = await _client
          .post(Uri.parse('$kBaseUrl/api/privacy'),
              headers: {
                ..._headers,
                'Content-Type': 'application/json; charset=utf-8',
              },
              body: jsonEncode({
                if (lastSeen != null) 'privacy_last_seen': lastSeen,
                if (dm != null) 'privacy_dm': dm,
              }))
          .timeout(const Duration(seconds: 12));
      _absorb(r);
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      return ApiResult(j is Map && j['success'] == true
          ? ApiStatus.ok
          : ApiStatus.error,
          data: j is Map && j['success'] == true);
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// GET /api/sessions — {sessions:[{sid,ip,device,ua,created_at,last_active,is_current}]}
  Future<ApiResult<List<Map<String, dynamic>>>> sessions() async {
    try {
      final r = await _client
          .get(Uri.parse('$kBaseUrl/api/sessions'), headers: _headers)
          .timeout(const Duration(seconds: 12));
      _absorb(r);
      if (r.statusCode == 200 && _isJsonBody(r)) {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        final list = (j is Map ? j['sessions'] as List? : null) ?? const [];
        return ApiResult(ApiStatus.ok,
            data: list
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList());
      }
      if (r.statusCode == 302) return const ApiResult(ApiStatus.unauthorized);
      return const ApiResult(ApiStatus.error);
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// POST /api/sessions/revoke — {sid}
  Future<ApiResult<bool>> revokeSession(String sid) => _postJsonBool(
      '/api/sessions/revoke', {'sid': sid});

  /// POST /api/sessions/revoke_all — {keep_sid}
  Future<ApiResult<bool>> revokeAllSessions(String keepSid) =>
      _postJsonBool('/api/sessions/revoke_all', {'keep_sid': keepSid});

  /// POST /room/<id>/set_slowmode — {seconds}
  Future<ApiResult<Map<String, dynamic>>> setSlowMode(
      String roomId, int seconds) async {
    try {
      final r = await _client
          .post(Uri.parse('$kBaseUrl/room/$roomId/set_slowmode'),
              headers: {
                ..._headers,
                'Content-Type': 'application/json; charset=utf-8',
              },
              body: jsonEncode({'seconds': seconds}))
          .timeout(const Duration(seconds: 12));
      _absorb(r);
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is Map && j['success'] == true) {
        return ApiResult(ApiStatus.ok,
            data: Map<String, dynamic>.from(j['settings'] ?? {}));
      }
      return ApiResult(ApiStatus.error, message: j is Map ? '${j['error']}' : 'fail');
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// POST /room/<id>/set_perms — {only_admins, send_media, send_gifs}
  Future<ApiResult<Map<String, dynamic>>> setRoomPerms(String roomId,
      {bool? onlyAdmins, bool? sendMedia, bool? sendGifs}) async {
    try {
      final r = await _client
          .post(Uri.parse('$kBaseUrl/room/$roomId/set_perms'),
              headers: {
                ..._headers,
                'Content-Type': 'application/json; charset=utf-8',
              },
              body: jsonEncode({
                if (onlyAdmins != null) 'only_admins': onlyAdmins,
                if (sendMedia != null) 'send_media': sendMedia,
                if (sendGifs != null) 'send_gifs': sendGifs,
              }))
          .timeout(const Duration(seconds: 12));
      _absorb(r);
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is Map && j['success'] == true) {
        return ApiResult(ApiStatus.ok,
            data: Map<String, dynamic>.from(j['settings'] ?? {}));
      }
      return ApiResult(ApiStatus.error, message: j is Map ? '${j['error']}' : 'fail');
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// POST /room/<id>/promote — {user_id, title, permissions:[…]}
  Future<ApiResult<bool>> promoteAdvanced(String roomId, int userId,
      {String title = '', List<String> permissions = const []}) async {
    try {
      final r = await _client
          .post(Uri.parse('$kBaseUrl/room/$roomId/promote'),
              headers: {
                ..._headers,
                'Content-Type': 'application/json; charset=utf-8',
              },
              body: jsonEncode({
                'user_id': userId,
                'title': title,
                'permissions': permissions,
              }))
          .timeout(const Duration(seconds: 12));
      _absorb(r);
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      return ApiResult(
          j is Map && j['success'] == true ? ApiStatus.ok : ApiStatus.error,
          data: j is Map && j['success'] == true,
          message: j is Map ? '${j['error'] ?? ''}' : null);
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// POST /room/<id>/edit_admin — {user_id, title, permissions}
  Future<ApiResult<bool>> editAdmin(String roomId, int userId,
      {String? title, List<String>? permissions}) async {
    try {
      final r = await _client
          .post(Uri.parse('$kBaseUrl/room/$roomId/edit_admin'),
              headers: {
                ..._headers,
                'Content-Type': 'application/json; charset=utf-8',
              },
              body: jsonEncode({
                'user_id': userId,
                if (title != null) 'title': title,
                if (permissions != null) 'permissions': permissions,
              }))
          .timeout(const Duration(seconds: 12));
      _absorb(r);
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      return ApiResult(
          j is Map && j['success'] == true ? ApiStatus.ok : ApiStatus.error,
          data: j is Map && j['success'] == true,
          message: j is Map ? '${j['error'] ?? ''}' : null);
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  /// POST /report_user/<username> — AJAX header → JSON success.
  Future<ApiResult<bool>> reportUser(String username) async {
    try {
      final r = await _client
          .get(Uri.parse('$kBaseUrl/report_user/$username'),
              headers: {..._headers, 'X-Requested-With': 'XMLHttpRequest'})
          .timeout(const Duration(seconds: 12));
      _absorb(r);
      if (r.statusCode == 200 && _isJsonBody(r)) {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        return ApiResult(j is Map && j['success'] == true
            ? ApiStatus.ok
            : ApiStatus.error,
            data: j is Map && j['success'] == true);
      }
      return const ApiResult(ApiStatus.error);
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }

  Future<ApiResult<bool>> _postJsonBool(String path, Map<String, dynamic> body) async {
    try {
      final r = await _client
          .post(Uri.parse('$kBaseUrl$path'),
              headers: {
                ..._headers,
                'Content-Type': 'application/json; charset=utf-8',
              },
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 12));
      _absorb(r);
      if (r.statusCode == 200 && _isJsonBody(r)) {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        return ApiResult(j is Map && j['success'] == true
            ? ApiStatus.ok
            : ApiStatus.error,
            data: j is Map && j['success'] == true);
      }
      return const ApiResult(ApiStatus.error);
    } catch (e) {
      return ApiResult(ApiStatus.networkError, message: '$e');
    }
  }
}

/// MultipartRequest that reports upload progress while the body streams out.
class _ProgressMultipartRequest extends http.MultipartRequest {
  final void Function(int sent, int total)? onProgress;
  _ProgressMultipartRequest(super.method, super.url, {this.onProgress});

  @override
  http.ByteStream finalize() {
    final base = super.finalize();
    final total = contentLength;
    int sent = 0;
    final controller = StreamController<List<int>>();
    base.listen(
      (chunk) {
        sent += chunk.length;
        try {
          onProgress?.call(sent, total);
        } catch (_) {}
        controller.add(chunk);
      },
      onDone: controller.close,
      onError: controller.addError,
      cancelOnError: true,
    );
    return http.ByteStream(controller.stream);
  }
}
