"""Real Magazine Feed & User Profile Posts API for RAVI.

Replaces the old hardcoded static magazine posts and empty profile tabs with
SQLite-backed posts, likes, replies, views, search, and publishing.
"""

from __future__ import annotations

from datetime import datetime
from flask import jsonify, request
from flask_login import current_user, login_required

from security import sanitize_client_file_url

MAX_POST_LEN = 4000
MAX_REPLY_LEN = 1000
MAX_CHANNEL_LEN = 60


def init_magazine_tables(db_conn_fn) -> None:
    """Create magazine/posts tables & indexes idempotently (safe on existing chat.db)."""
    conn = db_conn_fn()
    c = conn.cursor()
    c.execute('''CREATE TABLE IF NOT EXISTS posts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        channel_name TEXT DEFAULT '',
        content TEXT NOT NULL,
        image_url TEXT DEFAULT '',
        category TEXT DEFAULT 'general',
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        is_deleted INTEGER DEFAULT 0
    )''')
    c.execute('''CREATE TABLE IF NOT EXISTS post_likes (
        post_id INTEGER NOT NULL,
        user_id INTEGER NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (post_id, user_id)
    )''')
    c.execute('''CREATE TABLE IF NOT EXISTS post_replies (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        post_id INTEGER NOT NULL,
        user_id INTEGER NOT NULL,
        content TEXT NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        is_deleted INTEGER DEFAULT 0
    )''')
    c.execute('''CREATE TABLE IF NOT EXISTS post_views (
        post_id INTEGER NOT NULL,
        user_id INTEGER NOT NULL,
        PRIMARY KEY (post_id, user_id)
    )''')
    c.execute('CREATE INDEX IF NOT EXISTS idx_posts_user ON posts(user_id, id DESC)')
    c.execute('CREATE INDEX IF NOT EXISTS idx_posts_created ON posts(is_deleted, id DESC)')
    c.execute('CREATE INDEX IF NOT EXISTS idx_post_replies_post ON post_replies(post_id, id ASC)')
    conn.commit()
    conn.close()


def get_user_posts_count(db_conn_fn, user_id: int) -> int:
    try:
        conn = db_conn_fn()
        c = conn.cursor()
        c.execute('SELECT COUNT(*) FROM posts WHERE user_id = ? AND is_deleted = 0', (user_id,))
        row = c.fetchone()
        conn.close()
        return int(row[0] if row else 0)
    except Exception:
        return 0


def _serialize_posts(conn, rows, viewer_id: int) -> list[dict]:
    if not rows:
        return []
    c = conn.cursor()
    pids = [r[0] for r in rows]
    ph = ','.join('?' for _ in pids)

    likes_map: dict[int, int] = {}
    liked_set: set[int] = set()
    replies_map: dict[int, int] = {}
    views_map: dict[int, int] = {}
    pro_ids: set[int] = set()

    c.execute(f'SELECT post_id, COUNT(*) FROM post_likes WHERE post_id IN ({ph}) GROUP BY post_id', pids)
    for pid, cnt in c.fetchall():
        likes_map[pid] = cnt

    c.execute(f'SELECT post_id FROM post_likes WHERE user_id = ? AND post_id IN ({ph})', [viewer_id] + pids)
    liked_set = {r[0] for r in c.fetchall()}

    c.execute(
        f'SELECT post_id, COUNT(*) FROM post_replies WHERE is_deleted = 0 AND post_id IN ({ph}) GROUP BY post_id',
        pids,
    )
    for pid, cnt in c.fetchall():
        replies_map[pid] = cnt

    c.execute(f'SELECT post_id, COUNT(*) FROM post_views WHERE post_id IN ({ph}) GROUP BY post_id', pids)
    for pid, cnt in c.fetchall():
        views_map[pid] = cnt

    uids = list({r[1] for r in rows})
    if uids:
        uph = ','.join('?' for _ in uids)
        try:
            c.execute(f'SELECT DISTINCT user_id FROM pro_accounts WHERE is_active = 1 AND user_id IN ({uph})', uids)
            pro_ids = {r[0] for r in c.fetchall()}
        except Exception:
            pro_ids = set()

    # Record viewer views in batch
    try:
        c.executemany(
            'INSERT OR IGNORE INTO post_views (post_id, user_id) VALUES (?, ?)',
            [(pid, viewer_id) for pid in pids],
        )
        conn.commit()
        for pid in pids:
            views_map[pid] = max(views_map.get(pid, 0), 1)
    except Exception:
        pass

    out = []
    for r in rows:
        pid, uid, channel_name, content, image_url, category, created_at, username, name, avatar, is_admin = r
        display_name = (name or '').strip() or username
        out.append({
            'id': pid,
            'user_id': uid,
            'username': username,
            'display_name': display_name,
            'avatar': avatar or 'default.png',
            'channel': (channel_name or '').strip() or display_name,
            'content': content,
            'image_url': image_url or '',
            'category': category or 'general',
            'created_at': str(created_at or ''),
            'likes_count': likes_map.get(pid, 0),
            'liked_by_me': pid in liked_set,
            'replies_count': replies_map.get(pid, 0),
            'views_count': views_map.get(pid, 0),
            'is_official': bool(is_admin),
            'is_pro': uid in pro_ids,
            'is_mine': uid == viewer_id,
        })
    return out


