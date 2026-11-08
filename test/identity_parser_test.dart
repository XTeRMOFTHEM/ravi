import 'package:flutter_test/flutter_test.dart';
import 'package:ravi/core/identity_parser.dart';

void main() {
  // Exact shape captured live from http://195.18.10.82:5000/ (logged in).
  const liveBlock = '''
  <script>
  window.CURRENT_USER = {
    id: 35,
    username: "probe_ravi_552",
    name: "probe_ravi_552",
    avatar: "default.png",
    chat_bg: ""
  };
  </script>''';

  test('parses the REAL live server block (unquoted JS keys)', () {
    final m = parseCurrentUser(liveBlock);
    expect(m, isNotNull);
    expect(m!['id'], '35');
    expect(m['username'], 'probe_ravi_552');
    expect(m['name'], 'probe_ravi_552');
    expect(m['avatar'], 'default.png');
    expect(m['chat_bg'], '');
  });

  test('parses proper JSON with quoted keys too (future-proof)', () {
    const j = 'window.CURRENT_USER = {"id": 7, "username": "ali", '
        '"name": "Ali", "avatar": "a.png", "chat_bg": ""};';
    final m = parseCurrentUser(j);
    expect(m, isNotNull);
    expect(m!['id'], '7');
    expect(m['username'], 'ali');
    expect(m['avatar'], 'a.png');
  });

  test('name containing colon/comma/escaped quote does not break parsing', () {
    const tricky = 'CURRENT_USER = { id: 3, username: "u1", '
        'name: "sa, id: 9, x: \\"q\\"", avatar: "", chat_bg: "" };';
    final m = parseCurrentUser(tricky);
    expect(m, isNotNull);
    expect(m!['id'], '3'); // NOT 9 from inside the string
    expect(m['name'], 'sa, id: 9, x: "q"');
    expect(m['username'], 'u1');
  });

  test('single-quoted values are handled', () {
    const s = "CURRENT_USER = { id: 9, username: 'sara', name: 'Sara', "
        "avatar: 'x.png', chat_bg: '' };";
    final m = parseCurrentUser(s);
    expect(m!['username'], 'sara');
    expect(m['id'], '9');
  });

  test('logged-out page (CURRENT_USER = null) returns null', () {
    expect(parseCurrentUser('window.CURRENT_USER = null;'), isNull);
    expect(parseCurrentUser('window.CURRENT_USER || {}'), isNull);
    expect(parseCurrentUser(''), isNull);
  });

  test('realistic full page (lots of other username mentions) still works',
      () {
    const page = '<!doctype html><html><body>'
        '<script>var config = {"username": "decoy"};</script>'
        '<div data-user="another">"@someone said hi"</div>'
        '$liveBlock'
        '<script>app.init(CURRENT_USER || {});</script></body></html>';
    final m = parseCurrentUser(page);
    expect(m!['username'], 'probe_ravi_552');
  });
}
