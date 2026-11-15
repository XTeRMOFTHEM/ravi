"""Comprehensive security, regression, Socket.IO, and feature tests for RAVI backend."""

from __future__ import annotations

import io
import os
import sys
import tempfile
from pathlib import Path

import pytest


@pytest.fixture(scope='module')
def ravi_env():
    """Import backend/app.py isolated against a brand-new temporary SQLite DB & upload dir."""
    tmp = tempfile.TemporaryDirectory(prefix='ravi_test_')
    db_path = os.path.join(tmp.name, 'test_chat.db')
    upload_dir = os.path.join(tmp.name, 'uploads')
    os.makedirs(upload_dir, exist_ok=True)
    os.environ['RAVI_DB_PATH'] = db_path
    os.environ['RAVI_UPLOAD_FOLDER'] = upload_dir
    os.environ['RAVI_SECRET_KEY'] = 'test-secret-key-for-ravi-suite'

    backend_dir = str(Path(__file__).resolve().parents[1])
    if backend_dir not in sys.path:
        sys.path.insert(0, backend_dir)

    import app as ravi_app
    ravi_app.app.config['TESTING'] = True
    yield ravi_app, db_path, upload_dir
    tmp.cleanup()


def _register(client, username, password='password123', name='', gender='other'):
    return client.post(
        '/register',
        data={'username': username, 'password': password, 'name': name, 'gender': gender},
        follow_redirects=False,
    )


def _login(client, username, password='password123'):
    return client.post(
        '/login',
        data={'username': username, 'password': password},
        follow_redirects=False,
    )


# ==================== 1. Fresh DB, Registration, Identity & Logout ====================

def test_fresh_db_get_user_column_order_and_last_seen_no_crash(ravi_env):
    """Regression: get_user() positional column shift crashed int(session_epoch) after last_seen was set."""
    ravi_app, _, _ = ravi_env
    c = ravi_app.app.test_client()
    resp = _register(c, 'alice_one', name='آلیس راوی')
    assert resp.status_code == 302

    # Verify / returns 200 (templates exist) with CURRENT_USER
    home = c.get('/')
    assert home.status_code == 200
    assert b'window.CURRENT_USER' in home.data

    # Verify /api/me returns exact display name and clean JSON
    me = c.get('/api/me')
    assert me.status_code == 200
    data = me.get_json()
    assert data['username'] == 'alice_one'
    assert data['name'] == 'آلیس راوی'
    assert data['privacy_last_seen'] == 'all'
    assert data['privacy_dm'] == 'all'

    # Simulate disconnect writing ISO timestamp into last_seen
    conn = ravi_app.db_conn()
    conn.execute("UPDATE users SET last_seen = '2026-11-15 12:34:56' WHERE username = 'alice_one'")
    conn.commit()
    conn.close()

    # Must NOT raise ValueError on subsequent authenticated request
    me2 = c.get('/api/me')
    assert me2.status_code == 200
    assert me2.get_json()['username'] == 'alice_one'


def test_case_insensitive_username_uniqueness_and_logout(ravi_env):
    ravi_app, _, _ = ravi_env
    c = ravi_app.app.test_client()
    # Register duplicate with different case must fail
    r = _register(c, 'ALICE_ONE')
    assert r.status_code == 302
    assert '/register' in (r.headers.get('Location') or '')

    # Register bob, verify POST /logout invalidates session
    r2 = _register(c, 'bob_two', name='Bob')
    assert r2.status_code == 302
    assert c.get('/api/me').status_code == 200
    out = c.post('/logout')
    assert out.status_code == 200
    assert out.get_json()['success'] is True
    assert c.get('/api/me').status_code in (302, 401)


# ==================== 2. Critical Security Hardening ====================