def register_magazine_routes(app, db_conn_fn, get_user_fn) -> None:
    """Attach Magazine & Profile Posts endpoints to the Flask app."""

    @app.route('/api/magazine/posts', methods=['GET'])
    @login_required
    def api_magazine_posts():
        q = (request.args.get('q') or '').strip()
        category = (request.args.get('category') or '').strip().lower()
        try:
            before_id = int(request.args.get('before', 0) or 0)
        except Exception:
            before_id = 0
        try:
            limit = min(max(int(request.args.get('limit', 30) or 30), 1), 60)
        except Exception:
            limit = 30

        conn = db_conn_fn()
        c = conn.cursor()
        sql = '''SELECT p.id, p.user_id, p.channel_name, p.content, p.image_url, p.category,
                        p.created_at, u.username, u.name, u.avatar, u.is_admin
                 FROM posts p
                 JOIN users u ON p.user_id = u.id
                 WHERE p.is_deleted = 0 AND u.is_banned = 0'''
        params: list = []
        if before_id > 0:
            sql += ' AND p.id < ?'
            params.append(before_id)
        if category and category != 'all':
            sql += ' AND LOWER(p.category) = ?'
            params.append(category)
        if q:
            like_q = f'%{q}%'
            sql += ' AND (p.content LIKE ? OR p.channel_name LIKE ? OR u.username LIKE ? OR u.name LIKE ?)'
            params.extend([like_q, like_q, like_q, like_q])
        sql += ' ORDER BY p.id DESC LIMIT ?'
        params.append(limit)
        c.execute(sql, params)
        rows = c.fetchall()
        posts = _serialize_posts(conn, rows, current_user.id)
        conn.close()
        return jsonify({'posts': posts})

    @app.route('/api/magazine/posts', methods=['POST'])
    @login_required
    def api_create_magazine_post():
        data = request.get_json(silent=True) or request.form or {}
        content = (data.get('content') or '').strip()[:MAX_POST_LEN]
        image_url = sanitize_client_file_url(data.get('image_url')) or ''
        channel_name = (data.get('channel') or '').strip()[:MAX_CHANNEL_LEN]
        category = (data.get('category') or 'general').strip().lower()[:24] or 'general'
        if not content and not image_url:
            return jsonify({'error': 'متن یا تصویر پست الزامی است'}), 400
        now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        conn = db_conn_fn()
        c = conn.cursor()
        c.execute(
            '''INSERT INTO posts (user_id, channel_name, content, image_url, category, created_at)
               VALUES (?, ?, ?, ?, ?, ?)''',
            (current_user.id, channel_name, content, image_url, category, now),
        )
        post_id = c.lastrowid
        conn.commit()
        c.execute(
            '''SELECT p.id, p.user_id, p.channel_name, p.content, p.image_url, p.category,
                      p.created_at, u.username, u.name, u.avatar, u.is_admin
               FROM posts p JOIN users u ON p.user_id = u.id WHERE p.id = ?''',
            (post_id,),
        )
        rows = c.fetchall()
        post = _serialize_posts(conn, rows, current_user.id)[0]
        conn.close()
        return jsonify({'success': True, 'post': post}), 201

    @app.route('/api/magazine/posts/<int:post_id>', methods=['DELETE'])
    @app.route('/api/magazine/posts/<int:post_id>/delete', methods=['POST'])
    @login_required
    def api_delete_magazine_post(post_id: int):
        conn = db_conn_fn()
        c = conn.cursor()
        c.execute('SELECT user_id, is_deleted FROM posts WHERE id = ?', (post_id,))
        row = c.fetchone()
        if not row or row[1]:
            conn.close()
            return jsonify({'error': 'پست پیدا نشد'}), 404
        if row[0] != current_user.id and not current_user.is_admin:
            conn.close()
            return jsonify({'error': 'دسترسی غیرمجاز'}), 403
        c.execute('UPDATE posts SET is_deleted = 1 WHERE id = ?', (post_id,))
        conn.commit()
        conn.close()
        return jsonify({'success': True})

    @app.route('/api/magazine/posts/<int:post_id>/like', methods=['POST'])
    @login_required
    def api_toggle_post_like(post_id: int):
        conn = db_conn_fn()
        c = conn.cursor()
        c.execute('SELECT 1 FROM posts WHERE id = ? AND is_deleted = 0', (post_id,))
        if not c.fetchone():
            conn.close()
            return jsonify({'error': 'پست پیدا نشد'}), 404
        c.execute('SELECT 1 FROM post_likes WHERE post_id = ? AND user_id = ?', (post_id, current_user.id))
        if c.fetchone():
            c.execute('DELETE FROM post_likes WHERE post_id = ? AND user_id = ?', (post_id, current_user.id))
            liked = False
        else:
            c.execute(
                'INSERT INTO post_likes (post_id, user_id, created_at) VALUES (?, ?, ?)',
                (post_id, current_user.id, datetime.now().strftime('%Y-%m-%d %H:%M:%S')),
            )
            liked = True
        c.execute('SELECT COUNT(*) FROM post_likes WHERE post_id = ?', (post_id,))
        cnt = c.fetchone()[0]
        conn.commit()
        conn.close()
        return jsonify({'success': True, 'liked': liked, 'likes_count': cnt})

    @app.route('/api/magazine/posts/<int:post_id>/replies', methods=['GET'])
    @login_required
    def api_get_post_replies(post_id: int):
        conn = db_conn_fn()
        c = conn.cursor()
        c.execute('SELECT 1 FROM posts WHERE id = ? AND is_deleted = 0', (post_id,))
        if not c.fetchone():
            conn.close()
            return jsonify({'error': 'پست پیدا نشد'}), 404
        c.execute(
            '''SELECT r.id, r.user_id, r.content, r.created_at, u.username, u.name, u.avatar, u.is_admin
               FROM post_replies r JOIN users u ON r.user_id = u.id
               WHERE r.post_id = ? AND r.is_deleted = 0
               ORDER BY r.id ASC LIMIT 100''',
            (post_id,),
        )
        replies = [
            {
                'id': r[0],
                'user_id': r[1],
                'content': r[2],
                'created_at': str(r[3] or ''),
                'username': r[4],
                'display_name': (r[5] or '').strip() or r[4],
                'avatar': r[6] or 'default.png',
                'is_official': bool(r[7]),
                'is_mine': r[1] == current_user.id,
            }
            for r in c.fetchall()
        ]
        conn.close()
        return jsonify({'replies': replies})

    @app.route('/api/magazine/posts/<int:post_id>/replies', methods=['POST'])
    @login_required
    def api_add_post_reply(post_id: int):
        data = request.get_json(silent=True) or request.form or {}
        content = (data.get('content') or '').strip()[:MAX_REPLY_LEN]
        if not content:
            return jsonify({'error': 'متن دیدگاه خالی است'}), 400
        conn = db_conn_fn()
        c = conn.cursor()
        c.execute('SELECT 1 FROM posts WHERE id = ? AND is_deleted = 0', (post_id,))
        if not c.fetchone():
            conn.close()
            return jsonify({'error': 'پست پیدا نشد'}), 404
        now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        c.execute(
            'INSERT INTO post_replies (post_id, user_id, content, created_at) VALUES (?, ?, ?, ?)',
            (post_id, current_user.id, content, now),
        )
        rid = c.lastrowid
        conn.commit()
        conn.close()
        return jsonify({
            'success': True,
            'reply': {
                'id': rid,
                'user_id': current_user.id,
                'content': content,
                'created_at': now,
                'username': current_user.username,
                'display_name': (current_user.name or '').strip() or current_user.username,
                'avatar': current_user.avatar or 'default.png',
                'is_official': bool(current_user.is_admin),
                'is_mine': True,
            },
        }), 201

    @app.route('/api/users/<username>/posts', methods=['GET'])
    @login_required
    def api_user_posts(username: str):
        u = get_user_fn(username=username)
        if not u:
            return jsonify({'error': 'not_found'}), 404
        try:
            limit = min(max(int(request.args.get('limit', 30) or 30), 1), 60)
        except Exception:
            limit = 30
        conn = db_conn_fn()
        c = conn.cursor()
        c.execute(
            '''SELECT p.id, p.user_id, p.channel_name, p.content, p.image_url, p.category,
                      p.created_at, u.username, u.name, u.avatar, u.is_admin
               FROM posts p JOIN users u ON p.user_id = u.id
               WHERE p.user_id = ? AND p.is_deleted = 0
               ORDER BY p.id DESC LIMIT ?''',
            (u['id'], limit),
        )
        rows = c.fetchall()
        posts = _serialize_posts(conn, rows, current_user.id)
        conn.close()
        return jsonify({'posts': posts, 'count': len(posts)})
