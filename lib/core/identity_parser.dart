/// Tolerant parser for the `window.CURRENT_USER = {...}` block that the
/// RAVI backend injects into the index page.
///
/// WHY THIS EXISTS: the backend renders the block as a **JavaScript object
/// literal with UNQUOTED keys** —
///
/// ```js
/// window.CURRENT_USER = {
///     id: 35,
///     username: "probe_ravi_552",
///     name: "probe_ravi_552",
///     avatar: "default.png",
///     chat_bg: ""
///   };
/// ```
///
/// That is valid JS but **not valid JSON**, so `jsonDecode` throws and the
/// old parser reported every successful login/register as a failure. This
/// parser accepts both shapes (quoted JSON keys and bare-JS keys), extracting
/// the fields with anchored value regexes instead of rewriting the payload —
/// user-authored values (like a display name containing `,` or `:`) can never
/// break it.
library;

final RegExp _member = RegExp(
    r"""(?:^|[,{\s])(?:"([A-Za-z_][A-Za-z0-9_]*)"|([A-Za-z_][A-Za-z0-9_]*))\s*:\s*"""
    r"""(?:"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'|(-?\d+(?:\.\d+)?)|true|false|null)""");

String _unescape(String s) => s
    .replaceAllMapped(RegExp(r'\\(u[0-9a-fA-F]{4}|.)'), (m) {
      final g = m.group(1)!;
      switch (g[0]) {
        case 'n':
          return '\n';
        case 't':
          return '\t';
        case 'r':
          return '\r';
        case 'u':
          return String.fromCharCode(int.parse(g.substring(1), radix: 16));
        default:
          return g; // \" \\ \/ etc.
      }
    });

/// Extracts the identity fields from an index page.
/// Returns a flat map (`id`, `username`, `name`, `avatar`, `chat_bg`) or null
/// when the page has no usable CURRENT_USER block (e.g. logged-out page).
Map<String, String>? parseCurrentUser(String html) {
  if (html.isEmpty) return null;
  final start = html.indexOf('CURRENT_USER');
  if (start < 0) return null;
  final brace = html.indexOf('{', start);
  if (brace < 0) return null;

  // Walk to the matching closing brace (string-aware, escaped quotes safe).
  var depth = 0;
  var inStr = false;
  var end = -1;
  for (var i = brace; i < html.length; i++) {
    final ch = html[i];
    if (inStr) {
      if (ch == r'\') {
        i++;
      } else if (ch == '"') {
        inStr = false;
      }
      continue;
    }
    if (ch == '"') {
      inStr = true;
    } else if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) {
        end = i;
        break;
      }
    }
  }
  if (end < 0) return null;
  final block = html.substring(brace, end + 1);

  final out = <String, String>{};
  for (final m in _member.allMatches(block)) {
    final key = (m.group(1) ?? m.group(2))!;
    final raw = m.group(3) ?? m.group(4) ?? m.group(5) ?? '';
    out[key] = raw.startsWith(r'\') || raw.contains(r'\') ? _unescape(raw) : raw;
  }

  final username = out['username'] ?? '';
  if (username.isEmpty || username == 'null') return null;
  return out;
}