def test_unauthenticated_endpoints_and_media_blocked(ravi_env):
    ravi_app, _, upload_dir = ravi_env
    anon = ravi_app.app.test_client()

    # Sensitive metadata routes require login
    assert anon.get('/api/user_exists/alice_one').status_code in (302, 401)
    assert anon.get('/api/user_profile/alice_one').status_code in (302, 401)
    assert anon.get('/get_user_tags/1').status_code in (302, 401)
    assert anon.get('/check_pro/1').status_code in (302, 401)

    # /api/health does NOT leak user/message counts
    h = anon.get('/api/health')
    assert h.status_code == 200
    hj = h.get_json()
    assert hj['status'] == 'ok'
    assert 'users' not in hj and 'messages' not in hj

    # Upload a file as alice, verify anonymous cannot download via /files/ or /static/uploads/
    secret_file = os.path.join(upload_dir, 'secret_dm_pic.png')
    with open(secret_file, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\nfake')
    assert anon.get('/files/secret_dm_pic.png').status_code in (302, 401)
    assert anon.get('/static/uploads/secret_dm_pic.png').status_code == 401


def test_security_helpers_path_traversal_and_cookie_theft_url_rejected(ravi_env):
    ravi_app, db_path, upload_dir = ravi_env
    from security import (
        is_safe_upload_url,
        safe_redirect_target,
        safe_remove_upload_file,
        sanitize_client_file_type,
        sanitize_upload_ext,
    )

    assert is_safe_upload_url('/static/uploads/1_2026_abcd.png') is True
    assert is_safe_upload_url('https://evil.com/steal.png') is False
    assert is_safe_upload_url('/static/uploads/../../chat.db') is False
    assert is_safe_upload_url('/static/uploads/sub/a.png') is False
    assert is_safe_upload_url('/static/uploads/a.png?x=1') is False

    # Attempt to delete DB via traversal must return False and leave DB intact
    assert safe_remove_upload_file(upload_dir, '/static/uploads/../test_chat.db') is False
    assert os.path.exists(db_path)

    # Client cannot spoof sys_* file types
    assert sanitize_client_file_type('sys_join_link', False) == 'text'
    assert sanitize_client_file_type('sys_ban', True) == 'file'
    assert sanitize_client_file_type('image', True) == 'image'

    # Extension sanitization blocks trailing space bypass
    assert sanitize_upload_ext('evil.html ') == 'html'
    assert sanitize_upload_ext('evil.svg...') == 'svg'

    # Open redirect blocked
    assert safe_redirect_target('https://evil.com/phish', 'ravi.local', '/') == '/'
    assert safe_redirect_target('https://ravi.local/profile/a', 'ravi.local', '/') == '/profile/a'


def test_socket_blocks_unauthenticated_and_malicious_payloads(ravi_env):
    ravi_app, db_path, _ = ravi_env

    # Unauthenticated socket must be rejected
    anon_sio = ravi_app.socketio.test_client(ravi_app.app)
    assert not anon_sio.is_connected()

    # Log in alice and bob
    c_alice = ravi_app.app.test_client()
    assert _login(c_alice, 'alice_one').status_code == 302
    c_bob = ravi_app.app.test_client()
    assert _login(c_bob, 'bob_two').status_code == 302

    c_charlie = ravi_app.app.test_client()
    assert _register(c_charlie, 'charlie_three', name='Charlie').status_code == 302

    # Start PV between alice and bob and send a secret DM
    pv_resp = c_alice.get('/api/start_pv/bob_two')
    assert pv_resp.status_code == 200
    pv_id = pv_resp.get_json()['chat_id']

    sio_alice = ravi_app.socketio.test_client(ravi_app.app, flask_test_client=c_alice)
    sio_bob = ravi_app.socketio.test_client(ravi_app.app, flask_test_client=c_bob)
    sio_charlie = ravi_app.socketio.test_client(ravi_app.app, flask_test_client=c_charlie)
    assert sio_alice.is_connected() and sio_bob.is_connected() and sio_charlie.is_connected()

    sio_alice.emit('join_pv', {'chat_id': pv_id})
    sio_alice.emit('send_message', {
        'private_chat_id': pv_id,
        'message': 'SUPER_SECRET_DM_42',
        'client_msg_id': 'pv_secret_1',
    })
    pv_msgs = c_alice.get(f'/api/pv/{pv_id}/messages').get_json()
    assert any(m['message'] == 'SUPER_SECRET_DM_42' for m in pv_msgs)
    secret_msg_id = pv_msgs[-1]['id']

    # Verify is_self is FALSE for bob (receiver) when alice started the PV!
    bob_pvs = c_bob.get('/my_pvs').get_json()
    target_pv = [p for p in bob_pvs if p['id'] == pv_id][0]
    assert target_pv['is_self'] is False
    assert target_pv['last_time_iso'] != ''

    # Verify Saved Messages IS is_self=True
    saved = c_bob.get('/api/saved_chat').get_json()
    bob_pvs2 = c_bob.get('/my_pvs').get_json()
    saved_row = [p for p in bob_pvs2 if p['id'] == saved['chat_id']][0]
    assert saved_row['is_self'] is True

    # Attack 1: Charlie tries cross-chat reply_to exfiltration against Alice-Bob secret DM
    sio_charlie.get_received()
    sio_charlie.emit('send_message', {
        'room': 'general',
        'message': 'exfil attempt',
        'reply_to': secret_msg_id,
        'client_msg_id': 'exfil_1',
    })
    gen_msgs = c_charlie.get('/api/general_messages').get_json()
    exfil_msg = [m for m in gen_msgs if m['message'] == 'exfil attempt'][0]
    assert 'reply_text' not in exfil_msg or 'SUPER_SECRET_DM_42' not in str(exfil_msg)

    # Attack 2: Charlie tries sending external cookie-theft file_url
    sio_charlie.get_received()
    sio_charlie.emit('send_message', {
        'room': 'general',
        'message': 'steal cookies',
        'file_url': 'https://attacker.evil/steal.jpg',
        'file_type': 'image',
        'client_msg_id': 'steal_1',
    })
    errs = [e for e in sio_charlie.get_received() if e['name'] == 'error']
    assert any(e['args'][0].get('code') == 'invalid_file_url' for e in errs)

    # Attack 3: Charlie tries room injection to pv_<pv_id> with private_chat_id=None
    sio_charlie.get_received()
    sio_charlie.emit('send_message', {
        'room': f'pv_{pv_id}',
        'message': 'injected into pv',
        'client_msg_id': 'inj_1',
    })
    errs2 = [e for e in sio_charlie.get_received() if e['name'] == 'error']
    assert any(e['args'][0].get('code') == 'invalid_room' for e in errs2)

    # Attack 4: Charlie tries path traversal file_url
    sio_charlie.get_received()
    sio_charlie.emit('send_message', {
        'room': 'general',
        'message': 'del db',
        'file_url': '/static/uploads/../test_chat.db',
        'file_type': 'file',
    })
    errs3 = [e for e in sio_charlie.get_received() if e['name'] == 'error']
    assert any(e['args'][0].get('code') == 'invalid_file_url' for e in errs3)
    assert os.path.exists(db_path)

    sio_alice.disconnect()
    sio_bob.disconnect()
    sio_charlie.disconnect()


# ==================== 3. Rooms, Channels, Permissions & Reply Index ====================

def test_rooms_api_channel_can_post_counts_unread_and_reply_index(ravi_env):
    ravi_app, _, _ = ravi_env
    c_alice = ravi_app.app.test_client()
    assert _login(c_alice, 'alice_one').status_code == 302
    c_bob = ravi_app.app.test_client()
    assert _login(c_bob, 'bob_two').status_code == 302

    # Alice creates a channel
    cr = c_alice.post('/create_private_room', data={'name': 'NewsCh', 'type': 'channel'})
    assert cr.status_code == 200
    ch_id = cr.get_json()['room_id']

    # Bob joins the channel
    assert c_bob.post('/join_private_room', data={'room_id': ch_id}).status_code == 200

    # /api/rooms for Alice MUST show member_count == 2 and can_post == True!
    alice_rooms = c_alice.get('/api/rooms').get_json()
    ch_a = [r for r in alice_rooms if r['room_id'] == ch_id][0]
    assert ch_a['member_count'] == 2
    assert ch_a['can_post'] is True

    # /api/rooms for Bob MUST show member_count == 2 and can_post == False!
    bob_rooms = c_bob.get('/api/rooms').get_json()
    ch_b = [r for r in bob_rooms if r['room_id'] == ch_id][0]
    assert ch_b['member_count'] == 2
    assert ch_b['can_post'] is False

    # Alice creates a group, promotes Bob with only delete_messages (no promote, no change_info)
    gr = c_alice.post('/create_private_room', data={'name': 'DevGroup', 'type': 'group'})
    g_id = gr.get_json()['room_id']
    assert c_bob.post('/join_private_room', data={'room_id': g_id}).status_code == 200

    # Regular member Bob must NOT see banned list even when visibility == 'all'
    mem_bob = c_bob.get(f'/room/{g_id}/members').get_json()
    assert mem_bob['room_id'] == g_id
    assert mem_bob['banned'] == []
    alice_row = [m for m in mem_bob['members'] if m['username'] == 'alice_one'][0]
    assert alice_row['is_owner'] is True  # real JSON boolean!

    # Alice posts a message in the group and replies to it; verify reply snapshot loads from r[15] (not r[14])!
    sio_alice = ravi_app.socketio.test_client(ravi_app.app, flask_test_client=c_alice)
    sio_alice.emit('join_group_room', {'room_id': g_id})
    sio_alice.emit('send_message', {'room': f'private_{g_id}', 'message': 'Parent msg', 'client_msg_id': 'g1'})
    g_msgs1 = c_alice.get(f'/api/room/{g_id}/messages').get_json()['messages']
    parent_id = [m for m in g_msgs1 if m['message'] == 'Parent msg'][0]['message_id']

    sio_alice.emit('send_message', {
        'room': f'private_{g_id}',
        'message': 'Child reply',
        'reply_to': parent_id,
        'client_msg_id': 'g2',
    })
    g_msgs2 = c_alice.get(f'/api/room/{g_id}/messages').get_json()['messages']
    child = [m for m in g_msgs2 if m['message'] == 'Child reply'][0]
    assert child.get('reply_to') == parent_id
    assert child.get('reply_text') == 'Parent msg'

    # Bob's unread count for this group in /api/rooms must be > 0 (was always 0 before!)
    bob_rooms2 = c_bob.get('/api/rooms').get_json()
    g_b = [r for r in bob_rooms2 if r['room_id'] == g_id][0]
    assert g_b['unread'] >= 2

    # Promote Bob with ONLY 'promote' (not 'ban_members'/'change_info')
    bob_uid = c_bob.get('/api/me').get_json()['id']
    pr_res = c_alice.post(f'/room/{g_id}/promote', json={
        'user_id': bob_uid,
        'title': 'Mod',
        'permissions': ['promote'],
    })
    assert pr_res.status_code == 200

    # Bob MUST NOT be able to edit Alice's (owner's) message in the group
    ed_res = c_bob.post(f'/edit_message/{parent_id}', json={'new_text': 'hacked'})
    assert ed_res.status_code == 403

    # Bob MUST NOT be able to rename room without change_info
    ren_fail = c_bob.post(f'/room/{g_id}/rename', json={'name': 'Hijacked'})
    assert ren_fail.status_code == 403

    # Alice grants Bob change_info -> now Bob CAN rename
    assert c_alice.post(f'/room/{g_id}/edit_admin', json={
        'user_id': bob_uid,
        'title': 'Mod',
        'permissions': ['change_info'],
    }).status_code == 200
    assert c_bob.post(f'/room/{g_id}/rename', json={'name': 'DevGroup v2'}).status_code == 200

    # Bob (non-owner) CANNOT demote or edit admins
    assert c_bob.post(f'/room/{g_id}/demote', json={'user_id': bob_uid}).status_code == 403

    sio_alice.disconnect()


# ==================== 4. Upload Security & AI Hardening ====================

def test_upload_blocks_banned_ext_and_ai_blocks_dos_and_non_pro(ravi_env):
    ravi_app, _, _ = ravi_env
    c_bob = ravi_app.app.test_client()
    assert _login(c_bob, 'bob_two').status_code == 302

    # Banned extension with trailing space bypass attempt must be rejected
    bad_up = c_bob.post(
        '/upload_image',
        data={'image': (io.BytesIO(b'<script>alert(1)</script>'), 'xss.html ')},
        content_type='multipart/form-data',
    )
    assert bad_up.status_code == 400

    # Valid upload works and returns local /static/uploads/ URL
    good_up = c_bob.post(
        '/upload_image',
        data={'image': (io.BytesIO(b'\x89PNG\r\n\x1a\n1234567890'), 'pic.png')},
        content_type='multipart/form-data',
    )
    assert good_up.status_code == 200
    assert good_up.get_json()['file_url'].startswith('/static/uploads/')

    # AI math DoS (huge exponent) must be safely rejected without hanging CPU
    ai_dos = c_bob.post('/api/ai_chat', json={'message': 'توان 999999 به 999999'})
    assert ai_dos.status_code == 200
    assert 'بزرگ' in ai_dos.get_json()['reply']

    # Non-Pro Bob must get 403 on AI PRO
    pro_deny = c_bob.post('/api/ai_pro_chat', json={'message': 'hi'})
    assert pro_deny.status_code == 403


# ==================== 5. Real Magazine Feed & Profile Posts ====================

def test_magazine_and_profile_posts_crud_likes_replies(ravi_env):
    ravi_app, _, _ = ravi_env
    c_alice = ravi_app.app.test_client()
    assert _login(c_alice, 'alice_one').status_code == 302
    c_bob = ravi_app.app.test_client()
    assert _login(c_bob, 'bob_two').status_code == 302

    # Alice publishes a real Magazine post
    created = c_alice.post('/api/magazine/posts', json={
        'channel': 'RAVI Tech',
        'content': 'سلام دنیا! نسخه جدید راوی منتشر شد.',
        'category': 'tech',
    })
    assert created.status_code == 201
    post = created.get_json()['post']
    pid = post['id']
    assert post['username'] == 'alice_one'
    assert post['likes_count'] == 0

    # Feed search finds it
    feed = c_bob.get('/api/magazine/posts?q=راوی').get_json()['posts']
    assert any(p['id'] == pid for p in feed)

    # Bob likes and adds a reply
    like1 = c_bob.post(f'/api/magazine/posts/{pid}/like').get_json()
    assert like1['liked'] is True and like1['likes_count'] == 1
    rep = c_bob.post(f'/api/magazine/posts/{pid}/replies', json={'content': 'عالی بود!'}).get_json()
    assert rep['success'] is True and rep['reply']['content'] == 'عالی بود!'

    replies = c_alice.get(f'/api/magazine/posts/{pid}/replies').get_json()['replies']
    assert len(replies) == 1 and replies[0]['username'] == 'bob_two'

    # Alice's profile shows real posts_count == 1 and /api/users/alice_one/posts returns it
    prof = c_bob.get('/api/user_profile/alice_one').get_json()
    assert prof['posts_count'] == 1
    uposts = c_bob.get('/api/users/alice_one/posts').get_json()['posts']
    assert len(uposts) == 1 and uposts[0]['id'] == pid

    # Bob CANNOT delete Alice's post; Alice CAN
    assert c_bob.delete(f'/api/magazine/posts/{pid}').status_code == 403
    assert c_alice.delete(f'/api/magazine/posts/{pid}').status_code == 200
    assert c_bob.get('/api/user_profile/alice_one').get_json()['posts_count'] == 0


# ==================== 6. CSRF GET-Mutating Reject, Report User, Multi-Device & Ban ====================

def test_csrf_get_mutations_rejected_report_persists_and_multidevice_presence(ravi_env):
    ravi_app, _, _ = ravi_env
    c_alice = ravi_app.app.test_client()
    assert _login(c_alice, 'alice_one').status_code == 302
    c_bob = ravi_app.app.test_client()
    assert _login(c_bob, 'bob_two').status_code == 302

    # Destructive routes must reject GET (405 Method Not Allowed)
    assert c_alice.get('/admin/ban/2').status_code == 405
    assert c_alice.get('/admin/unban/2').status_code == 405
    assert c_alice.get('/admin/make_admin/2').status_code == 405
    assert c_alice.get('/admin/remove_pro/2').status_code == 405
    assert c_alice.get('/delete_message/1').status_code == 405

    # Report user persists reason in DB
    rep = c_alice.post(
        '/report_user/bob_two',
        json={'reason': 'Spam messages in test'},
        headers={'X-Requested-With': 'XMLHttpRequest'},
    )
    assert rep.status_code == 200
    assert rep.get_json()['success'] is True
    conn = ravi_app.db_conn()
    row = conn.execute("SELECT reason FROM reports ORDER BY id DESC LIMIT 1").fetchone()
    conn.close()
    assert row is not None and row[0] == 'Spam messages in test'

    # Multi-device Socket.IO presence: 2 sockets for alice -> disconnect 1 -> still online
    alice_uid = c_alice.get('/api/me').get_json()['id']
    s1 = ravi_app.socketio.test_client(ravi_app.app, flask_test_client=c_alice)
    s2 = ravi_app.socketio.test_client(ravi_app.app, flask_test_client=c_alice)
    assert len(ravi_app.online_users.get(alice_uid, set())) == 2
    s1.disconnect()
    assert len(ravi_app.online_users.get(alice_uid, set())) == 1
    s2.disconnect()
    assert alice_uid not in ravi_app.online_users

    # Ban member kicks Bob cleanly (verifies leave_room(sid, room_name) arg order & no crash)
    gr = c_alice.post('/create_private_room', data={'name': 'KickTest', 'type': 'group'})
    g_id = gr.get_json()['room_id']
    assert c_bob.post('/join_private_room', data={'room_id': g_id}).status_code == 200
    s_bob = ravi_app.socketio.test_client(ravi_app.app, flask_test_client=c_bob)
    s_bob.emit('join_group_room', {'room_id': g_id})
    s_bob.get_received()
    bob_uid = c_bob.get('/api/me').get_json()['id']
    ban_res = c_alice.post(f'/room/{g_id}/ban', json={'user_id': bob_uid})
    assert ban_res.status_code == 200
    assert ban_res.get_json()['success'] is True
    rec = s_bob.get_received()
    assert any(e['name'] == 'kicked_from_room' for e in rec)
    s_bob.disconnect()

