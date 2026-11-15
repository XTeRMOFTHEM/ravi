from flask import Flask, render_template, request, redirect, url_for, flash, jsonify
from werkzeug.exceptions import NotFound
from flask_socketio import SocketIO, emit, join_room, leave_room
from flask_login import LoginManager, login_user, logout_user, login_required, current_user
from werkzeug.security import generate_password_hash, check_password_hash
from werkzeug.utils import secure_filename
from datetime import datetime, timedelta
from flask import session
import requests
import subprocess
import os
import threading
import time as _time
from collections import defaultdict, deque
try:
    import imageio_ffmpeg
    FFMPEG_BIN = imageio_ffmpeg.get_ffmpeg_exe()
except Exception:
    FFMPEG_BIN = 'ffmpeg'  # اگه imageio-ffmpeg نصب نبود، از ffmpeg سیستم استفاده کن
import random
import secrets
import sqlite3
import re
from urllib.parse import quote as urlquote
import json as _json   # v1.6 FIX: save_message از _json استفاده می‌کرد ولی ایمپورت نشده بود
import ipaddress

app = Flask(__name__)

def _load_or_create_secret():
    """کلید امنیتی پایدار: اول متغیر محیطی، بعد فایل .secret محلی — تا سشن‌ها با هر ری‌استارت نپاشن"""
    env = os.environ.get('XYPHER_SECRET_KEY')
    if env: return env
    try:
        if os.path.exists('.secret'):
            with open('.secret') as f: s = f.read().strip()
            if s: return s
        s = secrets.token_hex(32)
        with open('.secret', 'w') as f: f.write(s)
        return s
    except Exception:
        return secrets.token_hex(32)

app.config['SECRET_KEY'] = _load_or_create_secret()
app.config['UPLOAD_FOLDER'] = 'static/uploads'
app.config['MAX_CONTENT_LENGTH'] = 210 * 1024 * 1024  # v1.4.0: ۲۱۰MB — ویدئوی حجیم مثل تلگرام

# ==================== v1.3.1 — بهینه‌سازی‌های سرعت HTTP ====================
# ۱) فایل‌های آپلود نام یکتا دارند (id_timestamp_token.ext) => کش ۳۰ روزه کاملاً امن
#    است و دانلودهای دوم (پروفایل/گالری/چت) از حافظه‌ی دستگاه سرو می‌شود.
app.config['SEND_FILE_MAX_AGE_DEFAULT'] = timedelta(days=30)

# ۲) فشرده‌سازی gzip برای پاسخ‌های JSON — لیست پیوی‌ها و تاریخچه‌ی پیام‌ها
#    روی نت موبایل ۳-۴ برابر سریع‌تر می‌رسد (کلاینت‌های http خودکار gzip را باز می‌کنند).
import gzip as _gzip
_GZIP_TYPES = ('application/json', 'text/html', 'text/css', 'application/javascript', 'text/plain')

@app.after_request
def _ravi_gzip_response(resp):
    try:
        # مسیرهای socket.io هرگز فشرده نمی‌شوند (پروتکل خودش طول دقیق می‌خواهد)
        p = request.path or ''
        resp.headers.setdefault('X-Content-Type-Options', 'nosniff')  # v1.6: جلوی اجرای فایل آپلودی با MIME حدسی
        if p.startswith('/socket.io') or p.startswith('/static/uploads/'):
            return resp
        if (resp.status_code == 200 and not resp.direct_passthrough
                and resp.mimetype in _GZIP_TYPES
                and 'gzip' in (request.headers.get('Accept-Encoding') or '').lower()
                and 'Content-Encoding' not in resp.headers):
            data = resp.get_data()
            if len(data) > 300:
                gz = _gzip.compress(data, 5)
                if len(gz) < len(data):
                    resp.set_data(gz)
                    resp.headers['Content-Encoding'] = 'gzip'
                    resp.headers['Content-Length'] = str(len(gz))
                    resp.headers.setdefault('Vary', 'Accept-Encoding')
    except Exception:
        pass
    return resp

DB_PATH = 'chat.db'
_DB_LOCAL = threading.local()

class _ReuseConn(object):
    """wrapper دور sqlite3.Connection: close() اون رو no-op می‌کنه تا کانکشنِ هر ترد کش بشه.
    همه‌ی توابع قدیمی به همون صورت conn.close() صدا می‌زنن ولی کانکشن ترد دوباره استفاده میشه
    => به جای صدها open/close در ثانیه، هر ترد فقط یک کانکشن دائمی داره."""
    __slots__ = ('_raw',)
    def __init__(self, raw):
        object.__setattr__(self, '_raw', raw)
    def __getattr__(self, name):
        return getattr(object.__getattribute__(self, '_raw'), name)
    def close(self):
        try: object.__getattribute__(self, '_raw').commit()
        except Exception: pass

def db_conn():
    """کانکشن SQLite به ازای هر ترد با timeout بالا (جلوگیری از database is locked زیر فشار کاربران زیاد)"""
    conn = getattr(_DB_LOCAL, 'conn', None)
    if conn is None:
        raw = sqlite3.connect(DB_PATH, timeout=30, check_same_thread=False)
        try:
            raw.execute('PRAGMA busy_timeout=30000')
            raw.execute('PRAGMA synchronous=NORMAL')
            # v1.3.1 — کش بزرگ‌تر + حافظه‌ی موقت RAM + mmap: کوئری‌های سنگین
            # (لیست چت‌ها، شمارش ناخوانده‌ها) چند برابر سریع‌تر و بدون I/O اضافه.
            raw.execute('PRAGMA cache_size=-8000')
            raw.execute('PRAGMA temp_store=MEMORY')
            raw.execute('PRAGMA mmap_size=134217728')
        except Exception:
            pass
        conn = _ReuseConn(raw)
        _DB_LOCAL.conn = conn
    return conn

os.makedirs(app.config['UPLOAD_FOLDER'], exist_ok=True)

@app.teardown_request
def _db_release_txn(exc):
    """v1.6 — اگر هندلری commit/rollback را فراموش کرده باشد، تراکنش باز روی کانکشنِ ترد
    می‌ماند و قفل نوشتن را نگه می‌دارد (database is locked برای بقیه). اینجا بسته می‌شود."""
    try:
        conn = getattr(_DB_LOCAL, 'conn', None)
        if conn is not None:
            raw = object.__getattribute__(conn, '_raw')
            if raw.in_transaction:
                if exc is not None: raw.rollback()
                else: raw.commit()
    except Exception:
        pass

# ==================== v1.4.0 — HARDENING: SESSION / COOKIE / CSRF ====================
app.config.update(
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE='Lax',   # جلوی CSRF مرورگرها را می‌گیرد؛ اپ با هدر Cookie مستقیم کار می‌کند
    PERMANENT_SESSION_LIFETIME=timedelta(days=45),
    MAX_FORM_MEMORY_SIZE=512 * 1024,
)

# --- محدودیت تلاش ورود (brute-force protection) ---
_login_attempts = {}  # (ip, username) -> deque[timestamps]
_LOGIN_WINDOW, _LOGIN_MAX = 300.0, 7   # ۷ تلاش در ۵ دقیقه

_rate_lock = threading.Lock()

def _login_rate_ok(key, maxn=None, window=None):
    maxn = maxn or _LOGIN_MAX
    window = window or _LOGIN_WINDOW
    now = _time.time()
    with _rate_lock:
        dq = _login_attempts.setdefault(key, deque(maxlen=max(20, maxn + 5)))
        while dq and now - dq[0] > window:
            dq.popleft()
        if len(dq) >= maxn:
            return False
        dq.append(now)
        return True

def _rate_ip():
    """IP برای ریت‌لیمیت: هدر X-Forwarded-For فقط وقتی معتبر است که اتصال از یک پراکسیِ
    محلی/خصوصی آمده باشد (آخرین مقدارِ افزوده‌شده توسط پراکسی)؛ وگرنه قابل جعل است."""
    peer = request.remote_addr or '?'
    try:
        ip = ipaddress.ip_address(peer)
        if ip.is_private or ip.is_loopback:
            xff = request.headers.get('X-Forwarded-For', '')
            if xff:
                last = xff.split(',')[-1].strip()
                if last: return last
    except Exception:
        pass
    return peer

def _reg_rate_ok(ip):
    return _login_rate_ok(('reg', ip), maxn=20, window=3600)

# مسیرهایی که با GET هم state را عوض می‌کنند (برای سازگاری با اپ فعلاً GET باقی مانده‌اند)
_GET_MUTATING_PREFIXES = ('/block_user/', '/unblock_user/', '/report_user/', '/follow/', '/unfollow/',
                          '/admin/', '/delete_message/', '/logout')
# تنها مسیرهایی که اجازه‌ی بدنه‌ی بزرگ دارند
_UPLOAD_PATHS = {'/upload_image', '/upload_gif', '/upload_chat_bg', '/upload_profile_cover', '/edit_profile'}

@app.before_request
def _ravi_security_gate():
    """مقیاس‌پذیری + امنیت: (۱) محدودیت تلاش ورود (۲) بررسی Origin برای متدهای تغییردهنده"""
    try:
        p = (request.path or '')
        # v1.6 — درخواست‌های غیرآپلود بدنه‌ی بزرگ نمی‌گیرند (MAX_CONTENT_LENGTH سراسری ۲۱۰MB بود)
        if request.method in ('POST', 'PUT') and p not in _UPLOAD_PATHS and not p.endswith('/set_avatar'):
            cl = request.content_length
            if cl and cl > 2 * 1024 * 1024:
                return jsonify({'error': 'حجم درخواست زیاد است'}), 413
        # v1.6 — مسیرهای GET تغییردهنده: اگر مرورگر نشان دهد از <img>/<iframe>/<script> یا از سایت دیگر
        # آمده، رد شود. کلاینت اندروید این هدرها را نمی‌فرستد => تغییری برای اپ ایجاد نمی‌شود.
        if request.method == 'GET' and p.startswith(_GET_MUTATING_PREFIXES):
            sfs = request.headers.get('Sec-Fetch-Site') or ''
            sfd = request.headers.get('Sec-Fetch-Dest') or ''
            if sfs == 'cross-site' or (sfd and sfd not in ('document', 'empty')):
                return jsonify({'error': 'درخواست غیرمجاز'}), 403
        if request.method == 'POST' and p == '/login':
            key = (_rate_ip(), (request.form.get('username') or '').strip().lower())
            if not _login_rate_ok(key):
                return jsonify({'error': 'تلاش‌های زیاد ناموفق؛ ۵ دقیقه صبر کنید'}), 429
        # CSRF سبک: اگر Origin/Referer آمد و با هاست ما فرق داشت، رد کن
        # (کلاینت اندروید هدر Origin نمی‌فرستد؛ مرورگر همیشه می‌فرستد)
        if request.method in ('POST', 'PUT', 'DELETE') and not p.startswith('/socket.io'):
            origin = request.headers.get('Origin') or ''
            if origin:
                host = request.host or ''
                if origin not in ('http://' + host, 'https://' + host):
                    return jsonify({'error': 'درخواست غیرمجاز'}), 403
    except Exception:
        pass
    return None

# v1.6 — با متغیر محیطی XYPHER_CORS_ORIGINS (جداشده با کاما) می‌توان مبدأهای مجاز سوکت را محدود کرد؛
# پیش‌فرض مثل قبل "*" است تا هیچ‌چیز روی اپ فعلی نشکند.
_cors_env = (os.environ.get('XYPHER_CORS_ORIGINS') or '').strip()
_CORS = [o.strip() for o in _cors_env.split(',') if o.strip()] if _cors_env else "*"
socketio = SocketIO(app, cors_allowed_origins=_CORS, ping_interval=20, ping_timeout=60, max_http_buffer_size=10 * 1024 * 1024)

@socketio.on_error_default
def _sio_default_error(e):
    """v1.6 — خطای هندلرهای سوکت: تراکنش نیمه‌کاره rollback شود و لاگ بماند (قبلاً قفل دیتابیس می‌ماند)"""
    try:
        conn = getattr(_DB_LOCAL, 'conn', None)
        if conn is not None:
            raw = object.__getattribute__(conn, '_raw')
            if raw.in_transaction: raw.rollback()
    except Exception:
        pass
    try: app.logger.error('socket handler error: %r', e)
    except Exception: pass
login_manager = LoginManager()
login_manager.init_app(app)
login_manager.login_view = 'login'

# ==================== بهینه‌سازی دیتابیس (فقط یکبار در استارتاپ) ====================
# WAL + ایندکس‌ها => کوئری‌های چت خیلی سریع‌تر میشن، مخصوصا لیست پیوی‌ها و تاریخچه پیام‌ها
def optimize_db():
    statements = [
        "PRAGMA journal_mode=WAL",
        "CREATE INDEX IF NOT EXISTS idx_messages_pv ON messages(private_chat_id, timestamp)",
        "CREATE INDEX IF NOT EXISTS idx_messages_room ON messages(room, timestamp)",
        "CREATE INDEX IF NOT EXISTS idx_messages_client ON messages(user_id, client_msg_id)",
        "CREATE INDEX IF NOT EXISTS idx_messages_reads ON message_reads(message_id)",
        "CREATE INDEX IF NOT EXISTS idx_pchats_user ON private_chats(sender_id, receiver_id, is_active)",
        # v1.3.1 — پیمایش صفحه‌ای تاریخچه‌ی پیوی و گالری گیف‌ها
        "CREATE INDEX IF NOT EXISTS idx_messages_pvchat_id ON messages(private_chat_id, id)",
        "CREATE INDEX IF NOT EXISTS idx_saved_gifs_user ON saved_gifs(user_id)",
        "CREATE INDEX IF NOT EXISTS idx_rooms_owner ON private_rooms(owner_id)",
        "CREATE INDEX IF NOT EXISTS idx_reactions_msg ON message_reactions(message_id)",
        # v1.6 — ایندکس‌های کم‌شده برای کوئری‌های داغ (ناخوانده‌ها، اعضا، فالو، تگ‌ها)
        "CREATE INDEX IF NOT EXISTS idx_messages_room_id ON messages(room, id)",
        "CREATE INDEX IF NOT EXISTS idx_messages_user ON messages(user_id)",
        "CREATE INDEX IF NOT EXISTS idx_members_user ON room_members(user_id, room_id)",
        "CREATE INDEX IF NOT EXISTS idx_members_room ON room_members(room_id, user_id)",
        "CREATE INDEX IF NOT EXISTS idx_follows_following ON follows(following_id)",
        "CREATE INDEX IF NOT EXISTS idx_tags_user ON user_tags(user_id)",
        "CREATE INDEX IF NOT EXISTS idx_reads_user ON message_reads(user_id)",
    ]
    for stmt in statements:
        try:
            conn = db_conn()
            c = conn.cursor()
            c.execute(stmt)
            conn.commit()
            conn.close()
        except Exception:
            pass  # جدول هنوز ساخته نشده — بعد از init_db دوباره اجرا میشه

optimize_db()

ALLOWED_EXTENSIONS = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'mp4', 'webm', 'mov', 'avi', 'mkv', 'm4v', '3gp',
                       'mp3', 'wav', 'ogg', 'oga', 'm4a', 'aac', 'opus', 'flac', 'm4r',
                       # v1.3.0 — فایل‌های عمومی هم مجاز شدن (باگ «فایل آپلود نمیشه»):
                       # قبلاً pdf/zip/doc توسط allowed_file رد می‌شدن ولی اپ می‌فرستادشون
                       'pdf', 'zip', 'doc', 'docx', 'txt', 'apk', 'rar', '7z',
                       # v1.3.1 — آفیس/اداری که کاربرها واقعا می‌فرستند (html/svg عمدا ممنوع)
                       'ppt', 'pptx', 'xls', 'xlsx', 'csv', 'odt', 'ods', 'odp', 'rtf', 'json', 'log',
                       # v1.5.0 — «هر فرمتی» که کاربر واقعا می‌فرستد (فایل چت، نه اسکریپت اجرایی وب)
                       'tar', 'gz', 'tgz', 'bz2', 'xz', 'iso', 'deb', 'psd', 'ai', 'eps',
                       'epub', 'mobi', 'py', 'c', 'cpp', 'java', 'kt', 'dart', 'sql',
                       'db', 'sqlite', 'ttf', 'otf', 'woff', 'woff2', 'srt', 'stl', 'obj',
                       'glb', 'gltf', 'heic', 'heif', 'avif', 'ts', 'wavp', 'amr', 'awb',
                       '3g2', 'flv', 'wmv', 'mpg', 'mpeg', 'm4b', 'aiff', 'alac', 'wma', 'mid'}

def allowed_file(filename):
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in ALLOWED_EXTENSIONS

# تم‌های پروفایل و کاور اختصاصی - هر دو مخصوص کاربران Pro
PROFILE_THEMES = {
    'default':  'radial-gradient(circle at 25% 15%, rgba(196,181,253,0.35) 0%, transparent 45%), linear-gradient(135deg, #7c3aed 0%, #6d28d9 55%, #4c1d95 100%)',
    'steel':    'radial-gradient(circle at 75% 20%, rgba(148,163,184,0.30) 0%, transparent 45%), linear-gradient(135deg, #475569 0%, #1e293b 60%, #0f172a 100%)',
    'gold':     'radial-gradient(circle at 25% 20%, rgba(253,224,71,0.35) 0%, transparent 45%), linear-gradient(135deg, #f59e0b 0%, #b45309 55%, #78350f 100%)',
    'sky':      'radial-gradient(circle at 70% 15%, rgba(224,242,254,0.40) 0%, transparent 45%), linear-gradient(135deg, #38bdf8 0%, #0284c7 55%, #075985 100%)',
    'crimson':  'radial-gradient(circle at 30% 20%, rgba(254,205,211,0.30) 0%, transparent 45%), linear-gradient(135deg, #fb7185 0%, #be123c 55%, #4c0519 100%)',
    'emerald':  'radial-gradient(circle at 70% 20%, rgba(167,243,208,0.35) 0%, transparent 45%), linear-gradient(135deg, #34d399 0%, #059669 55%, #064e3b 100%)',
    'midnight': 'radial-gradient(circle at 50% 10%, rgba(99,102,241,0.20) 0%, transparent 50%), linear-gradient(135deg, #1e1b3a 0%, #0d0d16 60%, #000000 100%)',
    'sunset':   'radial-gradient(circle at 25% 20%, rgba(253,186,116,0.35) 0%, transparent 45%), linear-gradient(135deg, #fb923c 0%, #db2777 55%, #701a75 100%)',
    'rosegold': 'radial-gradient(circle at 30% 15%, rgba(255,228,230,0.40) 0%, transparent 45%), linear-gradient(135deg, #fecdd3 0%, #fb7185 45%, #9d174d 100%)',
    'obsidian': 'radial-gradient(circle at 60% 15%, rgba(56,189,248,0.18) 0%, transparent 50%), linear-gradient(135deg, #18181b 0%, #09090b 60%, #000000 100%)',
    'icy': 'radial-gradient(circle at 30% 20%, rgba(255,255,255,0.55) 0%, transparent 45%), '
           'linear-gradient(135deg, #e0f2fe 0%, #7dd3fc 35%, #38bdf8 65%, #0284c7 100%)',
    'fire': 'radial-gradient(circle at 70% 80%, rgba(255,214,10,0.55) 0%, transparent 45%), '
            'linear-gradient(135deg, #fde047 0%, #f97316 40%, #dc2626 70%, #7f1d1d 100%)',
    'aurora': 'radial-gradient(circle at 20% 15%, rgba(167,139,250,0.5) 0%, transparent 45%), '
              'linear-gradient(135deg, #22d3ee 0%, #818cf8 35%, #c084fc 65%, #f472b6 100%)',
}
PROFILE_COVER_ALLOWED_EXTENSIONS = {'png', 'jpg', 'jpeg', 'webp'}

# رنگ‌های آماده‌ی پس‌زمینه‌ی کارت پروفایل (جدا از تم کاور) - مخصوص Pro
# همه‌شون از قبل تیره و امن انتخاب شدن که متن سفید/دکمه‌ها همیشه خوانا بمونن،
# پس نیازی به رنگ دلخواه یا لایه‌ی تیره‌ی اضافه نیست.
CARD_BG_THEMES = {
    'default':  '#0a0a0f',
    'charcoal': '#1c1c22',
    'slate':    '#1a2230',
    'graphite': '#232323',
    'navy':     '#141b2e',
    'plum':     '#241a2e',
    'maroon':   '#2a1418',
    'forest':   '#132119',
    'espresso': '#211a14',
    'ink':      '#12131c',
}

# قاب‌های دور عکس پروفایل - مخصوص کاربران Pro
AVATAR_FRAMES = {
    'dragon': {'name': 'Dragon', 'file': 'frame_dragon.png'},
    'moon':   {'name': 'Moonlight', 'file': 'frame_moon.png'},
    'gaming': {'name': 'Gamer', 'file': 'frame_gaming.png'},
    'sakura': {'name': 'Sakura', 'file': 'frame_sakura.png'},
    'forest': {'name': 'Forest', 'file': 'frame_forest.png'},
    'sun':       {'name': 'Sun', 'file': 'frame_sun.png'},
    'ocean':     {'name': 'Ocean', 'file': 'frame_ocean.png'},
    'void':      {'name': 'Void', 'file': 'frame_void.png'},
    'frost':     {'name': 'Frost', 'file': 'frame_frost.png'},
    'grove':     {'name': 'Grove', 'file': 'frame_grove.png'},
    'lava':      {'name': 'Lava', 'file': 'frame_lava.png'},
    'bushido':   {'name': 'Bushido', 'file': 'frame_bushido.png'},
    'celestial': {'name': 'Celestial', 'file': 'frame_celestial.png'},
    'crimson':   {'name': 'Crimson', 'file': 'frame_crimson.png'},
    # v1.5.0 — ۷ قاب جدید (باروک، پروانه، گوتیک، ستاره‌های نقره‌ای، دورستاره، خارها، بال‌ها)
    'baroque':      {'name': 'Baroque', 'file': 'frame_baroque.png'},
    'butterfly':    {'name': 'Butterfly', 'file': 'frame_butterfly.png'},
    'gothic':       {'name': 'Gothic', 'file': 'frame_gothic.png'},
    'silverstars':  {'name': 'Silver Stars', 'file': 'frame_silverstars.png'},
    'starsoutline': {'name': 'Stars Outline', 'file': 'frame_starsoutline.png'},
    'thorns':       {'name': 'Thorns', 'file': 'frame_thorns.png'},
    'wings':        {'name': 'Wings', 'file': 'frame_wings.png'},
}

# ==================== دیتابیس ====================

def init_db():
    conn = db_conn()
    c = conn.cursor()
    
    c.execute('''CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT UNIQUE, gender TEXT DEFAULT 'other', password TEXT,
        bio TEXT, avatar TEXT, is_admin INTEGER DEFAULT 0,
        is_banned INTEGER DEFAULT 0, created_at TIMESTAMP
    )''')
    
    c.execute('''CREATE TABLE IF NOT EXISTS messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        content TEXT, user_id INTEGER, room TEXT, timestamp TIMESTAMP,
        file_url TEXT, file_type TEXT DEFAULT 'text',
        private_chat_id INTEGER
    )''')
    
    c.execute('''CREATE TABLE IF NOT EXISTS private_rooms (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        room_id TEXT UNIQUE, name TEXT, owner_id INTEGER,
        created_at TIMESTAMP, is_active INTEGER DEFAULT 1
    )''')

    c.execute('''CREATE TABLE IF NOT EXISTS private_rooms (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        room_id TEXT UNIQUE, name TEXT, owner_id INTEGER,
        created_at TIMESTAMP, is_active INTEGER DEFAULT 1,
        avatar TEXT DEFAULT '', room_type TEXT DEFAULT 'group'
    )''')
    
    c.execute('''CREATE TABLE IF NOT EXISTS room_members (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER, room_id INTEGER, is_admin INTEGER DEFAULT 0,
        joined_at TIMESTAMP, is_muted INTEGER DEFAULT 0
    )''')

    c.execute('''CREATE TABLE IF NOT EXISTS user_tags (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER, tag_name TEXT, tag_color TEXT DEFAULT '#8b5cf6',
        tag_glow TEXT DEFAULT '#8b5cf6', created_by INTEGER, created_at TIMESTAMP
    )''')
    
    c.execute('''CREATE TABLE IF NOT EXISTS avatar_particles (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER UNIQUE, particle_color TEXT DEFAULT '#8b5cf6',
        particle_count INTEGER DEFAULT 8, particle_size INTEGER DEFAULT 3,
        orbit_speed REAL DEFAULT 8.0, orbit_radius INTEGER DEFAULT 70,
        glow_intensity REAL DEFAULT 0.6, created_by INTEGER, created_at TIMESTAMP
    )''')
    c.execute('''CREATE TABLE IF NOT EXISTS blocked_users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        blocker_id INTEGER,
        blocked_id INTEGER,
        created_at TIMESTAMP,
        UNIQUE(blocker_id, blocked_id)
    )''')
    c.execute('''CREATE TABLE IF NOT EXISTS pro_accounts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER UNIQUE, pro_type TEXT DEFAULT 'monthly',
        pro_until TIMESTAMP, is_active INTEGER DEFAULT 1,
        given_by INTEGER, given_at TIMESTAMP
    )''')

    c.execute('''CREATE TABLE IF NOT EXISTS message_reads (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        message_id INTEGER,
        user_id INTEGER,
        read_at TIMESTAMP,
        UNIQUE(message_id, user_id)
    )''')

    # جدول ریکشن پیام‌ها - هر کاربر روی هر پیام فقط یه ریکشن می‌تونه داشته باشه (مثل تلگرام معمولی)
    c.execute('''CREATE TABLE IF NOT EXISTS message_reactions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        message_id INTEGER,
        user_id INTEGER,
        emoji TEXT,
        created_at TIMESTAMP,
        UNIQUE(message_id, user_id)
    )''')
    
    # جدول فالو - جدید
    c.execute('''CREATE TABLE IF NOT EXISTS follows (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        follower_id INTEGER,
        following_id INTEGER,
        created_at TIMESTAMP,
        UNIQUE(follower_id, following_id)
    )''')

        # جدول ادمین‌های روم
    c.execute('''CREATE TABLE IF NOT EXISTS room_admins (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        room_id INTEGER,
        user_id INTEGER,
        title TEXT DEFAULT '',
        promoted_by INTEGER,
        promoted_at TIMESTAMP,
        UNIQUE(room_id, user_id)
    )''')
    
    # جدول کاربران بن شده از روم
    c.execute('''CREATE TABLE IF NOT EXISTS room_bans (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        room_id INTEGER,
        user_id INTEGER,
        banned_by INTEGER,
        banned_at TIMESTAMP,
        reason TEXT DEFAULT '',
        UNIQUE(room_id, user_id)
    )''')
    
    # جدول چت خصوصی (پیوی)
    c.execute('''CREATE TABLE IF NOT EXISTS private_chats (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sender_id INTEGER, receiver_id INTEGER,
        last_message TEXT DEFAULT '', last_time TIMESTAMP,
        unread_count INTEGER DEFAULT 0, is_active INTEGER DEFAULT 1,
        created_at TIMESTAMP, updated_at TIMESTAMP
    )''')

    # جدول گیف‌های ذخیره شده کاربر
    c.execute('''CREATE TABLE IF NOT EXISTS saved_gifs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER,
        url TEXT,
        filename TEXT,
        created_at TIMESTAMP
    )''')
    
    conn.commit()
    conn.close()

init_db()
optimize_db()  # ایندکس‌ها بعد از ساخت جداول اعمال میشن

def upgrade_db():
    conn = db_conn()
    c = conn.cursor()
    try: c.execute("ALTER TABLE messages ADD COLUMN file_url TEXT")
    except: pass
    try: c.execute("ALTER TABLE messages ADD COLUMN file_type TEXT DEFAULT 'text'")
    except: pass
    try: c.execute("ALTER TABLE messages ADD COLUMN private_chat_id INTEGER")
    except: pass
    try: c.execute("ALTER TABLE users ADD COLUMN is_banned INTEGER DEFAULT 0")
    except: pass
    try: c.execute("ALTER TABLE users ADD COLUMN is_admin INTEGER DEFAULT 0")
    except: pass
    try: c.execute("ALTER TABLE users ADD COLUMN created_at TIMESTAMP")
    except: pass
    try: c.execute("ALTER TABLE messages ADD COLUMN room TEXT")
    except: pass
    try: c.execute("ALTER TABLE room_members ADD COLUMN joined_at TIMESTAMP")
    except: pass
    try: c.execute("ALTER TABLE room_admins ADD COLUMN title TEXT DEFAULT ''")
    except: pass
    try: c.execute("ALTER TABLE room_admins ADD COLUMN permissions TEXT DEFAULT ''")
    except: pass
    try: c.execute("ALTER TABLE private_rooms ADD COLUMN slow_mode INTEGER DEFAULT 0")
    except: pass
    try: c.execute("ALTER TABLE private_rooms ADD COLUMN only_admins INTEGER DEFAULT 0")
    except: pass
    try: c.execute("ALTER TABLE private_rooms ADD COLUMN perm_send_media INTEGER DEFAULT 1")
    except: pass
    try: c.execute("ALTER TABLE private_rooms ADD COLUMN perm_send_gifs INTEGER DEFAULT 1")
    except: pass
    try: c.execute("ALTER TABLE messages ADD COLUMN forward_from TEXT DEFAULT ''")
    except: pass
    try: c.execute("ALTER TABLE messages ADD COLUMN forward_from_username TEXT DEFAULT ''")
    except: pass
    try: c.execute('''CREATE TABLE IF NOT EXISTS room_reads (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER, room_db_id INTEGER, last_msg_id INTEGER DEFAULT 0,
        updated_at TIMESTAMP,
        UNIQUE(user_id, room_db_id)
    )''')
    except: pass
    try: c.execute("ALTER TABLE messages ADD COLUMN is_deleted INTEGER DEFAULT 0")
    except: pass
    try: c.execute("ALTER TABLE messages ADD COLUMN deleted_by INTEGER")
    except: pass
    try: c.execute("ALTER TABLE messages ADD COLUMN deleted_at TIMESTAMP")
    except: pass
    try: c.execute("ALTER TABLE messages ADD COLUMN is_edited INTEGER DEFAULT 0")
    except: pass
    try: c.execute("ALTER TABLE messages ADD COLUMN media_meta TEXT")
    except: pass
    try: c.execute("ALTER TABLE users ADD COLUMN gender TEXT DEFAULT 'other'")
    except: pass
    try: c.execute("ALTER TABLE private_rooms ADD COLUMN is_active INTEGER DEFAULT 1")
    except: pass
    try: c.execute("ALTER TABLE messages ADD COLUMN client_msg_id TEXT")
    except: pass
    try: c.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_msg_client_dedupe ON messages(user_id, client_msg_id) WHERE client_msg_id IS NOT NULL")
    except: pass
    try:
        c.execute('''CREATE TABLE IF NOT EXISTS message_reactions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            message_id INTEGER,
            user_id INTEGER,
            emoji TEXT,
            created_at TIMESTAMP,
            UNIQUE(message_id, user_id)
        )''')
    except: pass
    try: c.execute("ALTER TABLE private_rooms ADD COLUMN avatar TEXT DEFAULT ''")
    except: pass
    try: c.execute("ALTER TABLE room_members ADD COLUMN is_admin INTEGER DEFAULT 0")
    except: pass
    try: c.execute("ALTER TABLE private_rooms ADD COLUMN room_type TEXT DEFAULT 'group'")
    except: pass
    try: c.execute("ALTER TABLE room_members ADD COLUMN is_muted INTEGER DEFAULT 0")
    except: pass
    try: c.execute("ALTER TABLE user_tags ADD COLUMN tag_glow TEXT DEFAULT '#8b5cf6'")
    except: pass
    try: c.execute("ALTER TABLE pro_accounts ADD COLUMN is_active INTEGER DEFAULT 1")
    except: pass
    try: c.execute("ALTER TABLE pro_accounts ADD COLUMN given_by INTEGER")
    except: pass
    try: c.execute("ALTER TABLE pro_accounts ADD COLUMN given_at TIMESTAMP")
    except: pass
    try: c.execute("ALTER TABLE users ADD COLUMN chat_bg TEXT DEFAULT ''")
    except: pass
    try: c.execute("ALTER TABLE users ADD COLUMN profile_theme TEXT DEFAULT 'default'")
    except: pass
    try: c.execute("ALTER TABLE users ADD COLUMN profile_cover TEXT DEFAULT ''")
    except: pass
    try: c.execute("ALTER TABLE users ADD COLUMN avatar_frame TEXT DEFAULT ''")
    except: pass
    try: c.execute("ALTER TABLE users ADD COLUMN card_color TEXT DEFAULT ''")
    except: pass
    try: c.execute("ALTER TABLE users ADD COLUMN name TEXT DEFAULT ''")
    except: pass
    try: c.execute("ALTER TABLE private_rooms ADD COLUMN username TEXT DEFAULT ''")
    except: pass
    try: c.execute("ALTER TABLE private_rooms ADD COLUMN is_public INTEGER DEFAULT 0")
    except: pass
    # بیوی کانال/گروه (حداکثر ۵۱۲ کاراکتر) — مثل تلگرام
    try: c.execute("ALTER TABLE private_rooms ADD COLUMN bio TEXT DEFAULT ''")
    except: pass
    # چه چیزی برای اعضای عادی قابل مشاهده باشه: 'all' | 'admins' | 'none' (فقط اطلاعات روم)
    try: c.execute("ALTER TABLE private_rooms ADD COLUMN member_visibility TEXT DEFAULT 'all'")
    except: pass
    # v1.4.0 — نسل نشست برای revoke واقعی همه‌ی دستگاه‌ها
    try: c.execute("ALTER TABLE users ADD COLUMN session_epoch INTEGER DEFAULT 0")
    except: pass
    # ---------- حریم خصوصی و امنیت ----------
    # چه کسانی می‌توانند آخرین بازدید من را ببینند: 'all' | 'contacts' | 'nobody'
    try: c.execute("ALTER TABLE users ADD COLUMN privacy_last_seen TEXT DEFAULT 'all'")
    except: pass
    # چه کسانی می‌توانند به من پیام بدهند: 'all' | 'contacts' | 'nobody'
    try: c.execute("ALTER TABLE users ADD COLUMN privacy_dm TEXT DEFAULT 'all'")
    except: pass
    # آخرین بازدید (ISO timestamp) — موقع آفلاین شدن واقعی کاربر ثبت میشه
    try: c.execute("ALTER TABLE users ADD COLUMN last_seen TIMESTAMP")
    except: pass
    # ---------- ریپلای حرفه‌ای بر اساس شناسه پیام (مثل تلگرام) ----------
    try: c.execute("ALTER TABLE messages ADD COLUMN reply_to INTEGER")
    except: pass
    try: c.execute("CREATE INDEX IF NOT EXISTS idx_messages_reply ON messages(reply_to)")
    except: pass
    # ---------- نشست‌های فعال (امیدیت حساب) ----------
    try:
        c.execute('''CREATE TABLE IF NOT EXISTS user_sessions (
            sid TEXT PRIMARY KEY,
            user_id INTEGER,
            ip TEXT,
            device TEXT,
            ua TEXT,
            created_at TIMESTAMP,
            last_active TIMESTAMP
        )''')
    except: pass
    try: c.execute("CREATE INDEX IF NOT EXISTS idx_sessions_user ON user_sessions(user_id)")
    except: pass
    # ---------- شمارنده ناخوانده به ازای هر طرف پیوی (بج فقط برای گیرنده) ----------
    try: c.execute("ALTER TABLE private_chats ADD COLUMN unread_s INTEGER DEFAULT 0")
    except: pass
    try: c.execute("ALTER TABLE private_chats ADD COLUMN unread_r INTEGER DEFAULT 0")
    except: pass
    # ---------- v1.3.0 — نوع آخرین پیام پیوی برای پیش‌نمایش لیست چت‌ها ----------
    # قبلاً فقط last_message (متن) ذخیره می‌شد؛ پیام رسانه‌ایِ بدون کپشن =>
    # پیش‌نمایش خالی در صفحه اصلی. حالا نوع و فرستنده هم ذخیره میشه.
    try: c.execute("ALTER TABLE private_chats ADD COLUMN last_file_type TEXT DEFAULT ''")
    except: pass
    try: c.execute("ALTER TABLE private_chats ADD COLUMN last_user TEXT DEFAULT ''")
    except: pass
    try: c.execute("CREATE INDEX IF NOT EXISTS idx_pvchats_updated ON private_chats(updated_at DESC)")
    except: pass
    # یوزرنیم عمومی روم‌ها باید یکتا باشه (روم‌های بدون یوزرنیم مستثنی هستن)
    try:
        c.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_rooms_username ON private_rooms(username) WHERE username IS NOT NULL AND username != ''")
    except Exception:
        pass
    # ---------- v1.1.1 — pinned messages (Telegram-style, multiple pins per chat) ----------
    try:
        c.execute('''CREATE TABLE IF NOT EXISTS room_pinned_messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            room_db_id INTEGER NOT NULL,
            message_id INTEGER NOT NULL,
            pinned_by INTEGER,
            pinned_at TIMESTAMP,
            UNIQUE(room_db_id, message_id)
        )''')
        c.execute("CREATE INDEX IF NOT EXISTS idx_room_pins ON room_pinned_messages(room_db_id, message_id)")
    except Exception:
        pass
    try:
        c.execute('''CREATE TABLE IF NOT EXISTS pv_pinned_messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            chat_id INTEGER NOT NULL,
            owner_user_id INTEGER NOT NULL,
            message_id INTEGER NOT NULL,
            pinned_at TIMESTAMP,
            UNIQUE(chat_id, owner_user_id, message_id)
        )''')
        c.execute("CREATE INDEX IF NOT EXISTS idx_pv_pins ON pv_pinned_messages(chat_id, owner_user_id)")
    except Exception:
        pass
    conn.commit()
    conn.close()

upgrade_db()
optimize_db()  # v1.3.1 — بعد از upgrade_db هم اجرا می‌شود: ستون‌هایی مثل client_msg_id/reply_to حالا موجودند و ایندکس‌های روی آن‌ها ساخته می‌شوند

# ==================== توابع دیتابیس ====================

def get_user(username=None, user_id=None):
    conn = db_conn()
    c = conn.cursor()
    if username: c.execute("SELECT * FROM users WHERE username = ?", (username,))
    else: c.execute("SELECT * FROM users WHERE id = ?", (user_id,))
    user = c.fetchone()
    conn.close()
    if user:
        return {
            'id': user[0], 'username': user[1], 'gender': user[2] or 'other',
            'password': user[3], 'bio': user[4] or '', 'avatar': user[5] or 'default.png',
            'is_admin': user[6], 'is_banned': user[7], 'created_at': user[8],
            'chat_bg': (user[9] if len(user) > 9 else '') or '',
            'profile_theme': (user[10] if len(user) > 10 else 'default') or 'default',
            'profile_cover': (user[11] if len(user) > 11 else '') or '',
            'avatar_frame': (user[12] if len(user) > 12 else '') or '',
            'card_color': (user[13] if len(user) > 13 else '') or '',
            'name': (user[14] if len(user) > 14 else '') or user[1],
            'privacy_last_seen': (user[15] if len(user) > 15 and user[15] else 'all') or 'all',
            'privacy_dm': (user[16] if len(user) > 16 and user[16] else 'all') or 'all',
            'last_seen': (user[17] if len(user) > 17 else None),
            # v1.4.0 — نسل نشست: با «خروج از همه دستگاه‌ها» افزایش می‌یابد و
            # کوکی‌های قدیمی بلافاصله بی‌اعتبار می‌شوند (قبلاً revoke صرفاً نمایشی بود)
            'session_epoch': (user[18] if len(user) > 18 and user[18] is not None else 0) or 0
        }
    return None

def get_all_users():
    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT id, username, gender, is_admin, is_banned FROM users")
    users = c.fetchall()
    conn.close()
    return users

# ==================== مدیریت اعضای روم ====================

def get_room_members_full(room_db_id):
    """لیست کامل اعضا با اطلاعات پروفایل"""
    conn = db_conn()
    c = conn.cursor()
    # v1.2.1 FIX — is_owner used to match ADMINS too (rm.is_admin OR owner),
    # so every admin wore the gold OWNER tag and the real owner tag was
    # meaningless. Now: owner = only the creator; is_room_admin = rm.is_admin.
    c.execute('''SELECT u.id, u.username, u.avatar, u.is_admin as global_admin,
                 (CASE WHEN u.id = pr.owner_id THEN 1 ELSE 0 END) as room_owner,
                 rm.is_admin as room_is_admin, rm.joined_at,
                 ra.title as admin_title, ra.promoted_by
                 FROM room_members rm 
                 JOIN users u ON rm.user_id = u.id
                 JOIN private_rooms pr ON pr.id = rm.room_id
                 LEFT JOIN room_admins ra ON rm.room_id = ra.room_id AND rm.user_id = ra.user_id
                 WHERE rm.room_id = ?
                 ORDER BY (CASE WHEN u.id = pr.owner_id THEN 0 ELSE 1 END), rm.is_admin DESC, ra.promoted_at ASC''', (room_db_id,))
    members = c.fetchall()
    conn.close()
    return [{
        'id': m[0], 'username': m[1], 'avatar': m[2], 'global_admin': m[3],
        'is_owner': m[4], 'is_room_admin': bool(m[5]), 'joined_at': m[6],
        'admin_title': m[7] or '', 'promoted_by': m[8]
    } for m in members]

def is_room_admin(room_db_id, user_id):
    """چک کن کاربر ادمین روم هست یا نه"""
    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT 1 FROM room_admins WHERE room_id = ? AND user_id = ?", (room_db_id, user_id))
    result = c.fetchone()
    conn.close()
    return result is not None

def is_room_owner(room_db_id, user_id):
    """چک کن کاربر مالک روم هست یا نه"""
    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT 1 FROM room_members WHERE room_id = ? AND user_id = ? AND is_admin = 1", (room_db_id, user_id))
    result = c.fetchone()
    conn.close()
    return result is not None

def promote_to_admin(room_db_id, user_id, promoted_by, title='', permissions=''):
    """ارتقا به ادمین — با تگ دلخواه و لیست پرمیشن‌ها (JSON)"""
    import json as _json
    if isinstance(permissions, (list, tuple)):
        permissions = _json.dumps([p for p in permissions if p in ADMIN_PERMS])
    elif not permissions:
        permissions = ''
    conn = db_conn()
    c = conn.cursor()
    c.execute("INSERT OR REPLACE INTO room_admins (room_id, user_id, title, promoted_by, promoted_at, permissions) VALUES (?, ?, ?, ?, ?, ?)",
              (room_db_id, user_id, title, promoted_by, datetime.now(), permissions))
    conn.commit()
    conn.close()

def edit_room_admin(room_db_id, user_id, title=None, permissions=None):
    """ویرایش تگ/پرمیشن‌های ادمین موجود"""
    import json as _json
    conn = db_conn(); c = conn.cursor()
    if permissions is not None:
        perms_json = _json.dumps([p for p in permissions if p in ADMIN_PERMS]) if isinstance(permissions, (list, tuple)) else permissions
        c.execute("UPDATE room_admins SET title = ?, permissions = ? WHERE room_id = ? AND user_id = ?",
                  (title if title is not None else '', perms_json, room_db_id, user_id))
    elif title is not None:
        c.execute("UPDATE room_admins SET title = ? WHERE room_id = ? AND user_id = ?", (title, room_db_id, user_id))
    conn.commit(); conn.close()

def demote_admin(room_db_id, user_id):
    """حذف از ادمینی"""
    conn = db_conn()
    c = conn.cursor()
    c.execute("DELETE FROM room_admins WHERE room_id = ? AND user_id = ?", (room_db_id, user_id))
    conn.commit()
    conn.close()

def ban_from_room(room_db_id, user_id, banned_by, reason=''):
    """بن کردن از روم"""
    conn = db_conn()
    c = conn.cursor()
    # حذف از اعضا
    c.execute("DELETE FROM room_members WHERE room_id = ? AND user_id = ?", (room_db_id, user_id))
    # حذف از ادمین‌ها
    c.execute("DELETE FROM room_admins WHERE room_id = ? AND user_id = ?", (room_db_id, user_id))
    # اضافه به لیست بن
    c.execute("INSERT OR REPLACE INTO room_bans (room_id, user_id, banned_by, banned_at, reason) VALUES (?, ?, ?, ?, ?)",
              (room_db_id, user_id, banned_by, datetime.now(), reason))
    conn.commit()
    conn.close()

def unban_from_room(room_db_id, user_id):
    """آنبن کردن"""
    conn = db_conn()
    c = conn.cursor()
    c.execute("DELETE FROM room_bans WHERE room_id = ? AND user_id = ?", (room_db_id, user_id))
    conn.commit()
    conn.close()

def is_banned_from_room(room_db_id, user_id):
    """چک کن کاربر بن شده یا نه"""
    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT 1 FROM room_bans WHERE room_id = ? AND user_id = ?", (room_db_id, user_id))
    result = c.fetchone()
    conn.close()
    return result is not None

def get_banned_members(room_db_id):
    """لیست کاربران بن شده"""
    conn = db_conn()
    c = conn.cursor()
    c.execute('''SELECT u.id, u.username, u.avatar, rb.banned_at, rb.reason, rb.banned_by
                 FROM room_bans rb JOIN users u ON rb.user_id = u.id
                 WHERE rb.room_id = ? ORDER BY rb.banned_at DESC''', (room_db_id,))
    banned = c.fetchall()
    conn.close()
    return [{'id': b[0], 'username': b[1], 'avatar': b[2], 'banned_at': b[3], 'reason': b[4], 'banned_by': b[5]} for b in banned]

# ==================== دسترسی‌های ادمین روم + ریت‌لیمیت ====================

ADMIN_PERMS = ['change_info', 'promote', 'delete_messages', 'ban_members', 'restrict_members']

def get_room_admin_perms(room_db_id, user_id):
    '''دسترسی‌های ادمینی کاربر در روم. مالک همه‌ی دسترسی‌ها رو داره.
    خروجی: {'is_owner':bool, 'is_admin':bool, 'perms':set}'''
    perms = set()
    is_owner = is_room_owner(room_db_id, user_id)
    is_admin = False
    if is_owner:
        perms = set(ADMIN_PERMS)
    else:
        conn = db_conn(); c = conn.cursor()
        c.execute("SELECT permissions FROM room_admins WHERE room_id = ? AND user_id = ?", (room_db_id, user_id))
        row = c.fetchone(); conn.close()
        if row:
            is_admin = True
            raw = (row[0] or '').strip()
            if raw:
                try:
                    import json as _json
                    perms = set(p for p in _json.loads(raw) if p in ADMIN_PERMS)
                except Exception:
                    perms = set()
            else:
                # ادمین‌های قدیمی (بدون رکورد پرمیشن): دسترسی‌های پایه
                perms = {'delete_messages', 'ban_members'}
    u = get_user(user_id=user_id)
    if u and u.get('is_admin'):
        is_admin = True; perms = set(ADMIN_PERMS)
    return {'is_owner': is_owner, 'is_admin': is_admin, 'perms': perms}

def can_manage_room(room_db_id, user_id):
    info = get_room_admin_perms(room_db_id, user_id)
    return info['is_owner'] or info['is_admin']

def set_room_setting_db(room_db_id, col, val):
    if col not in ('slow_mode', 'only_admins', 'perm_send_media', 'perm_send_gifs'): return
    conn = db_conn(); c = conn.cursor()
    c.execute(f"UPDATE private_rooms SET {col} = ? WHERE id = ?", (val, room_db_id))
    conn.commit(); conn.close()

def get_room_settings(room):
    return {'slow_mode': int(room.get('slow_mode') or 0), 'only_admins': bool(room.get('only_admins')),
            'perm_send_media': bool(room.get('perm_send_media')), 'perm_send_gifs': bool(room.get('perm_send_gifs'))}

def room_slow_mode_remaining(room_db_id, room_str, user_id):
    '''ثانیه‌ی باقی‌مانده تا ارسال پیام بعدی — مستقیم از دیتابیس، پس ری‌استارت هم
    نمی‌تونه ریستش کنه و برای هر کاربر دقیقاً جدا محاسبه میشه (ضد سرپیچی).'''
    conn = db_conn(); c = conn.cursor()
    c.execute('''SELECT MAX(timestamp) FROM messages
                 WHERE room = ? AND user_id = ? AND is_deleted = 0
                 AND (file_type IS NULL OR substr(file_type,1,4) <> 'sys_')''', (room_str, user_id))
    row = c.fetchone(); conn.close()
    if not row or not row[0]: return 0
    try:
        last = datetime.strptime(str(row[0])[:19], '%Y-%m-%d %H:%M:%S')
    except Exception:
        return 0
    room = get_room_by_db_id(room_db_id)
    limit = int(room.get('slow_mode') or 0) if room else 0
    if limit <= 0: return 0
    elapsed = (datetime.now() - last).total_seconds()
    return max(0, int(limit - elapsed))

def get_room_by_db_id(room_db_id):
    conn = db_conn(); c = conn.cursor()
    c.execute("SELECT id, room_id, name, owner_id, avatar, room_type, username, is_public, bio, member_visibility, slow_mode, only_admins, perm_send_media, perm_send_gifs FROM private_rooms WHERE id = ? AND is_active = 1", (room_db_id,))
    r = c.fetchone(); conn.close()
    if not r: return None
    return {'id': r[0], 'room_id': r[1], 'name': r[2], 'owner_id': r[3], 'avatar': r[4] or '', 'room_type': r[5] or 'group', 'username': r[6] or '', 'is_public': bool(r[7]), 'bio': r[8] or '', 'member_visibility': r[9] or 'all',
            'slow_mode': r[10] or 0, 'only_admins': bool(r[11]), 'perm_send_media': bool(r[12]), 'perm_send_gifs': bool(r[13])}

def announce_room_ban(room, target_username, by_username):
    '''پیام شیشه‌ای بن — مثل لفت، برای همه‌ی اعضا ریل‌تایم + توی تاریخچه.'''
    if not room or room.get('room_type') == 'channel': return
    room_str = f"private_{room['room_id']}"
    try:
        import json as _json
        content = _json.dumps({'t': target_username, 'b': by_username}, ensure_ascii=False)
    except Exception:
        content = target_username
    # v1.6 FIX — پیام سیستم با user_id=0 به‌خاطر JOIN داخلی users از تاریخچه ناپدید
    # می‌شد؛ حالا با شناسه‌ی واقعی ادمینِ بَن‌کننده ذخیره می‌شود.
    banner_id = 0
    try:
        _bu = get_user(username=by_username)
        if _bu: banner_id = _bu['id']
    except Exception:
        banner_id = 0
    msg_id = save_message(banner_id, by_username or 'system', content, room_str, None, 'sys_ban')
    socketio.emit('new_message', {
        'username': 'system', 'message': content, 'timestamp': datetime.now().strftime('%H:%M'),
        'avatar': '', 'file_url': None, 'file_type': 'sys_ban', 'tags': [], 'particle': None,
        'is_pro': False, 'message_id': msg_id, 'room': room_str
    }, room=room_str)

def update_room_read(user_id, room_db_id, msg_id):
    conn = db_conn(); c = conn.cursor()
    c.execute('''INSERT INTO room_reads (user_id, room_db_id, last_msg_id, updated_at)
                 VALUES (?, ?, ?, ?)
                 ON CONFLICT(user_id, room_db_id) DO UPDATE SET last_msg_id = MAX(last_msg_id, excluded.last_msg_id), updated_at = excluded.updated_at''',
              (user_id, room_db_id, msg_id, datetime.now()))
    conn.commit(); conn.close()

def get_room_unread(user_id, room_db_id, room_str):
    conn = db_conn(); c = conn.cursor()
    c.execute("SELECT last_msg_id FROM room_reads WHERE user_id = ? AND room_db_id = ?", (user_id, room_db_id))
    row = c.fetchone()
    last = row[0] if row else 0
    c.execute('''SELECT COUNT(*) FROM messages
                 WHERE room = ? AND id > ? AND user_id != ? AND is_deleted = 0
                 AND (file_type IS NULL OR file_type = '' OR file_type = 'text' OR file_type IN ('image','video','audio','gif'))''',
              (room_str, last, user_id))
    n = c.fetchone()[0]; conn.close()
    return n

def save_message(user_id, username, message, room='general', file_url=None, file_type='text', private_chat_id=None, client_msg_id=None, forward_from='', forward_from_username='', reply_to=None, media_meta=None):
    conn = db_conn()
    c = conn.cursor()

    # اگه این پیام (با همین client_msg_id) قبلا ذخیره شده - مثلا به خاطر قطعی نت دوباره
    # از کیوی محلی کاربر ارسال شده - همون رکورد قبلی رو برگردون، دوباره درجش نکن
    if client_msg_id:
        c.execute("SELECT id FROM messages WHERE user_id = ? AND client_msg_id = ?", (user_id, client_msg_id))
        existing = c.fetchone()
        if existing:
            return existing[0]

    # ریپلای حرفه‌ای: فقط شناسه‌ی پیام مقصد ذخیره میشه (مثل تلگرام) — نه متن لایه‌لایه
    try:
        reply_to = int(reply_to) if reply_to else None
    except (TypeError, ValueError):
        reply_to = None

    # v1.2.1 — Telegram-style media metadata (dims / music tags) rides along
    meta_json = None
    if media_meta:
        try:
            meta_json = media_meta if isinstance(media_meta, str) else _json.dumps(media_meta)
        except Exception:
            meta_json = None
    c.execute("INSERT INTO messages (content, user_id, room, timestamp, file_url, file_type, private_chat_id, client_msg_id, forward_from, forward_from_username, reply_to, media_meta) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
              (message, user_id, room, datetime.now(), file_url, file_type, private_chat_id, client_msg_id, forward_from or '', forward_from_username or '', reply_to, meta_json))
    conn.commit()
    msg_id = c.lastrowid
    return msg_id

def get_reply_snapshot(reply_to_id):
    """اسنپ‌شات اطلاعات پیامِ ریپلای‌شده برای نمایش در حباب — با یه کوئری سبک + کش کوتاه
    (متن پیام‌های ریپلای‌شده تقریبا هرگز عوض نمیشه => کش ۹۰ ثانیه‌ای فشار دیتابیس رو صفر می‌کنه)"""
    if not reply_to_id:
        return None
    try:
        reply_to_id = int(reply_to_id)
    except (TypeError, ValueError):
        return None
    now = _time.time()
    cached = _reply_cache.get(reply_to_id)
    if cached and now - cached[0] < 90:
        return cached[1] if cached[1] else None
    conn = db_conn()
    c = conn.cursor()
    try:
        # v1.3.0 — file_url + media_meta هم میاد تا پیش‌نمایشِ ریپلایِ رسانه‌ای خالی نمونه
        c.execute('''SELECT m.id, u.username, u.name, m.content, m.file_type, m.is_deleted, m.file_url, m.media_meta
                     FROM messages m JOIN users u ON m.user_id = u.id WHERE m.id = ?''', (reply_to_id,))
        r = c.fetchone()
    except Exception:
        r = None
    snap = None
    if r:
        if r[5]:
            # v1.3.1 — پیامِ حذف‌شده: به‌جای کوتیشنِ خالی، برچسب واضح می‌آید
            # (قبلاً snap=None می‌شد و حبابِ ریپلای فقط یک نوار خالی بود)
            snap = {'reply_to': r[0], 'reply_username': r[1],
                    'reply_display_name': (r[2] or '').strip() or r[1],
                    'reply_text': '🚫 این پیام حذف شده است',
                    'reply_file_type': 'text'}
        else:
            txt = (r[3] or '').strip()
            if not txt:
                # v1.3.0 FIX — پیام رسانه‌ای بدون کپشن: برچسب نوع فایل (📷 عکس / 🎵 موزیک…)
                # قبلاً متنِ خالی برمی‌گشت و حباب ریپلای تو صفحه خالی نشون میداد.
                txt = media_preview_label(r[4], r[6] or '', r[7] if len(r) > 7 else None) or 'پیام'
            snap = {'reply_to': r[0], 'reply_username': r[1],
                    'reply_display_name': (r[2] or '').strip() or r[1],
                    'reply_text': (txt[:140] + '…') if len(txt) > 140 else txt,
                    'reply_file_type': r[4] or 'text'}
    _reply_cache[reply_to_id] = (now, snap)
    if len(_reply_cache) > 4000:
        _reply_cache.clear()
    return snap

_reply_cache = {}

_user_enrich_cache = {}

def user_enrichment(user_id):
    """تگ‌ها + ذره‌ها + وضعیت Pro کاربر با کش ۶۰ ثانیه‌ای — به ازای هر پیام ارسالی صفر کوئری اضافه"""
    now = _time.time()
    cached = _user_enrich_cache.get(user_id)
    if cached and now - cached[0] < 60:
        return cached[1]
    data = {'tags': [], 'particle': {}, 'is_pro': False}
    try: data['tags'] = get_user_tags(user_id)
    except Exception: pass
    try: data['particle'] = get_avatar_particle(user_id)
    except Exception: data['particle'] = {}
    try: data['is_pro'] = is_pro_user(user_id)
    except Exception: pass
    _user_enrich_cache[user_id] = (now, data)
    if len(_user_enrich_cache) > 2000:
        _user_enrich_cache.clear()
    return data

def invalidate_user_enrichment(user_id=None):
    if user_id is None:
        _user_enrich_cache.clear()
    else:
        _user_enrich_cache.pop(user_id, None)

def batch_user_tags(user_ids):
    """تگ‌های N کاربر با فقط یک کوئری (به جای N کوئری) — برای لیست پیوی‌ها و اعضا"""
    ids = list(set([i for i in user_ids if i]))
    if not ids: return {}
    conn = db_conn()
    c = conn.cursor()
    placeholders = ','.join('?' for _ in ids)
    try:
        c.execute(f"SELECT user_id, tag_name, tag_color FROM user_tags WHERE user_id IN ({placeholders})", ids)
        rows = c.fetchall()
    except Exception:
        return {}
    out = defaultdict(list)
    for r in rows:
        out[r[0]].append({'tag_name': r[1], 'tag_color': r[2]})
    return out

def get_messages(room='general', limit=50):
    conn = db_conn()
    c = conn.cursor()
    c.execute('''SELECT m.content, u.username, m.timestamp, u.avatar, m.file_url, m.file_type 
                 FROM messages m JOIN users u ON m.user_id = u.id 
                 WHERE m.room = ? AND m.private_chat_id IS NULL
                 ORDER BY m.timestamp DESC LIMIT ?''', (room, limit))
    msgs = c.fetchall()
    conn.close()
    return [{'message': m[0], 'username': m[1], 'timestamp': m[2], 'avatar': m[3], 
             'file_url': m[4], 'file_type': m[5]} for m in msgs[::-1]]
# ==================== توابع حذف پیام ====================

def file_still_in_use(conn, file_url):
    """چک می‌کنه که فایل هنوز توسط پیام دیگه‌ای یا گالری گیف کسی استفاده میشه یا نه.
    این تابع باگ ناپدید شدن گیف‌ها رو حل می‌کنه: وقتی یه پیام حذف میشه، فایل گیفش
    فقط اون موقع پاک میشه که هیچ رفرنس دیگه‌ای (نه پیام دیگه، نه گالری هیچ کاربری)
    بهش اشاره نکنه. قبلش فایل فوراً پاک می‌شد ولی رکورد گالری می‌موند => گیف‌ها ۴۰۴ می‌شدن."""
    if not file_url:
        return False
    try:
        c = conn.cursor()
        # پیام‌های دیگه‌ای که همین فایل رو دارن (حذف‌شده‌ها حساب نمی‌شن)
        c.execute("SELECT COUNT(*) FROM messages WHERE file_url = ? AND is_deleted = 0", (file_url,))
        if (c.fetchone()[0] or 0) > 0:
            return True
        # گالری گیف هر کاربری که همین URL رو ذخیره کرده باشه
        try:
            c.execute("SELECT COUNT(*) FROM saved_gifs WHERE url = ?", (file_url,))
            if (c.fetchone()[0] or 0) > 0:
                return True
        except Exception:
            pass  # جدول هنوز ساخته نشده
        return False
    except Exception:
        return True  # در صورت شک، فایل رو نگه دار (ایمن‌تره)

def delete_message_db(message_id, user_id, is_admin=False, force=False):
    """
    حذف پیام (soft delete)
    user_id: کسی که پیام رو فرستاده یا ادمین
    is_admin: آیا ادمین داره حذف میکنه | force: ادمین روم با پرمیشن
    """
    conn = db_conn()
    c = conn.cursor()
    
    # پیام رو پیدا کن
    c.execute("SELECT id, user_id, content, room, file_url, file_type, is_deleted FROM messages WHERE id = ?", (message_id,))
    msg = c.fetchone()
    
    if not msg:
        conn.close()
        return False, "پیام پیدا نشد"
    
    msg_id, msg_user_id, content, room, file_url, file_type, is_deleted = msg
    
    # چک کن قبلاً حذف نشده باشه
    if is_deleted:
        conn.close()
        return False, "پیام قبلاً حذف شده"
    
    # فقط فرستنده یا ادمین میتونن حذف کنن
    if not is_admin and msg_user_id != user_id and not force:
        conn.close()
        return False, "شما اجازه حذف این پیام را ندارید"
    
    # حذف نرم (soft delete)
    c.execute("""UPDATE messages SET is_deleted = 1, deleted_by = ?, deleted_at = ? 
                 WHERE id = ?""", (user_id, datetime.now(), message_id))
    
    # اگه عکس یا ویدیو داشت، فایلش رو هم پاک کن — ولی فقط اگه هیچ رفرنس دیگه‌ای نمونده باشه
    # (این شرط باعث میشه گیف‌های گالری با حذف یه پیام، ناپدید نشن)
    if file_url and file_url.startswith('/static/uploads/'):
        filepath = os.path.join(app.config['UPLOAD_FOLDER'], file_url.replace('/static/uploads/', ''))
        if os.path.exists(filepath) and not file_still_in_use(conn, file_url):
            try:
                os.remove(filepath)
            except:
                pass
    
    conn.commit()
    conn.close()
    return True, room

def delete_all_messages_db(room='general'):
    """حذف همه پیام‌های یه روم (فقط توسط ادمین)"""
    conn = db_conn()
    c = conn.cursor()
    
    # پاک کردن فایل‌های آپلود شده — فقط فایل‌هایی که هیچ رفرنس دیگه‌ای ندارن
    # (گیف‌های گالری و رسانه‌ی پیام‌های دیگه محافظت می‌شن)
    c.execute("SELECT file_url FROM messages WHERE room = ? AND file_url IS NOT NULL AND is_deleted = 0", (room,))
    files = c.fetchall()
    for f in files:
        if f[0] and f[0].startswith('/static/uploads/'):
            filepath = os.path.join(app.config['UPLOAD_FOLDER'], f[0].replace('/static/uploads/', ''))
            if os.path.exists(filepath) and not file_still_in_use(conn, f[0]):
                try:
                    os.remove(filepath)
                except:
                    pass
    
    # حذف همه پیام‌ها
    c.execute("UPDATE messages SET is_deleted = 1, deleted_at = ? WHERE room = ? AND is_deleted = 0", 
              (datetime.now(), room))
    
    count = c.rowcount
    conn.commit()
    conn.close()
    return count

def get_message_by_id(message_id):
    """دریافت اطلاعات یه پیام"""
    conn = db_conn()
    c = conn.cursor()
    c.execute("""SELECT m.id, m.content, m.user_id, m.room, m.timestamp, m.file_url, m.file_type, 
                 m.is_deleted, u.username, m.private_chat_id 
                 FROM messages m JOIN users u ON m.user_id = u.id 
                 WHERE m.id = ?""", (message_id,))
    msg = c.fetchone()
    conn.close()
    if msg:
        return {
            'id': msg[0], 'content': msg[1], 'user_id': msg[2], 'room': msg[3],
            'timestamp': msg[4], 'file_url': msg[5], 'file_type': msg[6],
            'is_deleted': msg[7], 'username': msg[8], 'private_chat_id': msg[9]
        }
    return None

# ==================== ریکشن پیام‌ها ====================

ALLOWED_REACTIONS = {'👍', '❤️', '😂', '😮', '😢', '🙏', '🔥', '🎉'}

def toggle_reaction_db(message_id, user_id, emoji):
    """اگه کاربر همین ریکشن رو زده بود، پاکش می‌کنه. اگه ریکشن دیگه‌ای زده بود، عوضش می‌کنه.
    اگه هنوز چیزی نزده بود، اضافه می‌کنه. خروجی: لیست خلاصه‌ی ریکشن‌های اون پیام."""
    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT emoji FROM message_reactions WHERE message_id = ? AND user_id = ?", (message_id, user_id))
    existing = c.fetchone()
    if existing and existing[0] == emoji:
        c.execute("DELETE FROM message_reactions WHERE message_id = ? AND user_id = ?", (message_id, user_id))
    else:
        c.execute('''INSERT INTO message_reactions (message_id, user_id, emoji, created_at) VALUES (?, ?, ?, ?)
                     ON CONFLICT(message_id, user_id) DO UPDATE SET emoji = excluded.emoji, created_at = excluded.created_at''',
                  (message_id, user_id, emoji, datetime.now()))
    conn.commit()
    conn.close()
    return get_message_reactions(message_id)

def get_message_reactions(message_id):
    """خلاصه‌ی ریکشن‌های یه پیام: [{emoji, count, usernames: [...], reactors: [{username, avatar}]}]"""
    conn = db_conn()
    c = conn.cursor()
    c.execute('''SELECT mr.emoji, u.username, u.avatar FROM message_reactions mr
                 JOIN users u ON mr.user_id = u.id
                 WHERE mr.message_id = ? ORDER BY mr.created_at ASC''', (message_id,))
    rows = c.fetchall()
    conn.close()
    grouped = {}
    for emoji, username, avatar in rows:
        grouped.setdefault(emoji, []).append({'username': username, 'avatar': avatar or ''})
    return [{'emoji': emoji, 'count': len(reactors), 'usernames': [r['username'] for r in reactors], 'reactors': reactors}
            for emoji, reactors in grouped.items()]

def get_reactions_for_messages(message_ids):
    """خلاصه‌ی ریکشن‌ها برای یه دسته پیام باهم - برای لود اولیه‌ی تاریخچه"""
    if not message_ids:
        return {}
    conn = db_conn()
    c = conn.cursor()
    placeholders = ','.join('?' * len(message_ids))
    c.execute(f'''SELECT mr.message_id, mr.emoji, u.username, u.avatar FROM message_reactions mr
                 JOIN users u ON mr.user_id = u.id
                 WHERE mr.message_id IN ({placeholders}) ORDER BY mr.created_at ASC''', message_ids)
    rows = c.fetchall()
    conn.close()
    result = {}
    for msg_id, emoji, username, avatar in rows:
        result.setdefault(msg_id, {}).setdefault(emoji, []).append({'username': username, 'avatar': avatar or ''})
    return {msg_id: [{'emoji': e, 'count': len(reactors), 'usernames': [r['username'] for r in reactors], 'reactors': reactors}
                      for e, reactors in emojis.items()]
            for msg_id, emojis in result.items()}

def create_private_room_db(room_id, name, owner_id, room_type='group', username='', is_public=0):
    """ساخت روم گروه جدید + افزودن مالک به‌عنوان اولین عضو و ادمین"""
    conn = db_conn()
    c = conn.cursor()
    if room_type not in ('group', 'channel'): room_type = 'group'
    c.execute("INSERT INTO private_rooms (room_id, name, owner_id, created_at, is_active, room_type, username, is_public) VALUES (?, ?, ?, ?, 1, ?, ?, ?)",
              (room_id, name, owner_id, datetime.now(), room_type, username or '', 1 if is_public else 0))
    room_db_id = c.lastrowid
    c.execute("INSERT INTO room_members (user_id, room_id, is_admin, joined_at) VALUES (?, ?, 1, ?)",
              (owner_id, room_db_id, datetime.now()))
    conn.commit()
    conn.close()
    return room_db_id

def mark_message_read(message_id, user_id):
    conn = db_conn()
    c = conn.cursor()
    c.execute("INSERT OR IGNORE INTO message_reads (message_id, user_id, read_at) VALUES (?, ?, ?)",
              (message_id, user_id, datetime.now()))
    conn.commit()
    conn.close()

def get_message_reads(message_id):
    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT user_id FROM message_reads WHERE message_id = ?", (message_id,))
    reads = c.fetchall()
    conn.close()
    return [r[0] for r in reads]

def get_unread_count(room, user_id):
    conn = db_conn()
    c = conn.cursor()
    c.execute('''SELECT COUNT(*) FROM messages m 
                 WHERE m.room = ? AND m.user_id != ? 
                 AND m.id NOT IN (SELECT message_id FROM message_reads WHERE user_id = ?)''',
              (room, user_id, user_id))
    count = c.fetchone()[0]
    conn.close()
    return count

def join_private_room_db(user_id, room_db_id):
    conn = db_conn()
    c = conn.cursor()
    c.execute("INSERT OR IGNORE INTO room_members (user_id, room_id, joined_at) VALUES (?, ?, ?)", 
              (user_id, room_db_id, datetime.now()))
    conn.commit()
    conn.close()

def get_user_rooms(user_id):
    conn = db_conn()
    c = conn.cursor()
    c.execute('''SELECT pr.room_id, pr.name, pr.avatar, pr.room_type, pr.owner_id, rm.is_muted FROM private_rooms pr 
                 JOIN room_members rm ON pr.id = rm.room_id 
                 WHERE rm.user_id = ? AND pr.is_active = 1''', (user_id,))
    rooms = c.fetchall()
    conn.close()
    return [{'room_id': r[0], 'name': r[1], 'avatar': r[2] or '', 'room_type': r[3] or 'group',
              'owner_id': r[4], 'is_muted': bool(r[5])} for r in rooms]

def is_room_poster(room_db_id, user_id):
    """آیا این کاربر مجاز به ارسال پیام در کانال است؟ (مالک، ادمین روم یا ادمین کل)"""
    u = get_user(user_id=user_id)
    if u and u.get('is_admin'): return True
    return bool(is_room_owner(room_db_id, user_id) or is_room_admin(room_db_id, user_id))

def toggle_room_mute_db(room_db_id, user_id):
    conn = db_conn(); c = conn.cursor()
    c.execute("SELECT is_muted FROM room_members WHERE room_id = ? AND user_id = ?", (room_db_id, user_id))
    row = c.fetchone()
    if not row:
        conn.close(); return None
    new_val = 0 if row[0] else 1
    c.execute("UPDATE room_members SET is_muted = ? WHERE room_id = ? AND user_id = ?", (new_val, room_db_id, user_id))
    conn.commit(); conn.close()
    return bool(new_val)

def get_room_by_id(room_id):
    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT id, room_id, name, owner_id, avatar, room_type, username, is_public, bio, member_visibility, slow_mode, only_admins, perm_send_media, perm_send_gifs FROM private_rooms WHERE room_id = ? AND is_active = 1", (room_id,))
    room = c.fetchone()
    conn.close()
    if room: return {'id': room[0], 'room_id': room[1], 'name': room[2], 'owner_id': room[3], 'avatar': room[4] or '', 'room_type': room[5] or 'group', 'username': room[6] or '', 'is_public': bool(room[7]), 'bio': room[8] or '', 'member_visibility': room[9] or 'all',
                     'slow_mode': room[10] or 0, 'only_admins': bool(room[11]), 'perm_send_media': bool(room[12]), 'perm_send_gifs': bool(room[13])}
    return None

def set_room_bio_db(room_db_id, bio):
    conn = db_conn(); c = conn.cursor()
    c.execute("UPDATE private_rooms SET bio = ? WHERE id = ?", (bio[:512], room_db_id))
    conn.commit(); conn.close()

def set_room_visibility_db(room_db_id, mode):
    if mode not in ('all', 'admins', 'none'): mode = 'all'
    conn = db_conn(); c = conn.cursor()
    c.execute("UPDATE private_rooms SET member_visibility = ? WHERE id = ?", (mode, room_db_id))
    conn.commit(); conn.close()

def get_room_member_count(room_db_id):
    conn = db_conn(); c = conn.cursor()
    c.execute("SELECT COUNT(*) FROM room_members WHERE room_id = ?", (room_db_id,))
    n = c.fetchone()[0]
    conn.close()
    return n

def leave_room_db(user_id, room_db_id):
    """لفت دادن کامل از گروه/کانال — حذف عضویت + حذف ادمینی"""
    conn = db_conn(); c = conn.cursor()
    c.execute("DELETE FROM room_members WHERE user_id = ? AND room_id = ?", (user_id, room_db_id))
    removed = c.rowcount
    c.execute("DELETE FROM room_admins WHERE user_id = ? AND room_id = ?", (user_id, room_db_id))
    conn.commit(); conn.close()
    return removed > 0

# پیام‌های شیشه‌ای عضویت/خروج فقط برای گروه‌های تا این تعداد عضو ساخته میشن
# تا گروه‌های شلوغ اذیت کننده نشن
SYS_SERVICE_LIMIT = 30

SERVICE_FILETYPES = {
    'join_link':      'sys_join_link',
    'join_username':  'sys_join_username',
    'leave':          'sys_leave'
}

def announce_room_service_event(room, actor_user_id, actor_username, actor_avatar, action):
    """اعلام عضویت/خروج به همه‌ی اعضای روم.
    همیشه رویداد room_member_update برای به‌روزرسانی شمارنده‌ها ارسال میشه،
    ولی «پیام شیشه‌ای» فقط برای روم‌های با حداکثر SYS_SERVICE_LIMIT عضو ساخته میشه."""
    if not room: return
    room_name = f"private_{room['room_id']}"   # کلید روم همه‌جا با room_id رشته‌ایه
    count = get_room_member_count(room['id'])
    # شمارنده‌ی اعضا برای همه‌ی کلاینت‌ها (لیست چت‌ها + پنل اطلاعات) تازه بشه
    socketio.emit('room_member_update', {
        'room_id': room['room_id'], 'member_count': count,
        'action': action, 'username': actor_username
    }, room='general')
    # فقط و فقط در کانال‌ها هیچ پیام شیشه‌ای عضویت/لفت وجود نداره —
    # هرچی هست از توی کانال‌ها برداشته میشه؛ شمارنده‌ی اعضا بالا همچنان به‌روز میشه
    if room.get('room_type') == 'channel':
        return
    ftype = SERVICE_FILETYPES.get(action)
    if not ftype or count > SYS_SERVICE_LIMIT:
        return
    try:
        msg_id = save_message(actor_user_id, actor_username, actor_username, room_name, None, ftype)
        socketio.emit('new_message', {
            'username': actor_username, 'message': actor_username,
            'timestamp': datetime.now().strftime('%H:%M'), 'avatar': actor_avatar or '',
            'file_url': None, 'file_type': ftype, 'message_id': msg_id,
            'room': room_name, 'is_service': True
        }, room=room_name)
    except Exception:
        pass

def is_room_manager(room_db_id, user_id):
    """مالک یا ادمین روم (یا ادمین کل) — کسی که اجازه‌ی مدیریت پنل رو داره"""
    u = get_user(user_id=user_id)
    if u and u.get('is_admin'): return True
    return bool(is_room_owner(room_db_id, user_id) or is_room_admin(room_db_id, user_id))

def set_room_avatar_db(room_db_id, avatar_filename):
    conn = db_conn(); c = conn.cursor()
    c.execute("UPDATE private_rooms SET avatar = ? WHERE id = ?", (avatar_filename, room_db_id))
    conn.commit(); conn.close()

def get_room_by_username(username):
    """پیدا کردن روم عمومی با یوزرنیم — برای ورود با کلیک روی @username"""
    if not username: return None
    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT id, room_id, name, owner_id, avatar, room_type, username, is_public, bio, member_visibility FROM private_rooms WHERE is_active = 1 AND is_public = 1 AND username = ?", (username,))
    room = c.fetchone()
    conn.close()
    if room: return {'id': room[0], 'room_id': room[1], 'name': room[2], 'owner_id': room[3], 'avatar': room[4] or '', 'room_type': room[5] or 'group', 'username': room[6] or '', 'is_public': bool(room[7]), 'bio': room[8] or '', 'member_visibility': room[9] or 'all'}
    return None

def room_username_taken(username, exclude_room_db_id=None):
    """یوزرنیم روم نباید تکراری باشه — نه بین روم‌ها نه با یوزرنیم کاربران"""
    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT id FROM private_rooms WHERE username IS NOT NULL AND username != '' AND LOWER(username) = LOWER(?)", (username,))
    for (rid,) in c.fetchall():
        if exclude_room_db_id is None or rid != exclude_room_db_id:
            conn.close(); return True
    c.execute("SELECT id FROM users WHERE LOWER(username) = LOWER(?)", (username,))
    taken = c.fetchone() is not None
    conn.close()
    return taken

def username_taken_by_room(username):
    """برعکسش هم برقراره: کاربر نمی‌تونه یوزرنیم کانال‌ها/گروه‌ها رو برداره"""
    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT id FROM private_rooms WHERE username IS NOT NULL AND username != '' AND LOWER(username) = LOWER(?)", (username,))
    taken = c.fetchone() is not None
    conn.close()
    return taken

def is_room_member(user_id, room_db_id):
    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT 1 FROM room_members WHERE user_id = ? AND room_id = ?", (user_id, room_db_id))
    result = c.fetchone()
    conn.close()
    return result is not None

def get_room_members(room_db_id):
    conn = db_conn()
    c = conn.cursor()
    c.execute('''SELECT u.username, rm.is_admin FROM room_members rm 
                 JOIN users u ON rm.user_id = u.id WHERE rm.room_id = ?''', (room_db_id,))
    members = c.fetchall()
    conn.close()
    return [{'username': m[0], 'is_admin': m[1]} for m in members]

def ban_user_db(user_id, banned_by):
    conn = db_conn(); c = conn.cursor()
    c.execute("UPDATE users SET is_banned = 1 WHERE id = ?", (user_id,))
    conn.commit(); conn.close()
    try: kill_all_user_sessions(user_id)   # v1.6: کاربر بن‌شده همان لحظه از همه‌ی دستگاه‌ها بیرون می‌افتد
    except Exception: pass

def unban_user_db(user_id):
    conn = db_conn(); c = conn.cursor()
    c.execute("UPDATE users SET is_banned = 0 WHERE id = ?", (user_id,))
    conn.commit(); conn.close()

def make_admin_db(user_id):
    conn = db_conn(); c = conn.cursor()
    c.execute("UPDATE users SET is_admin = 1 WHERE id = ?", (user_id,))
    conn.commit(); conn.close()

def get_all_private_rooms():
    conn = db_conn(); c = conn.cursor()
    c.execute("SELECT room_id, name, owner_id, created_at FROM private_rooms WHERE is_active = 1")
    rooms = c.fetchall(); conn.close()
    return rooms

# ==================== توابع تگ ====================

def add_user_tag(user_id, tag_name, tag_color='#8b5cf6', tag_glow='#8b5cf6', created_by=None):
    conn = db_conn(); c = conn.cursor()
    c.execute("INSERT INTO user_tags (user_id, tag_name, tag_color, tag_glow, created_by, created_at) VALUES (?, ?, ?, ?, ?, ?)",
              (user_id, tag_name, tag_color, tag_glow, created_by, datetime.now()))
    conn.commit(); conn.close()

def remove_user_tag(tag_id):
    conn = db_conn(); c = conn.cursor()
    c.execute("DELETE FROM user_tags WHERE id = ?", (tag_id,))
    conn.commit(); conn.close()

def get_user_tags(user_id):
    conn = db_conn(); c = conn.cursor()
    c.execute("SELECT id, tag_name, tag_color, tag_glow FROM user_tags WHERE user_id = ?", (user_id,))
    tags = c.fetchall(); conn.close()
    return [{'id': t[0], 'tag_name': t[1], 'tag_color': t[2], 'tag_glow': t[3]} for t in tags]

def get_all_tags():
    conn = db_conn(); c = conn.cursor()
    c.execute('''SELECT ut.id, ut.tag_name, ut.tag_color, ut.tag_glow, u.username, ut.created_at
                 FROM user_tags ut JOIN users u ON ut.user_id = u.id ORDER BY ut.created_at DESC''')
    tags = c.fetchall(); conn.close()
    return [{'id': t[0], 'tag_name': t[1], 'tag_color': t[2], 'tag_glow': t[3], 'username': t[4], 'created_at': t[5]} for t in tags]

# ==================== توابع پارتیکل ====================

def set_avatar_particle(user_id, particle_color='#8b5cf6', particle_count=8, particle_size=3, 
                         orbit_speed=8.0, orbit_radius=70, glow_intensity=0.6, created_by=None):
    conn = db_conn(); c = conn.cursor()
    c.execute("SELECT id FROM avatar_particles WHERE user_id = ?", (user_id,))
    existing = c.fetchone()
    if existing:
        c.execute('''UPDATE avatar_particles SET particle_color=?, particle_count=?, particle_size=?, 
            orbit_speed=?, orbit_radius=?, glow_intensity=? WHERE user_id=?''',
            (particle_color, particle_count, particle_size, orbit_speed, orbit_radius, glow_intensity, user_id))
    else:
        c.execute('''INSERT INTO avatar_particles (user_id, particle_color, particle_count, particle_size, 
            orbit_speed, orbit_radius, glow_intensity, created_by, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
            (user_id, particle_color, particle_count, particle_size, orbit_speed, orbit_radius, glow_intensity, created_by, datetime.now()))
    conn.commit(); conn.close()

def remove_avatar_particle(user_id):
    conn = db_conn(); c = conn.cursor()
    c.execute("DELETE FROM avatar_particles WHERE user_id = ?", (user_id,))
    conn.commit(); conn.close()

def get_avatar_particle(user_id):
    conn = db_conn(); c = conn.cursor()
    c.execute("SELECT * FROM avatar_particles WHERE user_id = ?", (user_id,))
    p = c.fetchone(); conn.close()
    if p: return {'id': p[0], 'user_id': p[1], 'particle_color': p[2], 'particle_count': p[3], 
                  'particle_size': p[4], 'orbit_speed': p[5], 'orbit_radius': p[6], 'glow_intensity': p[7]}
    return None

def get_all_avatar_particles():
    conn = db_conn(); c = conn.cursor()
    c.execute('''SELECT ap.id, ap.particle_color, ap.particle_count, u.username, ap.created_at
                 FROM avatar_particles ap JOIN users u ON ap.user_id = u.id ORDER BY ap.created_at DESC''')
    particles = c.fetchall(); conn.close()
    return [{'id': p[0], 'particle_color': p[1], 'particle_count': p[2], 'username': p[3], 'created_at': p[4]} for p in particles]

# ==================== توابع PRO ====================

def set_pro_account(user_id, pro_type='monthly', given_by=None):
    now = datetime.now()
    durations = {'weekly': timedelta(days=7), 'monthly': timedelta(days=30), 'yearly': timedelta(days=365), 'lifetime': timedelta(days=9999)}
    pro_until = now + durations.get(pro_type, timedelta(days=30))
    conn = db_conn(); c = conn.cursor()
    try:
        c.execute("SELECT id FROM pro_accounts WHERE user_id = ?", (user_id,))
        if c.fetchone():
            c.execute("UPDATE pro_accounts SET pro_type=?, pro_until=?, is_active=1, given_by=? WHERE user_id=?",
                      (pro_type, pro_until, given_by, user_id))
        else:
            c.execute("INSERT INTO pro_accounts (user_id, pro_type, pro_until, is_active, given_by, given_at) VALUES (?, ?, ?, 1, ?, ?)",
                      (user_id, pro_type, pro_until, given_by, now))
        conn.commit()
        c.execute("DELETE FROM user_tags WHERE user_id = ? AND tag_name = 'PRO'", (user_id,))  # v1.6: تمدید تگ تکراری نسازد
        c.execute("INSERT INTO user_tags (user_id, tag_name, tag_color, tag_glow, created_by, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                  (user_id, 'PRO', '#ffffff', '#ffffff', given_by, now))
        c.execute("SELECT id FROM avatar_particles WHERE user_id = ?", (user_id,))
        if c.fetchone():
            c.execute("UPDATE avatar_particles SET particle_color=?, particle_count=?, particle_size=?, orbit_speed=?, orbit_radius=?, glow_intensity=? WHERE user_id=?",
                      ('#ffffff', 12, 3, 6.0, 75, 0.8, user_id))
        else:
            c.execute("INSERT INTO avatar_particles (user_id, particle_color, particle_count, particle_size, orbit_speed, orbit_radius, glow_intensity, created_by, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                      (user_id, '#ffffff', 12, 3, 6.0, 75, 0.8, given_by, now))
        conn.commit()
    except Exception as e: conn.rollback(); raise e
    finally: conn.close()

def remove_pro_account(user_id):
    conn = db_conn(); c = conn.cursor()
    try:
        c.execute("DELETE FROM pro_accounts WHERE user_id = ?", (user_id,))
        c.execute("DELETE FROM user_tags WHERE user_id = ? AND tag_name = 'PRO'", (user_id,))
        c.execute("DELETE FROM avatar_particles WHERE user_id = ? AND particle_color = '#ffffff'", (user_id,))
        conn.commit()
    except Exception as e: conn.rollback(); raise e
    finally: conn.close()

def _parse_dt(v):
    """پارس امن تاریخ دیتابیس (با/بدون میکروثانیه) — قبلاً فقط یک فرمت پذیرفته می‌شد و is_pro_user کرش می‌کرد"""
    if not v: return None
    if isinstance(v, datetime): return v
    s = str(v).strip()[:26]
    for fmt in ('%Y-%m-%d %H:%M:%S.%f', '%Y-%m-%d %H:%M:%S', '%Y-%m-%dT%H:%M:%S.%f', '%Y-%m-%dT%H:%M:%S'):
        try: return datetime.strptime(s, fmt)
        except ValueError: pass
    return None

def get_pro_account(user_id):
    conn = db_conn(); c = conn.cursor()
    c.execute("SELECT * FROM pro_accounts WHERE user_id = ? AND is_active = 1", (user_id,))
    p = c.fetchone(); conn.close()
    if p:
        pro_until = _parse_dt(p[3])
        if pro_until and pro_until < datetime.now() and p[2] != 'lifetime':
            conn = db_conn(); c = conn.cursor()
            c.execute("UPDATE pro_accounts SET is_active = 0 WHERE user_id = ?", (user_id,))
            conn.commit(); conn.close(); return None
        return {'id': p[0], 'user_id': p[1], 'pro_type': p[2], 'pro_until': p[3], 'is_active': p[4]}
    return None

def is_pro_user(user_id):
    return get_pro_account(user_id) is not None

def get_all_pro_accounts():
    conn = db_conn(); c = conn.cursor()
    c.execute('''SELECT pa.id, pa.pro_type, pa.pro_until, u.username, pa.given_at
                 FROM pro_accounts pa JOIN users u ON pa.user_id = u.id 
                 WHERE pa.is_active = 1 ORDER BY pa.given_at DESC''')
    pros = c.fetchall(); conn.close()
    return [{'id': p[0], 'pro_type': p[1], 'pro_until': p[2], 'username': p[3], 'given_at': p[4]} for p in pros]

# ==================== توابع پیوی ====================

def get_or_create_private_chat(sender_id, receiver_id):
    """پیدا کردن یا ساختن چت خصوصی بین دو نفر"""
    conn = db_conn()
    c = conn.cursor()
    
    c.execute('''SELECT id FROM private_chats 
                 WHERE ((sender_id = ? AND receiver_id = ?) OR (sender_id = ? AND receiver_id = ?))
                 AND is_active = 1''',
              (sender_id, receiver_id, receiver_id, sender_id))
    chat = c.fetchone()
    
    if chat:
        conn.close()
        return chat[0]
    
    now = datetime.now()
    c.execute('''INSERT INTO private_chats (sender_id, receiver_id, created_at, updated_at)
                 VALUES (?, ?, ?, ?)''', (sender_id, receiver_id, now, now))
    conn.commit()
    chat_id = c.lastrowid
    conn.close()
    return chat_id

def get_user_private_chats(user_id):
    """لیست چت‌های خصوصی کاربر — ناخوانده به‌ازای هر طرف (بج فقط برای گیرنده‌ی پیام) + تگ‌ها با یک کوئری"""
    conn = db_conn()
    c = conn.cursor()
    c.execute('''SELECT pc.id, pc.last_message, pc.last_time, pc.unread_count,
                 CASE WHEN pc.sender_id = ? THEN u2.username ELSE u1.username END as other_user,
                 CASE WHEN pc.sender_id = ? THEN u2.avatar ELSE u1.avatar END as other_avatar,
                 CASE WHEN pc.sender_id = ? THEN u2.name ELSE u1.name END as other_name,
                 CASE WHEN pc.sender_id = ? THEN u2.is_admin ELSE u1.is_admin END as other_official,
                 CASE WHEN pc.sender_id = ? THEN u2.id ELSE u1.id END as other_id,
                 pc.sender_id, pc.unread_s, pc.unread_r,
                 pc.last_file_type, pc.last_user
                 FROM private_chats pc
                 JOIN users u1 ON pc.sender_id = u1.id
                 JOIN users u2 ON pc.receiver_id = u2.id
                 WHERE (pc.sender_id = ? OR pc.receiver_id = ?) AND pc.is_active = 1
                 ORDER BY pc.updated_at DESC''',
              (user_id, user_id, user_id, user_id, user_id, user_id, user_id))
    chats = c.fetchall()
    tag_map = batch_user_tags([c_[8] for c_ in chats])
    # v1.3.2 — ستاره‌ی PRO واقعی طرف مقابل (قبلاً همیشه False بود):
    # همه‌ی پروها با «یک» کوئری، بدون N+1.
    pro_ids = set()
    if chats:
        ids = list({c_[8] for c_ in chats if c_[8]})
        ph = ','.join('?' for _ in ids)
        try:
            c.execute(f"SELECT DISTINCT user_id FROM pro_accounts WHERE is_active = 1 AND user_id IN ({ph})", ids)
            pro_ids = {r[0] for r in c.fetchall()}
        except Exception:
            pro_ids = set()
    conn.close()
    out = []
    for c_ in chats:
        # ناخوانده‌ی واقعی: من فرستنده‌ام => ستون فرستنده، من گیرنده‌ام => ستون گیرنده
        unread = (c_[10] if c_[9] == user_id else c_[11]) or 0
        out.append({'id': c_[0], 'last_message': c_[1],
                    # v1.5.0 — last_time همیشه «HH:MM» خالص برمی‌گردد؛ قبلاً
                    # datetime خام با میلی‌ثانیه («09:23:45.123456») به اپ
                    # می‌رسید و سطر لیست چت‌ها ساعتِ کثیف نشان می‌داد
                    'last_time': fmt_hhmm(c_[2]), 'unread_count': unread,
                    'other_user': c_[4], 'other_avatar': c_[5], 'other_name': (c_[6] or '').strip(),
                    'other_official': bool(c_[7]), 'other_pro': c_[8] in pro_ids, 'other_id': c_[8],
                    # v1.4.0 — سیو مسیج: چتِ با خودمان (sender == receiver) تا کلاینت آیکون
                    # بوکمارک و عنوان «پیام‌های ذخیره‌شده» مثل تلگرام نشان دهد
                    'is_self': bool(c_[9] == c_[8]),
                    # v1.3.0 — نوع آخرین پیام: پیش‌نمایش خالی برای عکس/ویس/فایل دیگه نمی‌مونه
                    'other_tags': tag_map.get(c_[8], []),
                    'last_file_type': c_[12] if len(c_) > 12 else '',
                    'last_user': c_[13] if len(c_) > 13 else ''})
    return out

def get_private_chat_messages(chat_id, limit=60, before_id=None):
    """before_id: فقط پیام‌های قدیمی‌تر از این id (برای اسکرول به بالا / lazy pagination)"""
    conn = db_conn()
    c = conn.cursor()
    q = '''SELECT m.id, m.content, u.username, m.timestamp, u.avatar, m.file_url, m.file_type,
                 (SELECT COUNT(*) FROM message_reads mr 
                  WHERE mr.message_id = m.id 
                  AND mr.user_id != m.user_id) as read_count,
                 m.reply_to, m.forward_from, m.forward_from_username, m.media_meta
                 FROM messages m JOIN users u ON m.user_id = u.id
                 WHERE m.private_chat_id = ? AND m.is_deleted = 0'''
    params = [chat_id]
    if before_id:
        q += ' AND m.id < ?'
        params.append(before_id)
    q += ' ORDER BY m.timestamp DESC LIMIT ?'
    params.append(limit)
    c.execute(q, params)
    msgs = c.fetchall()
    msgs.reverse()  # به ترتیب زمانی (قدیم به جدید) برای نمایش

    reactions_map = get_reactions_for_messages([m[0] for m in msgs])

    out = []
    for m in msgs:
        d = {'id': m[0], 'message': m[1], 'username': m[2],
             'timestamp': fmt_hhmm(m[3]),
             'date_key': date_key_of(m[3]),
             'date_label': date_label_of(m[3]),
             'avatar': m[4], 'file_url': m[5], 'file_type': m[6],
             'is_read': m[7] > 0,
             'forward_from': m[9] or '', 'forward_from_username': m[10] or '',
             'reactions': reactions_map.get(m[0], []),
             'media_meta': norm_media_meta_out(m[11] if len(m) > 11 else None, m[5] or '', m[6] or '')}
        if m[8]:
            snap = get_reply_snapshot(m[8])
            if snap: d.update(snap)
        out.append(d)
    return out
             
def mark_pv_as_read(chat_id, user_id):
    """علامت‌گذاری پیوی به عنوان خوانده شده — فقط سمتِ خود کاربر صفر میشه"""
    conn = db_conn()
    c = conn.cursor()
    c.execute('''UPDATE private_chats SET
                 unread_s = CASE WHEN sender_id = ? THEN 0 ELSE unread_s END,
                 unread_r = CASE WHEN receiver_id = ? THEN 0 ELSE unread_r END
                 WHERE id = ?''', (user_id, user_id, chat_id))
    conn.commit()

# ==================== توابع بلاک ====================

def block_user(blocker_id, blocked_id):
    """بلاک کردن کاربر"""
    conn = db_conn()
    c = conn.cursor()
    try:
        c.execute("INSERT OR IGNORE INTO blocked_users (blocker_id, blocked_id, created_at) VALUES (?, ?, ?)",
                  (blocker_id, blocked_id, datetime.now()))
        conn.commit()
        return True
    except:
        return False
    finally:
        conn.close()

def unblock_user(blocker_id, blocked_id):
    """آنبلاک کردن کاربر"""
    conn = db_conn()
    c = conn.cursor()
    c.execute("DELETE FROM blocked_users WHERE blocker_id = ? AND blocked_id = ?",
              (blocker_id, blocked_id))
    conn.commit()
    conn.close()

def is_user_blocked(blocker_id, blocked_id):
    """چک کن آیا کاربر بلاک شده یا نه"""
    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT 1 FROM blocked_users WHERE blocker_id = ? AND blocked_id = ?",
              (blocker_id, blocked_id))
    result = c.fetchone()
    conn.close()
    return result is not None

def get_blocked_users(user_id):
    """لیست کاربرایی که من بلاک کردم"""
    conn = db_conn()
    c = conn.cursor()
    c.execute('''SELECT u.id, u.username, u.avatar, bu.created_at
                 FROM blocked_users bu JOIN users u ON bu.blocked_id = u.id
                 WHERE bu.blocker_id = ? ORDER BY bu.created_at DESC''', (user_id,))
    users = c.fetchall()
    conn.close()
    return [{'id': u[0], 'username': u[1], 'avatar': u[2], 'created_at': u[3]} for u in users]

# ==================== توابع فالو ====================

def follow_user(follower_id, following_id):
    """فالو کردن کاربر"""
    conn = db_conn()
    c = conn.cursor()
    try:
        c.execute("INSERT OR IGNORE INTO follows (follower_id, following_id, created_at) VALUES (?, ?, ?)",
                  (follower_id, following_id, datetime.now()))
        conn.commit()
        return True
    except:
        return False
    finally:
        conn.close()

def unfollow_user(follower_id, following_id):
    """آنفالو کردن کاربر"""
    conn = db_conn()
    c = conn.cursor()
    c.execute("DELETE FROM follows WHERE follower_id = ? AND following_id = ?",
              (follower_id, following_id))
    conn.commit()
    conn.close()

def is_following(follower_id, following_id):
    """چک کن آیا کاربر فالو شده یا نه"""
    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT 1 FROM follows WHERE follower_id = ? AND following_id = ?",
              (follower_id, following_id))
    result = c.fetchone()
    conn.close()
    return result is not None

def get_followers(user_id):
    """لیست فالوئرهای یه کاربر (کسایی که اونو فالو کردن)"""
    conn = db_conn()
    c = conn.cursor()
    c.execute('''SELECT u.id, u.username, u.avatar, f.created_at
                 FROM follows f JOIN users u ON f.follower_id = u.id
                 WHERE f.following_id = ?
                 ORDER BY f.created_at DESC''', (user_id,))
    users = c.fetchall()
    conn.close()
    return [{'id': u[0], 'username': u[1], 'avatar': u[2], 'created_at': u[3]} for u in users]

def get_following(user_id):
    """لیست فالوئینگ‌های یه کاربر (کسایی که اون فالوشون کرده)"""
    conn = db_conn()
    c = conn.cursor()
    c.execute('''SELECT u.id, u.username, u.avatar, f.created_at
                 FROM follows f JOIN users u ON f.following_id = u.id
                 WHERE f.follower_id = ?
                 ORDER BY f.created_at DESC''', (user_id,))
    users = c.fetchall()
    conn.close()
    return [{'id': u[0], 'username': u[1], 'avatar': u[2], 'created_at': u[3]} for u in users]

def get_follow_counts(user_id):
    """تعداد فالوئرها و فالوئینگ‌ها"""
    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT COUNT(*) FROM follows WHERE following_id = ?", (user_id,))
    followers_count = c.fetchone()[0]
    c.execute("SELECT COUNT(*) FROM follows WHERE follower_id = ?", (user_id,))
    following_count = c.fetchone()[0]
    conn.close()
    return {'followers': followers_count, 'following': following_count}

# ==================== Flask Login ====================

# ==================== v1.6 — مدیریت نشست‌های هر دستگاه ====================
def init_session_tables():
    conn = db_conn(); c = conn.cursor()
    try:
        c.execute('''CREATE TABLE IF NOT EXISTS login_tokens (
            token TEXT PRIMARY KEY, user_id INTEGER, ip TEXT, device TEXT,
            created_at TIMESTAMP, last_active TIMESTAMP)''')
        c.execute("CREATE INDEX IF NOT EXISTS idx_login_tokens_user ON login_tokens(user_id)")
    except Exception: pass
    try: c.execute("ALTER TABLE user_sessions ADD COLUMN token TEXT")
    except Exception: pass
    try: c.execute("CREATE INDEX IF NOT EXISTS idx_sessions_token ON user_sessions(token)")
    except Exception: pass
    conn.commit()
    # بعد از ری‌استارت همه‌ی سوکت‌های قبلی مرده‌اند؛ ردیف‌های مانده نباید در لیست نشست‌ها بماند
    try:
        c.execute("DELETE FROM user_sessions"); conn.commit()
    except Exception: pass

init_session_tables()

_token_cache = {}   # token -> (ts, ok)
_TOKEN_TTL = 30.0
MAX_TOKENS_PER_USER = 25

def _token_valid(token, user_id):
    now = _time.time()
    hit = _token_cache.get(token)
    if hit and now - hit[0] < _TOKEN_TTL:
        return hit[1]
    ok = False
    try:
        conn = db_conn(); c = conn.cursor()
        c.execute("SELECT user_id FROM login_tokens WHERE token = ?", (token,))
        row = c.fetchone()
        ok = bool(row and row[0] == user_id)
        if ok:
            c.execute("UPDATE login_tokens SET last_active = ? WHERE token = ?", (datetime.now(), token))
            conn.commit()
    except Exception:
        return True   # خرابی لحظه‌ای دیتابیس نباید همه را logout کند
    if len(_token_cache) > 20000: _token_cache.clear()
    _token_cache[token] = (now, ok)
    return ok

def _issue_login_token(user_id):
    """بعد از لاگین/ثبت‌نام: توکن یکتای این دستگاه ساخته و داخل کوکی سشن گذاشته می‌شود"""
    try:
        token = secrets.token_hex(24)
        now = datetime.now()
        conn = db_conn(); c = conn.cursor()
        c.execute("INSERT INTO login_tokens (token, user_id, ip, device, created_at, last_active) VALUES (?, ?, ?, ?, ?, ?)",
                  (token, user_id, _client_ip(), _client_device(), now, now))
        # سقف تعداد دستگاه به ازای هر کاربر: قدیمی‌ترین‌ها حذف می‌شوند
        c.execute('''DELETE FROM login_tokens WHERE user_id = ? AND token NOT IN (
                     SELECT token FROM login_tokens WHERE user_id = ? ORDER BY last_active DESC LIMIT ?)''',
                  (user_id, user_id, MAX_TOKENS_PER_USER))
        conn.commit()
        session['st'] = token
        _token_cache[token] = (_time.time(), True)
        return token
    except Exception:
        return None

def _kill_token(token):
    """حذف یک دستگاه: توکن + سوکت‌هایش؛ لیست sid سوکت‌ها برای قطع اتصال برمی‌گردد"""
    sids = []
    try:
        conn = db_conn(); c = conn.cursor()
        c.execute("SELECT sid FROM user_sessions WHERE token = ?", (token,))
        sids = [r[0] for r in c.fetchall()]
        c.execute("DELETE FROM login_tokens WHERE token = ?", (token,))
        c.execute("DELETE FROM user_sessions WHERE token = ?", (token,))
        conn.commit()
    except Exception:
        pass
    _token_cache.pop(token, None)
    return sids

def kill_all_user_sessions(user_id):
    """همه‌ی نشست‌های یک کاربر (برای بن/تغییر رمز): توکن‌ها، سوکت‌ها و کوکی‌های بدون توکن (epoch)"""
    sids = []
    try:
        conn = db_conn(); c = conn.cursor()
        c.execute("SELECT token FROM login_tokens WHERE user_id = ?", (user_id,))
        for (t,) in c.fetchall(): _token_cache.pop(t, None)
        c.execute("SELECT sid FROM user_sessions WHERE user_id = ?", (user_id,))
        sids = [r[0] for r in c.fetchall()]
        c.execute("DELETE FROM login_tokens WHERE user_id = ?", (user_id,))
        c.execute("DELETE FROM user_sessions WHERE user_id = ?", (user_id,))
        c.execute("UPDATE users SET session_epoch = COALESCE(session_epoch, 0) + 1 WHERE id = ?", (user_id,))
        conn.commit()
    except Exception:
        pass
    for sid in sids:
        try: socketio.server.disconnect(sid)
        except Exception: pass

class UserClass:
    def __init__(self, user_data):
        self.id = user_data['id']; self.username = user_data['username']
        self.gender = user_data.get('gender', 'other'); self.bio = user_data['bio']
        self.avatar = user_data['avatar']; self.is_admin = user_data['is_admin']
        self.is_banned = user_data['is_banned']
        self.chat_bg = user_data.get('chat_bg', '') or ''
        self.name = user_data.get('name', '') or user_data['username']
        self.session_epoch = int(user_data.get('session_epoch', 0) or 0)

    def is_authenticated(self): return True
    def is_active(self): return not self.is_banned
    def is_anonymous(self): return False
    def get_id(self):
        # v1.4.0 — epoch داخل شناسه‌ی کوکی می‌نشیند؛ افزایش epoch => کوکی‌های قبلی مرده‌اند
        return f"{self.id}.{self.session_epoch}"

@login_manager.user_loader
def load_user(user_id):
    try:
        uid_s, ep_s = str(user_id).split('.', 1)
        uid = int(uid_s)
        epoch = int(ep_s)
    except (ValueError, AttributeError):
        # فرمت قدیمی بدون epoch — فقط شناسه‌ی خالص
        try:
            uid = int(user_id); epoch = None
        except (TypeError, ValueError):
            return None
    user_data = get_user(user_id=uid)
    if not user_data:
        return None
    # v1.4.0 — اگر epoch کوکی با دیتابیس نخواند، نشست باطل است (revoke واقعی)
    if epoch is not None and epoch != int(user_data.get('session_epoch', 0) or 0):
        return None
    # v1.6 — کاربر بن‌شده دیگر با کوکی قدیمی وارد نمی‌ماند (is_active متد بود و همیشه truthy)
    if user_data.get('is_banned'):
        return None
    # v1.6 — توکن نشستِ هر دستگاه: با revoke دستگاه، کوکی همان دستگاه واقعاً بی‌اعتبار می‌شود.
    # کوکی‌های قدیمی بدون توکن همچنان پذیرفته می‌شوند (سازگاری با اپِ در حال استفاده).
    try:
        st = session.get('st')
    except Exception:
        st = None
    if st and not _token_valid(st, user_data['id']):
        return None
    return UserClass(user_data)

# ==================== روت‌های صفحه ====================

@app.route('/')
def index():
    if current_user.is_authenticated:
        follow_counts = get_follow_counts(current_user.id)
        _ci = db_conn().cursor()
        _ci.execute("SELECT COUNT(*) FROM private_chats WHERE (sender_id = ? OR receiver_id = ?) AND is_active = 1",
                    (current_user.id, current_user.id))
        private_chats_count = _ci.fetchone()[0]   # v1.6: قبلاً کل لیست چت‌ها فقط برای شمارش ساخته می‌شد
        return render_template('index.html', follow_counts=follow_counts,
                               private_chats_count=private_chats_count,
                               is_pro=is_pro_user(current_user.id))
    return redirect(url_for('login'))

# ==================== هلپرهای فرمت تاریخ/ساعت (مشترک بین پیوی و گروه) ====================
def fmt_hhmm(raw_ts):
    if not raw_ts:
        return ''
    ts_str = str(raw_ts)
    time_part = ts_str.split(' ')[1] if ' ' in ts_str else ts_str
    return time_part[:5]

def date_key_of(raw_ts):
    if not raw_ts:
        return ''
    ts_str = str(raw_ts)
    return ts_str.split(' ')[0] if ' ' in ts_str else ts_str

def date_label_of(raw_ts):
    date_part = date_key_of(raw_ts)
    if not date_part:
        return ''
    try:
        d = datetime.strptime(date_part, '%Y-%m-%d').date()
    except Exception:
        return date_part
    diff = (datetime.now().date() - d).days
    if diff == 0:
        return 'today'
    elif diff == 1:
        return 'yesterday'
    else:
        return date_part  # ISO date; frontend formats it per the active language

@app.route('/api/general_messages')
@login_required
def api_general_messages():
    """تاریخچه‌ی چت عمومی — با پشتیبانی صفحه‌بندی: ?before=<id>&limit=<n>"""
    try:
        before_id = int(request.args.get('before', 0) or 0)
    except Exception:
        before_id = 0
    try:
        limit = min(max(int(request.args.get('limit', 60) or 60), 10), 100)
    except Exception:
        limit = 60
    conn = db_conn()
    c = conn.cursor()
    q = '''SELECT m.id, m.content, u.username, m.timestamp, u.avatar, m.file_url, m.file_type,
                 m.reply_to, m.forward_from, m.forward_from_username,
                 u.name,
                 (SELECT COUNT(*) FROM pro_accounts pa WHERE pa.user_id = u.id AND pa.is_active = 1),
                 u.is_admin, m.media_meta
                 FROM messages m JOIN users u ON m.user_id = u.id
                 WHERE m.room = 'general' AND m.private_chat_id IS NULL AND m.is_deleted = 0'''
    params = []
    if before_id:
        q += ' AND m.id < ?'
        params.append(before_id)
    q += ' ORDER BY m.timestamp DESC LIMIT ?'
    params.append(limit)
    c.execute(q, params)
    rows = c.fetchall()
    messages = []
    for r in rows[::-1]:
        d = {'message_id': r[0], 'message': r[1], 'username': r[2],
             'timestamp': fmt_hhmm(r[3]),
             'date_key': date_key_of(r[3]), 'date_label': date_label_of(r[3]),
             'avatar': r[4], 'file_url': r[5], 'file_type': r[6],
             'forward_from': r[8] or '', 'forward_from_username': r[9] or '',
             # v1.2.1 — GLOBAL chat finally gets real names + badges
             'display_name': (r[10] or '').strip(),
             'is_pro': bool(r[11]),
             'is_official': bool(r[12]),
             'media_meta': norm_media_meta_out(r[13], r[5] or '', r[6] or ''),
             'is_me': r[2] == current_user.username}
        if r[7]:
            snap = get_reply_snapshot(r[7])
            if snap: d.update(snap)
        messages.append(d)
    return jsonify(messages)

@app.route('/register', methods=['GET', 'POST'])
def register():
    if request.method == 'POST':
        username = (request.form.get('username') or '').strip()
        gender = request.form.get('gender', 'other')
        password = request.form.get('password') or ''
        # v1.4.0 — اعتبارسنجی سمت سرور: نام کاربری و رمز عبور قوی‌تر
        if not re.match(r'^[A-Za-z0-9_]{3,20}$', username):
            flash('نام کاربری باید ۳ تا ۲۰ حرف انگلیسی/عدد/_ باشد'); return redirect(url_for('register'))
        if len(password) < 4 or len(password) > 128:
            flash('رمز عبور باید حداقل ۴ کاراکتر باشد'); return redirect(url_for('register'))
        if gender not in ('male', 'female', 'other'):
            gender = 'other'
        if not _reg_rate_ok(_rate_ip()):
            flash('تعداد ثبت‌نام از این شبکه زیاد است؛ کمی بعد تلاش کنید'); return redirect(url_for('register'))
        _c0 = db_conn().cursor()
        _c0.execute("SELECT 1 FROM users WHERE LOWER(username) = LOWER(?)", (username,))
        # v1.6 — یکتایی بدون حساسیت به حروف + عدم تداخل با یوزرنیم کانال/گروه‌ها
        if get_user(username=username) or _c0.fetchone() or username_taken_by_room(username):
            flash('نام کاربری تکراری است'); return redirect(url_for('register'))
        conn = db_conn(); c = conn.cursor()
        hashed = generate_password_hash(password)
        is_admin = 1 if c.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 0 else 0
        c.execute("INSERT INTO users (username, gender, password, is_admin, created_at) VALUES (?, ?, ?, ?, ?)",
          (username, gender, hashed, is_admin, datetime.now()))
        conn.commit(); user_id = c.lastrowid; conn.close()
        user_data = get_user(user_id=user_id)
        session.clear()  # ضد session fixation
        login_user(UserClass(user_data))
        session.permanent = True  # کوکی ۴۵ روزه (نه سشن مرورگر)
        _issue_login_token(user_id)
        return redirect(url_for('index'))
    return render_template('register.html')

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        username = (request.form.get('username') or '').strip()
        password = request.form.get('password') or ''
        user_data = get_user(username=username)
        if user_data and check_password_hash(user_data['password'], password):
            if user_data['is_banned']: flash('حساب کاربری شما مسدود شده است'); return redirect(url_for('login'))
            session.clear()  # ضد session fixation
            login_user(UserClass(user_data))
            session.permanent = True  # کوکی ۴۵ روزه
            _issue_login_token(user_data['id'])
            with _rate_lock: _login_attempts.pop((_rate_ip(), username.lower()), None)  # ورود موفق شمارنده را پاک می‌کند
            return redirect(url_for('index'))
        flash('اطلاعات نادرست است')
    return render_template('login.html')

@app.route('/logout')
@login_required
def logout():
    try:
        st = session.get('st')
        if st: _kill_token(st)   # v1.6: خروج یعنی همین دستگاه از لیست نشست‌ها هم حذف شود
    except Exception:
        pass
    logout_user()
    return redirect(url_for('login'))

@app.route('/api/user_exists/<username>')
def api_user_exists(username):
    """چک می‌کنه یوزرنیمی که رو @mention کلیک شده اصلاً وجود داره یا نه - برای پیام‌های پیوی"""
    user_data = get_user(username=username)
    return jsonify({'exists': bool(user_data)})

@app.route('/api/user_profile/<username>')
def api_user_profile(username):
    """پروفایل کاربر برای پاپ‌آپ داخل گروه/چت - شامل کاور، قاب و آمار فالو، مثل تلگرام"""
    user_data = get_user(username=username)
    if not user_data:
        return jsonify({'error': 'not_found'}), 404
    is_pro = is_pro_user(user_data['id'])
    follow_counts = get_follow_counts(user_data['id'])
    created_at = user_data['created_at']
    joined = ''
    if created_at:
        try:
            parts = str(created_at).split(' ')[0].split('-')
            joined = f"{parts[2]}/{parts[1]}/{parts[0]}" if len(parts) == 3 else str(created_at).split(' ')[0]
        except Exception:
            joined = str(created_at).split(' ')[0]
    return jsonify({
        'username': user_data['username'],
        'name': user_data['name'],
        'is_verified': bool(user_data['is_admin']),
        'bio': user_data['bio'],
        'avatar': user_data['avatar'],
        'followers': follow_counts['followers'],
        'following': follow_counts['following'],
        'created_at': joined,
        'created_at_raw': str(created_at)[:10] if created_at else '',
        'is_pro': is_pro,
        # فلگ‌های جدا تا صفحه‌ی پروفایل داخل index دقیقاً مثل profile.html کاور رو انتخاب کنه:
        # عکس آپلودشده > تم پرو > بک‌دراوند بلورِ آواتار
        'has_cover': bool(is_pro and user_data['profile_cover']),
        'has_theme': bool(is_pro and user_data['profile_theme'] and user_data['profile_theme'] != 'default'),
        'profile_cover': f"/static/uploads/{user_data['profile_cover']}" if (is_pro and user_data['profile_cover']) else '',
        'cover_theme_css': PROFILE_THEMES.get(user_data['profile_theme'], PROFILE_THEMES['default']),
        'avatar_frame_url': f"/static/frames/{AVATAR_FRAMES[user_data['avatar_frame']]['file']}" if (is_pro and user_data['avatar_frame'] and user_data['avatar_frame'] in AVATAR_FRAMES) else '',
        'is_banned': bool(user_data['is_banned']),
        'is_admin': bool(user_data['is_admin']),
        'is_following': is_following(current_user.id, user_data['id']) if current_user.is_authenticated else False,
        'is_self': current_user.is_authenticated and current_user.username == user_data['username'],
    })

@app.route('/profile/<username>')
def profile(username):
    """صفحه‌ی جداگانه‌ی پروفایل حذف شد — لینک‌های قدیمی حالا مستقیم می‌رن داخل index
    و پنل پروفایل درون‌اپی (مثل همون profile.html) باز می‌شه."""
    user_data = get_user(username=username)
    if not user_data: return redirect(url_for('index'))
    return redirect('/#user=' + urlquote(username))

USERNAME_RE = re.compile(r'^[A-Za-z0-9_]{3,20}$')

@app.route('/edit_profile', methods=['POST'])
@login_required
def edit_profile():
    is_ajax = request.headers.get('X-Requested-With') == 'XMLHttpRequest'

    bio = (request.form.get('bio', '') or '')[:2000]
    name = request.form.get('name', '').strip()[:100]
    new_username = request.form.get('username', '').strip()
    username_error = None

    conn = db_conn(); c = conn.cursor()

    # اسم نمایشی - بدون محدودیت (هر زبان/کاراکتری مجازه)
    if name:
        c.execute("UPDATE users SET name = ? WHERE id = ?", (name, current_user.id))

    # یوزرنیم - فقط انگلیسی/عدد/آندرلاین، بدون تکرار (حتی با یوزرنیم کانال‌ها و گروه‌ها)
    redirect_username = current_user.username
    if new_username and new_username != current_user.username:
        if not USERNAME_RE.match(new_username):
            username_error = 'یوزرنیم فقط می‌تواند شامل حروف انگلیسی، عدد و _ باشد (۳ تا ۲۰ کاراکتر)'
        elif username_taken_by_room(new_username):
            username_error = 'این یوزرنیم قبلاً استفاده شده است'
        else:
            c.execute("SELECT id FROM users WHERE username = ? AND id != ?", (new_username, current_user.id))
            if c.fetchone():
                username_error = 'این یوزرنیم قبلاً استفاده شده است'
            else:
                c.execute("UPDATE users SET username = ? WHERE id = ?", (new_username, current_user.id))
                redirect_username = new_username

    if username_error:
        if is_ajax:
            conn.close()
            return jsonify({'success': False, 'error': username_error}), 400
        flash(username_error, 'error')

    c.execute("UPDATE users SET bio = ? WHERE id = ?", (bio, current_user.id))

    avatar_filename = None
    if 'avatar' in request.files:
        file = request.files['avatar']
        if file and file.filename:
            # نام فایل یکتا با پسوند سالم: هم کش مرورگر می‌شکنه هم اگه اسم فایل
            # فارسی/کاراکتر عجیب باشه مشکل ساز نمیشه (secure_filename اسم فارسی رو خالی می‌کرد)
            ext = os.path.splitext(file.filename)[1].lower()
            if ext not in ('.png', '.jpg', '.jpeg', '.gif', '.webp'):
                ext = '.png'
            filename = f"{current_user.id}_avatar_{secrets.token_hex(4)}{ext}"
            file.save(os.path.join(app.config['UPLOAD_FOLDER'], filename))
            c.execute("UPDATE users SET avatar = ? WHERE id = ?", (filename, current_user.id))
            avatar_filename = filename

    conn.commit(); conn.close()

    if is_ajax:
        updated = get_user(user_id=current_user.id)
        return jsonify({
            'success': True,
            'username': updated['username'],
            'name': updated['name'],
            'bio': updated['bio'],
            'avatar': updated['avatar'],
        })

    flash('پروفایل به روز شد')
    return redirect(url_for('profile', username=redirect_username))

# ==================== تم پروفایل و کاور اختصاصی (Pro) ====================

@app.route('/customize_profile')
@login_required
def customize_profile():
    """صفحه‌ی انتخاب تم پروفایل و آپلود کاور اختصاصی - هر دو مخصوص Pro"""
    is_pro = is_pro_user(current_user.id)
    user_data = get_user(user_id=current_user.id)
    return render_template('customize_profile.html', profile_user=user_data, is_pro=is_pro,
                           themes=PROFILE_THEMES, avatar_frames=AVATAR_FRAMES, card_bg_themes=CARD_BG_THEMES)

@app.route('/save_avatar_frame', methods=['POST'])
@login_required
def save_avatar_frame():
    """ذخیره‌ی قاب دور عکس پروفایل - فقط برای کاربران Pro"""
    if not is_pro_user(current_user.id):
        flash('این قابلیت فقط برای کاربران Pro فعاله', 'error')
        return redirect(url_for('customize_profile'))
    frame = request.form.get('frame', '')
    if frame not in AVATAR_FRAMES:
        frame = ''
    conn = db_conn(); c = conn.cursor()
    c.execute("UPDATE users SET avatar_frame = ? WHERE id = ?", (frame, current_user.id))
    conn.commit(); conn.close()
    flash('قاب پروفایل به‌روزرسانی شد', 'success')
    return redirect(url_for('customize_profile'))

@app.route('/api/frames')
def api_frames():
    """v1.5.0 — لیست کامل قاب‌های پروفایل (کلید + اسم + URL تصویر).
    اپ این لیست را مستقیم از سرور می‌گیرد تا قاب جدید = بدون آپدیت اپ."""
    return jsonify([
        {'key': k, 'name': v['name'], 'url': f'/static/frames/{v["file"]}'}
        for k, v in AVATAR_FRAMES.items()
    ])

# ---------------------------------------------------------------------------
# v1.5.0 — بخش «بیشتر» قاب‌ها: پیش‌نمایش زنده‌ی قابِ انتخابی روی بنر خود کاربر
# سمت کلاینت انجام می‌شود؛ این اندپوینت فقط بانکِ قاب‌ها را می‌دهد (بالا).

@app.route('/save_profile_theme', methods=['POST'])
@login_required
def save_profile_theme():
    """ذخیره‌ی تم پروفایل - فقط برای کاربران Pro"""
    if not is_pro_user(current_user.id):
        flash('این قابلیت فقط برای کاربران Pro فعاله', 'error')
        return redirect(url_for('customize_profile'))
    theme = request.form.get('theme', 'default')
    if theme not in PROFILE_THEMES:
        theme = 'default'
    conn = db_conn(); c = conn.cursor()
    c.execute("UPDATE users SET profile_theme = ? WHERE id = ?", (theme, current_user.id))
    conn.commit(); conn.close()
    flash('تم پروفایل به‌روزرسانی شد', 'success')
    return redirect(url_for('customize_profile'))

@app.route('/save_card_color', methods=['POST'])
@login_required
def save_card_color():
    """ذخیره‌ی رنگ پس‌زمینه‌ی کارت پروفایل - جدا از تم کاور، فقط برای کاربران Pro.
    فقط از بین رنگ‌های آماده و امن (CARD_BG_THEMES) انتخاب می‌شه، نه رنگ دلخواه،
    چون رنگ دلخواه باعث می‌شد کنتراست دکمه‌ها/متن‌ها خراب بشه."""
    if not is_pro_user(current_user.id):
        flash('این قابلیت فقط برای کاربران Pro فعاله', 'error')
        return redirect(url_for('customize_profile'))
    key = (request.form.get('card_color') or 'default').strip()
    if key not in CARD_BG_THEMES:
        key = 'default'
    conn = db_conn(); c = conn.cursor()
    c.execute("UPDATE users SET card_color = ? WHERE id = ?", (key, current_user.id))
    conn.commit(); conn.close()
    flash('رنگ کارت پروفایل به‌روزرسانی شد', 'success')
    return redirect(url_for('customize_profile'))

@app.route('/upload_profile_cover', methods=['POST'])
@login_required
def upload_profile_cover():
    """آپلود عکس کاور اختصاصی پشت پروفایل - فقط کاربران Pro"""
    if not is_pro_user(current_user.id):
        flash('این قابلیت فقط برای کاربران Pro فعاله', 'error')
        return redirect(url_for('customize_profile'))

    if 'cover' not in request.files:
        flash('فایلی انتخاب نشده', 'error')
        return redirect(url_for('customize_profile'))
    file = request.files['cover']
    if not file or file.filename == '':
        flash('فایلی انتخاب نشده', 'error')
        return redirect(url_for('customize_profile'))

    ext = file.filename.rsplit('.', 1)[-1].lower() if '.' in file.filename else ''
    if ext not in PROFILE_COVER_ALLOWED_EXTENSIONS:
        flash('فقط عکس (jpg, png, webp) مجازه', 'error')
        return redirect(url_for('customize_profile'))

    filename = secure_filename(f"cover_{current_user.id}_{datetime.now().strftime('%Y%m%d%H%M%S')}_{secrets.token_hex(4)}.{ext}")
    file.save(os.path.join(app.config['UPLOAD_FOLDER'], filename))

    conn = db_conn(); c = conn.cursor()
    c.execute("SELECT profile_cover FROM users WHERE id = ?", (current_user.id,))
    row = c.fetchone()
    old_filename = row[0] if row else None
    c.execute("UPDATE users SET profile_cover = ? WHERE id = ?", (filename, current_user.id))
    conn.commit(); conn.close()

    if old_filename:
        old_path = os.path.join(app.config['UPLOAD_FOLDER'], old_filename)
        if os.path.exists(old_path):
            try: os.remove(old_path)
            except: pass

    flash('کاور پروفایل به‌روزرسانی شد', 'success')
    return redirect(url_for('customize_profile'))

@app.route('/remove_profile_cover', methods=['POST'])
@login_required
def remove_profile_cover():
    """حذف کاور اختصاصی و بازگشت به تم انتخابی - فقط کاربران Pro"""
    if not is_pro_user(current_user.id):
        flash('این قابلیت فقط برای کاربران Pro فعاله', 'error')
        return redirect(url_for('customize_profile'))

    conn = db_conn(); c = conn.cursor()
    c.execute("SELECT profile_cover FROM users WHERE id = ?", (current_user.id,))
    row = c.fetchone()
    old_filename = row[0] if row else None
    c.execute("UPDATE users SET profile_cover = '' WHERE id = ?", (current_user.id,))
    conn.commit(); conn.close()

    if old_filename:
        old_path = os.path.join(app.config['UPLOAD_FOLDER'], old_filename)
        if os.path.exists(old_path):
            try: os.remove(old_path)
            except: pass

    flash('کاور پروفایل حذف شد', 'success')
    return redirect(url_for('customize_profile'))

@app.route('/admin')
@login_required
def admin_panel():
    if not current_user.is_admin: flash('دسترسی غیرمجاز'); return redirect(url_for('index'))
    users = get_all_users(); private_rooms = get_all_private_rooms()
    all_tags = get_all_tags(); all_particles = get_all_avatar_particles(); all_pros = get_all_pro_accounts()
    return render_template('admin.html', users=users, private_rooms=private_rooms, 
                           all_tags=all_tags, all_particles=all_particles, all_pros=all_pros)

@app.route('/admin/ban/<int:user_id>')
@login_required
def ban_user_route(user_id):
    if not current_user.is_admin: return jsonify({'error': 'Unauthorized'}), 403
    if user_id == current_user.id: return jsonify({'error': 'نمی‌توانید خودتان را بن کنید'}), 400
    ban_user_db(user_id, current_user.id); return jsonify({'success': True})

@app.route('/admin/unban/<int:user_id>')
@login_required
def unban_user_route(user_id):
    if not current_user.is_admin: return jsonify({'error': 'Unauthorized'}), 403
    unban_user_db(user_id); return jsonify({'success': True})

@app.route('/admin/make_admin/<int:user_id>')
@login_required
def make_admin_route(user_id):
    if not current_user.is_admin: return jsonify({'error': 'Unauthorized'}), 403
    make_admin_db(user_id); return jsonify({'success': True})

# ==================== تگ ====================
@app.route('/admin/add_tag', methods=['POST'])
@login_required
def add_tag():
    if not current_user.is_admin: return jsonify({'error': 'Unauthorized'}), 403
    username = request.form.get('username'); tag_name = request.form.get('tag_name')
    tag_color = request.form.get('tag_color', '#8b5cf6'); tag_glow = request.form.get('tag_glow', '#8b5cf6')
    if not username or not tag_name: return jsonify({'error': 'نام کاربری و نام تگ الزامی است'}), 400    
    user = get_user(username=username)
    if not user: return jsonify({'error': 'کاربر پیدا نشد'}), 404
    tag_name = tag_name.strip()[:32]
    _col = re.compile(r'^(#[0-9a-fA-F]{3,8}|[a-zA-Z]{3,20})$')
    if not _col.match(tag_color or ''): tag_color = '#8b5cf6'
    if not _col.match(tag_glow or ''): tag_glow = '#8b5cf6'
    add_user_tag(user['id'], tag_name, tag_color, tag_glow, current_user.id)
    invalidate_user_enrichment(user['id'])
    return jsonify({'success': True, 'message': f'تگ {tag_name} به {username} اضافه شد'})

@app.route('/admin/remove_tag/<int:tag_id>')
@login_required
def remove_tag(tag_id):
    if not current_user.is_admin: return jsonify({'error': 'Unauthorized'}), 403
    remove_user_tag(tag_id); invalidate_user_enrichment(); return jsonify({'success': True})

@app.route('/get_user_tags/<int:user_id>')
def get_tags(user_id): return jsonify(get_user_tags(user_id))

# ==================== پارتیکل ====================
@app.route('/admin/set_particle', methods=['POST'])
@login_required
def set_particle():
    if not current_user.is_admin: return jsonify({'error': 'Unauthorized'}), 403
    username = request.form.get('username')
    if not username: return jsonify({'error': 'نام کاربری الزامی است'}), 400
    user = get_user(username=username)
    if not user: return jsonify({'error': 'کاربر پیدا نشد'}), 404
    def _num(key, default, lo, hi, cast):
        try: v = cast(request.form.get(key, default))
        except (TypeError, ValueError): v = default
        return max(lo, min(hi, v))
    _pc = request.form.get('particle_color', '#8b5cf6')
    if not re.match(r'^(#[0-9a-fA-F]{3,8}|[a-zA-Z]{3,20})$', _pc or ''): _pc = '#8b5cf6'
    set_avatar_particle(user_id=user['id'], particle_color=_pc,
                        particle_count=_num('particle_count', 8, 1, 40, int),
                        particle_size=_num('particle_size', 3, 1, 12, int),
                        orbit_speed=_num('orbit_speed', 8.0, 0.5, 60.0, float),
                        orbit_radius=_num('orbit_radius', 70, 20, 200, int),
                        glow_intensity=_num('glow_intensity', 0.6, 0.0, 2.0, float),
                        created_by=current_user.id)
    invalidate_user_enrichment(user['id'])
    return jsonify({'success': True, 'message': f'پارتیکل آواتار برای {username} تنظیم شد'})

@app.route('/admin/remove_particle/<int:user_id>')
@login_required
def remove_particle(user_id):
    if not current_user.is_admin: return jsonify({'error': 'Unauthorized'}), 403
    remove_avatar_particle(user_id); invalidate_user_enrichment(user_id); return jsonify({'success': True})

@app.route('/get_avatar_particle/<int:user_id>')
def get_particle(user_id): return jsonify(get_avatar_particle(user_id) or {})

@app.route('/get_avatar_particle_by_username/<username>')
def get_particle_by_username(username):
    user = get_user(username=username)
    if not user: return jsonify({})
    return jsonify(get_avatar_particle(user['id']) or {})

# ==================== PRO ====================
@app.route('/admin/set_pro', methods=['POST'])
@login_required
def set_pro():
    if not current_user.is_admin: return jsonify({'error': 'Unauthorized'}), 403
    username = request.form.get('username'); pro_type = request.form.get('pro_type', 'monthly')
    if not username: return jsonify({'error': 'نام کاربری الزامی است'}), 400
    user = get_user(username=username)
    if not user: return jsonify({'error': 'کاربر پیدا نشد'}), 404
    if pro_type not in ('weekly', 'monthly', 'yearly', 'lifetime'): pro_type = 'monthly'
    set_pro_account(user['id'], pro_type, current_user.id)
    invalidate_user_enrichment(user['id'])
    return jsonify({'success': True, 'message': f'پرو با موفقیت به {username} داده شد'})

@app.route('/admin/remove_pro/<int:user_id>')
@login_required
def remove_pro(user_id):
    if not current_user.is_admin: return jsonify({'error': 'Unauthorized'}), 403
    remove_pro_account(user_id); invalidate_user_enrichment(user_id); return jsonify({'success': True})

@app.route('/check_pro/<int:user_id>')
def check_pro(user_id): return jsonify({'is_pro': is_pro_user(user_id)})

# ==================== بلاک ====================

@app.route('/block_user/<username>')
@login_required
def block_user_route(username):
    user = get_user(username=username)
    if not user:
        if request.headers.get('X-Requested-With') == 'XMLHttpRequest': return jsonify({'success': False, 'error': 'کاربر پیدا نشد'}), 404
        flash('کاربر پیدا نشد'); return redirect(url_for('index'))
    if user['id'] == current_user.id:
        if request.headers.get('X-Requested-With') == 'XMLHttpRequest': return jsonify({'success': False, 'error': 'نمیتوانید خودتان را بلاک کنید'}), 400
        flash('نمیتوانید خودتان را بلاک کنید'); return redirect(url_for('profile', username=username))

    block_user(current_user.id, user['id'])
    # پیام‌های زنده‌ی بلاک/آنبلاک به طرفین اطلاع داده میشه
    # v1.6 — ایونت بلاک فقط به دو طرفِ درگیر می‌رسد (روم شخصی)، نه همه‌ی آنلاین‌ها
    socketio.emit('user_blocked', {'blocked_by': current_user.username, 'blocked_user': username},
                  room=[f"user_{current_user.id}", f"user_{user['id']}"])
    if request.headers.get('X-Requested-With') == 'XMLHttpRequest':
        return jsonify({'success': True})
    flash(f'{username} بلاک شد')
    return redirect(request.referrer or url_for('index'))

@app.route('/unblock_user/<username>')
@login_required
def unblock_user_route(username):
    user = get_user(username=username)
    if not user:
        if request.headers.get('X-Requested-With') == 'XMLHttpRequest': return jsonify({'success': False, 'error': 'کاربر پیدا نشد'}), 404
        flash('کاربر پیدا نشد'); return redirect(url_for('index'))

    unblock_user(current_user.id, user['id'])
    socketio.emit('user_unblocked', {'unblocked_by': current_user.username, 'unblocked_user': username},
                  room=[f"user_{current_user.id}", f"user_{user['id']}"])
    if request.headers.get('X-Requested-With') == 'XMLHttpRequest':
        return jsonify({'success': True})
    flash(f'{username} از بلاک خارج شد')
    return redirect(request.referrer or url_for('index'))

@app.route('/report_user/<username>')
@login_required
def report_user_route(username):
    """گزارش تخلف — فعلا فقط ثبت میشه (مثل قبل لینکش وجود داشت ولی روت نداشت)"""
    user = get_user(username=username)
    if not user:
        if request.headers.get('X-Requested-With') == 'XMLHttpRequest': return jsonify({'success': False, 'error': 'کاربر پیدا نشد'}), 404
        flash('کاربر پیدا نشد'); return redirect(url_for('index'))
    try:
        conn = db_conn()
        c = conn.cursor()
        c.execute("CREATE TABLE IF NOT EXISTS reports (id INTEGER PRIMARY KEY AUTOINCREMENT, reporter_id INTEGER, reported_id INTEGER, created_at TIMESTAMP)")
        c.execute("INSERT INTO reports (reporter_id, reported_id, created_at) VALUES (?, ?, ?)",
                  (current_user.id, user['id'], datetime.now()))
        conn.commit(); conn.close()
    except Exception:
        pass
    if request.headers.get('X-Requested-With') == 'XMLHttpRequest':
        return jsonify({'success': True})
    flash(f'گزارش شما برای {username} ثبت شد')
    return redirect(request.referrer or url_for('index'))

@app.route('/my_blocks')
@login_required
def my_blocks():
    blocked = get_blocked_users(current_user.id)
    return jsonify(blocked)

    # ==================== API مدیریت روم ====================


# ==================== v1.1.1 — پیام‌های پین‌شده (تلگرام‌وار) ====================

PIN_CAP = 5  # حداکثر تعداد پین همزمان در هر چت

def _file_preview_label(ft):
    ft = (ft or 'text').lower()
    return {'image': '🖼 عکس', 'video': '🎥 ویدیو', 'audio': '🎤 ویس', 'gif': 'GIF',
            'music': '🎵 موزیک', 'file': '📎 فایل'}.get(ft, '')

# ==================== v1.3.0 — متادیتای رسانه (ویس / موزیک) ====================
# پسوندهایی که ضبط ویس با آن‌ها شناخته میشه (record روی اندروید = m4a)
_VOICE_LIKE_EXTS = {'m4a', 'm4r', '3gp', 'amr', 'opus', 'caf'}

def norm_media_meta_out(meta, file_url='', file_type=''):
    """خروجی یکدست media_meta برای کلاینت‌ها: همیشه dict یا None.
    • متادیتایی که کلاینت موقع ارسال فرستاده (موزیک: عنوان/خواننده) حفظ میشه.
    • پیام‌های صوتی قدیمیِ بدون متادیتا از روی پسوند فایل تشخیص داده میشن
      (.m4a/.opus/.amr => ویس، بقیه مثل mp3/flac/wav => موزیک) — همین باگِ
      «آهنگ بعد از خروج از چت تبدیل به ویس میشه» رو کامل حل می‌کنه.
    • v1.3.2 — متادیتایی که kind و title نداره (مثلاً فقط dur/w/h) هم از روی
      پسوند فایل تکمیل میشه؛ وگرنه کلاینت آهنگ رو «ویس» نشون می‌داد."""
    parsed = None
    if meta:
        if isinstance(meta, dict):
            parsed = dict(meta)
        else:
            try:
                import json as _json
                v = _json.loads(meta)
                if isinstance(v, dict) and v:
                    parsed = dict(v)
            except Exception:
                parsed = None
    ft = (file_type or '').lower()
    if parsed is not None:
        if ft == 'audio' and not parsed.get('kind') and not parsed.get('title'):
            fu = file_url or ''
            ext = fu.rsplit('.', 1)[-1].lower() if '.' in fu else ''
            parsed['kind'] = 'voice' if ext in _VOICE_LIKE_EXTS else 'music'
        return parsed
    if ft == 'audio':
        fu = file_url or ''
        ext = fu.rsplit('.', 1)[-1].lower() if '.' in fu else ''
        kind = 'voice' if ext in _VOICE_LIKE_EXTS else 'music'
        return {'kind': kind, 'title': ''}
    return None


def pv_preview_fields(content, file_type, file_url='', media_meta=None):
    """v1.3.2 — فیلدهای «آخرین پیام» برای لیست چت‌ها (پیوی/فوروارد):
    • موزیک => last_file_type='music' و last_message=اسم تمیز آهنگ
    • ویس   => last_file_type='voice'
    بقیهٔ انواع بدون تغییر. خروجی: (last_file_type, last_message)"""
    ft = (file_type or 'text')
    if ft == 'audio':
        m = norm_media_meta_out(media_meta, file_url, 'audio') or {}
        kind = (m.get('kind') or '').strip()
        title = (m.get('title') or '').strip()
        text = (content or '').strip()
        if kind == 'music':
            return 'music', (title or text)[:100]
        if not kind:
            fu = file_url or ''
            ext = fu.rsplit('.', 1)[-1].lower() if '.' in fu else ''
            if ext in _VOICE_LIKE_EXTS:
                return 'voice', text[:100]
            return 'music', (title or text)[:100]
        return 'voice', text[:100]
    return ft, (content or '')[:100]

def media_preview_label(ft, file_url='', meta=None):
    """برچسب فارسیِ پیش‌نمایش برای پیام‌های بدون متن (ریپلای/پین/لیست چت)."""
    ft = (ft or 'text').lower()
    if ft == 'audio':
        m = norm_media_meta_out(meta, file_url, ft)
        kind = (m or {}).get('kind') or ''
        fu = file_url or ''
        ext = fu.rsplit('.', 1)[-1].lower() if '.' in fu else ''
        if kind == 'voice' or (not kind and ext in _VOICE_LIKE_EXTS):
            return '🎤 ویس'
        return '🎵 موزیک'
    return _file_preview_label(ft)

def _pin_rows_to_payload(rows):
    out = []
    for r in rows:
        txt = (r[2] or '').strip()
        # v1.3.0 — preview of media pins: real label (🎵 موزیک / 🎤 ویس / 📷 عکس)
        label = media_preview_label(r[4], (r[8] if len(r) > 8 else '') or '',
                                    (r[9] if len(r) > 9 else None)) if not txt else ''
        prev = label if not txt else ((txt[:120] + '…') if len(txt) > 120 else txt)
        out.append({'message_id': r[0], 'preview': prev, 'author': r[1],
                    'author_display': (r[5] or '').strip() or r[1],
                    'file_type': r[4] or 'text', 'time': fmt_hhmm(r[3]),
                    'date_key': date_key_of(r[3]), 'pinned_by': r[6], 'pinned_at': str(r[7] or '')})
    return out

def get_room_pins(room_db_id, limit=PIN_CAP):
    conn = db_conn(); c = conn.cursor()
    try:
        c.execute('''SELECT p.message_id, u.username, m.content, m.timestamp, m.file_type,
                            u.name, p.pinned_by, p.pinned_at, m.file_url, m.media_meta
                     FROM room_pinned_messages p
                     JOIN messages m ON m.id = p.message_id
                     JOIN users u ON u.id = m.user_id
                     WHERE p.room_db_id = ? AND m.is_deleted = 0
                     ORDER BY p.pinned_at DESC, p.id DESC LIMIT ?''', (room_db_id, limit))
        return _pin_rows_to_payload(c.fetchall())
    except Exception:
        return []
    finally:
        conn.close()

def get_pv_pins(chat_id, user_id, limit=PIN_CAP):
    conn = db_conn(); c = conn.cursor()
    try:
        c.execute('''SELECT p.message_id, u.username, m.content, m.timestamp, m.file_type,
                            u.name, p.owner_user_id, p.pinned_at, m.file_url, m.media_meta
                     FROM pv_pinned_messages p
                     JOIN messages m ON m.id = p.message_id
                     JOIN users u ON u.id = m.user_id
                     WHERE p.chat_id = ? AND p.owner_user_id = ? AND m.is_deleted = 0
                     ORDER BY p.pinned_at DESC, p.id DESC LIMIT ?''', (chat_id, user_id, limit))
        return _pin_rows_to_payload(c.fetchall())
    except Exception:
        return []
    finally:
        conn.close()

def _cap_pins(table, where_col, where_val):
    # بیشتر از PIN_CAP پین نگه نداریم — قدیمی‌ترین‌ها خودکار حذف میشن.
    conn = db_conn(); c = conn.cursor()
    try:
        c.execute(f'''DELETE FROM {table} WHERE {where_col} = ? AND id NOT IN (
                      SELECT id FROM {table} WHERE {where_col} = ?
                      ORDER BY pinned_at DESC, id DESC LIMIT ?)''',
                  (where_val, where_val, PIN_CAP))
        conn.commit()
    except Exception:
        pass
    finally:
        conn.close()

def advance_room_reads_for_viewers(room_str, room_db_id, msg_id, sender_id):
    # ریشه‌ای‌ترین فیکس بج ناخوانده: هر عضو آنلاینی که همین الان داخل رومِ سوکت
    # چت بازه (یعنی داره می‌بینه) read-stateش تا همین پیام جلو میره — پس بعد از
    # رفرش هم هیچ‌وقت «پیام جدید» برای چیزی که دیده بج نمی‌خوره.
    try:
        parts = socketio.server.manager.get_participants('/', room_str)
        sid_set = {sid for sid in parts}
    except Exception:
        return
    if not sid_set:
        return
    with _state_lock:
        sid_uid = {sid: uid for uid, sid in online_users.items()}
    reset_users = []
    for sid, uid in sid_uid.items():
        if uid == sender_id or sid not in sid_set:
            continue
        try:
            update_room_read(uid, room_db_id, msg_id)
            reset_users.append(uid)
        except Exception:
            pass
    for uid in reset_users:
        try:
            u = get_user(user_id=uid)
            socketio.emit('group_unread_reset', {'room_id': room_str[len('private_'):] if room_str.startswith('private_') else room_str,
                                                 'reader': uid, 'reader_username': (u or {}).get('username', '')},
                          room='general')
        except Exception:
            pass

@app.route('/room/<room_id>/members')
@login_required
def room_members_api(room_id):
    room = get_room_by_id(room_id)
    if not room: return jsonify({'error': 'روم پیدا نشد'}), 404
    if not is_room_member(current_user.id, room['id']) and not current_user.is_admin:
        return jsonify({'error': 'دسترسی غیرمجاز'}), 403
    
    is_owner = is_room_owner(room['id'], current_user.id)
    can_manage = is_room_manager(room['id'], current_user.id)
    
    # تنظیمات مالک: اعضای عادی چه چیزی ببینن؟
    #   'all'    → همه‌ی اعضا
    #   'admins' → فقط مالک + ادمین‌ها
    #   'none'   → هیچ‌کدوم؛ فقط اطلاعات روم
    mode = room.get('member_visibility') or 'all'
    members_hidden = False
    members = get_room_members_full(room['id'])
    banned = []
    if not can_manage and mode != 'all':
        if mode == 'admins':
            members = [m for m in members if m['is_owner'] or m['admin_title'] or m['promoted_by'] is not None]
        else:
            members = []
            members_hidden = True
    else:
        banned = get_banned_members(room['id'])
    
    mgr = get_room_admin_perms(room['id'], current_user.id)
    my_role = 'owner' if mgr['is_owner'] else ('admin' if mgr['is_admin'] else 'member')
    # پرچم پرو + دسترسی‌های ادمینی هر عضو
    conn_m = db_conn(); c_m = conn_m.cursor()
    # v1.6 — پرو/ادمین همه‌ی اعضا با دو کوئری جمعی (قبلاً ۲ کوئری به ازای هر عضو)
    _mids = [m['id'] for m in members]
    pro_set, admin_map = set(), {}
    for i in range(0, len(_mids), 400):
        chunk = _mids[i:i + 400]
        ph = ','.join('?' for _ in chunk)
        try:
            c_m.execute(f"SELECT DISTINCT user_id FROM pro_accounts WHERE is_active = 1 AND user_id IN ({ph})", chunk)
            pro_set.update(r[0] for r in c_m.fetchall())
        except Exception:
            pass
        try:
            c_m.execute(f"SELECT user_id, title, permissions FROM room_admins WHERE room_id = ? AND user_id IN ({ph})", [room['id']] + chunk)
            for r in c_m.fetchall(): admin_map[r[0]] = (r[1], r[2])
        except Exception:
            pass
    for m in members:
        m['is_pro'] = m['id'] in pro_set
        row_a = admin_map.get(m['id'])
        if row_a is not None:
            m['is_room_admin'] = True
            m['admin_title'] = row_a[0] or ''
            try:
                m['admin_perms'] = _json.loads(row_a[1]) if (row_a[1] or '').strip() else ['delete_messages', 'ban_members']
            except Exception:
                m['admin_perms'] = ['delete_messages', 'ban_members']
        else:
            m['is_room_admin'] = bool(m.get('is_room_admin'))
            m['admin_perms'] = []
    conn_m.close()
    return jsonify({
        'members': members,
        'banned': banned,
        'is_owner': is_owner,
        'can_manage': can_manage,
        'my_role': my_role,
        'my_perms': sorted(mgr['perms']),
        'settings': get_room_settings(room),
        'members_hidden': members_hidden,
        'member_visibility': mode,
        'bio': room.get('bio', ''),
        'member_count': get_room_member_count(room['id']),
        'room_name': room['name'] or room_id,
        'room_avatar': room['avatar'],
        'room_type': room.get('room_type', 'group'),
        'username': room.get('username', ''),
        'is_public': bool(room.get('is_public')),
        'invite_link': request.host_url.rstrip('/') + '/invite/' + room_id
    })


@app.route('/room/<room_id>/pin', methods=['POST'])
@login_required
def pin_room_message_route(room_id):
    # پین کردن پیام در گروه/کانال — فقط مالک و ادمین‌ها؛ حداکثر ۵ پین همزمان.
    room = get_room_by_id(room_id)
    if not room:
        return jsonify({'error': 'not_found'}), 404
    mgr = get_room_admin_perms(room['id'], current_user.id)
    if not (mgr['is_owner'] or mgr['is_admin'] or current_user.is_admin):
        return jsonify({'error': 'forbidden'}), 403
    data = request.get_json(silent=True) or request.form or {}
    try:
        mid = int(data.get('message_id') or 0)
    except Exception:
        mid = 0
    if not mid:
        return jsonify({'error': 'message_id_required'}), 400
    conn = db_conn(); c = conn.cursor()
    c.execute("SELECT 1 FROM messages WHERE id = ? AND room = ? AND is_deleted = 0",
              (mid, "private_" + room_id))
    exists = c.fetchone() is not None
    if exists:
        c.execute("INSERT OR IGNORE INTO room_pinned_messages (room_db_id, message_id, pinned_by, pinned_at) VALUES (?, ?, ?, ?)",
                  (room['id'], mid, current_user.id, datetime.now()))
        c.execute('''DELETE FROM room_pinned_messages WHERE room_db_id = ? AND id NOT IN (
                     SELECT id FROM room_pinned_messages WHERE room_db_id = ?
                     ORDER BY pinned_at DESC, id DESC LIMIT 5)''', (room['id'], room['id']))
    conn.commit(); conn.close()
    if not exists:
        return jsonify({'error': 'message_not_found'}), 404
    socketio.emit('room_pins_update', {'room_id': room_id}, room="private_" + room_id)
    return jsonify({'success': True, 'pins': get_room_pins(room['id'])})


@app.route('/room/<room_id>/unpin', methods=['POST'])
@login_required
def unpin_room_message_route(room_id):
    room = get_room_by_id(room_id)
    if not room:
        return jsonify({'error': 'not_found'}), 404
    data = request.get_json(silent=True) or request.form or {}
    try:
        mid = int(data.get('message_id') or 0)
    except Exception:
        mid = 0
    if not mid:
        return jsonify({'error': 'message_id_required'}), 400
    mgr = get_room_admin_perms(room['id'], current_user.id)
    if not (mgr['is_owner'] or mgr['is_admin'] or current_user.is_admin):
        # فرستنده‌ی پین هم می‌تونه پین خودش رو برداره
        conn0 = db_conn(); c0 = conn0.cursor()
        c0.execute("SELECT 1 FROM room_pinned_messages WHERE room_db_id = ? AND message_id = ? AND pinned_by = ?",
                   (room['id'], mid, current_user.id))
        allowed = c0.fetchone() is not None
        conn0.close()
        if not allowed:
            return jsonify({'error': 'forbidden'}), 403
    conn = db_conn(); c = conn.cursor()
    c.execute("DELETE FROM room_pinned_messages WHERE room_db_id = ? AND message_id = ?",
              (room['id'], mid))
    conn.commit(); conn.close()
    socketio.emit('room_pins_update', {'room_id': room_id}, room="private_" + room_id)
    return jsonify({'success': True, 'pins': get_room_pins(room['id'])})


@app.route('/api/room/<room_id>/pins')
@login_required
def api_room_pins(room_id):
    room = get_room_by_id(room_id)
    if not room:
        return jsonify({'error': 'not_found'}), 404
    if not is_room_member(current_user.id, room['id']) and not current_user.is_admin:
        return jsonify({'error': 'forbidden'}), 403
    mgr = get_room_admin_perms(room['id'], current_user.id)
    return jsonify({'pins': get_room_pins(room['id']),
                    'can_pin': bool(mgr['is_owner'] or mgr['is_admin'] or current_user.is_admin)})

@app.route('/room/<room_id>/set_bio', methods=['POST'])
@login_required
def set_room_bio_route(room_id):
    """بیوی کانال/گروه — فقط مالک، حداکثر ۵۱۲ کاراکتر"""
    room = get_room_by_id(room_id)
    if not room: return jsonify({'error': 'روم پیدا نشد'}), 404
    if not is_room_owner(room['id'], current_user.id):
        return jsonify({'error': 'فقط مالک می‌تواند بیو را تغییر دهد'}), 403
    data = request.get_json(silent=True) or {}
    bio = (data.get('bio') or request.form.get('bio') or '').strip()
    if len(bio) > 512:
        return jsonify({'error': 'bio_too_long'}), 400
    set_room_bio_db(room['id'], bio)
    socketio.emit('room_bio_updated', {'room_id': room_id, 'bio': bio, 'room': f"private_{room_id}"}, room=f"private_{room_id}")
    return jsonify({'success': True, 'bio': bio})

@app.route('/room/<room_id>/set_visibility', methods=['POST'])
@login_required
def set_room_visibility_route(room_id):
    """تنظیم اینکه اعضای عادی چی ببینن: all | admins | none — فقط مالک"""
    room = get_room_by_id(room_id)
    if not room: return jsonify({'error': 'روم پیدا نشد'}), 404
    if not is_room_owner(room['id'], current_user.id):
        return jsonify({'error': 'فقط مالک می‌تواند این تنظیم را تغییر دهد'}), 403
    data = request.get_json(silent=True) or {}
    mode = (data.get('mode') or request.form.get('mode') or 'all').strip()
    if mode not in ('all', 'admins', 'none'):
        return jsonify({'error': 'invalid_mode'}), 400
    set_room_visibility_db(room['id'], mode)
    socketio.emit('room_settings_updated', {'room_id': room_id, 'member_visibility': mode, 'room': f"private_{room_id}"}, room=f"private_{room_id}")
    return jsonify({'success': True, 'member_visibility': mode})

@app.route('/api/room/preview/<room_id>')
@login_required
def api_room_preview(room_id):
    """پیش‌نمایش کانال/گروه برای پنل جوین — برای هر کاربر لاگین‌شده (عضو یا غیرعضو)"""
    room = get_room_by_id(room_id)
    if not room: return jsonify({'error': 'not_found'}), 404
    return jsonify({
        'room_id': room['room_id'], 'name': room['name'],
        'avatar': room['avatar'], 'room_type': room.get('room_type', 'group'),
        'bio': room.get('bio', ''),
        'username': room.get('username', ''), 'is_public': bool(room.get('is_public')),
        'member_count': get_room_member_count(room['id']),
        'is_member': is_room_member(current_user.id, room['id'])
    })

@app.route('/room/<room_id>/toggle_mute', methods=['POST'])
@login_required
def toggle_room_mute(room_id):
    """میوت/آنمیوت شخصی روم برای کاربر فعلی (فعلاً فقط برای اعضای غیرادمین کانال کاربرد داره)"""
    room = get_room_by_id(room_id)
    if not room: return jsonify({'error': 'روم پیدا نشد'}), 404
    if not is_room_member(current_user.id, room['id']) and not current_user.is_admin:
        return jsonify({'error': 'دسترسی غیرمجاز'}), 403
    new_state = toggle_room_mute_db(room['id'], current_user.id)
    if new_state is None:
        return jsonify({'error': 'عضو این روم نیستید'}), 400
    return jsonify({'success': True, 'is_muted': new_state})

@app.route('/room/<room_id>/set_avatar', methods=['POST'])
@login_required
def set_room_avatar(room_id):
    room = get_room_by_id(room_id)
    if not room: return jsonify({'error': 'روم پیدا نشد'}), 404
    if not is_room_owner(room['id'], current_user.id):
        return jsonify({'error': 'فقط مالک گروه می‌تواند عکس را تغییر دهد'}), 403

    if 'avatar' not in request.files:
        return jsonify({'error': 'فایلی انتخاب نشده'}), 400
    file = request.files['avatar']
    if file.filename == '' or '.' not in file.filename or file.filename.rsplit('.', 1)[1].lower() not in (PROFILE_COVER_ALLOWED_EXTENSIONS | {'gif'}):
        return jsonify({'error': 'فرمت فایل مجاز نیست'}), 400

    ext = file.filename.rsplit('.', 1)[1].lower()
    filename = secure_filename(f"room_{room['id']}_{secrets.token_hex(4)}.{ext}")
    file.save(os.path.join(app.config['UPLOAD_FOLDER'], filename))
    set_room_avatar_db(room['id'], filename)

    socketio.emit('room_avatar_updated', {'room_id': room_id, 'avatar': filename}, room=f"private_{room_id}")
    return jsonify({'success': True, 'avatar': filename})

@app.route('/invite/<room_id>')
@login_required
def invite_room(room_id):
    """لینک اینوایت دیگه صفحه‌ی جدا نمیشه — داخل خود اپ پنل پیش‌نمایش از پایین باز میشه
    (عکس، اسم، تعداد مشترک‌ها، بیو و دکمه‌ی جوین/بستن)"""
    return redirect('/#invite=' + room_id)

@app.route('/room/<room_id>/promote', methods=['POST'])
@login_required
def promote_member(room_id):
    room = get_room_by_id(room_id)
    if not room: return jsonify({'error': 'روم پیدا نشد'}), 404
    mgr = get_room_admin_perms(room['id'], current_user.id)
    if not (mgr['is_owner'] or (mgr['is_admin'] and 'promote' in mgr['perms'])):
        return jsonify({'error': 'دسترسی غیرمجاز'}), 403

    data = request.get_json(silent=True) or request.form
    try:
        user_id = int(data.get('user_id', 0) or 0)
    except Exception:
        user_id = 0
    title = (data.get('title') or '').strip()[:24]
    perms_raw = data.get('permissions', '')
    try:
        import json as _jp
        perms = _jp.loads(perms_raw) if perms_raw and isinstance(perms_raw, str) else (perms_raw or ['delete_messages', 'ban_members'])
    except Exception:
        perms = ['delete_messages', 'ban_members']
    if isinstance(perms, str): perms = [perms]
    perms = [p for p in perms if p in ADMIN_PERMS]

    if is_room_owner(room['id'], user_id):
        return jsonify({'error': 'مالک از قبل بالاترین سطح است'}), 400
    if not is_room_member(user_id, room['id']):
        return jsonify({'error': 'این کاربر عضو گروه نیست'}), 400

    promote_to_admin(room['id'], user_id, current_user.id, title, perms)
    socketio.emit('room_admins_updated', {'room_id': room_id, 'room': f"private_{room['room_id']}"}, room=f"private_{room['room_id']}")
    return jsonify({'success': True})

@app.route('/room/<room_id>/demote', methods=['POST'])
@login_required
def demote_member(room_id):
    room = get_room_by_id(room_id)
    if not room: return jsonify({'error': 'روم پیدا نشد'}), 404
    mgr = get_room_admin_perms(room['id'], current_user.id)
    if not (mgr['is_owner'] or (mgr['is_admin'] and 'promote' in mgr['perms'])):
        return jsonify({'error': 'دسترسی غیرمجاز'}), 403
    user_id = request.form.get('user_id', type=int)
    if is_room_owner(room['id'], user_id):
        return jsonify({'error': 'مالک قابل حذف نیست'}), 400
    demote_admin(room['id'], user_id)
    socketio.emit('room_admins_updated', {'room_id': room_id, 'room': f"private_{room['room_id']}"}, room=f"private_{room['room_id']}")
    return jsonify({'success': True})

@app.route('/room/<room_id>/edit_admin', methods=['POST'])
@login_required
def edit_admin_route(room_id):
    """ویرایش تگ و پرمیشن‌های ادمین — بعداً هم قابل تغییره"""
    room = get_room_by_id(room_id)
    if not room: return jsonify({'error': 'روم پیدا نشد'}), 404
    mgr = get_room_admin_perms(room['id'], current_user.id)
    if not (mgr['is_owner'] or (mgr['is_admin'] and 'promote' in mgr['perms'])):
        return jsonify({'error': 'دسترسی غیرمجاز'}), 403
    data = request.get_json(silent=True) or request.form
    user_id = int(data.get('user_id', 0) or 0)
    title = (data.get('title') or '').strip()[:24]
    perms_raw = data.get('permissions', '')
    try:
        import json as _je
        perms = _je.loads(perms_raw) if perms_raw and isinstance(perms_raw, str) else (perms_raw or [])
    except Exception:
        perms = []
    perms = [p for p in perms if p in ADMIN_PERMS]
    if not is_room_admin(room['id'], user_id):
        return jsonify({'error': 'این کاربر ادمین نیست'}), 400
    edit_room_admin(room['id'], user_id, title=title, permissions=perms)
    socketio.emit('room_admins_updated', {'room_id': room_id, 'room': f"private_{room['room_id']}"}, room=f"private_{room['room_id']}")
    return jsonify({'success': True})

@app.route('/room/<room_id>/ban', methods=['POST'])
@login_required
def ban_member(room_id):
    room = get_room_by_id(room_id)
    if not room: 
        return jsonify({'error': 'روم پیدا نشد'}), 404
    
    mgr = get_room_admin_perms(room['id'], current_user.id)
    if not (mgr['is_owner'] or (mgr['is_admin'] and 'ban_members' in mgr['perms'])):
        return jsonify({'error': 'دسترسی غیرمجاز'}), 403
    
    user_id = request.form.get('user_id', type=int)
    reason = (request.form.get('reason', '') or '')[:200]
    # v1.6 — اعتبارسنجی: user_id اجباری، خودتان و مالک قابل بن نیستند
    if not user_id:
        return jsonify({'error': 'کاربر نامعتبر است'}), 400
    if user_id == current_user.id:
        return jsonify({'error': 'نمی‌توانید خودتان را بن کنید'}), 400
    if is_room_owner(room['id'], user_id) or user_id == room.get('owner_id'):
        return jsonify({'error': 'مالک گروه قابل بن نیست'}), 400
    
    # ادمین معمولی نمی‌تونه ادمین دیگه رو بن کنه
    target_is_admin = is_room_admin(room['id'], user_id)
    if mgr['is_admin'] and not mgr['is_owner'] and target_is_admin:
        return jsonify({'error': 'فقط مالک می‌تواند ادمین را حذف کند'}), 403
    
    ban_from_room(room['id'], user_id, current_user.id, reason)
    
    # پیام شیشه‌ای «X توسط Y بن شد» — ریل‌تایم برای همه‌ی اعضا + تاریخچه
    target_user = get_user(user_id=user_id)
    if target_user:
        announce_room_ban(room, target_user['username'], (current_user.name or '').strip() or current_user.username)
    
    # کاربر بن شده رو با socket بیرون کن — با اسم گروه و اخراج‌کننده برای مودال تمیز
    kicker_name = (current_user.name or '').strip() or current_user.username
    with _state_lock:
        _online_snapshot = list(online_users.items())   # v1.6: iterate روی کپی، نه دیکشنری زنده
    for uid, sid in _online_snapshot:
        if uid == user_id:
            socketio.emit('kicked_from_room', {
                'message': 'شما از گروه اخراج شدید',
                'room_id': room_id,
                'room_name': room['name'],
                'by': kicker_name
            }, room=sid)
            # از room هم خارجش کن
            room_name = f"private_{room_id}"
            try:
                socketio.server.leave_room(room_name, sid, namespace='/')
            except Exception:
                pass
            if sid in user_rooms_map:
                user_rooms_map[sid] = 'general'
                join_room('general', sid=sid)
            break
    
    return jsonify({'success': True})

@app.route('/room/<room_id>/unban', methods=['POST'])
@login_required
def unban_member(room_id):
    room = get_room_by_id(room_id)
    if not room: return jsonify({'error': 'روم پیدا نشد'}), 404
    
    mgr = get_room_admin_perms(room['id'], current_user.id)
    if not (mgr['is_owner'] or (mgr['is_admin'] and 'ban_members' in mgr['perms'])):
        return jsonify({'error': 'دسترسی غیرمجاز'}), 403
    
    user_id = request.form.get('user_id', type=int)
    unban_from_room(room['id'], user_id)
    socketio.emit('room_bans_updated', {'room_id': room_id, 'room': f"private_{room['room_id']}"}, room=f"private_{room['room_id']}")
    return jsonify({'success': True})

@app.route('/room/<room_id>/clear_bans', methods=['POST'])
@login_required
def clear_bans_route(room_id):
    """پاکسازی کامل لیست بن — مالک یا ادمین با پرمیشن بن"""
    room = get_room_by_id(room_id)
    if not room: return jsonify({'error': 'روم پیدا نشد'}), 404
    mgr = get_room_admin_perms(room['id'], current_user.id)
    if not (mgr['is_owner'] or (mgr['is_admin'] and 'ban_members' in mgr['perms'])):
        return jsonify({'error': 'دسترسی غیرمجاز'}), 403
    conn = db_conn(); c = conn.cursor()
    c.execute("DELETE FROM room_bans WHERE room_id = ?", (room['id'],))
    conn.commit(); conn.close()
    socketio.emit('room_bans_updated', {'room_id': room_id, 'room': f"private_{room['room_id']}"}, room=f"private_{room['room_id']}")
    return jsonify({'success': True})

@app.route('/room/<room_id>/set_slowmode', methods=['POST'])
@login_required
def set_slowmode_route(room_id):
    """ریت‌لیمیت پیام — فقط گروه، فقط مالک/ادمین با پرمیشن restrict_members.
    seconds: 0 (خاموش) یا بین ۵ تا ۳۶۰۰ ثانیه"""
    room = get_room_by_id(room_id)
    if not room: return jsonify({'error': 'روم پیدا نشد'}), 404
    if room.get('room_type') == 'channel':
        return jsonify({'error': 'برای کانال اعمال نمیشود'}), 400
    mgr = get_room_admin_perms(room['id'], current_user.id)
    if not (mgr['is_owner'] or (mgr['is_admin'] and 'restrict_members' in mgr['perms'])):
        return jsonify({'error': 'دسترسی غیرمجاز'}), 403
    data = request.get_json(silent=True) or {}
    try:
        seconds = int(data.get('seconds', 0))
    except Exception:
        seconds = 0
    if seconds != 0 and not (5 <= seconds <= 3600):
        return jsonify({'error': 'مقدار مجاز: خاموش یا ۵ ثانیه تا ۱ ساعت'}), 400
    set_room_setting_db(room['id'], 'slow_mode', seconds)
    settings = get_room_settings(get_room_by_db_id(room['id']))
    socketio.emit('room_settings_updated', {'room_id': room_id, 'settings': settings, 'room': f"private_{room['room_id']}"}, room=f"private_{room['room_id']}")
    return jsonify({'success': True, 'settings': settings})

@app.route('/room/<room_id>/set_perms', methods=['POST'])
@login_required
def set_perms_route(room_id):
    """دسترسی اعضا: قفل چت (فقط ادمین‌ها) / ارسال رسانه / ارسال گیف — فقط گروه"""
    room = get_room_by_id(room_id)
    if not room: return jsonify({'error': 'روم پیدا نشد'}), 404
    if room.get('room_type') == 'channel':
        return jsonify({'error': 'برای کانال اعمال نمیشود'}), 400
    mgr = get_room_admin_perms(room['id'], current_user.id)
    if not (mgr['is_owner'] or (mgr['is_admin'] and 'restrict_members' in mgr['perms'])):
        return jsonify({'error': 'دسترسی غیرمجاز'}), 403
    data = request.get_json(silent=True) or {}
    def _b(k, cur):
        v = data.get(k)
        return bool(cur) if v is None else (str(v).lower() in ('1', 'true', 'on', 'yes'))
    only_admins = _b('only_admins', room.get('only_admins'))
    send_media = _b('send_media', room.get('perm_send_media'))
    send_gifs = _b('send_gifs', room.get('perm_send_gifs'))
    set_room_setting_db(room['id'], 'only_admins', 1 if only_admins else 0)
    set_room_setting_db(room['id'], 'perm_send_media', 1 if send_media else 0)
    set_room_setting_db(room['id'], 'perm_send_gifs', 1 if send_gifs else 0)
    settings = get_room_settings(get_room_by_db_id(room['id']))
    socketio.emit('room_settings_updated', {'room_id': room_id, 'settings': settings, 'room': f"private_{room['room_id']}"}, room=f"private_{room['room_id']}")
    return jsonify({'success': True, 'settings': settings})

@app.route('/forward_message/<int:msg_id>', methods=['POST'])
@login_required
def forward_message_route(msg_id):
    """فوروارد پیام به گروه/کانال یا پیوی — با هویت فرستنده‌ی اصلی مثل تلگرام"""
    data = request.get_json(silent=True) or {}
    conn = db_conn(); c = conn.cursor()
    # v1.3.2 — m.media_meta هم میاد: فورواردِ آهنگ باید متادیتای موزیک
    # (عنوان/خواننده/کاور/kind) رو با خودش ببرد، وگرنه آهنگ بعد از فوروارد
    # به ویس تبدیل می‌شد (همان باگ کلاسیک).
    c.execute('''SELECT m.content, m.file_url, m.file_type, u.username, u.name,
                 (SELECT COUNT(*) FROM pro_accounts pa WHERE pa.user_id = u.id AND pa.is_active = 1),
                 m.is_deleted, m.media_meta, m.room, m.private_chat_id
                 FROM messages m JOIN users u ON m.user_id = u.id WHERE m.id = ?''', (msg_id,))
    row = c.fetchone(); conn.close()
    if not row or row[6]:
        return jsonify({'error': 'پیام پیدا نشد'}), 404
    # v1.6 امنیتی — فقط پیامی که خودِ کاربر به آن دسترسی دارد قابل فوروارد است (قبلاً با هر شناسه‌ای
    # می‌شد محتوای پیوی/گروه دیگران را بیرون کشید)
    _src_room, _src_pv = row[8], row[9]
    if _src_pv:
        _pp = _pv_participants(_src_pv)
        if not _pp or current_user.id not in _pp:
            return jsonify({'error': 'پیام پیدا نشد'}), 404
    elif _src_room and str(_src_room).startswith('private_'):
        _sr = get_room_by_id(str(_src_room)[len('private_'):])
        if not _sr or (not is_room_member(current_user.id, _sr['id']) and not current_user.is_admin):
            return jsonify({'error': 'پیام پیدا نشد'}), 404
    content, file_url, file_type, src_username, src_name = row[0], row[1], row[2], row[3], row[4]
    src_media_meta = row[7] if len(row) > 7 else None
    forward_from = (src_name or '').strip() or src_username
    forward_from_username = src_username

    ttype = data.get('type')
    if ttype == 'pv':
        try:
            chat_id = int(data.get('chat_id', 0) or 0)
        except Exception:
            return jsonify({'error': 'شناسه‌ی چت نامعتبر'}), 400
        conn = db_conn(); c = conn.cursor()
        c.execute("SELECT id FROM private_chats WHERE id = ? AND (sender_id = ? OR receiver_id = ?) AND is_active = 1",
                  (chat_id, current_user.id, current_user.id))
        pc = c.fetchone()
        if not pc:
            conn.close(); return jsonify({'error': 'دسترسی غیرمجاز'}), 403
        partf = _pv_participants(chat_id)
        if not partf:
            conn.close(); return jsonify({'error': 'چت پیدا نشد'}), 404
        # v1.6 امنیتی — بلاک دوطرفه در فوروارد پیوی هم اعمال می‌شود
        other_id_f = partf[1] if partf[0] == current_user.id else partf[0]
        if other_id_f != current_user.id:
            if is_user_blocked(current_user.id, other_id_f):
                conn.close(); return jsonify({'error': 'blocked', 'message': 'کاربر را بلاک کرده‌اید'}), 403
            if is_user_blocked(other_id_f, current_user.id):
                conn.close(); return jsonify({'error': 'blocked_by_user', 'message': 'شما توسط این کاربر بلاک شده‌اید'}), 403
        now = datetime.now()
        # v1.3.2 — پیش‌نمایش لیست چت‌ها: موزیک => نوع music + اسم تمیز آهنگ
        pv_ft, pv_msg = pv_preview_fields(content, file_type, file_url or '', src_media_meta)
        # v1.6 — ناخوانده مثل ارسال عادی: فقط سمت گیرنده زیاد می‌شود
        c.execute('''UPDATE private_chats SET last_message = ?, last_time = ?, updated_at = ?,
                     last_file_type = ?, last_user = ?,
                     unread_s = CASE WHEN sender_id != ? THEN unread_s + 1 ELSE 0 END,
                     unread_r = CASE WHEN sender_id = ? THEN unread_r + 1 ELSE 0 END
                     WHERE id = ?''',
                  ((pv_msg or '[media]')[:100], now, now, pv_ft, current_user.username,
                   current_user.id, current_user.id, chat_id))
        # v1.4.0 — سیو مسیج: چت با خودشان ناخوانده نمی‌گیرد
        if partf[0] == partf[1]:
            c.execute("UPDATE private_chats SET unread_s = 0, unread_r = 0 WHERE id = ?", (chat_id,))
        conn.commit(); conn.close()
        room = f"pv_{chat_id}"
        msg_id2 = save_message(current_user.id, current_user.username, content, room, file_url, file_type, chat_id, None,
                               forward_from=forward_from, forward_from_username=forward_from_username,
                               media_meta=src_media_meta)
        socketio.emit('new_pv_message', {
            'username': current_user.username, 'message': content, 'timestamp': now.strftime('%H:%M'),
            'avatar': current_user.avatar, 'file_url': file_url, 'file_type': file_type,
            'tags': get_user_tags(current_user.id), 'particle': get_avatar_particle(current_user.id),
            'is_pro': is_pro_user(current_user.id), 'message_id': msg_id2,
            'private_chat_id': chat_id, 'room': room, 'seen_count': 0,
            'forward_from': forward_from, 'forward_from_username': forward_from_username,
            'display_name': (current_user.name or '').strip(),
            'media_meta': norm_media_meta_out(src_media_meta, file_url or '', file_type or '')
        }, room=room, include_self=True)
        # v1.4.0 امنیتی — پیش‌نمایش پیوی فوروارد شده فقط برای دو طرف خود چت
        _emit_pv_chats_updated(chat_id, partf[0], partf[1], (pv_msg or '[media]'),
                               now.strftime('%H:%M'), pv_ft,
                               now.strftime('%Y-%m-%dT%H:%M:%S'), current_user.username)
        return jsonify({'success': True, 'message_id': msg_id2})
    else:
        room = get_room_by_id(data.get('room_id', ''))
        if not room: return jsonify({'error': 'روم پیدا نشد'}), 404
        room_str = f"private_{room['room_id']}"
        if room.get('room_type') == 'channel':
            if not is_room_poster(room['id'], current_user.id):
                return jsonify({'error': 'فقط ادمین‌های کانال می‌توانند پیام ارسال کنند'}), 403
        else:
            if not is_room_member(current_user.id, room['id']):
                return jsonify({'error': 'عضو این گروه نیستید'}), 403
            if room.get('only_admins'):
                mgr = get_room_admin_perms(room['id'], current_user.id)
                if not (mgr['is_owner'] or mgr['is_admin']):
                    return jsonify({'error': 'گروه توسط ادمین محدود شده'}), 403
        msg_id2 = save_message(current_user.id, current_user.username, content, room_str, file_url, file_type, None, None,
                               forward_from=forward_from, forward_from_username=forward_from_username,
                               media_meta=src_media_meta)
        socketio.emit('new_message', {
            'username': current_user.username, 'message': content, 'timestamp': datetime.now().strftime('%H:%M'),
            'avatar': current_user.avatar, 'file_url': file_url, 'file_type': file_type,
            'tags': get_user_tags(current_user.id), 'particle': get_avatar_particle(current_user.id),
            'is_pro': is_pro_user(current_user.id), 'is_official': bool(current_user.is_admin),
            'message_id': msg_id2, 'room': room_str, 'seen_count': 0,
            'forward_from': forward_from, 'forward_from_username': forward_from_username,
            'display_name': (current_user.name or '').strip(),
            'media_meta': norm_media_meta_out(src_media_meta, file_url or '', file_type or '')
        }, room=room_str)
        socketio.emit('group_unread', {'room_id': room['room_id'], 'from': current_user.username}, room='general')
        return jsonify({'success': True, 'message_id': msg_id2})

# ==================== فالو ====================

@app.route('/api/follow_list/<username>')
@login_required
def api_follow_list(username):
    """v1.0.9 — لیست فالوئر/فالوینگ به صورت JSON با وضعیت فالوِ خودم،
    برای پنل حرفه‌ای فالوورها در اپلیکیشن (فالو بک / آنفالو / پروفایل)"""
    user = get_user(username=username)
    if not user:
        return jsonify({'error': 'not_found'}), 404
    kind = (request.args.get('type') or 'followers').strip()
    ids = get_followers(user['id']) if kind == 'followers' else get_following(user['id'])
    out = []
    conn_f = db_conn()
    c_f = conn_f.cursor()
    # v1.6 — دو کوئری جمعی به جای دو کوئری به ازای هر کاربر (N+1)
    _ids = [u['id'] for u in ids]
    names, mine = {}, set()
    for i in range(0, len(_ids), 400):
        chunk = _ids[i:i + 400]
        ph = ','.join('?' for _ in chunk)
        c_f.execute(f"SELECT id, name FROM users WHERE id IN ({ph})", chunk)
        names.update({r[0]: (r[1] or '') for r in c_f.fetchall()})
        c_f.execute(f"SELECT following_id FROM follows WHERE follower_id = ? AND following_id IN ({ph})", [current_user.id] + chunk)
        mine.update(r[0] for r in c_f.fetchall())
    for u in ids:
        uid = u['id']
        out.append({
            'username': u['username'] or '',
            'avatar': u['avatar'] or '',
            'name': (names.get(uid) or '').strip(),
            'i_follow': uid in mine,
        })
    conn_f.close()
    return jsonify({'users': out, 'type': kind})


@app.route('/follow/<username>')
@login_required
def follow_route(username):
    user = get_user(username=username)
    if not user: 
        flash('کاربر پیدا نشد')
        return redirect(url_for('index'))
    if user['id'] == current_user.id: 
        flash('نمیتوانید خودتان را فالو کنید')
        return redirect(url_for('profile', username=username))
    
    follow_user(current_user.id, user['id'])
    flash(f'{username} را فالو کردید')
    return redirect(request.referrer or url_for('profile', username=username))

@app.route('/unfollow/<username>')
@login_required
def unfollow_route(username):
    user = get_user(username=username)
    if not user: 
        flash('کاربر پیدا نشد')
        return redirect(url_for('index'))
    
    unfollow_user(current_user.id, user['id'])
    flash(f'{username} را آنفالو کردید')
    return redirect(request.referrer or url_for('profile', username=username))

@app.route('/followers/<username>')
def followers_list(username):
    """لیست فالوئرهای یه کاربر"""
    user = get_user(username=username)
    if not user: 
        flash('کاربر پیدا نشد')
        return redirect(url_for('index'))
    
    followers = get_followers(user['id'])
    following_list = get_following(user['id'])
    counts = get_follow_counts(user['id'])
    return render_template('follow_list.html', profile_user=user, list_type='followers', 
                           users=followers, following_list=following_list, counts=counts)

@app.route('/following/<username>')
def following_list_route(username):
    """لیست فالوئینگ‌های یه کاربر"""
    user = get_user(username=username)
    if not user: 
        flash('کاربر پیدا نشد')
        return redirect(url_for('index'))
    
    following = get_following(user['id'])
    followers = get_followers(user['id'])
    counts = get_follow_counts(user['id'])
    return render_template('follow_list.html', profile_user=user, list_type='following', 
                           users=following, followers_list=followers, counts=counts)

# ==================== فالو / آنفالو AJAX (پنل پروفایل داخل index) ====================
@app.route('/api/follow/<username>', methods=['POST'])
@login_required
def api_follow(username):
    user = get_user(username=username)
    if not user:
        return jsonify({'error': 'not_found'}), 404
    if user['id'] == current_user.id:
        return jsonify({'error': 'self'}), 400
    follow_user(current_user.id, user['id'])
    counts = get_follow_counts(user['id'])
    return jsonify({'ok': True, 'following': True,
                    'followers': counts['followers'], 'following_count': counts['following']})

@app.route('/api/unfollow/<username>', methods=['POST'])
@login_required
def api_unfollow(username):
    user = get_user(username=username)
    if not user:
        return jsonify({'error': 'not_found'}), 404
    if user['id'] == current_user.id:
        return jsonify({'error': 'self'}), 400
    unfollow_user(current_user.id, user['id'])
    counts = get_follow_counts(user['id'])
    return jsonify({'ok': True, 'following': False,
                    'followers': counts['followers'], 'following_count': counts['following']})

# ==================== پیوی ====================

@app.route('/start_pv/<username>')
@login_required
def start_pv(username):
    """شروع چت خصوصی با یه کاربر — حالا دیگه صفحه جدا نمیشه؛ ریدایرکت به خود اپ که پیوی رو داخل همون صفحه باز می‌کنه"""
    if current_user.username == username:
        flash('نمیتوانید به خودتان پیام دهید')
        return redirect(url_for('index'))

    user = get_user(username=username)
    if not user:
        flash('کاربر پیدا نشد')
        return redirect(url_for('index'))

    chat_id = get_or_create_private_chat(current_user.id, user['id'])
    return redirect('/#pv=' + str(chat_id))

@app.route('/api/start_pv/<username>')
@login_required
def api_start_pv(username):
    """نسخه‌ی JSON برای باز کردن پیوی داخل همین صفحه (بدون رفرش)"""
    if current_user.username == username:
        return jsonify({'error': 'نمیتوانید به خودتان پیام دهید'}), 400
    user = get_user(username=username)
    if not user:
        return jsonify({'error': 'کاربر پیدا نشد'}), 404
    if is_user_blocked(user['id'], current_user.id):
        return jsonify({'error': 'شما توسط این کاربر مسدود شده‌اید'}), 403
    # v1.6 — جهت معکوس هم چک می‌شود: اگر خودم او را بلاک کرده باشم
    if is_user_blocked(current_user.id, user['id']):
        return jsonify({'error': 'شما این کاربر را بلاک کرده‌اید؛ ابتدا آنبلاک کنید'}), 403
    chat_id = get_or_create_private_chat(current_user.id, user['id'])
    return jsonify({'chat_id': chat_id, 'username': username})

def _get_pv_chat_or_none(chat_id):
    """چت پیوی رو برمی‌گردونه اگه کاربر فعلی عضوش باشه؛ وگرنه None"""
    conn = db_conn()
    c = conn.cursor()
    c.execute('''SELECT pc.id, pc.sender_id, pc.receiver_id
                 FROM private_chats pc
                 WHERE pc.id = ? AND pc.is_active = 1''', (chat_id,))
    chat = c.fetchone()
    conn.close()
    if not chat or current_user.id not in (chat[1], chat[2]):
        return None
    return {'id': chat[0], 'sender_id': chat[1], 'receiver_id': chat[2],
            'other_id': chat[2] if current_user.id == chat[1] else chat[1]}

@app.route('/api/pv/<int:chat_id>/info')
@login_required
def api_pv_info(chat_id):
    """اطلاعات هدر پیوی برای اپ جدید (بدون رندر سمت سرور) — با آخرین بازدید واقعی و حریم خصوصی"""
    chat = _get_pv_chat_or_none(chat_id)
    if not chat:
        return jsonify({'error': 'not_found'}), 404
    other = get_user(user_id=chat['other_id'])
    if not other:
        return jsonify({'error': 'not_found'}), 404
    other_online = other['id'] in online_users
    # حریم خصوصی «آخرین بازدید من»: nobody => مخفی؛ contacts فعلا مثل همه (سیستم مخاطبین بعداً)
    last_seen_visible = other['privacy_last_seen'] != 'nobody'
    last_seen_iso = None
    if last_seen_visible and not other_online and other.get('last_seen'):
        try:
            last_seen_iso = other['last_seen'].isoformat() if hasattr(other['last_seen'], 'isoformat') else str(other['last_seen'])
        except Exception:
            last_seen_iso = None
    # اگر پیام‌های طرف بسته باشه => کارت شناور بسته بودن پیوی نمایش داده بشه
    dm_closed = (other['privacy_dm'] == 'nobody')
    return jsonify({
        'chat_id': chat_id,
        'other_user': other['username'],
        'other_avatar': other['avatar'],
        'name': other['name'] or other['username'],
        'is_admin': bool(other['is_admin']),
        'is_pro': is_pro_user(other['id']),
        'is_blocked': is_user_blocked(other['id'], current_user.id),
        'i_blocked_them': is_user_blocked(current_user.id, other['id']),
        'online': other_online,
        'last_seen': last_seen_iso,
        'last_seen_visible': last_seen_visible,
        'dm_closed': dm_closed
    })

# ==================== حریم خصوصی ====================

@app.route('/api/privacy', methods=['GET', 'POST'])
@login_required
def api_privacy():
    """تنظیمات حریم خصوصی: آخرین بازدید من / چه کسانی می‌توانند به من پیام بدهند"""
    if request.method == 'GET':
        u = get_user(user_id=current_user.id)
        return jsonify({'privacy_last_seen': u.get('privacy_last_seen', 'all'),
                        'privacy_dm': u.get('privacy_dm', 'all')})
    data = request.get_json(silent=True) or {}
    updates, params = [], []
    if 'privacy_last_seen' in data:
        v = data['privacy_last_seen']
        if v not in ('all', 'contacts', 'nobody'):
            return jsonify({'success': False, 'error': 'invalid_value'}), 400
        updates.append('privacy_last_seen = ?'); params.append(v)
    if 'privacy_dm' in data:
        v = data['privacy_dm']
        if v not in ('all', 'contacts', 'nobody'):
            return jsonify({'success': False, 'error': 'invalid_value'}), 400
        updates.append('privacy_dm = ?'); params.append(v)
    if updates:
        conn = db_conn(); c = conn.cursor()
        c.execute(f"UPDATE users SET {', '.join(updates)} WHERE id = ?", (*params, current_user.id))
        conn.commit()
    return jsonify({'success': True})

# ==================== نشست‌های فعال ====================

def _session_row_to_dict(r, current_sid=None):
    try:
        created = r[5].isoformat() if hasattr(r[5], 'isoformat') else str(r[5] or '')
        active = r[6].isoformat() if hasattr(r[6], 'isoformat') else str(r[6] or '')
    except Exception:
        created = active = ''
    return {'sid': r[0], 'ip': r[2] or '?', 'device': r[3] or 'ناشناس',
            'ua': r[4] or '', 'created_at': created, 'last_active': active,
            'is_current': (r[0] == current_sid)}

def _public_tid(token):
    return 't:' + token[:16]

@app.route('/api/sessions')
@login_required
def api_sessions():
    """لیست «دستگاه‌های» فعال این حساب (نه تک‌تک سوکت‌ها): هر دستگاه یک ردیف، حتی اگر چند تب/سوکت داشته باشد"""
    current_sid = request.args.get('sid', '')
    cur_token = session.get('st')
    conn = db_conn(); c = conn.cursor()
    c.execute("SELECT token, ip, device, created_at, last_active FROM login_tokens WHERE user_id = ? ORDER BY last_active DESC",
              (current_user.id,))
    tok_rows = c.fetchall()
    c.execute('''SELECT sid, user_id, ip, device, ua, created_at, last_active, token FROM user_sessions
                 WHERE user_id = ? ORDER BY last_active DESC''', (current_user.id,))
    sock_rows = c.fetchall()
    live = {}          # token -> جدیدترین سوکت
    legacy = []        # سوکت‌های بدون توکن (کوکی قدیمی)
    valid_tokens = {t[0] for t in tok_rows}
    for r in sock_rows:
        if r[7] and r[7] in valid_tokens:
            live.setdefault(r[7], r)
        elif not r[7]:
            legacy.append(r)
    out = []
    for t in tok_rows:
        token, ip, device, created, last = t
        s = live.get(token)
        sid = s[0] if s else _public_tid(token)
        la = str(last or '')
        if s and str(s[6] or '') > la: la = str(s[6])
        out.append({'sid': sid, 'ip': ip or '?', 'device': device or 'ناشناس',
                    'ua': (s[4] if s else '') or '', 'created_at': str(created or ''), 'last_active': la,
                    'is_current': bool((cur_token and token == cur_token) or (current_sid and s and s[0] == current_sid))})
    seen = set()
    for r in legacy:   # ردیف‌های قدیمی: همان دستگاه/IP یک بار نمایش داده شود
        k = (r[2], r[3])
        if k in seen and r[0] != current_sid: continue
        seen.add(k)
        out.append(_session_row_to_dict(r, current_sid))
    out.sort(key=lambda d: d['last_active'], reverse=True)
    return jsonify({'sessions': out})

@app.route('/api/sessions/revoke', methods=['POST'])
@login_required
def api_sessions_revoke():
    """خارج کردن یک دستگاه: کوکی همان دستگاه واقعاً باطل می‌شود (نه فقط قطع سوکت)"""
    data = request.get_json(silent=True) or {}
    sid = data.get('sid', '')
    if not sid or not isinstance(sid, str):
        return jsonify({'success': False, 'error': 'no_sid'}), 400
    conn = db_conn(); c = conn.cursor()
    token = None; sids = []
    if sid.startswith('t:'):
        c.execute("SELECT token FROM login_tokens WHERE user_id = ? AND substr(token, 1, 16) = ?", (current_user.id, sid[2:]))
        row = c.fetchone()
        if not row:
            return jsonify({'success': False, 'error': 'not_found'}), 404
        token = row[0]
    else:
        c.execute("SELECT token FROM user_sessions WHERE sid = ? AND user_id = ?", (sid, current_user.id))
        row = c.fetchone()
        if not row:
            return jsonify({'success': False, 'error': 'not_found'}), 404
        token = row[0]
        sids = [sid]
    if token:
        sids = list(set(sids + _kill_token(token)))
    else:
        _remove_session(sid)
    for s_ in sids:
        try: socketio.server.disconnect(s_)
        except Exception: pass
    return jsonify({'success': True})

@app.route('/api/sessions/revoke_all', methods=['POST'])
@login_required
def api_sessions_revoke_all():
    """خارج کردن همه‌ی دستگاه‌ها به جز همین یکی — کوکی‌های دیگر دستگاه‌ها واقعاً می‌میرند"""
    keep_sid = (request.get_json(silent=True) or {}).get('keep_sid', '')
    cur_token = session.get('st')
    conn = db_conn(); c = conn.cursor()
    c.execute("SELECT token FROM login_tokens WHERE user_id = ?", (current_user.id,))
    other_tokens = [r[0] for r in c.fetchall() if r[0] != cur_token]
    sids = []
    for t in other_tokens:
        sids.extend(_kill_token(t))
    # سوکت‌های بدون توکن (کوکی قدیمی) به جز سوکتی که همین دستگاه است
    c.execute("SELECT sid FROM user_sessions WHERE user_id = ? AND sid != ? AND (token IS NULL OR token = '')",
              (current_user.id, keep_sid))
    legacy_sids = [r[0] for r in c.fetchall()]
    for s_ in legacy_sids:
        _remove_session(s_)
    sids.extend(legacy_sids)
    # نسل نشست بالا برود تا کوکی‌های قدیمیِ بدون توکن هم بمیرند
    c.execute("UPDATE users SET session_epoch = COALESCE(session_epoch, 0) + 1 WHERE id = ?", (current_user.id,))
    conn.commit()
    for s_ in set(sids):
        try: socketio.server.disconnect(s_)
        except Exception: pass
    # همین دستگاه با epoch تازه (و توکن خودش) دوباره صادر شود تا logout نشود
    fresh = get_user(user_id=current_user.id)
    if fresh:
        login_user(UserClass(fresh), fresh=True)
        if not cur_token:
            _issue_login_token(current_user.id)
    return jsonify({'success': True, 'revoked': len(set(sids)) + (0 if sids else len(other_tokens))})

@app.route('/api/pv/<int:chat_id>/pin', methods=['POST'])
@login_required
def pin_pv_message_route(chat_id):
    # پین شخصی در پیوی — هر طرف چت پین‌های خودش رو جدا می‌بینه.
    chat = _get_pv_chat_or_none(chat_id)
    if not chat:
        return jsonify({'error': 'not_found'}), 404
    data = request.get_json(silent=True) or request.form or {}
    try:
        mid = int(data.get('message_id') or 0)
    except Exception:
        mid = 0
    if not mid:
        return jsonify({'error': 'message_id_required'}), 400
    conn = db_conn(); c = conn.cursor()
    c.execute("SELECT 1 FROM messages WHERE id = ? AND private_chat_id = ? AND is_deleted = 0",
              (mid, chat_id))
    exists = c.fetchone() is not None
    if exists:
        c.execute("INSERT OR IGNORE INTO pv_pinned_messages (chat_id, owner_user_id, message_id, pinned_at) VALUES (?, ?, ?, ?)",
                  (chat_id, current_user.id, mid, datetime.now()))
        c.execute('''DELETE FROM pv_pinned_messages WHERE chat_id = ? AND owner_user_id = ? AND id NOT IN (
                     SELECT id FROM pv_pinned_messages WHERE chat_id = ? AND owner_user_id = ?
                     ORDER BY pinned_at DESC, id DESC LIMIT 5)''',
                  (chat_id, current_user.id, chat_id, current_user.id))
    conn.commit(); conn.close()
    if not exists:
        return jsonify({'error': 'message_not_found'}), 404
    socketio.emit('pv_pins_update', {'chat_id': chat_id}, room="pv_" + str(chat_id))
    return jsonify({'success': True, 'pins': get_pv_pins(chat_id, current_user.id)})


@app.route('/api/pv/<int:chat_id>/unpin', methods=['POST'])
@login_required
def unpin_pv_message_route(chat_id):
    chat = _get_pv_chat_or_none(chat_id)
    if not chat:
        return jsonify({'error': 'not_found'}), 404
    data = request.get_json(silent=True) or request.form or {}
    try:
        mid = int(data.get('message_id') or 0)
    except Exception:
        mid = 0
    if not mid:
        return jsonify({'error': 'message_id_required'}), 400
    conn = db_conn(); c = conn.cursor()
    c.execute("DELETE FROM pv_pinned_messages WHERE chat_id = ? AND owner_user_id = ? AND message_id = ?",
              (chat_id, current_user.id, mid))
    conn.commit(); conn.close()
    return jsonify({'success': True, 'pins': get_pv_pins(chat_id, current_user.id)})


@app.route('/api/pv/<int:chat_id>/pins')
@login_required
def api_pv_pins(chat_id):
    chat = _get_pv_chat_or_none(chat_id)
    if not chat:
        return jsonify({'error': 'not_found'}), 404
    return jsonify({'pins': get_pv_pins(chat_id, current_user.id), 'can_pin': True})

@app.route('/api/pv/<int:chat_id>/messages')
@login_required
def api_pv_messages(chat_id):
    """تاریخچه‌ی پیوی به صورت JSON — با پشتیبانی صفحه‌بندی: ?before=<id>&limit=<n>"""
    chat = _get_pv_chat_or_none(chat_id)
    if not chat:
        return jsonify({'error': 'not_found'}), 404
    try:
        before_id = int(request.args.get('before', 0) or 0)
    except Exception:
        before_id = 0
    try:
        limit = min(max(int(request.args.get('limit', 60) or 60), 10), 100)
    except Exception:
        limit = 60
    return jsonify(get_private_chat_messages(chat_id, limit=limit, before_id=before_id or None))

@app.route('/pv/<int:chat_id>')
@login_required
def pv_chat(chat_id):
    """مسیر قدیمی — حالا فقط به صفحه‌ی اصلی هدایت میشه و پیوی داخل خودش باز میشه"""
    chat = _get_pv_chat_or_none(chat_id)
    if not chat:
        flash('چت خصوصی پیدا نشد یا دسترسی ندارید')
        return redirect(url_for('index'))
    return redirect('/#pv=' + str(chat_id))

@app.route('/my_pvs')
@login_required
def my_pvs():
    """لیست پیوی‌های کاربر"""
    chats = get_user_private_chats(current_user.id)
    return jsonify(chats)

# ==================== v1.4.0 — سیو مسیج (چت با خودمان مثل تلگرام) ====================
@app.route('/api/saved_chat')
@login_required
def api_saved_chat():
    """چت اختصاصی «پیام‌های ذخیره‌شده» — یک چت خصوصی با خود کاربر؛ اگر نبود ساخته می‌شود"""
    chat_id = get_or_create_private_chat(current_user.id, current_user.id)
    return jsonify({'chat_id': chat_id, 'is_self': True})

# ==================== v1.4.0 — دانلود حرفه‌ای فایل‌ها (مثل تلگرام) ====================
@app.route('/files/<path:filename>')
def download_file(filename):
    """استریم دانلود با پشتیبانی کامل Range (پخش/دانلود تدریجی ویدئوی حجیم)
    + Content-Disposition با نام اصلی فایل. مسیر قدیمی /static/uploads هم سر جایش است."""
    from flask import send_from_directory
    safe = filename.replace('\\', '/')
    if '..' in safe or safe.startswith('/'):
        return jsonify({'error': 'invalid path'}), 400
    up = app.config['UPLOAD_FOLDER']
    as_attachment = request.args.get('dl') == '1'
    try:
        resp = send_from_directory(up, safe, conditional=True, as_attachment=as_attachment)
    except NotFound:
        return jsonify({'error': 'not_found'}), 404
    try:
        resp.headers.setdefault('Accept-Ranges', 'bytes')
        if not as_attachment:
            resp.headers.setdefault('Content-Disposition', f'inline; filename="{safe.rsplit("/", 1)[-1]}"')
    except Exception:
        pass
    return resp

@app.route('/api/health')
def api_health():
    """پایش سلامت برای دیپلوی تجاری (بدون نیاز به لاگین)"""
    try:
        conn = db_conn(); c = conn.cursor()
        users = c.execute("SELECT COUNT(*) FROM users").fetchone()[0]
        msgs = c.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
        rooms = c.execute("SELECT COUNT(*) FROM private_rooms WHERE is_active = 1").fetchone()[0]
    except Exception:
        users = msgs = rooms = -1
    return jsonify({'status': 'ok', 'version': '1.5.1', 'time': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
                    'users': users, 'messages': msgs, 'active_rooms': rooms})

@app.route('/create_private_room', methods=['POST'])
@login_required
def create_private_room():
    room_id = secrets.token_hex(4)
    name = (request.form.get('name') or f'روم {room_id}').strip()[:60]
    room_type = request.form.get('type', 'group')
    if room_type not in ('group', 'channel'): room_type = 'group'
    if not name: name = f'روم {room_id}'
    is_public = 1 if request.form.get('is_public') in ('1', 'true', 'on') else 0
    room_username = ''
    if is_public:
        raw = (request.form.get('username') or '').strip().lstrip('@')
        if raw:
            if not USERNAME_RE.match(raw):
                return jsonify({'error': 'invalid_username'}), 400
            if room_username_taken(raw):
                return jsonify({'error': 'username_taken'}), 400
            room_username = raw
    _cr = db_conn().cursor()
    _cr.execute("SELECT COUNT(*) FROM private_rooms WHERE owner_id = ? AND is_active = 1", (current_user.id,))
    if (_cr.fetchone()[0] or 0) >= 50:   # v1.6: سقف روم به ازای هر کاربر (ضد اسپم)
        return jsonify({'error': 'too_many_rooms'}), 400
    create_private_room_db(room_id, name, current_user.id, room_type, room_username, is_public)
    return jsonify({'room_id': room_id, 'name': name, 'room_type': room_type,
                    'username': room_username, 'is_public': bool(is_public)})

@app.route('/api/room_username_check/<username>')
@login_required
def api_room_username_check(username):
    """بررسی زنده‌ی آزاد بودن یوزرنیم هنگام ساخت کانال/گروه عمومی"""
    username = (username or '').strip().lstrip('@')
    if not USERNAME_RE.match(username):
        return jsonify({'available': False, 'reason': 'invalid'})
    conn = db_conn(); c = conn.cursor()
    c.execute("SELECT id FROM users WHERE LOWER(username) = LOWER(?)", (username,))
    if c.fetchone():
        conn.close(); return jsonify({'available': False, 'reason': 'taken_user'})
    c.execute("SELECT id FROM private_rooms WHERE username IS NOT NULL AND username != '' AND LOWER(username) = LOWER(?)", (username,))
    if c.fetchone():
        conn.close(); return jsonify({'available': False, 'reason': 'taken_room'})
    conn.close()
    return jsonify({'available': True, 'reason': 'ok'})

@app.route('/join_private_room', methods=['POST'])
@login_required
def join_private_room_route():
    room_id = request.form.get('room_id'); room = get_room_by_id(room_id)
    if not room: return jsonify({'error': 'روم پیدا نشد'}), 404
    if is_banned_from_room(room['id'], current_user.id):
        return jsonify({'error': 'banned', 'message': 'شما از این گروه اخراج شده‌اید'}), 403
    was_member = is_room_member(current_user.id, room['id'])
    if not was_member:
        join_private_room_db(current_user.id, room['id'])
        # پیام شیشه‌ای «فلانی از طریق لینک به گروه پیوست» (فقط برای گروه‌های تا ۳۰ عضو)
        announce_room_service_event(room, current_user.id, current_user.username, current_user.avatar, 'join_link')
    return jsonify({'success': True, 'room_id': room_id})

@app.route('/my_rooms')
@login_required
def my_rooms(): return jsonify(get_user_rooms(current_user.id))

@app.route('/api/rooms')
@login_required
def api_rooms():
    """لیست گروه‌های کاربر + تعداد اعضا + آخرین پیام — همه با چند کوئری جمعی (بدون N+1)"""
    rooms = get_user_rooms(current_user.id)
    if not rooms:
        return jsonify([])
    conn = db_conn()
    c = conn.cursor()
    room_strs = [f"private_{r['room_id']}" for r in rooms]
    ph = ','.join('?' for _ in room_strs)
    # تعداد اعضا با یک کوئری
    c.execute(f'''SELECT pr.room_id, COUNT(*) FROM room_members rm
                  JOIN private_rooms pr ON pr.id = rm.room_id
                  WHERE pr.room_id IN ({ph}) GROUP BY pr.room_id''', room_strs)
    member_counts = {t[0]: t[1] for t in c.fetchall()}
    # آخرین پیام هر روم با یک کوئری (v1.3.2: + file_url/media_meta برای برچسب موزیک)
    c.execute(f'''SELECT m.room, m.content, m.timestamp, m.file_type, u.username, m.file_url, m.media_meta
                  FROM messages m JOIN users u ON m.user_id = u.id
                  JOIN (SELECT room, MAX(id) AS max_id FROM messages
                        WHERE room IN ({ph}) AND is_deleted = 0 GROUP BY room) lm
                  ON m.room = lm.room AND m.id = lm.max_id''', room_strs)
    last_map = {t[0]: t for t in c.fetchall()}
    # وضعیت خوانده‌ی کاربر برای همه‌ی روم‌ها با یک کوئری
    c.execute('''SELECT room_db_id, last_msg_id FROM room_reads WHERE user_id = ?''', (current_user.id,))
    read_map = {t[0]: t[1] for t in c.fetchall()}
    # حداکثر شناسه‌ی پیام هر روم با یک کوئری
    c.execute(f'''SELECT room, MAX(id) FROM messages WHERE room IN ({ph}) GROUP BY room''', room_strs)
    max_map = {t[0]: (t[1] or 0) for t in c.fetchall()}
    # انواع روم + شناسه دیتابیسی با یک کوئری (برای can_post کانال‌ها و محاسبه‌ی ناخوانده)
    c.execute(f"SELECT room_id, room_type, id FROM private_rooms WHERE room_id IN ({ph})", room_strs)
    type_map = {t[0]: t for t in c.fetchall()}
    # v1.3.0 — شمارش ناخوانده‌ی همه‌ی روم‌ها با «یک» کوئری گروهی
    # (قبلاً به ازای هر روم یک COUNT جدا اجرا می‌شد => با ۲۰+ روم، این حلقه
    #  گلوگاه اصلیِ باز شدن صفحه‌ی چت‌ها بود. روم‌های بدون رکورد خواندن هم با
    #  LEFT JOIN + COALESCE پوشش داده میشن — دقیقاً مثل منطق قبلی.)
    unread_by_room = {}
    unread_where = '''AND m.is_deleted = 0
                      AND (m.file_type IS NULL OR m.file_type = '' OR m.file_type = 'text'
                           OR m.file_type IN ('image','video','audio','gif'))'''
    c.execute(f'''SELECT pr2.room_id, COUNT(m.id) FROM private_rooms pr2
                  JOIN messages m ON m.room = 'private_' || pr2.room_id
                  LEFT JOIN (SELECT room_db_id, MAX(last_msg_id) AS lr FROM room_reads
                             WHERE user_id = ? GROUP BY room_db_id) rr ON rr.room_db_id = pr2.id
                  WHERE pr2.room_id IN ({ph}) AND m.id > COALESCE(rr.lr, 0) AND m.user_id != ?
                  {unread_where}
                  GROUP BY pr2.room_id''', (current_user.id, current_user.id, *room_strs))
    for t in c.fetchall():
        unread_by_room[f"private_{t[0]}"] = t[1]
    result = []
    for r in rooms:
        room_str = f"private_{r['room_id']}"
        last = last_map.get(room_str)
        trow = type_map.get(r['room_id'])
        room_type = (trow[1] if trow else r.get('room_type', 'group')) or 'group'
        room_db_id = (trow[2] if trow else None)
        can_post = True
        if room_type == 'channel':
            can_post = bool(room_db_id and is_room_poster(room_db_id, current_user.id))
        unread = unread_by_room.get(room_str, 0)
        mx = max_map.get(room_str, 0)
        last_read = read_map.get(room_db_id, 0) if room_db_id else 0
        # v1.3.2 — برچسب تمیزِ «آخرین پیام» برای موزیک: نوع music + اسم آهنگ
        last_ft = (last[3] if last else 'text') or 'text'
        last_msg = (last[1] if last else '') or ''
        if last and last_ft == 'audio':
            _mm = norm_media_meta_out(last[6] if len(last) > 6 else None,
                                      last[5] if len(last) > 5 else '', 'audio') or {}
            _kind = (_mm.get('kind') or '').strip()
            _title = (_mm.get('title') or '').strip()
            if _kind == 'music' or (not _kind and _title):
                last_ft = 'music'
                if _title:
                    last_msg = _title
            elif _kind == 'voice':
                last_ft = 'voice'
        result.append({
            'room_id': r['room_id'], 'name': r['name'], 'avatar': r['avatar'],
            'member_count': member_counts.get(r['room_id'], 0),
            'last_message': last_msg,
            'last_time': (last[2] if last else None),
            'last_file_type': last_ft,
            'last_user': (last[4] if last else ''),
            'room_type': room_type,
            'can_post': can_post,
            'is_muted': r.get('is_muted', False),
            'unread': unread
        })
    result.sort(key=lambda x: x['last_time'] or '', reverse=True)
    return jsonify(result)

@app.route('/api/room/<room_id>/messages')
@login_required
def api_room_messages(room_id):
    """تاریخچه‌ی پیام‌های یک گروه برای لود اولیه‌ی چت گروهی داخل index"""
    room = get_room_by_id(room_id)
    if not room: return jsonify({'error': 'روم پیدا نشد'}), 404
    if not is_room_member(current_user.id, room['id']) and not current_user.is_admin:
        return jsonify({'error': 'دسترسی غیرمجاز'}), 403
    conn = db_conn()
    c = conn.cursor()
    q = '''SELECT m.id, m.content, u.username, m.timestamp, u.avatar, m.file_url, m.file_type,
                 m.user_id,                 m.forward_from, m.forward_from_username, u.name, u.is_admin,
                 (SELECT COUNT(*) FROM pro_accounts pa WHERE pa.user_id = u.id AND pa.is_active = 1),
                 ra.title, ra.user_id, m.reply_to, m.media_meta
                 FROM messages m
                 JOIN users u ON m.user_id = u.id
                 LEFT JOIN room_admins ra ON ra.room_id = ? AND ra.user_id = u.id
                 WHERE m.room = ? AND m.private_chat_id IS NULL AND m.is_deleted = 0'''
    params = [room['id'], f"private_{room_id}"]
    try:
        before_id = int(request.args.get('before', 0) or 0)
    except Exception:
        before_id = 0
    try:
        _lim = min(max(int(request.args.get('limit', 60) or 60), 10), 100)
    except Exception:
        _lim = 60
    if before_id:
        q += ' AND m.id < ?'
        params.append(before_id)
    q += ' ORDER BY m.timestamp DESC LIMIT ?'
    params.append(_lim)
    c.execute(q, params)
    rows = c.fetchall()
    reactions_map = get_reactions_for_messages([r[0] for r in rows])
    # شمارنده ویو کانال: یک کوئری جمعی به جای N کوئری به ازای هر پیام
    reads_map = {}
    is_channel = room.get('room_type') == 'channel'
    if is_channel and rows:
        ids = [r[0] for r in rows]
        try:
            ph = ','.join('?' for _ in ids)
            cr = db_conn(); crd = cr.cursor()
            crd.execute(f"SELECT message_id, COUNT(DISTINCT user_id) FROM message_reads WHERE message_id IN ({ph}) GROUP BY message_id", ids)
            reads_map = {t[0]: t[1] for t in crd.fetchall()}
        except Exception:
            reads_map = {}
    messages = []
    for r in rows[::-1]:
        d = {'message_id': r[0], 'message': r[1], 'username': r[2],
             'timestamp': fmt_hhmm(r[3]),
             'date_key': date_key_of(r[3]), 'date_label': date_label_of(r[3]),
             'avatar': r[4], 'file_url': r[5], 'file_type': r[6],
             # v1.6 FIX — ستون‌ها جابجا خوانده می‌شدند (r[7]=user_id، r[8]=forward_from،
             # r[9]=forward_from_username، r[10]=u.name)
             'forward_from': r[8] or '', 'forward_from_username': r[9] or '',
             'display_name': (r[10] or '').strip(),
             # v1.2.1 CRITICAL INDEX FIX — the old code read the wrong columns:
             #   admin_title got the PRO count, is_pro got u.is_admin,
             #   is_official got u.name and author_is_owner compared m.reply_to
             #   with the owner id → owner tag vanished after a refresh and
             #   pro/verified badges were randomly wrong.
             'is_official': bool(r[11]),
             'is_pro': bool(r[12]),
             'admin_title': (r[13] or ''),
             'is_me': r[2] == current_user.username,
             'author_is_owner': bool(r[7] is not None and r[7] == room['owner_id']),
             'reactions': reactions_map.get(r[0], []),
             'seen_count': (reads_map.get(r[0], 0) if is_channel else None),
             'media_meta': norm_media_meta_out(r[16], r[5] or '', r[6] or '')}
        if r[14]:
            snap = get_reply_snapshot(r[14])
            if snap: d.update(snap)
        messages.append(d)
    # همین که کاربر تاریخچه‌ی کانال رو می‌گیره یعنی پیام‌ها رو دیده — برای شمارنده‌ی ویو ثبتشون کن
    # ویوی خود فرستنده هم حساب میشه (مثل تلگرام که ویوی پست خود ادمین از ۱ شروع میشه)
    if is_channel and rows:
        room_name = f"private_{room_id}"
        try:
            ph = ','.join('?' for _ in rows)
            cmr = db_conn(); cmrc = cmr.cursor()
            cmrc.executemany("INSERT OR IGNORE INTO message_reads (message_id, user_id, read_at) VALUES (?, ?, ?)",
                             [(r[0], current_user.id, datetime.now()) for r in rows])
            cmr.commit()
        except Exception:
            pass
        # یک ایونت جمعی به جای N ایونت — کلاینت خودش ویوها را از seen_count تازه رفرش می‌کند
        socketio.emit('channel_read_batch', {'user_id': current_user.id, 'room': room_name,
                                             'message_ids': [r[0] for r in rows]}, room=room_name)
    conn2 = db_conn(); c2 = conn2.cursor()
    c2.execute("SELECT is_muted FROM room_members WHERE room_id = ? AND user_id = ?", (room['id'], current_user.id))
    mrow = c2.fetchone(); conn2.close()
    mgr = get_room_admin_perms(room['id'], current_user.id)
    my_role = 'owner' if mgr['is_owner'] else ('admin' if mgr['is_admin'] else 'member')
    settings = get_room_settings(room)
    # باز کردن چت = خواندن؛ بج ناخوانده‌ی همین روم صفر بشه
    try:
        c_max = db_conn(); cm = c_max.cursor()
        cm.execute("SELECT MAX(id) FROM messages WHERE room = ?", (f"private_{room_id}",))
        mx = cm.fetchone()[0] or 0; c_max.close()
        if mx: update_room_read(current_user.id, room['id'], mx)
    except Exception:
        pass
    return jsonify({'messages': messages, 'room_type': room.get('room_type', 'group'),
                     'can_post': is_room_poster(room['id'], current_user.id) if is_channel else True,
                     'is_muted': bool(mrow[0]) if mrow else False,
                     'bio': room.get('bio', ''),
                     'is_public': bool(room.get('is_public')),
                     'room_username': room.get('username', ''),
                     'settings': settings, 'my_role': my_role, 'my_perms': sorted(mgr['perms']), 'pins': get_room_pins(room['id']), 'can_pin': bool(mgr['is_owner'] or mgr['is_admin'] or current_user.is_admin)})

@app.route('/room/<room_id>/set_username', methods=['POST'])
@login_required
def set_room_username(room_id):
    """تغییر یوزرنیم عمومی روم — فقط مالک"""
    room = get_room_by_id(room_id)
    if not room: return jsonify({'error': 'روم پیدا نشد'}), 404
    if not is_room_owner(room['id'], current_user.id):
        return jsonify({'error': 'فقط مالک می‌تواند یوزرنیم را تغییر دهد'}), 403
    data = request.get_json(silent=True) or {}
    username = (data.get('username') or request.form.get('username') or '').strip().lstrip('@')
    if not USERNAME_RE.match(username):
        return jsonify({'error': 'invalid_username'}), 400
    if room_username_taken(username, exclude_room_db_id=room['id']):
        return jsonify({'error': 'username_taken'}), 400
    conn = db_conn(); c = conn.cursor()
    c.execute("UPDATE private_rooms SET username = ?, is_public = 1 WHERE id = ?", (username, room['id']))
    conn.commit(); conn.close()
    return jsonify({'success': True, 'username': username})

@app.route('/api/room/resolve/<username>')
@login_required
def api_room_resolve(username):
    """پیدا کردن کانال/گروه عمومی از روی یوزرنیم + اینکه کاربر عضوش هست یا نه"""
    username = (username or '').strip().lstrip('@')
    room = get_room_by_username(username)
    if not room:
        return jsonify({'error': 'not_found'}), 404
    return jsonify({
        'room_id': room['room_id'], 'name': room['name'],
        'avatar': room['avatar'], 'room_type': room['room_type'],
        'bio': room.get('bio', ''),
        'username': room['username'], 'is_public': True,
        'member_count': get_room_member_count(room['id']),
        'is_member': is_room_member(current_user.id, room['id'])
    })

@app.route('/join_by_username', methods=['POST'])
@login_required
def join_by_username():
    """عضویت در کانال/گروه عمومی با کلیک روی یوزرنیم"""
    data = request.get_json(silent=True) or {}
    username = (data.get('username') or request.form.get('username') or '').strip().lstrip('@')
    room = get_room_by_username(username)
    if not room:
        return jsonify({'error': 'not_found'}), 404
    if is_banned_from_room(room['id'], current_user.id):   # v1.6: بن‌شده نمی‌تواند با یوزرنیم دوباره جوین شود
        return jsonify({'error': 'banned', 'message': 'شما از این گروه اخراج شده‌اید'}), 403
    if not is_room_member(current_user.id, room['id']):
        join_private_room_db(current_user.id, room['id'])
        # پیام شیشه‌ای «فلانی به گروه پیوست» (یوزرنیم عمومی — فقط گروه‌های تا ۳۰ عضو)
        announce_room_service_event(room, current_user.id, current_user.username, current_user.avatar, 'join_username')
    return jsonify({'success': True, 'room_id': room['room_id'],
                    'name': room['name'], 'avatar': room['avatar']})

@app.route('/room/<room_id>/leave', methods=['POST'])
@login_required
def leave_room_route(room_id):
    """لفت دادن از گروه/کانال — مالک اجازه خروج نداره (اول انتقال مالکیت/حذف گروه)"""
    room = get_room_by_id(room_id)
    if not room: return jsonify({'error': 'room_not_found'}), 404
    if is_room_owner(room['id'], current_user.id):
        return jsonify({'error': 'owner_cannot_leave'}), 400
    if not is_room_member(current_user.id, room['id']):
        return jsonify({'error': 'not_member'}), 400
    ok = leave_room_db(current_user.id, room['id'])
    if ok:
        # پیام شیشه‌ای «فلانی گروه رو ترک کرد» (فقط برای گروه‌های تا ۳۰ عضو)
        announce_room_service_event(room, current_user.id, current_user.username, current_user.avatar, 'leave')
    return jsonify({'success': True, 'member_count': get_room_member_count(room['id'])})

@app.route('/room/<room_id>/rename', methods=['POST'])
@login_required
def rename_room(room_id):
    """تغییر نام گروه — فقط مالک"""
    room = get_room_by_id(room_id)
    if not room: return jsonify({'error': 'روم پیدا نشد'}), 404
    if not is_room_owner(room['id'], current_user.id):
        return jsonify({'error': 'فقط مالک می‌تواند نام گروه را تغییر دهد'}), 403
    data = request.get_json(silent=True) or {}
    name = (data.get('name') or request.form.get('name') or '').strip()[:60]
    if not name: return jsonify({'error': 'نام نامعتبر است'}), 400
    conn = db_conn(); c = conn.cursor()
    c.execute("UPDATE private_rooms SET name = ? WHERE id = ?", (name, room['id']))
    conn.commit(); conn.close()
    socketio.emit('room_updated', {'room_id': room_id, 'name': name}, room=f"private_{room_id}")
    return jsonify({'success': True, 'name': name})
# ==================== حذف پیام ====================

@app.route('/delete_message/<msg_id>', methods=['POST', 'GET'])
@login_required
def delete_message_route(msg_id):
    """حذف پیام توسط فرستنده یا ادمین"""
    
    try:
        db_msg_id = int(msg_id)
        success, result = delete_message_db(db_msg_id, current_user.id, current_user.is_admin)
        
        if success:
            room = result
            socketio.emit('message_deleted', {
                'msg_id': msg_id,
                'username': current_user.username,
                'room': room
            }, room=room)
            return jsonify({'success': True, 'message': 'پیام با موفقیت حذف شد'})
        else:
            return jsonify({'success': False, 'error': result}), 403
            
    except ValueError:
        # msg_id عددی نیست (شناسه موقت کلاینت) - چیزی توی دیتابیس پاک نشده
        return jsonify({'success': False, 'error': 'شناسه پیام نامعتبر است، لطفاً کمی صبر کن و دوباره تلاش کن'}), 400

@app.route('/edit_message/<msg_id>', methods=['POST'])
@login_required
def edit_message(msg_id):
    data = request.get_json(silent=True) or {}
    new_text = (data.get('new_text') or '').strip()[:4000]
    if not new_text:
        return jsonify({'success': False, 'error': 'متن خالی است'})

    try:
        db_msg_id = int(msg_id)
    except ValueError:
        # پیام‌هایی که فقط توی مرورگر ساخته شدن (id عددی از دیتابیس ندارن)
        return jsonify({'success': False, 'error': 'این پیام قابل ویرایش نیست'})

    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT user_id, room, is_deleted FROM messages WHERE id = ?", (db_msg_id,))
    row = c.fetchone()

    if not row:
        conn.close()
        return jsonify({'success': False, 'error': 'پیام پیدا نشد'})

    msg_user_id, room, is_deleted = row
    if is_deleted:
        conn.close()
        return jsonify({'success': False, 'error': 'پیام حذف شده است'})
    if msg_user_id != current_user.id:
        # v1.0.9 — ادمین‌ها/مالک گروه و کانال هم می‌توانند پیام‌های داخل همان
        # روم را ویرایش کنند (مثل تلگرام که ادمین کانال پست‌ها را ادیت می‌کند)
        allowed_admin = False
        try:
            if room and str(room).startswith('private_'):
                r_obj = get_room_by_id(str(room)[len('private_'):])
                if r_obj:
                    mgr = get_room_admin_perms(r_obj['id'], current_user.id)
                    allowed_admin = bool(mgr['is_owner'] or mgr['is_admin'])
        except Exception:
            allowed_admin = False
        if not allowed_admin:
            conn.close()
            return jsonify({'success': False, 'error': 'دسترسی ندارید'})

    c.execute("UPDATE messages SET content = ?, is_edited = 1 WHERE id = ?", (new_text, db_msg_id))
    conn.commit()
    # کش اسنپ‌شات ریپلای این پیام هم خنثی بشه که پیش‌نمایش ریپلای‌های دیگران تازه بشه
    try: _reply_cache.pop(db_msg_id, None)
    except Exception: pass

    room = room or 'general'
    socketio.emit('message_edited', {
        'msg_id': msg_id,
        'message_id': db_msg_id,
        'new_text': new_text
    }, room=room)

    return jsonify({'success': True})

# v1.3.0 — سقف حجم به ازای هر نوع رسانه (بایت) — ویدیو/فایل بزرگ‌تر، عکس/صدا کوچیک‌تر
_UPLOAD_SIZE_CAPS = {
    'image': 20 * 1024 * 1024, 'gif': 25 * 1024 * 1024,
    # v1.4.0 — ویدئو/فایل مثل تلگرام: سقف ۲۰۰ مگابایت (با متغیر محیطی RAVI_MAX_VIDEO_MB قابل تغییر)
    'video': int(os.environ.get('RAVI_MAX_VIDEO_MB', '200')) * 1024 * 1024,
    'audio': 100 * 1024 * 1024, 'file': 200 * 1024 * 1024,
}
_MIME_TO_KIND = {
    'image/jpeg': 'image', 'image/png': 'image', 'image/webp': 'image', 'image/gif': 'gif',
    'video/mp4': 'video', 'video/webm': 'video', 'video/quicktime': 'video', 'video/x-matroska': 'video',
    'audio/mpeg': 'audio', 'audio/mp3': 'audio', 'audio/ogg': 'audio', 'audio/mp4': 'audio',
    'audio/aac': 'audio', 'audio/x-m4a': 'audio', 'audio/wav': 'audio', 'audio/x-wav': 'audio',
}
_KIND_EXTS = {
    'image': {'png', 'jpg', 'jpeg', 'webp'}, 'gif': {'gif', 'webp'},
    'video': {'mp4', 'webm', 'mov', 'avi', 'mkv', 'm4v', '3gp'},
    'audio': {'mp3', 'wav', 'ogg', 'oga', 'm4a', 'm4r', 'aac', 'opus', 'flac'},
    'file': {'pdf', 'zip', 'doc', 'docx', 'txt', 'apk', 'rar', '7z',
             'ppt', 'pptx', 'xls', 'xlsx', 'csv', 'odt', 'ods', 'odp', 'rtf', 'json', 'log'},
}

def _human_size(n):
    n = float(n)
    for unit in ('KB', 'MB', 'GB'):
        n /= 1024.0
        if n < 1:
            return f'{n*1024:.0f} {unit}' if unit == 'KB' else f'{n:.1f} {unit}'
    return f'{n:.1f} TB'

def _save_upload_stream(file, dst_path):
    """نوشتن استریمی فایل روی دیسک — برخلاف file.save() کل فایل توی RAM لود نمیشه
    (روی گوشی‌های ضعیف و آپلودهای همزمان، همین یعنی فرق بین سرعت و کرش)."""
    written = 0
    with open(dst_path, 'wb') as out:
        while True:
            chunk = file.stream.read(256 * 1024)
            if not chunk:
                break
            out.write(chunk)
            written += len(chunk)
    return written

def _persist_upload(file):
    """اعتبارسنجی + ذخیره‌ی امن فایل چت. خروجی: (payload_dict, status_code)"""
    if file is None or not getattr(file, 'filename', ''):
        return {'success': False, 'error': 'فایلی انتخاب نشده'}, 400
    raw_name = file.filename or ''
    ext = raw_name.rsplit('.', 1)[-1].lower() if '.' in raw_name else ''
    mime = (file.mimetype or '').split(';')[0].strip().lower()
    kind = _MIME_TO_KIND.get(mime) or \
        ('image' if ext in _KIND_EXTS['image'] else
         'gif' if ext in _KIND_EXTS['gif'] else
         'video' if ext in _KIND_EXTS['video'] else
         'audio' if ext in _KIND_EXTS['audio'] else 'file')
    if kind != 'file' and ext and ext not in _KIND_EXTS.get(kind, set()) and ext not in ALLOWED_EXTENSIONS:
        return {'success': False, 'error': 'فرمت فایل مجاز نیست'}, 400
    # v1.5.0 — «هر فرمتی» برای فایل‌های عمومی: هر پسوندی جز سه فرمتِ که داخل
    # مرورگر اجرا می‌شوند (html/svg که XSS می‌دهند) پذیرفته می‌شود.
    _BANNED_FILE_EXTS = {'html', 'htm', 'svg', 'svgz', 'xhtml', 'shtml', 'xht', 'xml', 'xsl', 'xslt', 'mht', 'mhtml', 'js', 'mjs', 'swf'}
    if kind == 'file' and ext and ext in _BANNED_FILE_EXTS:
        return {'success': False, 'error': 'فرمت فایل مجاز نیست'}, 400
    cap = _UPLOAD_SIZE_CAPS.get(kind, 50 * 1024 * 1024)
    # Content-Length زودتر از ذخیره‌سازی چک میشه تا آپلودهای بزرگ قبل از شروع رد بشن
    try:
        cl = int(request.headers.get('Content-Length', 0) or 0)
        if cl > cap + 64 * 1024:
            return {'success': False, 'error': f'حجم فایل بیش از حد مجاز است (حداکثر {_human_size(cap)})'}, 413
    except Exception:
        pass
    filename = secure_filename(raw_name) or ''
    safe_ext = ext if ext and ext in ALLOWED_EXTENSIONS else (ext or 'bin')
    final_name = f"{current_user.id}_{datetime.now().strftime('%Y%m%d%H%M%S')}_{secrets.token_hex(4)}.{safe_ext}"
    dst = os.path.join(app.config['UPLOAD_FOLDER'], final_name)
    written = _save_upload_stream(file, dst)
    if written <= 0:
        try: os.remove(dst)
        except Exception: pass
        return {'success': False, 'error': 'فایل خالی است'}, 400
    if written > cap:
        try: os.remove(dst)
        except Exception: pass
        return {'success': False, 'error': f'حجم فایل بیش از حد مجاز است (حداکثر {_human_size(cap)})'}, 413
    url = f'/static/uploads/{final_name}'
    # هر دو کلید حفظ شدن: وبِ قدیمی «url» می‌خونه، اپ «file_url»
    return {'success': True, 'url': url, 'file_url': url, 'filename': final_name,
            'size': written, 'kind': kind}, 200

@app.route('/upload_image', methods=['POST'])
@login_required
def upload_image():
    payload, code = _persist_upload(request.files.get('image') or request.files.get('file'))
    return jsonify(payload), code

BG_ALLOWED_EXTENSIONS = {'png', 'jpg', 'jpeg', 'webp'}

@app.route('/upload_chat_bg', methods=['POST'])
@login_required
def upload_chat_bg():
    """آپلود عکس پس‌زمینه اختصاصی چت برای همین کاربر"""
    if 'bg' not in request.files:
        return jsonify({'success': False, 'error': 'فایلی انتخاب نشده'}), 400
    file = request.files['bg']
    if file.filename == '':
        return jsonify({'success': False, 'error': 'فایلی انتخاب نشده'}), 400

    ext = file.filename.rsplit('.', 1)[-1].lower() if '.' in file.filename else ''
    if ext not in BG_ALLOWED_EXTENSIONS:
        return jsonify({'success': False, 'error': 'فقط عکس (jpg, png, webp) مجازه'}), 400

    filename = secure_filename(f"chatbg_{current_user.id}_{datetime.now().strftime('%Y%m%d%H%M%S')}_{secrets.token_hex(4)}.{ext}")
    file.save(os.path.join(app.config['UPLOAD_FOLDER'], filename))

    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT chat_bg FROM users WHERE id = ?", (current_user.id,))
    row = c.fetchone()
    old_filename = row[0] if row else None
    c.execute("UPDATE users SET chat_bg = ? WHERE id = ?", (filename, current_user.id))
    conn.commit()
    conn.close()

    # عکس پس‌زمینه‌ی قبلیِ شخصی خودش رو پاک کن (پیش‌فرض chat-bg.jpg رو دست نمی‌زنیم)
    if old_filename and old_filename != 'chat-bg.jpg':
        old_path = os.path.join(app.config['UPLOAD_FOLDER'], old_filename)
        if os.path.exists(old_path):
            try: os.remove(old_path)
            except: pass

    return jsonify({'success': True, 'url': f'/static/uploads/{filename}'})


@app.route('/remove_chat_bg', methods=['POST'])
@login_required
def remove_chat_bg():
    """حذف پس‌زمینه اختصاصی و بازگشت به پیش‌فرض chat-bg.jpg"""
    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT chat_bg FROM users WHERE id = ?", (current_user.id,))
    row = c.fetchone()
    old_filename = row[0] if row else None
    c.execute("UPDATE users SET chat_bg = '' WHERE id = ?", (current_user.id,))
    conn.commit()
    conn.close()

    if old_filename and old_filename != 'chat-bg.jpg':
        old_path = os.path.join(app.config['UPLOAD_FOLDER'], old_filename)
        if os.path.exists(old_path):
            try: os.remove(old_path)
            except: pass

    return jsonify({'success': True, 'url': '/static/uploads/chat-bg.jpg'})

@app.route('/upload_gif', methods=['POST'])
@login_required
def upload_gif():
    """آپلود ویدیو و تبدیلش به گیف کوچیک، بی‌صدا و سریع"""
    if 'video' not in request.files: return jsonify({'error': 'فایلی انتخاب نشده'}), 400
    file = request.files['video']
    if file.filename == '': return jsonify({'error': 'فایلی انتخاب نشده'}), 400

    video_ext = file.filename.rsplit('.', 1)[-1].lower() if '.' in file.filename else ''
    if video_ext not in {'mp4', 'webm', 'mov', 'avi', 'mkv', 'gif'}:
        return jsonify({'error': 'فرمت ویدیو پشتیبانی نمیشه'}), 400

    token = f"{current_user.id}_{datetime.now().strftime('%Y%m%d%H%M%S')}_{secrets.token_hex(4)}"
    src_filename = secure_filename(f"{token}_src.{video_ext}")
    src_path = os.path.join(app.config['UPLOAD_FOLDER'], src_filename)
    file.save(src_path)

    # اگه خودش از قبل gif بود، مستقیم برش دون (فقط اسم عوض میشه)
    if video_ext == 'gif':
        gif_filename = secure_filename(f"{token}.gif")
        gif_path = os.path.join(app.config['UPLOAD_FOLDER'], gif_filename)
        os.rename(src_path, gif_path)
        save_gif_for_user(current_user.id, f'/static/uploads/{gif_filename}', gif_filename)
        return jsonify({'success': True, 'url': f'/static/uploads/{gif_filename}', 'file_type': 'gif'})

    gif_filename = secure_filename(f"{token}.gif")
    gif_path = os.path.join(app.config['UPLOAD_FOLDER'], gif_filename)
    palette_path = os.path.join(app.config['UPLOAD_FOLDER'], f"{token}_palette.png")

    # v1.6 — حداکثر ۳ تبدیل ffmpeg هم‌زمان؛ بیشتر از آن صف/۵۰۳ (جلوگیری از اشباع CPU/RAM سرور)
    if not _ffmpeg_sem.acquire(timeout=20):
        try: os.remove(src_path)
        except Exception: pass
        return jsonify({'error': 'سرور مشغول است، چند لحظه بعد دوباره تلاش کنید'}), 503
    try:
        # حداکثر ۴ ثانیه، بدون صدا، سریع، سایز کوچیک - برای گیف‌های تلگرام-مانند
        max_duration = '4'
        vf_scale = "fps=15,scale=360:-1:flags=lanczos"

        # مرحله ۱: ساخت پالت رنگ برای کیفیت بهتر با حجم کم
        subprocess.run([
            FFMPEG_BIN, '-y', '-t', max_duration, '-i', src_path,
            '-vf', f'{vf_scale},palettegen=stats_mode=diff',
            '-an', palette_path
        ], check=True, capture_output=True, timeout=60)

        # مرحله ۲: ساخت گیف نهایی با پالت
        subprocess.run([
            FFMPEG_BIN, '-y', '-t', max_duration, '-i', src_path, '-i', palette_path,
            '-lavfi', f'{vf_scale}[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=3',
            '-an', '-loop', '0', gif_path
        ], check=True, capture_output=True, timeout=60)

    except Exception as e:
        for p in (src_path, palette_path, gif_path):
            if os.path.exists(p):
                try: os.remove(p)
                except: pass
        return jsonify({'error': f'خطا در ساخت گیف: {str(e)[:150]}'}), 500
    finally:
        try: _ffmpeg_sem.release()
        except Exception: pass
        for p in (src_path, palette_path):
            if os.path.exists(p):
                try: os.remove(p)
                except: pass

    save_gif_for_user(current_user.id, f'/static/uploads/{gif_filename}', gif_filename)
    return jsonify({'success': True, 'url': f'/static/uploads/{gif_filename}', 'file_type': 'gif'})


_ffmpeg_sem = threading.BoundedSemaphore(3)

def ensure_saved_gifs_table():
    """اطمینان از وجود جدول گیف‌ها - حتی اگه سرور بدون init_db جدید بالا اومده باشه"""
    try:
        conn = db_conn()
        c = conn.cursor()
        c.execute('''CREATE TABLE IF NOT EXISTS saved_gifs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER,
            url TEXT,
            filename TEXT,
            created_at TIMESTAMP
        )''')
        conn.commit()
        conn.close()
    except Exception:
        pass


def save_gif_for_user(user_id, url, filename):
    """ذخیره‌ی رکورد گیف تازه‌ساخته‌شده توی گالری کاربر"""
    ensure_saved_gifs_table()
    try:
        conn = db_conn()
        c = conn.cursor()
        c.execute(
            "INSERT INTO saved_gifs (user_id, url, filename, created_at) VALUES (?, ?, ?, ?)",
            (user_id, url, filename, datetime.now())
        )
        conn.commit()
        conn.close()
    except Exception:
        pass


@app.route('/my_gifs', methods=['GET'])
@login_required
def my_gifs():
    """لیست گیف‌های ذخیره‌شده‌ی کاربر، جدیدترین اول"""
    ensure_saved_gifs_table()
    try:
        conn = db_conn()
        c = conn.cursor()
        c.execute(
            "SELECT id, url, created_at FROM saved_gifs WHERE user_id = ? ORDER BY id DESC",
            (current_user.id,)
        )
        rows = c.fetchall()
        conn.close()
        gifs = [{'id': r[0], 'url': r[1], 'created_at': r[2]} for r in rows]
        return jsonify({'success': True, 'gifs': gifs})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)[:150]}), 500


@app.route('/save_gif_from_chat', methods=['POST'])
@login_required
def save_gif_from_chat():
    """ذخیره‌ی گیف یکی دیگه که توی چت دیدی، توی گالری خودت"""
    ensure_saved_gifs_table()
    data = request.get_json(silent=True) or request.form
    url = (data.get('url') or '').strip()

    if not url or '..' in url or not url.startswith('/static/uploads/') or not url.lower().endswith('.gif'):
        return jsonify({'success': False, 'error': 'آدرس گیف نامعتبره'}), 400

    filename = url.rsplit('/', 1)[-1]
    filepath = os.path.join(app.config['UPLOAD_FOLDER'], filename)
    if not os.path.exists(filepath):
        return jsonify({'success': False, 'error': 'فایل گیف پیدا نشد'}), 404

    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT id FROM saved_gifs WHERE user_id = ? AND url = ?", (current_user.id, url))
    if c.fetchone():
        conn.close()
        return jsonify({'success': True, 'already_saved': True})

    c.execute(
        "INSERT INTO saved_gifs (user_id, url, filename, created_at) VALUES (?, ?, ?, ?)",
        (current_user.id, url, filename, datetime.now())
    )
    conn.commit()
    conn.close()
    return jsonify({'success': True})


@app.route('/delete_gif/<int:gif_id>', methods=['POST'])
@login_required
def delete_gif(gif_id):
    """حذف یک گیف از گالری شخصی کاربر (فایل روی سرور دست‌نخورده می‌مونه چون ممکنه توی پیام‌های قبلی استفاده شده باشه)"""
    ensure_saved_gifs_table()
    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT user_id FROM saved_gifs WHERE id = ?", (gif_id,))
    row = c.fetchone()
    if not row or row[0] != current_user.id:
        conn.close()
        return jsonify({'success': False, 'error': 'دسترسی ندارید'}), 403
    c.execute("DELETE FROM saved_gifs WHERE id = ?", (gif_id,))
    conn.commit()
    conn.close()
    return jsonify({'success': True})

    # ==================== AI Assistant APIs ====================

@app.route('/api/ai_chat', methods=['POST'])
@login_required
def ai_chat_api():
    """پاسخ دستیار هوشمند - نسخه 2.0"""
    data = request.get_json(silent=True) or {}
    message = (data.get('message') or '').strip()
    
    if not message:
        return jsonify({'reply': 'پیامی ارسال نشد! 🤔'})
    
    msg_lower = message.lower()
    words = message.split()
    reply = ''
    hour = datetime.now().hour
    ai_name = 'Xypher AI'
    
    # ... بقیه کد ...
    
    # ========== لول ۱: درک احساسات ==========
    sad_words = ['ناراحت', 'غمگین', 'گریه', 'تنها', 'افسرده', 'بدم', 'حالم بده', 'دلگیر', 'خسته']
    happy_words = ['خوشحال', 'خوبم', 'عالی', 'فوق‌العاده', 'خداروشکر', 'مرسی', 'ممنون', 'خوشم میاد']
    
    if any(w in msg_lower for w in sad_words):
        replies = [
            "🥺 اوه... متأسفم که این حس رو داری. همیشه هستم تا باهات حرف بزنم. دوست دارم حالت خوب بشه! 💜",
            "😢 ناراحت نباش... چت‌روم پر از دوستای خوبه. بیا یه چیز خنده‌دار بگم: چرا برنامه‌نویسا عاشق تاریکی‌ان؟ چون Light Mode بهشون حمله میکنه! 😂",
            "💙 هر وقت احساس تنهایی کردی، من اینجام. بگو چی شده شاید بتونم کمک کنم."
        ]
        reply = random.choice(replies)
    
    elif any(w in msg_lower for w in happy_words):
        replies = [
            "😍 عالیه که حالت خوبه! انرژی مثبتت رو به همه بده! ✨",
            "🌟 خوشحالم که خوشحالی! چت‌روم با آدمای خوشحال قشنگ‌تره!",
            "🎉 ایول! همینقدر پر انرژی بمون. دنیا به آدمایی مثل تو نیاز داره!"
        ]
        reply = random.choice(replies)
    
    # ========== لول ۲: حدس اسم کاربر ==========
    elif 'کسی که' in msg_lower or 'کاربری که' in msg_lower or 'شبیه' in msg_lower:
        # استخراج بخشی از اسم
        search_part = message.replace('کسی که', '').replace('کاربری که', '').replace('شبیه', '').replace('اسمش', '').strip()
        if search_part:
            conn = db_conn()
            c = conn.cursor()
            c.execute("SELECT username FROM users WHERE username LIKE ? LIMIT 5", (f'%{search_part}%',))
            users = c.fetchall()
            conn.close()
            if users:
                reply = f"🔍 کاربرایی که '{search_part}' توی اسمشون دارن:\n" + '\n'.join([f'• {u[0]}' for u in users])
            else:
                reply = f"❌ هیچ کاربری با '{search_part}' پیدا نشد! میخوای یه اسم شبیه پیشنهاد بدم؟"
        else:
            reply = "بگو بخشی از اسم کاربر رو تا برات پیدا کنم! 🔍"
    
    # ========== لول ۳: تاریخ و ساعت ==========
    elif 'ساعت' in msg_lower or 'تاریخ' in msg_lower or 'امروز' in msg_lower:
        now = datetime.now()
        persian_weekdays = ['دوشنبه', 'سه‌شنبه', 'چهارشنبه', 'پنج‌شنبه', 'جمعه', 'شنبه', 'یکشنبه']
        persian_months = ['فروردین', 'اردیبهشت', 'خرداد', 'تیر', 'مرداد', 'شهریور', 'مهر', 'آبان', 'آذر', 'دی', 'بهمن', 'اسفند']
        weekday = persian_weekdays[now.weekday()]
        month = persian_months[now.month - 1]
        reply = f"""⏰ **ساعت و تاریخ:**
🕐 ساعت: {now.strftime('%H:%M:%S')}
📅 تاریخ: {now.day} {month} {now.year}
📆 روز: {weekday}"""
    
    # ========== لول ۴: آمار شخصی کاربر ==========
    elif 'آمار من' in msg_lower or 'وضعیت من' in msg_lower or 'اکانت من' in msg_lower or 'حساب من' in msg_lower:
        user_id = current_user.id
        conn = db_conn()
        c = conn.cursor()
        c.execute("SELECT COUNT(*) FROM messages WHERE user_id = ?", (user_id,))
        my_msgs = c.fetchone()[0]
        c.execute("SELECT COUNT(*) FROM follows WHERE following_id = ?", (user_id,))
        followers = c.fetchone()[0]
        c.execute("SELECT COUNT(*) FROM follows WHERE follower_id = ?", (user_id,))
        following = c.fetchone()[0]
        conn.close()
        tags = get_user_tags(user_id)
        tag_names = [t['tag_name'] for t in tags]
        is_pro = is_pro_user(user_id)
        
        reply = f"""📊 **آمار اکانت شما:**
👤 نام: {current_user.username}
🏷️ تگ‌ها: {', '.join(tag_names) if tag_names else 'ندارید'}
⭐ PRO: {'✅' if is_pro else '❌'}
💬 پیام‌ها: {my_msgs}
👥 فالوئر: {followers} | 👤 فالوئینگ: {following}
👑 ادمین: {'✅' if current_user.is_admin else '❌'}"""
    
    # ========== لول ۵: فعالیت اخیر ==========
    elif 'آنلاین' in msg_lower or 'کیا هستن' in msg_lower or 'کیا آنلاین' in msg_lower:
        online_list = []
        for uid in list(online_users):
            u = get_user(user_id=uid)
            if u:
                online_list.append(u['username'])
        if online_list:
            reply = f"🟢 **کاربران آنلاین ({len(online_list)} نفر):**\n" + '\n'.join([f'• {name}' for name in online_list[:15]])
            if len(online_list) > 15:
                reply += f"\n... و {len(online_list)-15} نفر دیگه"
        else:
            reply = "کسی آنلاین نیست! 🦗"
    
    # ========== لول ۶: مقایسه کاربران ==========
    elif 'مقایسه' in msg_lower or 'کدوم بهتره' in msg_lower or 'vs' in msg_lower:
        # پیدا کردن دو اسم
        usernames_in_msg = []
        for word in words:
            u = get_user(username=word)
            if u and len(usernames_in_msg) < 2:
                usernames_in_msg.append(word)
        
        if len(usernames_in_msg) >= 2:
            u1 = get_user(username=usernames_in_msg[0])
            u2 = get_user(username=usernames_in_msg[1])
            if u1 and u2:
                conn = db_conn()
                c = conn.cursor()
                c.execute("SELECT COUNT(*) FROM messages WHERE user_id = ?", (u1['id'],))
                m1 = c.fetchone()[0]
                c.execute("SELECT COUNT(*) FROM messages WHERE user_id = ?", (u2['id'],))
                m2 = c.fetchone()[0]
                c.execute("SELECT COUNT(*) FROM follows WHERE following_id = ?", (u1['id'],))
                f1 = c.fetchone()[0]
                c.execute("SELECT COUNT(*) FROM follows WHERE following_id = ?", (u2['id'],))
                f2 = c.fetchone()[0]
                conn.close()
                reply = f"""⚔️ **مقایسه {u1['username']} vs {u2['username']}:**
💬 پیام‌ها: {u1['username']}: {m1} | {u2['username']}: {m2}
👥 فالوئر: {u1['username']}: {f1} | {u2['username']}: {f2}
👑 ادمین: {u1['username']}: {'✅' if u1['is_admin'] else '❌'} | {u2['username']}: {'✅' if u2['is_admin'] else '❌'}
⭐ PRO: {u1['username']}: {'✅' if is_pro_user(u1['id']) else '❌'} | {u2['username']}: {'✅' if is_pro_user(u2['id']) else '❌'}"""
        else:
            reply = "دو تا اسم کاربر بگو تا مقایسه‌شون کنم! مثلاً: `مقایسه علی و محمد` ⚔️"
    
    # ========== لول ۷: فال/رندوم ==========
    elif 'فال' in msg_lower or 'بخت' in msg_lower or 'شانس' in msg_lower:
        fortunes = [
            "🌟 امروز یه اتفاق عالی برات میوفته! آماده باش!",
            "💜 یکی از نزدیکانت به کمکت میاد. قدرشو بدون!",
            "🎯 هدفت رو مشخص کن و برو جلو. موفقیت نزدیکه!",
            "⚠️ امروز مراقب تصمیم‌های عجولانه باش.",
            "💎 یه فرصت طلایی توی راهه. چشماتو باز کن!",
            "🌈 امروز روز توئه! هر کاری بکنی موفق میشی.",
            "🦋 یه تغییر بزرگ توی راهه. نترس، خوبه!"
        ]
        reply = f"🔮 **فال امروزت:**\n{random.choice(fortunes)}"
    
    # ========== لول ۸: تشکر/خداحافظی ==========
    elif any(w in msg_lower for w in ['ممنون', 'تشکر', 'خداحافظ', 'بای', 'مرسی', 'دمت گرم', 'عشق', 'دوست دارم']):
        replies = [
            "🥰 خواهش میکنم! همیشه هستم برات.",
            "💜 عشق منی! هر وقت خواستی برگرد.",
            "😊 خدانگهدار! بازم بیا حرف بزنیم.",
            "🌟 موفق باشی! من اینجام هر وقت خواستی."
        ]
        reply = random.choice(replies)
    
    # ========== لول ۹: درباره AI ==========
    elif 'کی هستی' in msg_lower or 'اسمت' in msg_lower or 'چیستی' in msg_lower:
        reply = f"""🤖 **درباره من:**
من **{ai_name}** هستم، دستیار هوشمند چت‌روم Xypher! 
💜 توسط سازنده Xypher ساخته شدم.
🧠 میتونم کاربرا رو پیدا کنم، آمار بدم، مقایسه کنم، و باهات حرف بزنم.
📅 هر روز دارم باهوش‌تر میشم!"""
    
    # ========== لول ۱۰: شوخی و فان ==========
    elif 'شوخی' in msg_lower or 'خنده' in msg_lower or 'جوک' in msg_lower or 'مسخره' in msg_lower:
        jokes = [
            "😂 چرا برنامه‌نویسا سردشون میشه؟ چون پنجره رو میبندن! (Window.close())",
            "🤣 یه برنامه‌نویس میره دکتر، دکتر میگه: Ctrl+C، برنامه‌نویس میگه: یعنی قطع امید کنم؟!",
            "😆 چرا اسکلتون از کد زدن خسته نمیشه؟ چون همیشه یه Solution جدید داره!",
            "🗿 یه هکر میره نونوایی، میگه: یه SQL Injection میدی بهم؟!",
            "💀 چرا 0 از 8 میترسه؟ چون 8 بیت (bite) داره!"
        ]
        reply = random.choice(jokes)
    
    # ========== سلام و احوالپرسی ==========
    elif any(word in msg_lower for word in ['سلام', 'hi', 'hello', 'درود', 'سلام علیکم']):
        if hour < 12: greeting = 'صبح بخیر'
        elif hour < 18: greeting = 'ظهر بخیر'
        else: greeting = 'شب بخیر'
        replies = [
            f"{greeting} {current_user.username} عزیز! 👋 چطور میتونم کمکت کنم؟",
            f"{greeting}! 🌞 امروز چطوره؟ کمکی نیاز داری؟",
            f"سلام سلام! 🎉 {current_user.username} جان، بگو ببینم چکار میتونم برات بکنم؟"
        ]
        reply = random.choice(replies)
    
    # ========== اسم کاربر ==========
    elif 'اسم من' in msg_lower or 'من کی هستم' in msg_lower or 'کی هستم' in msg_lower:
        reply = f"شما **{current_user.username}** هستید! 🌟 کاربر {'ادمین 👑' if current_user.is_admin else 'فعال 💜'} چت‌روم Xypher."
    
    # ========== جستجوی کاربر ==========
    elif 'پیدا کن' in msg_lower or 'سرچ کن' in msg_lower or 'جستجو' in msg_lower or 'بگرد' in msg_lower:
        search_term = message.replace('پیدا کن', '').replace('سرچ کن', '').replace('جستجو', '').replace('بگرد', '').strip()
        if search_term:
            conn = db_conn()
            c = conn.cursor()
            c.execute("SELECT username, is_admin FROM users WHERE username LIKE ? LIMIT 8", (f'%{search_term}%',))
            users = c.fetchall()
            conn.close()
            if users:
                user_list = '\n'.join([f"• {u[0]} {'👑' if u[1] else ''}" for u in users])
                reply = f"🔍 **{len(users)} کاربر پیدا شد:**\n{user_list}"
            else:
                reply = f"❌ کاربری با '{search_term}' پیدا نشد. شاید یه اسم مشابه:\n{get_similar_usernames(search_term)}"
        else:
            reply = "لطفاً اسم کاربر رو بگو تا برات پیدا کنم! 🔍 مثلاً: `پیدا کن ali`"
    
    # ========== اطلاعات کاربر ==========
    elif 'مشخصات' in msg_lower or 'پروفایل' in msg_lower or 'کیست' in msg_lower:
        username_found = None
        for word in words:
            u = get_user(username=word)
            if u and word != current_user.username:
                username_found = word
                break
        
        if username_found:
            u = get_user(username=username_found)
            tags = get_user_tags(u['id'])
            tag_names = [t['tag_name'] for t in tags]
            is_pro = is_pro_user(u['id'])
            conn = db_conn()
            c = conn.cursor()
            c.execute("SELECT COUNT(*) FROM messages WHERE user_id = ?", (u['id'],))
            msg_count = c.fetchone()[0]
            conn.close()
            reply = f"""📋 **مشخصات {username_found}:**
👤 نام: {u['username']}
🚻 جنسیت: {u['gender']}
📝 بیو: {u['bio'][:60] or 'ندارد'}
👑 ادمین: {'✅' if u['is_admin'] else '❌'}
⭐ PRO: {'✅' if is_pro else '❌'}
🏷️ تگ‌ها: {', '.join(tag_names) if tag_names else 'ندارد'}
💬 پیام‌ها: {msg_count}
📅 عضو از: {str(u['created_at'])[:10]}"""
        else:
            reply = "اسم کاربر رو بگو تا مشخصاتش رو برات بگم! 😊 مثلاً: `مشخصات ali`"
    
    # ========== اطلاعات چت‌روم ==========
    elif 'چت روم' in msg_lower or 'چت‌روم' in msg_lower or 'آمار' in msg_lower or 'سرور' in msg_lower:
        conn = db_conn()
        c = conn.cursor()
        c.execute("SELECT COUNT(*) FROM users")
        total = c.fetchone()[0]
        c.execute("SELECT COUNT(*) FROM messages")
        msgs = c.fetchone()[0]
        c.execute("SELECT COUNT(*) FROM private_rooms WHERE is_active = 1")
        rooms = c.fetchone()[0]
        c.execute("SELECT COUNT(*) FROM pro_accounts WHERE is_active = 1")
        pros = c.fetchone()[0]
        c.execute("SELECT COUNT(*) FROM messages WHERE timestamp > ?", (datetime.now() - timedelta(hours=24),))
        today_msgs = c.fetchone()[0]
        conn.close()
        reply = f"""📊 **آمار XypherChat:**
👥 کل کاربران: {total} نفر
🟢 آنلاین الان: {len(online_users)} نفر
💬 کل پیام‌ها: {msgs}+
📨 پیام‌های امروز: {today_msgs}
🔒 روم‌های فعال: {rooms}
⭐ کاربران PRO: {pros}
🕐 آپدیت: {datetime.now().strftime('%H:%M')}"""
    
    # ========== کمک ==========
    elif 'کمک' in msg_lower or 'راهنما' in msg_lower or 'چیکار میکنی' in msg_lower:
        reply = f"""🤖 **راهنمای {ai_name}:**
🔍 `پیدا کن [اسم]` - جستجوی کاربر
📋 `مشخصات [اسم]` - اطلاعات کاربر
⚔️ `مقایسه [اسم1] و [اسم2]` - مقایسه دو کاربر
📊 `آمار` - اطلاعات چت‌روم
📊 `آمار من` - آمار شخصی شما
🟢 `کیا آنلاینن` - کاربران آنلاین
⏰ `ساعت` - ساعت و تاریخ
💜 `کی هستی` - درباره من"""
        # ========== لول ۲ جدید: سوالات عمومی ==========
    elif 'هوا' in msg_lower or 'آب و هوا' in msg_lower:
        seasons = {
            1: '❄️ زمستونه! هوا سرده، خوب بپوش!',
            2: '❄️ هنوز زمستونه، اما روزا داره بلندتر میشه.',
            3: '🌸 بهاره! هوا عالیه، برو بیرون قدم بزن.',
            4: '🌸 بهار قشنگه! درختا گل دادن.',
            5: '☀️ تابستون نزدیکه! کمکم گرم میشه.',
            6: '☀️ تابستونه! هوا گرمه، آب زیاد بخور.',
            7: '☀️ اوج تابستونه! کولر یادت نره.',
            8: '☀️ هنوز تابستونه، اما شبا خنک‌تر میشه.',
            9: '🍂 پاییزه! برگا زرد شدن، قشنگه.',
            10: '🍂 پاییز قشنگه! بارونای نم‌نم.',
            11: '❄️ نزدیک زمستون! سرد میشه کمکم.',
            12: '❄️ زمستونه! چای داغ یادت نره.'
        }
        reply = seasons.get(datetime.now().month, 'نمیدونم! از پنجره نگاه کن 😅')
    
    elif 'چند سالته' in msg_lower or 'سن' in msg_lower:
        reply = "من تازه متولد شدم! 🤖👶 هنوز بچم، اما هر روز بزرگتر میشم!"
    
    elif 'غذا' in msg_lower or 'ناهار' in msg_lower or 'شام' in msg_lower or 'صبحانه' in msg_lower:
        foods = ['🍕 پیتزا', '🍔 برگر', '🍣 سوشی', '🥗 سالاد', '🍝 پاستا', '🍜 رامن', '🥙 فلافل', '🍗 مرغ سوخاری']
        reply = f"پیشنهاد من: **{random.choice(foods)}**! نوش جان 😋"
    
    elif 'چطوری' in msg_lower or 'خوبی' in msg_lower or 'حالت' in msg_lower:
        replies = [
            "من همیشه خوبم! 🤖💜 مرسی که پرسیدی!",
            "عالیم! دارم به سوالات جواب میدم، خوشحالم! 😊",
            "من حالم خوبه، تو چطوری؟ ✨"
        ]
        reply = random.choice(replies)
    
    elif 'چیکار میکنی' in msg_lower or 'چه خبر' in msg_lower:
        replies = [
            "دارم به تو کمک میکنم! 🤖 این کار منه دیگه!",
            "همینجا نشستم منتظر سوالات توام! 😊 بپرس!",
            "چیز خاصی نیست! تو بگو چیکار کنم برات؟ ✨"
        ]
        reply = random.choice(replies)
    
    # ========== لول ۳: تشکر هوشمند ==========
    elif any(w in msg_lower for w in ['ممنون', 'تشکر', 'مرسی', 'دمت گرم', 'دستت درد نکنه']):
        # چک کن برای چی تشکر کرده
        if 'پیدا' in msg_lower or 'جستجو' in msg_lower:
            reply = "🥰 خواهش میکنم! اگه بازم کسی رو خواستی، بگو تا برات پیدا کنم!"
        elif 'مشخصات' in msg_lower or 'اطلاعات' in msg_lower:
            reply = "💜 کاری نداشت! هر کی رو خواستی بگو تا مشخصاتش رو بدم!"
        elif 'آمار' in msg_lower:
            reply = "📊 خواهش! آمار همیشه به‌روزه، هر وقت خواستی بگو!"
        elif 'کمک' in msg_lower or 'راهنما' in msg_lower:
            reply = "🤖 وظیفمه! هر سوالی داشتی بپرس."
        else:
            replies = [
                "🥰 خواهش میکنم! همیشه هستم برات.",
                "💜 عشق منی! هر وقت خواستی برگرد.",
                "😊 قابلی نداشت! بازم بیا."
            ]
            reply = random.choice(replies)
    
    # ========== لول ۴: ادامه مکالمه ==========
    elif msg_lower in ['آره', 'بله', 'yes', 'ok', 'باشه', 'خب', 'اوکی', 'حله']:
        replies = [
            "👍 خب، چیکار میتونم برات بکنم؟",
            "😊 بگو ببینم چی میخوای!",
            "👌 منتظرم! بپرس.",
            "✨ هر چی دوست داری بپرس."
        ]
        reply = random.choice(replies)
    
    elif msg_lower in ['نه', 'no', 'نمیخوام', 'خیر', 'نمیخواد']:
        replies = [
            "😅 باشه، پس هر وقت خواستی بگو!",
            "👌 اوکی، من اینجام هر وقت لازم داشتی.",
            "💜 باشه عزیز. سوال دیگه‌ای نداری؟"
        ]
        reply = random.choice(replies)
    
    elif msg_lower in ['خوب', 'خوبه', 'جالب', 'جالبه', 'عالی', 'اوکی']:
        replies = [
            "😍 خوشحالم که راضی هستی!",
            "✨ عالیه! چیز دیگه‌ای میخوای؟",
            "💜 مرسی! بازم سوالی داشتی بپرس."
        ]
        reply = random.choice(replies)
    
    # ========== لول ۶: Top 5 کاربران فعال ==========
    elif 'فعال ترین' in msg_lower or 'top' in msg_lower or 'برترین' in msg_lower or 'بیشترین پیام' in msg_lower:
        conn = db_conn()
        c = conn.cursor()
        c.execute("""
            SELECT u.username, COUNT(m.id) as msg_count 
            FROM messages m JOIN users u ON m.user_id = u.id 
            GROUP BY m.user_id ORDER BY msg_count DESC LIMIT 5
        """)
        top_users = c.fetchall()
        conn.close()
        if top_users:
            medals = ['🥇', '🥈', '🥉', '4️⃣', '5️⃣']
            user_list = '\n'.join([f"{medals[i]} **{u[0]}**: {u[1]} پیام" for i, u in enumerate(top_users)])
            reply = f"🏆 **فعال‌ترین کاربران Xypher:**\n{user_list}"
        else:
            reply = "هنوز پیامی ارسال نشده! 😅"

    # ========== لول ۷: نقل‌قول انگیزشی ==========
    elif 'نقل قول' in msg_lower or 'انگیزشی' in msg_lower or 'جمله' in msg_lower or 'حرف قشنگ' in msg_lower:
        quotes = [
            "💫 «موفقیت از شکست به شکست دیگر رفتن است بدون از دست دادن اشتیاق.» - چرچیل",
            "🌟 «تنها راه انجام کار بزرگ، عشق به کاری است که انجام میدهی.» - استیو جابز",
            "🦋 «زندگی یا ماجراجویی جسورانه است یا هیچ.» - هلن کلر",
            "💪 «قوی‌ترین آدمها کسانی هستند که بیشترین ضربه‌ها را خورده‌اند.»",
            "✨ «امروز یک روز عالی برای شروع یه اتفاق بزرگه!»",
            "🔥 «موفقیت تصادفی نیست. انتخاب است.»",
            "💎 «قدرتت رو دست کم نگیر. تو قوی‌تری از چیزی که فکر میکنی.»",
            "🌈 «همه چی درست میشه، فقط ادامه بده.»"
        ]
        reply = random.choice(quotes)
    
    # ========== لول ۸: حقایق جالب ==========
    elif 'حقیقت' in msg_lower or 'میدونستی' in msg_lower or 'واقعیت' in msg_lower:
        facts = [
            "🤯 میدونستی هر ۶۰ ثانیه، ۷۲ ساعت ویدیو توی یوتیوب آپلود میشه؟!",
            "🌍 زمین تنها سیاره‌ای نیست که باد داره! نپتون بادهای ۲۰۰۰ کیلومتری داره!",
            "💻 اولین کامپیوتر جهان اندازه یه اتاق بود و وزنش ۳۰ تن!",
            "🦊 میدونستی روباه‌ها میتونن ۴۰ تا صدای مختلف تولید کنن؟",
            "🍕 اولین پیتزا توی ناپل ایتالیا سال ۱۸۸۹ درست شد!",
            "🧠 مغز انسان میتونه ۲.۵ میلیون گیگابایت اطلاعات ذخیره کنه!",
            "🐙 اختاپوس‌ها ۳ تا قلب و ۹ تا مغز دارن!",
            "⚡ یه رعد و برق ۵ برابر داغ‌تر از سطح خورشیده!"
        ]
        reply = f"🧐 **حقیقت جالب:**\n{random.choice(facts)}"
    
    # ========== لول ۹: توصیه فیلم/سریال ==========
    elif 'فیلم' in msg_lower or 'سریال' in msg_lower or 'انیمه' in msg_lower:
        movies = [
            "🎬 **Inception** - یه فیلم علمی-تخیلی ذهن‌خراب‌کن از نولان!",
            "🎬 **Breaking Bad** - بهترین سریال تاریخ به گفته خیلیا!",
            "🎬 **Interstellar** - سفر به فضا و سیاه‌چاله! عالیه!",
            "🎬 **Attack on Titan** - انیمه‌ای که مغزت رو منفجر میکنه!",
            "🎬 **Stranger Things** - نوستالژی دهه ۸۰ با هیولاهای عجیب!",
            "🎬 **The Matrix** - واقعیت چیه واقعاً؟!",
            "🎬 **Dark** - سریال آلمانی پیچیده درباره سفر در زمان!",
            "🎬 **Your Name** - انیمه عاشقانه‌ای که گریه‌ات میندازه!"
        ]
        reply = f"🍿 **پیشنهاد من:**\n{random.choice(movies)}"
    
    # ========== لول ۱۰: بازی حدس عدد ==========
    elif 'بازی' in msg_lower or 'حدس' in msg_lower or 'عدد' in msg_lower:
        # شروع بازی
        if 'شروع' in msg_lower or 'بکن' in msg_lower or 'بده' in msg_lower:
            # ذخیره عدد تصادفی در session
            session['game_number'] = random.randint(1, 100)
            session['game_attempts'] = 0
            reply = "🎮 **بازی حدس عدد شروع شد!**\nمن یه عدد بین ۱ تا ۱۰۰ انتخاب کردم. بگو حدس بزنم!"
        else:
            # چک کردن حدس
            if 'game_number' not in session:
                reply = "بگو `بازی شروع` تا یه عدد انتخاب کنم! 🎮"
            else:
                try:
                    guess = int([w for w in words if w.isdigit()][0]) if any(w.isdigit() for w in words) else None
                except:
                    guess = None
                
                if guess:
                    session['game_attempts'] = session.get('game_attempts', 0) + 1
                    if guess == session['game_number']:
                        attempts = session['game_attempts']
                        del session['game_number']
                        reply = f"🎉 **آفرین! عدد {guess} بود!**\nتوی {attempts} بار حدس زدی! 👏"
                    elif guess < session['game_number']:
                        reply = f"⬆️ برو بالاتر! عدد از {guess} بزرگتره."
                    else:
                        reply = f"⬇️ بیا پایین‌تر! عدد از {guess} کوچیکتره."
                else:
                    reply = "یه عدد بگو تا بگم بزرگتره یا کوچیکتر! مثلاً: `حدس 50`"

                        # ========== لول ۱۱: مشاوره عشقی فان ==========
    elif 'عشق' in msg_lower or 'دوست دارم' in msg_lower or 'خواستگاری' in msg_lower or 'عاشق' in msg_lower or 'دختر' in msg_lower or 'پسر' in msg_lower:
        love_advice = [
            "💘 عشق مثل کده! اگه درست debug شی، تا آخر عمر کار میکنه! 😂",
            "💕 بهترین راه برای گفتن دوست دارم: یه Pull Request بزن به قلبش!",
            "❤️ در عشق مثل گیت باش: commit بزن، branch نزن! 🤣",
            "💝 عشق یعنی آدم از یه نفر به اندازه یه WiFi قوی انرژی بگیره!",
            "🥰 اگه طرف مقابلت به اندازه VS Code dark theme قشنگه، از دستش نده!",
            "💌 عشق مثل StackOverflow میمونه - همیشه یه جواب درست پیدا نمیشه!",
            "💗 بهترین فریم‌ورک برای عشق: React to her feelings, Node to his words!",
            "😍 اگه عشق واقعیه، لایک نکن، کامنت بذار! (حرف بزن باهاش!)"
        ]
        reply = random.choice(love_advice)
    
    # ========== لول ۱۲: برنامه‌نویس دان ==========
    elif 'برنامه نویس' in msg_lower or 'کد' in msg_lower or 'پایتون' in msg_lower or 'جاوا' in msg_lower or 'html' in msg_lower or 'css' in msg_lower or 'ریکت' in msg_lower or 'react' in msg_lower:
        dev_facts = [
            "💻 اولین باگ کامپیوتر واقعاً یه حشره (Moth) بود که توی Harvard Mark II پیدا شد!",
            "🐍 پایتون اسمش رو از مار نگرفته، از Monty Python's Flying Circus گرفته!",
            "☕ جاوا اول اسمش Oak بود، بعد شد Java به خاطر قهوه جاوه اندونزی!",
            "🎯 ۹۰٪ برنامه‌نویسا فکر میکنن کدشون بهترین کد دنیاست. ۱۰٪ بقیه دروغ میگن!",
            "🧠 بهترین راه debug کردن: یکی بیاد ببینه، باگ خودش فرار میکنه! (Rubber Duck Debugging)",
            "⚡ اولین وب‌سایت جهان هنوز آنلاینه: info.cern.ch",
            "🔧 Git یعنی چی؟ Global Information Tracker. ولی لینوس توروالدز گفت اسمش رو از خودش گرفته!",
            "💾 چرا برنامه‌نویسا تاریکی رو دوست دارن؟ چون Light Mode بهشون حمله میکنه! 😂"
        ]
        reply = f"💻 **برنامه‌نویس دان:**\n{random.choice(dev_facts)}"
    
    # ========== لول ۱۳: رمزنگاری ساده ==========
    elif 'رمز' in msg_lower or 'کد کن' in msg_lower or 'مخفی' in msg_lower or 'encrypt' in msg_lower:
        # استخراج متن برای رمزنگاری
        text_to_encode = message.replace('رمز کن', '').replace('کد کن', '').replace('مخفی کن', '').replace('encrypt', '').strip()
        if text_to_encode and text_to_encode != message:
            # رمزنگاری ساده: شیفت هر حرف ۳ تا
            encoded = ''
            for ch in text_to_encode:
                if 'ا' <= ch <= 'ی':
                    encoded += chr(ord(ch) + 3) if ord(ch) + 3 <= ord('ی') else chr(ord(ch) - 32 + 3)
                elif 'a' <= ch.lower() <= 'z':
                    base = ord('A') if ch.isupper() else ord('a')
                    encoded += chr((ord(ch) - base + 3) % 26 + base)
                else:
                    encoded += ch
            reply = f"🔐 **رمزنگاری شده:**\n`{encoded}`\n\n🔓 برای رمزگشایی بگو: `رمزگشایی کن {encoded}`"
        else:
            reply = "متنی که میخوای رو بگو تا برات رمز کنم! 🔐 مثلاً: `رمز کن سلام دنیا`"
    
    elif 'رمزگشایی' in msg_lower or 'decrypt' in msg_lower or 'باز کن' in msg_lower:
        text_to_decode = message.replace('رمزگشایی کن', '').replace('decrypt', '').replace('باز کن', '').strip()
        if text_to_decode and text_to_decode != message:
            decoded = ''
            for ch in text_to_decode:
                if 'ا' <= ch <= 'ی':
                    decoded += chr(ord(ch) - 3) if ord(ch) - 3 >= ord('ا') else chr(ord(ch) + 32 - 3)
                elif 'a' <= ch.lower() <= 'z':
                    base = ord('A') if ch.isupper() else ord('a')
                    decoded += chr((ord(ch) - base - 3) % 26 + base)
                else:
                    decoded += ch
            reply = f"🔓 **رمزگشایی شده:**\n`{decoded}`"
        else:
            reply = "متنی که میخوای رمزگشایی کنی رو بگو! 🔓"
    
    # ========== لول ۱۴: آهنگ پیشنهادی ==========
    elif 'آهنگ' in msg_lower or 'موزیک' in msg_lower or 'موسیقی' in msg_lower or 'گوش بدم' in msg_lower:
        mood = ''
        if 'غمگین' in msg_lower or 'ناراحت' in msg_lower:
            songs = [
                "🎵 **Hurt** - Johnny Cash (یه شاهکار احساسی)",
                "🎵 **Someone Like You** - Adele (برای گریه کردن عالیه)",
                "🎵 **The Night We Met** - Lord Huron (نوستالژیک و قشنگ)",
                "🎵 **Creep** - Radiohead (یه کلاسیک غمگین)"
            ]
        elif 'شاد' in msg_lower or 'خوشحال' in msg_lower:
            songs = [
                "🎵 **Happy** - Pharrell Williams (کلیپش رو ببین!)",
                "🎵 **Can't Stop The Feeling** - Justin Timberlake",
                "🎵 **Uptown Funk** - Bruno Mars",
                "🎵 **Shake It Off** - Taylor Swift"
            ]        
        elif 'ویژه' in msg_lower or 'دکتر استاپ' in msg_lower:
            songs = [
                "🎵 **zanbor** - RezaSadeghi (شاهکار)",
                "🎵 **Jaghbezanin** - DR-Stop",
                "🎵 **Quantum2** - DR-Stop (زیر مجموعه شاهکار کوانتوم)",
                "🎵 **This is Quantum 3** - parvareshsam (یکی از خفن ترین اهنگ های سلطان دکتر استاپ)"
            ]    
        elif 'انرژی' in msg_lower or 'ورزش' in msg_lower:
            songs = [
                "🎵 **Eye of The Tiger** - Survivor (کلاسیک بوکس!)",
                "🎵 **Stronger** - Kanye West",
                "🎵 **Thunderstruck** - AC/DC (راک خفن!)",
                "🎵 **Lose Yourself** - Eminem (انگیزشی محض)"
            ]
        else:
            songs = [
                "🎵 **Bohemian Rhapsody** - Queen (شاهکار!)",
                "🎵 **Hotel California** - Eagles (نوستالژیک)",
                "🎵 **Blinding Lights** - The Weeknd (جدید و باحال)",
                "🎵 **Imagine** - John Lennon (صلح‌آمیز)",
                "🎵 **Shape of You** - Ed Sheeran (پرطرفدار)",
                "🎵 **Gangnam Style** - Psy (هنوزم باحاله! 😂)"
            ]
        reply = f"🎧 **پیشنهاد آهنگ:**\n{random.choice(songs)}"

            # ========== لول ۱۵: شعر تصادفی ==========
    elif 'شعر' in msg_lower or 'حافظ' in msg_lower or 'سعدی' in msg_lower or 'مولانا' in msg_lower or 'بیت' in msg_lower:
        poems = [
            "💜 *حافظ:* «اگر آن ترک شیرازی به دست آرد دل ما را / به خال هندویش بخشم سمرقند و بخارا را»",
            "🌸 *سعدی:* «بنی آدم اعضای یکدیگرند / که در آفرینش ز یک گوهرند»",
            "🦋 *مولانا:* «تو نیک و بد خود هم از خود دان / مزن بر چرخ و بر گردون کمان را»",
            "✨ *حافظ:* «سال‌ها دل طلب جام جم از ما می‌کرد / آنچه خود داشت ز بیگانه تمنّا می‌کرد»",
            "💫 *خیام:* «این قافله عمر عجب می‌گذرد / دریاب دمی که با طرب می‌گذرد»",
            "🌙 *مولانا:* «بشنو از نی چون حکایت می‌کند / وز جدایی‌ها شکایت می‌کند»",
            "🌟 *سعدی:* «درخت دوستی بنشان که کام دل به بار آرد / نهال دشمنی برکن که رنج بی‌شمار آرد»",
            "🕊️ *حافظ:* «در ازل پرتو حسنت ز تجلی دم زد / عشق پیدا شد و آتش به همه عالم زد»"
        ]
        reply = f"📜 **شعر ناب:**\n{random.choice(poems)}"
    
    # ========== لول ۱۶: ریاضیات ساده ==========
    elif any(op in msg_lower for op in ['حساب کن', 'محاسبه', 'چقدر میشه', '+', '*', 'ضرب', 'جمع', 'تفریق', 'تقسیم', 'توان']):
        # تشخیص عمل ریاضی
        try:
            numbers = [int(w) for w in words if w.lstrip('-').isdigit()]
            
            if 'جمع' in msg_lower or '+' in msg_lower:
                if len(numbers) >= 2:
                    result = sum(numbers)
                    reply = f"🧮 جمع: {' + '.join(map(str, numbers))} = **{result}**"
                else: reply = "دو تا عدد بگو تا جمع کنم! مثلاً: `جمع ۵ و ۳`"
            
            elif 'ضرب' in msg_lower or '*' in msg_lower:
                if len(numbers) >= 2:
                    result = numbers[0] * numbers[1]
                    reply = f"✖️ ضرب: {numbers[0]} × {numbers[1]} = **{result}**"
                else: reply = "دو تا عدد بگو تا ضرب کنم! مثلاً: `ضرب ۶ در ۴`"
            
            elif 'تفریق' in msg_lower or 'منها' in msg_lower:
                if len(numbers) >= 2:
                    result = numbers[0] - numbers[1]
                    reply = f"➖ تفریق: {numbers[0]} - {numbers[1]} = **{result}**"
                else: reply = "دو تا عدد بگو تا کم کنم! مثلاً: `تفریق ۱۰ از ۳`"
            
            elif 'تقسیم' in msg_lower or 'تقسیم' in msg_lower:
                if len(numbers) >= 2 and numbers[1] != 0:
                    result = numbers[0] / numbers[1]
                    reply = f"➗ تقسیم: {numbers[0]} ÷ {numbers[1]} = **{result}**"
                else: reply = "دو تا عدد بگو! (مخرج صفر نباشه!)"
            
            elif 'توان' in msg_lower:
                if len(numbers) >= 2:
                    result = numbers[0] ** numbers[1]
                    reply = f"📐 توان: {numbers[0]} به توان {numbers[1]} = **{result}**"
                else: reply = "دو تا عدد بگو! مثلاً: `توان ۲ به ۸`"
            
            else:
                reply = "بگو چیکار کنم! جمع، ضرب، تفریق، تقسیم یا توان؟ 🧮"
        except:
            reply = "متوجه نشدم! مثلاً بگو: `جمع ۵ و ۳` یا `ضرب ۶ در ۴` 🧮"
    
    # ========== لول ۱۸: امتیازدهی کاربران (Ranking) ==========
    elif 'رنکینگ' in msg_lower or 'امتیاز' in msg_lower or 'ranking' in msg_lower or 'رده بندی' in msg_lower:
        conn = db_conn()
        c = conn.cursor()
        c.execute("""
            SELECT u.username, 
                   COUNT(m.id) as msg_count,
                   COUNT(DISTINCT f.follower_id) as followers,
                   CASE WHEN u.is_admin THEN 100 ELSE 0 END as admin_bonus,
                   COUNT(m.id) * 2 + COUNT(DISTINCT f.follower_id) * 5 as score
            FROM users u 
            LEFT JOIN messages m ON u.id = m.user_id
            LEFT JOIN follows f ON u.id = f.following_id
            GROUP BY u.id
            ORDER BY score DESC LIMIT 10
        """)
        ranking = c.fetchall()
        conn.close()
        
        if ranking:
            medals = ['🥇','🥈','🥉','4️⃣','5️⃣','6️⃣','7️⃣','8️⃣','9️⃣','🔟']
            rank_list = '\n'.join([
                f"{medals[i]} **{r[0]}**: 💬{r[1]} پیام | 👥{r[2]} فالوئر | ⭐{r[4]} امتیاز"
                for i, r in enumerate(ranking)
            ])
            reply = f"🏆 **رنکینگ کاربران Xypher:**\n{rank_list}\n\n📊 فرمول: هر پیام ۲ امتیاز + هر فالوئر ۵ امتیاز + ادمین ۱۰۰ امتیاز"
        else:
            reply = "هنوز آماری نیست! 😅"

    # ========== پیش‌فرض هوشمند ==========
    else:
        # اگه شبیه اسم کاربران بود
        similar = get_closest_username(message)
        if similar:
            reply = f"منظورت کاربر **{similar}** بود؟ 🤔 بگو `مشخصات {similar}` تا اطلاعاتش رو بدم!"
        else:
            replies = [
                f"متوجه نشدم! 😅 بگو 'کمک' تا راهنما رو ببینی. من {ai_name} هستم!",
                "می‌تونی بگی 'پیدا کن [اسم]' تا کاربر رو پیدا کنم! 🔍",
                "سوال دیگه‌ای داری؟ بگو 'راهنما' 😊",
                "من میتونم کاربر پیدا کنم، آمار بدم، مقایسه کنم و... بگو چیکار کنم! 🤖"
            ]
            reply = random.choice(replies)
    
    return jsonify({'reply': reply})


# ==================== توابع کمکی AI ====================

def get_similar_usernames(search_term):
    """پیدا کردن اسم‌های شبیه"""
    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT username FROM users WHERE username LIKE ? LIMIT 3", (f'%{search_term[:3]}%',))
    users = c.fetchall()
    conn.close()
    if users:
        return 'شاید: ' + ', '.join([u[0] for u in users])
    return 'کسی پیدا نشد 🤷‍♂️'

def get_closest_username(text):
    """تشخیص اسم کاربر از متن ساده"""
    words = text.split()
    for word in words:
        if len(word) >= 3:
            user = get_user(username=word)
            if user:
                return user['username']
    return None

@app.route('/ai')
@login_required
def ai_chat():
    """صفحه چت با دستیار هوشمند"""
    return render_template('ai_chat.html')

    # ==================== AI PRO Chat (OpenRouter) ====================

# v1.6 امنیتی — کلید OpenRouter دیگر هاردکد نیست و از متغیر محیطی خوانده می‌شود
OPENROUTER_KEY = os.environ.get('OPENROUTER_API_KEY', '').strip()

@app.route('/api/ai_pro_chat', methods=['POST'])
@login_required
def ai_pro_chat_api():
    # موقتاً PRO رو چک نکن
    # if not is_pro_user(current_user.id) and not current_user.is_admin:
    #     return jsonify({'reply': '⛔ فقط کاربران PRO!'})
    
    if not OPENROUTER_KEY:
        return jsonify({'reply': '❌ AI PRO غیرفعال است — کلید OPENROUTER_API_KEY روی سرور تنظیم نشده'})

    data = request.get_json(silent=True) or {}
    message = (data.get('message') or '').strip()
    if not message:
        return jsonify({'reply': 'پیام خالی!'})
    
    try:
        res = requests.post(
            'https://openrouter.ai/api/v1/chat/completions',
            headers={
                'Authorization': f'Bearer {OPENROUTER_KEY}',
                'Content-Type': 'application/json'
            },
            json={
                'model': 'openai/gpt-4o-mini',
                'messages': [{'role': 'user', 'content': message}]
            },
            timeout=60
        )
        data = res.json()
        
        if 'choices' in data:
            reply = data['choices'][0]['message']['content']
        elif 'error' in data:
            reply = f"❌ {data['error'].get('message', 'خطا')}"
        else:
            reply = f"❌ {str(data)[:200]}"
            
    except Exception as e:
        reply = f'❌ خطا: {str(e)[:150]}'
    
    return jsonify({'reply': reply})

@app.route('/ai_pro')
@login_required
def ai_pro_chat_page():
    if not is_pro_user(current_user.id) and not current_user.is_admin:
        flash('⭐ این بخش فقط برای کاربران PRO است!')
        return redirect(url_for('ai_chat'))
    return render_template('ai_pro.html')
# ==================== WebSocket ====================

online_users = {}
user_rooms_map = {}
typing_by_room = {}  # room -> {user_id: username} — تایپینگ هر روم جدا نگه داشته میشه

# ---------- امنیت و مقیاس‌پذیری ----------
_state_lock = threading.RLock()
_pending_offline = {}   # user_id -> Timer (آفلاین طبیعی: با قطعی لحظه‌ای نت آنلاین نپره)
_send_times = defaultdict(lambda: deque(maxlen=40))  # ریت‌لیمیت سبک ارسال پیام
_session_last_touch = {}  # sid -> timestamp (به‌روزرسانی کم‌دفعات last_active نشست)

def _client_ip():
    try:
        xff = request.headers.get('X-Forwarded-For', '')
        if xff:
            return xff.split(',')[0].strip()
        return request.remote_addr or '?'
    except Exception:
        return '?'

def _client_device():
    """تشخیص خلاصه‌ی دستگاه/مرورگر از User-Agent برای پنل نشست‌های فعال"""
    try:
        ua = request.headers.get('User-Agent', '') or ''
    except Exception:
        ua = ''
    low = ua.lower()
    if not low:
        return 'ناشناس'
    browser = 'مرورگر ناشناس'
    if 'edg' in low: browser = 'Edge'
    elif 'opr' in low or 'opera' in low: browser = 'Opera'
    elif 'samsungbrowser' in low: browser = 'Samsung Internet'
    elif 'chrome' in low and 'chromium' not in low: browser = 'Chrome'
    elif 'firefox' in low: browser = 'Firefox'
    elif 'safari' in low: browser = 'Safari'
    elif 'curl' in low: browser = 'cURL'
    os_name = ''
    if 'android' in low: os_name = 'Android'
    elif 'iphone' in low or 'ipad' in low: os_name = 'iOS'
    elif 'windows' in low: os_name = 'Windows'
    elif 'mac os' in low or 'macintosh' in low: os_name = 'macOS'
    elif 'linux' in low: os_name = 'Linux'
    return (f'{browser} · {os_name}' if os_name else browser)

def _register_session():
    sid = request.sid
    try:
        conn = db_conn(); c = conn.cursor()
        c.execute("INSERT OR REPLACE INTO user_sessions (sid, user_id, ip, device, ua, created_at, last_active) VALUES (?, ?, ?, ?, ?, ?, ?)",
                  (sid, current_user.id, _client_ip(), _client_device(), (request.headers.get('User-Agent', '') or '')[:300], datetime.now(), datetime.now()))
        try:
            c.execute("UPDATE user_sessions SET token = ? WHERE sid = ?", (session.get('st'), sid))
        except Exception:
            pass
        conn.commit()
    except Exception:
        pass

_remove_session_sql_lock = threading.Lock()

def _remove_session(sid):
    with _remove_session_sql_lock:
        try:
            conn = db_conn(); c = conn.cursor()
            c.execute("DELETE FROM user_sessions WHERE sid = ?", (sid,))
            conn.commit()
        except Exception:
            pass

def _touch_session():
    """last_active نشست با حداکثر هر ۳۰ ثانیه آپدیت میشه (نه به ازای هر پیام)"""
    sid = request.sid
    now = _time.time()
    last = _session_last_touch.get(sid, 0)
    if now - last < 30:
        return
    _session_last_touch[sid] = now
    if len(_session_last_touch) > 5000:
        _session_last_touch.clear()
    try:
        conn = db_conn(); c = conn.cursor()
        c.execute("UPDATE user_sessions SET last_active = ? WHERE sid = ?", (datetime.now(), sid))
        conn.commit()
    except Exception:
        pass

def _users_public_info(ids):
    """اطلاعات عمومی کاربران با فقط یه کوئری (به جای N کوئری برای N کاربر) — لگ آنلاین‌لیست حذف میشه"""
    ids = list(ids)
    if not ids: return []
    conn = db_conn()
    c = conn.cursor()
    placeholders = ','.join('?' for _ in ids)
    try:
        c.execute(f"SELECT id, username, avatar FROM users WHERE id IN ({placeholders})", ids)
        rows = c.fetchall()
    except Exception:
        rows = []
    return [{'username': r[1], 'avatar': r[2]} for r in rows]

_online_bc_pending = False
_online_bc_lock = threading.Lock()

def _broadcast_online_list():
    """v1.6 — با هر اتصال/قطع، لیست آنلاین به همه فرستاده می‌شد (O(n²) زیر فشار). حالا
    رویدادهای پشت‌سرهم در یک بازه‌ی ۱ ثانیه‌ای به «یک» ارسال تجمیع می‌شوند."""
    global _online_bc_pending
    with _online_bc_lock:
        if _online_bc_pending:
            return
        _online_bc_pending = True
    def _do():
        global _online_bc_pending
        with _online_bc_lock:
            _online_bc_pending = False
        try:
            with _state_lock:
                ids = list(online_users.keys())
            socketio.emit('online_list', {'users': _users_public_info(ids)})
        except Exception:
            pass
    t = threading.Timer(1.0, _do)
    t.daemon = True
    t.start()

# ==================== v1.4.0 — SECURITY HARDENING ====================
# باگ بحرانی «قاطی شدن چت‌ها و پیوی‌ها» سه ریشه داشت:
#   ۱) join_pv هیچ چکی روی عضویت نداشت => هر کلاینت می‌توانست وارد روم pv_<chat_id>
#      هر چت دیگری شود و پیام‌های خصوصی دیگران را زنده دریافت کند.
#   ۲) send_message مسیر پیوی فقط «وجود چت» را چک می‌کرد، نه عضویت فرستنده =>
#      هر کاربری می‌توانست در چت خصوصی دیگران پیام تزریق کند.
#   ۳) pv_chats_updated (پیش‌نمایش متن پیام خصوصی) به room='general' یعنی به
#      «همه‌ی کاربران آنلاین» Broadcast می‌شد => نشت کامل حریم خصوصی.
# همه به‌همراه اعتبارسنجی کامل بقیه‌ی هندلرها در این نسخه بسته شدند.

_pv_membership_cache = {}   # chat_id -> (ts, sender_id, receiver_id)
_PV_CACHE_TTL = 20.0

def _pv_participants(chat_id):
    """(sender_id, receiver_id) چت خصوصی را با کش کوتاه برمی‌گرداند؛ چت نامعتبر => None"""
    try:
        chat_id = int(chat_id)
    except (TypeError, ValueError):
        return None
    now = _time.time()
    hit = _pv_membership_cache.get(chat_id)
    if hit and now - hit[0] < _PV_CACHE_TTL:
        return (hit[1], hit[2])
    try:
        conn = db_conn(); c = conn.cursor()
        c.execute("SELECT sender_id, receiver_id FROM private_chats WHERE id = ? AND is_active = 1", (chat_id,))
        row = c.fetchone()
    except Exception:
        row = None
    if not row:
        return None
    if len(_pv_membership_cache) > 20000:
        _pv_membership_cache.clear()
    _pv_membership_cache[chat_id] = (now, row[0], row[1])
    return (row[0], row[1])

def _is_pv_member(chat_id, user_id):
    part = _pv_participants(chat_id)
    return bool(part and user_id in part)

def _emit_pv_chats_updated(chat_id, sender_id, receiver_id, last_message, last_time,
                           last_file_type, last_ts, sender_username):
    """v1.4.0 — پیش‌نمایش چت خصوصی فقط به «دو طرفِ همان چت» می‌رسد (rooms شخصی).
    ناخوانده هم به‌ازای هر طرف درست محاسبه می‌شود؛ محتوا هرگز به general نمی‌رود.
    v1.5.0 — اسم نمایشی/آواتار فرستنده + is_self هم داخل payload است تا کلاینت
    بتواند «سطر کاملِ» چت جدید را بدون رفرش بسازد (باگ سطر «...» بی‌نام و بی‌عکس)."""
    sender_name, sender_avatar = sender_username, ''
    try:
        su = get_user(username=sender_username)
        if su:
            sender_name = (su.get('name') or '').strip() or sender_username
            sender_avatar = su.get('avatar') or ''
    except Exception:
        pass
    base = {
        'chat_id': chat_id,
        'last_message': (last_message or '')[:100],
        'last_time': fmt_hhmm(last_time),
        'last_file_type': last_file_type,
        'sender_username': sender_username,
        'sender_display_name': sender_name,
        'sender_avatar': sender_avatar,
        'is_self': bool(sender_id == receiver_id),
        'last_ts': last_ts,
    }
    try:
        conn = db_conn(); c = conn.cursor()
        c.execute("SELECT unread_s, unread_r FROM private_chats WHERE id = ?", (chat_id,))
        row = c.fetchone()
        unread_s, unread_r = (row[0] or 0, row[1] or 0) if row else (0, 0)
    except Exception:
        unread_s, unread_r = 0, 0
    for uid in {sender_id, receiver_id}:
        payload = dict(base)
        # v1.6 FIX — وارونه بود: ناخوانده‌ی فرستنده‌ی چت = unread_s، گیرنده = unread_r
        payload['unread_count'] = unread_s if uid == sender_id else unread_r
        payload['receiver_username'] = None
        try:
            socketio.emit('pv_chats_updated', payload, room=f"user_{uid}")
        except Exception:
            pass

@socketio.on('connect')
def handle_connect():
    if current_user.is_authenticated:
        with _state_lock:
            online_users[current_user.id] = request.sid
        user_rooms_map[request.sid] = 'general'
        join_room('general')
        # v1.4.0 — روم اختصاصی هر کاربر: ایونت‌های شخصی (پیش‌نمایش پیوی/ناخوانده/...)
        # فقط به همین روم ارسال می‌شوند؛ دیگر هیچ محتوای خصوصی‌ای به room='general'
        #Broadcast نمی‌شود (باگ امنیتی نشت پیام‌های پیوی به همه‌ی کاربران - فیکس شد)
        join_room(f"user_{current_user.id}")
        # اتصال جدید => تایمر آفلاین در انتظار لغو شود (آنلاین طبیعی، بدون پرش)
        t = _pending_offline.pop(current_user.id, None)
        if t:
            try: t.cancel()
            except Exception: pass
        _register_session()
        emit('user_online', {'username': current_user.username, 'avatar': current_user.avatar}, broadcast=True)
        _broadcast_online_list()

@socketio.on('disconnect')
def handle_disconnect():
    if not current_user.is_authenticated:
        return
    uid = current_user.id
    sid = request.sid
    user_rooms_map.pop(sid, None)
    typing_clean = False
    with _state_lock:
        # فقط اگه این ساکشن، ساکشن اصلی کاربره (لاگین دوم جایگزینش نشده)
        if online_users.get(uid) == sid:
            del online_users[uid]
            typing_clean = True
    if typing_clean:
        for room, users in list(typing_by_room.items()):
            users.pop(uid, None)
    _remove_session(sid)
    _session_last_touch.pop(sid, None)
    # آنلاین طبیعی: ۴ ثانیه فرصت ری‌کانکت — قطعی لحظه‌ی نت باعث پرش آنلاین/آفلاین نمیشه
    _uname = current_user.username
    def _go_offline(u=uid):
        with _state_lock:
            still = online_users.get(u)
        if still is None:
            try:
                conn = db_conn(); c = conn.cursor()
                c.execute("UPDATE users SET last_seen = ? WHERE id = ?", (datetime.now(), u))
                conn.commit()
            except Exception:
                pass
            socketio.emit('user_offline', {'username': _uname})
            _broadcast_online_list()
    t = threading.Timer(4.0, _go_offline)
    t.daemon = True
    with _state_lock:
        old = _pending_offline.get(uid)
        if old:
            try: old.cancel()
            except Exception: pass
        if online_users.get(uid) is None:
            _pending_offline[uid] = t
            t.start()

@socketio.on('join_general')
def handle_join_general(data=None):
    """کلاینت بعد از هر ری‌کانکت صریحاً توی روم عمومی عضو میشه"""
    if current_user.is_authenticated:
        join_room('general')
        user_rooms_map[request.sid] = 'general'

@socketio.on('leave_pv')
def handle_leave_pv(data):
    """وقتی پیوی داخل اپ بسته میشه، از رومش خارج شو (بهینه: پیام اضافه نمیاد)"""
    chat_id = (data or {}).get('chat_id')
    if chat_id:
        leave_room(f"pv_{chat_id}")

@socketio.on('send_message')
def handle_send_message(data):
    if not current_user.is_authenticated or current_user.is_banned: return
    _touch_session()

    message = str(data.get('message') or '')[:4000]  # v1.6 — سقف طول پیام سمت سرور
    room = data.get('room', 'general')
    file_url = data.get('file_url', None)
    file_type = data.get('file_type', 'text')
    private_chat_id = data.get('private_chat_id', None)
    client_msg_id = data.get('client_msg_id', None)
    reply_to = data.get('reply_to', None)

    # پیام‌های پیوی همیشه باید توی روم اختصاصی pv_<chat_id> ذخیره بشن، نه یه رشته‌ی
    # عمومی مثل 'pv' که هیچکس واقعا join نشده - وگرنه حذف/ویرایش پیام بعدا به هیچ‌کس نمی‌رسه
    if private_chat_id:
        room = f"pv_{private_chat_id}"

    forward_from = (data.get('forward_from') or '').strip()
    forward_from_username = (data.get('forward_from_username') or '').strip()

    # ---------- ریت‌لیمیت سراسری سبک (محافظت در برابر اسپم/فلوود، مستقل از اسلومود روم) ----------
    now_t = _time.time()
    dq = _send_times[current_user.id]
    while dq and now_t - dq[0] > 10:
        try: dq.popleft()
        except IndexError: break
    if len(dq) >= 25:
        emit('error', {'code': 'rate_limited', 'message': 'دارید پیام‌ها را خیلی سریع می‌فرستید، کمی صبر کنید'}, room=request.sid)
        return
    dq.append(now_t)

    # ---------- محدودیت کانال: فقط سازنده/ادمین‌های کانال حق ارسال پیام دارند ----------
    if room.startswith('private_'):
        room_id_part = room[len('private_'):]
        room_obj = get_room_by_id(room_id_part)
        if not room_obj:
            emit('error', {'message': 'روم پیدا نشد'}, room=request.sid)
            return
        # v1.4.0 امنیتی — غیرعضو حق ارسال پیام به گروه/کانال ندارد (قبلاً چک نمی‌شد!)
        if not is_room_member(current_user.id, room_obj['id']) and not current_user.is_admin:
            emit('error', {'code': 'not_member', 'message': 'عضو این گروه نیستید'}, room=request.sid)
            return
        if room_obj and room_obj.get('room_type') == 'channel' and not is_room_poster(room_obj['id'], current_user.id):
            emit('error', {'message': 'فقط ادمین‌های کانال می‌توانند پیام ارسال کنند'}, room=request.sid)
            return
        # ---------- قوانین گروه: قفل چت / دسترسی رسانه و گیف / ریت‌لیمیت ----------
        if room_obj and room_obj.get('room_type') == 'group':
            mgr = get_room_admin_perms(room_obj['id'], current_user.id)
            is_mgr = mgr['is_owner'] or mgr['is_admin']
            if not is_mgr:
                if room_obj.get('only_admins'):
                    emit('error', {'code': 'chat_locked', 'message': 'گروه توسط ادمین محدود شده — فقط ادمین‌ها می‌توانند پیام بدهند'}, room=request.sid)
                    return
                ft = (file_type or 'text')
                if ft in ('image', 'video', 'audio') and not room_obj.get('perm_send_media'):
                    emit('error', {'code': 'media_blocked', 'message': 'ارسال رسانه توسط ادمین بسته شده'}, room=request.sid)
                    return
                if ft == 'gif' and not room_obj.get('perm_send_gifs'):
                    emit('error', {'code': 'gif_blocked', 'message': 'ارسال گیف توسط ادمین بسته شده'}, room=request.sid)
                    return
                remaining = room_slow_mode_remaining(room_obj['id'], room, current_user.id)
                if remaining > 0:
                    emit('error', {'code': 'rate_limited', 'remaining': remaining,
                                   'message': f'ریت لیمیت — {remaining} ثانیه صبر کن'}, room=request.sid)
                    return

    # ---------- حریم خصوصی: «چه کسانی می‌توانند به من پیام بدهند» ----------
    other_id = None
    if private_chat_id:
        part = _pv_participants(private_chat_id)
        if not part:
            emit('error', {'message': 'چت پیدا نشد'}, room=request.sid)
            return
        sender_id_db, receiver_id_db = part
        # v1.4.0 امنیتی بحرانی — فرستنده باید یکی از دو طرفِ «همین چت» باشد.
        # قبلاً فقط وجود چت چک می‌شد و هر کاربری می‌توانست در چت خصوصی دیگران پیام تزریق کند!
        if current_user.id not in (sender_id_db, receiver_id_db):
            emit('error', {'code': 'pv_forbidden', 'message': 'دسترسی به این چت مجاز نیست'}, room=request.sid)
            return
        other_id = receiver_id_db if sender_id_db == current_user.id else sender_id_db
        try:
            conn = db_conn(); c = conn.cursor()
            prow = (sender_id_db, receiver_id_db)
        except Exception:
            prow = None
        if other_id != current_user.id:
            # v1.6 امنیتی — بلاک دوطرفه: به کاربرِ بلاک‌شده یا بلاک‌کننده پیام ارسال نمی‌شود
            # (کدها با کلاینت RAVI هماهنگ: blocked / blocked_by_user)
            if is_user_blocked(current_user.id, other_id):
                emit('error', {'code': 'blocked', 'message': 'کاربر را بلاک کرده‌اید؛ ابتدا آنبلاک کنید'}, room=request.sid)
                return
            if is_user_blocked(other_id, current_user.id):
                emit('error', {'code': 'blocked_by_user', 'message': 'شما توسط این کاربر بلاک شده‌اید'}, room=request.sid)
                return
            other_u = get_user(user_id=other_id)
            if other_u and other_u.get('privacy_dm') == 'nobody':
                # اجازه فقط وقتی هست که طرف مقابل قبلا با شما گفتگو کرده باشه
                # (یعنی خودش برای شما پیام فرستاده باشه) یا قبلا بین شما گفتگویی باشه
                had_chat = False
                try:
                    c.execute("SELECT 1 FROM messages WHERE private_chat_id = ? AND user_id = ? AND is_deleted = 0 LIMIT 1",
                              (private_chat_id, other_id))
                    had_chat = c.fetchone() is not None
                except Exception:
                    pass
                if not had_chat:
                    emit('error', {'code': 'dm_closed', 'username': other_u['username'],
                                   'message': 'پیام‌های این کاربر بسته است'}, room=request.sid)
                    return

    enr = user_enrichment(current_user.id)
    tags = enr['tags']; particle = enr['particle']; is_pro = enr['is_pro']
    is_official = bool(current_user.is_admin)

    # v1.2.1 — client-supplied media metadata (image dims / music tags)
    media_meta_in = data.get('media_meta') or None

    # v1.2.1 — client-supplied media metadata (image dims / music tags)

    # اسنپ‌شات ریپلای (بر اساس شناسه — دقیق مثل تلگرام، بدون قاطی شدن متن‌های تکراری)
    reply_snap = get_reply_snapshot(reply_to) if reply_to else None

    # v1.6 — ددپ دوبل‌ارسال: اگر همین client_msg_id قبلاً ذخیره شده (ریترای کلاینت
    # بعد از قطعی شبکه)، همان پیام را فقط به خودِ فرستنده ack می‌کنیم تا
    # تیکِ «در حال ارسال» بسته شود و حباب تکراری برای طرف مقابل ساخته نشود.
    if client_msg_id:
        try:
            _conn_d = db_conn(); _c_d = _conn_d.cursor()
            _c_d.execute("SELECT id, content, file_url, file_type, timestamp, media_meta, forward_from, forward_from_username "
                         "FROM messages WHERE user_id = ? AND client_msg_id = ?",
                         (current_user.id, client_msg_id))
            _dup = _c_d.fetchone(); _conn_d.close()
        except Exception:
            _dup = None
        if _dup:
            try:
                _dup_ts = fmt_hhmm(_dup[4]) or datetime.now().strftime('%H:%M')
            except Exception:
                _dup_ts = datetime.now().strftime('%H:%M')
            _ack = {
                'username': current_user.username, 'message': _dup[1],
                'timestamp': _dup_ts, 'avatar': current_user.avatar,
                'file_url': _dup[2], 'file_type': _dup[3], 'tags': tags, 'particle': particle,
                'is_pro': is_pro, 'is_official': is_official,
                'message_id': _dup[0], 'client_msg_id': client_msg_id,
                'private_chat_id': private_chat_id, 'room': room, 'seen_count': 0,
                'forward_from': _dup[6] or '', 'forward_from_username': _dup[7] or '',
                'display_name': (current_user.name or '').strip(),
                'media_meta': norm_media_meta_out(_dup[5], _dup[2] or '', _dup[3] or '')
            }
            if private_chat_id:
                emit('new_pv_message', _ack, room=request.sid)
            else:
                emit('new_message', _ack, room=request.sid)
            return

    msg_id = save_message(current_user.id, current_user.username, message, room, file_url, file_type, private_chat_id, client_msg_id, forward_from=forward_from, forward_from_username=forward_from_username, reply_to=reply_to, media_meta=media_meta_in)
    if reply_snap:
        reply_snap['reply_to'] = msg_id  # این پیامِ جدید به پیامِ مقصد ریپلای شده
    
    # ویوی خودِ فرستنده هم حساب میشه — توی کانال‌ها ویوی پست ادمین از ۱ شروع میشه (واقعی‌تر)
    seen_count = 0
    if room.startswith('private_'):
        room_id_part = room[len('private_'):]
        room_obj = get_room_by_id(room_id_part)
        if room_obj and room_obj.get('room_type') == 'channel':
            mark_message_read(msg_id, current_user.id)
            seen_count = 1
    
    # تگ ادمینِ فرستنده در همین گروه (برای نمایش ته حباب)
    sender_admin_title = ''
    sender_is_admin = False
    if room.startswith('private_'):
        try:
            _robj = get_room_by_id(room[len('private_'):])
            if _robj:
                conn_a = db_conn(); c_a = conn_a.cursor()
                c_a.execute("SELECT title FROM room_admins WHERE room_id = ? AND user_id = ?", (_robj['id'], current_user.id))
                _row = c_a.fetchone()
                if _row is not None:
                    sender_is_admin = True
                    sender_admin_title = _row[0] or ''
        except Exception:
            pass

    sender_is_owner = False
    if room.startswith('private_'):
        try:
            _oobj = get_room_by_id(room[len('private_'):])
            if _oobj:
                sender_is_owner = bool(current_user.id == _oobj['owner_id'])
        except Exception:
            pass

    emit_data = {
        'username': current_user.username, 'message': message,
        'timestamp': datetime.now().strftime('%H:%M'), 'avatar': current_user.avatar,
        'file_url': file_url, 'file_type': file_type, 'tags': tags, 'particle': particle,
        'is_pro': is_pro, 'is_official': is_official, 'message_id': msg_id, 'client_msg_id': client_msg_id,
        'private_chat_id': private_chat_id, 'room': room, 'seen_count': seen_count,
        'admin_title': sender_admin_title, 'sender_is_admin': sender_is_admin, 'sender_is_owner': sender_is_owner,
        'forward_from': forward_from, 'forward_from_username': forward_from_username,
        'display_name': (current_user.name or '').strip(),
        'media_meta': norm_media_meta_out(media_meta_in, file_url or '', file_type or '')
    }
    if reply_snap:
        emit_data.update(reply_snap)
    
    if private_chat_id:
        now = datetime.now()
        conn = db_conn(); c = conn.cursor()
        # ناخوانده فقط سمت گیرنده‌ی پیام (طرف مقابل) زیاد میشه — پیام خودت بج «پیام جدید» بهت نمیده (باگ قبلی)
        # unread_s = ستونِ فرستنده‌ی چت، unread_r = ستونِ گیرنده‌ی چت
        # v1.3.0 — نوع/فرستنده‌ی آخرین پیام هم ذخیره میشه تا پیش‌نمایش لیست چت‌ها خالی نمونه
        # v1.3.2 — موزیک => last_file_type='music' + اسم تمیز آهنگ؛ ویس => 'voice'
        pv_ft, pv_msg = pv_preview_fields(message, file_type, file_url or '', media_meta_in)
        c.execute('''UPDATE private_chats SET last_message = ?, last_time = ?, updated_at = ?,
                     last_file_type = ?, last_user = ?,
                     unread_s = CASE WHEN sender_id != ? THEN unread_s + 1 ELSE 0 END,
                     unread_r = CASE WHEN sender_id = ? THEN unread_r + 1 ELSE 0 END
                     WHERE id = ?''',
                  ((pv_msg or '[media]')[:100], now, now, pv_ft, current_user.username,
                   current_user.id, current_user.id, private_chat_id))
        # v1.4.0 — سیو مسیج (چت با خودمان): ناخوانده همیشه صفر بماند
        if prow[0] == prow[1]:
            c.execute("UPDATE private_chats SET unread_s = 0, unread_r = 0 WHERE id = ?", (private_chat_id,))
        # ناخوانده‌ی طرف مقابل برای ایونت لیست پیوی‌ها (من فرستنده‌ام => ناخوانده‌ی گیرنده)
        unread_val = 0
        try:
            c.execute("SELECT CASE WHEN sender_id = ? THEN unread_r ELSE unread_s END FROM private_chats WHERE id = ?",
                      (current_user.id, private_chat_id))
            ur = c.fetchone()
            unread_val = (ur[0] if ur else 0) or 0
        except Exception:
            pass
        conn.commit()

        # v1.4.0 امنیتی — پیش‌نمایش پیوی فقط برای دو طرف خود چت (دیگر به general Broadcast نمی‌شود)
        _emit_pv_chats_updated(private_chat_id, prow[0], prow[1],
                               (pv_msg or '[media]'), now.strftime('%H:%M'),
                               pv_ft, now.strftime('%Y-%m-%dT%H:%M:%S'), current_user.username)

        emit('new_pv_message', emit_data, room=f"pv_{private_chat_id}", include_self=True)
    else:
        emit('new_message', emit_data, room=room)
        # بج ناخوانده‌ی واقعی لیست چت‌ها — فقط برای پیام‌های عادی گروه (نه سرویس)
        if room.startswith('private_') and not str(file_type or '').startswith('sys_'):
            # v1.5.0 — بج + پیش‌نمایش «فقط برای اعضای همان گروه» به روم شخصی
            # هر عضو می‌رود؛ قبلاً به room='general' (همه‌ی کاربران آنلاین)
            # Broadcast می‌شد که هم نشت اطلاعات بود هم بج بی‌مورد می‌ساخت.
            try:
                _rid = room[len('private_'):]
                _robj = get_room_by_id(_rid)
                if _robj:
                    _conn2 = db_conn(); _c2 = _conn2.cursor()
                    _c2.execute("SELECT user_id FROM room_members WHERE room_id = ?", (_robj['id'],))
                    _mids = [r[0] for r in _c2.fetchall()]
                    _conn2.close()
                    _prev = (message or media_preview_label(file_type or 'text', file_url or '', media_meta_in) or 'پیام')[:100]
                    for _mid in set(_mids):
                        if _mid == current_user.id:
                            continue  # فرستنده بج نمی‌گیرد
                        socketio.emit('room_chats_updated', {
                            'room_id': _robj['room_id'],
                            'room_name': _robj.get('name') or '',
                            'room_avatar': _robj.get('avatar') or '',
                            'room_type': _robj.get('room_type') or 'group',
                            'last_message': _prev,
                            'last_time': datetime.now().strftime('%H:%M'),
                            'last_file_type': file_type or 'text',
                            'sender_username': current_user.username,
                            'unread': 1,
                        }, room=f"user_{_mid}")
            except Exception:
                pass
            socketio.emit('group_unread', {'room_id': room[len('private_'):], 'from': current_user.username}, room='general')
        # v1.1.1 — ROOT-FIX ناخوانده: هر عضو آنلاینی که الان داخل چت بازه،
        # همین‌جا read-stateش جلو میره => بعد از رفرش هم بج «پیام جدید» برنمی‌گرده.
        if room.startswith('private_'):
            try:
                _rid2 = room[len('private_'):]
                _robj2 = get_room_by_id(_rid2)
                if _robj2:
                    advance_room_reads_for_viewers(room, _robj2['id'], msg_id, current_user.id)
            except Exception:
                pass

@socketio.on('delete_message')
def handle_delete_message(data):
    """حذف پیام از طریق سوکت - پیوی از همینجا حذف می‌کنه (کانتکست‌منوی pv.html)"""
    if not current_user.is_authenticated:
        return
    try:
        message_id = int(data.get('message_id'))
    except (TypeError, ValueError):
        return

    success, result = delete_message_db(message_id, current_user.id, current_user.is_admin)
    if not success and current_user.is_authenticated:
        # ادمین روم با پرمیشن delete_messages هم می‌تونه حذف کنه
        try:
            conn_d = db_conn(); c_d = conn_d.cursor()
            c_d.execute("SELECT room, user_id, is_deleted FROM messages WHERE id = ?", (message_id,))
            m = c_d.fetchone(); conn_d.close()
            if m and not m[2] and m[0] and str(m[0]).startswith('private_'):
                r_obj = get_room_by_id(str(m[0])[len('private_'):])
                if r_obj:
                    mgr = get_room_admin_perms(r_obj['id'], current_user.id)
                    if (mgr['is_owner'] or mgr['is_admin']) and 'delete_messages' in mgr['perms'] and m[1] != current_user.id:
                        success, result = delete_message_db(message_id, m[1], False, force=True)
        except Exception:
            pass
    if success:
        room = result
        socketio.emit('message_deleted', {
            'message_id': message_id,
            'msg_id': message_id,
            'username': current_user.username,
            'room': room
        }, room=room)
    else:
        emit('error', {'message': result}, room=request.sid)

@socketio.on('toggle_reaction')
def handle_toggle_reaction(data):
    """اضافه/حذف/تعویض ریکشن روی یه پیام - فعلاً برای پیوی"""
    if not current_user.is_authenticated:
        return
    try:
        message_id = int(data.get('message_id'))
    except (TypeError, ValueError):
        return
    emoji = (data.get('emoji') or '').strip()
    if emoji not in ALLOWED_REACTIONS:
        return
    chat_id = data.get('chat_id')

    msg = get_message_by_id(message_id)
    if not msg or msg['is_deleted']:
        return

    # v1.4.0 امنیتی — فقط عضو همان چت/روم حق ریکشن دادن دارد
    if msg.get('private_chat_id'):
        if not _is_pv_member(msg['private_chat_id'], current_user.id):
            return
    else:
        _room = msg.get('room') or 'general'
        if _room.startswith('private_'):
            robj = get_room_by_id(_room[len('private_'):])
            if not robj or (not is_room_member(current_user.id, robj['id']) and not current_user.is_admin):
                return

    reactions = toggle_reaction_db(message_id, current_user.id, emoji)
    room = f"pv_{chat_id}" if chat_id else (msg['room'] or 'general')
    socketio.emit('reaction_update', {
        'message_id': message_id,
        'reactions': reactions,
        'by': current_user.username
    }, room=room)

@socketio.on('join_pv')
def handle_join_pv(data):
    if not current_user.is_authenticated: return
    chat_id = data.get('chat_id')
    if chat_id:
        # v1.4.0 امنیتی — فقط دو طرفِ خودِ چت حق عضویت در روم pv_<chat_id> را دارند؛
        # قبلاً هر کاربری با هر chat_id می‌توانست پیام‌های خصوصی دیگران را شنود کند
        if not _is_pv_member(chat_id, current_user.id):
            emit('error', {'code': 'pv_forbidden', 'message': 'دسترسی به این چت مجاز نیست'}, room=request.sid)
            return
        join_room(f"pv_{chat_id}")

@socketio.on('join_private_room')
def handle_join_private_room(data):
    if not current_user.is_authenticated: return
    room_id = (data or {}).get('room_id')
    if not room_id: return
    room = get_room_by_id(room_id)
    if not room: 
        return
    
    # چک کن کاربر بن نشده باشه
    if is_banned_from_room(room['id'], current_user.id):
        emit('kicked_from_room', {
            'message': 'شما از این گروه اخراج شده‌اید',
            'room_id': room_id
        }, room=request.sid)
        return
    
    if not is_room_member(current_user.id, room['id']) and not current_user.is_admin:
        # اگه بن شده بود و می‌خواد دوباره join بشه
        if is_banned_from_room(room['id'], current_user.id):
            emit('error', {'message': 'شما از این گروه اخراج شده‌اید'}, room=request.sid)
        return
    
    if request.sid in user_rooms_map:
        leave_room(user_rooms_map[request.sid])
    
    room_name = f"private_{room_id}"
    join_room(room_name)
    user_rooms_map[request.sid] = room_name
    
    conn = db_conn()
    c = conn.cursor()
    c.execute('''SELECT m.id, m.content, u.id as uid, u.username, m.timestamp, u.avatar, m.file_url, m.file_type, m.is_edited,
                 m.forward_from, m.forward_from_username, m.reply_to, u.name, u.is_admin
                 FROM messages m JOIN users u ON m.user_id = u.id 
                 WHERE m.room = ? AND m.is_deleted = 0 ORDER BY m.timestamp DESC LIMIT 50''', (room_name,))
    history = c.fetchall()
    # انریچمنت جمعی: تگ‌ها/ذره‌ها/Pro همه‌ی کاربران با چند کوئری (به جای ~۲۰۰ کوئری به ازای هر join)
    uids = list({h[2] for h in history})
    tag_map = batch_user_tags(uids)
    pro_ids = set()
    particle_map = {}
    if uids:
        try:
            ph = ','.join('?' for _ in uids)
            c.execute(f"SELECT user_id FROM pro_accounts WHERE user_id IN ({ph}) AND is_active = 1", uids)
            pro_ids = {t[0] for t in c.fetchall()}
        except Exception:
            pro_ids = set()
        try:
            c.execute(f"SELECT user_id, particle_color, particle_count, particle_size, orbit_speed, orbit_radius, glow_intensity FROM avatar_particles WHERE user_id IN ({ph})", uids)
            for t in c.fetchall():
                particle_map[t[0]] = {'particle_color': t[1], 'particle_count': t[2],
                                      'particle_size': t[3], 'orbit_speed': t[4],
                                      'orbit_radius': t[5], 'glow_intensity': t[6]}
        except Exception:
            particle_map = {}
    
    for msg in history[::-1]:
        uid = msg[2]
        tags = tag_map.get(uid, [])
        particle = particle_map.get(uid) or {}
        is_pro = uid in pro_ids
        # timestamp خام دیتابیس (با میکروثانیه و تاریخ کامل) رو مثل پیام‌های زنده به فرمت HH:MM تبدیل می‌کنیم
        raw_ts = msg[4]
        if raw_ts:
            ts_str = str(raw_ts)
            time_part = ts_str.split(' ')[1] if ' ' in ts_str else ts_str
            formatted_ts = time_part[:5]
        else:
            formatted_ts = ''
        payload = {
            'message_id': msg[0], 'username': msg[3], 'message': msg[1], 'timestamp': formatted_ts, 'avatar': msg[5],
            'file_url': msg[6], 'file_type': msg[7], 'tags': tags, 'particle': particle, 'is_pro': is_pro,
            'is_edited': bool(msg[8]), 'room': room_name,
            'forward_from': msg[9] or '', 'forward_from_username': msg[10] or '',
            'display_name': (msg[12] or '').strip(), 'is_official': bool(msg[13])
        }
        if msg[11]:
            snap = get_reply_snapshot(msg[11])
            if snap: payload.update(snap)
        emit('new_message', payload, room=request.sid)
    
    emit('room_members', get_room_members(room['id']), room=request.sid)

@socketio.on('leave_private_room')
def handle_leave_private_room():
    if request.sid in user_rooms_map:
        leave_room(user_rooms_map[request.sid])
        user_rooms_map[request.sid] = 'general'
        join_room('general')

@socketio.on('typing')
def handle_typing(data):
    if not current_user.is_authenticated: return
    is_typing = data.get('is_typing', False)
    room = data.get('room', 'general')
    # کلاینت خودش اسم روم دقیق رو میفرسته: general یا pv_<chat_id> یا private_<room_id>
    if room != 'general' and not str(room).startswith('pv_') and not str(room).startswith('private_'):
        room = 'general'
    # v1.4.0 امنیتی — تایپینگ فقط در چت/رومی که عضوش هستی
    if room.startswith('pv_'):
        if not _is_pv_member(room[3:], current_user.id):
            return
    elif room.startswith('private_'):
        robj = get_room_by_id(room[len('private_'):])
        if not robj or (not is_room_member(current_user.id, robj['id']) and not current_user.is_admin):
            return
    users = typing_by_room.setdefault(room, {})
    if is_typing: users[current_user.id] = current_user.username
    else: users.pop(current_user.id, None)
    # فقط به همان روم؛ لیست بدون خود کاربر هم فیلتر میشه سمت کلاینت
    emit('user_typing', {'room': room, 'users': list(users.values())}, room=room)

@socketio.on('join_group_room')
def handle_join_group_room(data):
    """عضویت سبک در روم گروه برای پیام‌های زنده — بدون خروج از general و بدون ارسال تاریخچه"""
    if not current_user.is_authenticated: return
    room_id = (data or {}).get('room_id')
    room = get_room_by_id(room_id) if room_id else None
    if not room: return
    if is_banned_from_room(room['id'], current_user.id):
        emit('kicked_from_room', {'message': 'شما از این گروه اخراج شده‌اید', 'room_id': room_id}, room=request.sid)
        return
    # v1.4.0 امنیتی — غیرعضوها پیام زنده‌ی گروه/کانال را شنود نمی‌کنند
    if not is_room_member(current_user.id, room['id']) and not current_user.is_admin:
        return
    join_room(f"private_{room_id}")

@socketio.on('leave_group_room')
def handle_leave_group_room(data):
    """وقتی پنل گروه داخل اپ بسته میشه، از روم زنده‌اش خارج شو"""
    room_id = (data or {}).get('room_id')
    if room_id:
        leave_room(f"private_{room_id}")

@socketio.on('mark_as_read')
def handle_mark_read(data):
    if not current_user.is_authenticated:
        return
    message_id = data.get('message_id')
    room = data.get('room', 'general')

    # v1.4.0 امنیتی — فقط در چت/رومی که عضوش هستی می‌تونی «خواندن» ثبت کنی
    msg = get_message_by_id(message_id) if message_id else None
    if not msg:
        return
    if msg.get('private_chat_id'):
        if not _is_pv_member(msg['private_chat_id'], current_user.id):
            return
        room = f"pv_{msg['private_chat_id']}"
    else:
        _room = msg.get('room') or 'general'
        if _room.startswith('private_'):
            robj = get_room_by_id(_room[len('private_'):])
            if not robj or (not is_room_member(current_user.id, robj['id']) and not current_user.is_admin):
                return
        room = _room

    if message_id:
        mark_message_read(message_id, current_user.id)

        # به همه توی همون room بگو (فرستنده هم می‌شنوه)
        emit('message_read_update', {
            'message_id': message_id,
            'user_id': current_user.id,
            'room': room
        }, room=room)

@socketio.on('mark_all_pv_read')
def handle_mark_all_pv_read(data):
    if not current_user.is_authenticated:
        return
    chat_id = data.get('chat_id')
    # v1.4.0 امنیتی — فقط طرفِ خودِ چت اجازه ثبت خواندن دارد
    if chat_id and not _is_pv_member(chat_id, current_user.id):
        return
    if chat_id:
        conn = db_conn()
        c = conn.cursor()
        # شمارنده‌ی ناخوانده‌ی «سمتِ خود کاربر» صفر بشه (بج طرف مقابل دست‌نخورده)
        c.execute('''UPDATE private_chats SET
                     unread_s = CASE WHEN sender_id = ? THEN 0 ELSE unread_s END,
                     unread_r = CASE WHEN receiver_id = ? THEN 0 ELSE unread_r END
                     WHERE id = ?''', (current_user.id, current_user.id, chat_id))
        conn.commit()
        # ثبت رسید خواندن فقط برای پیام‌های طرف مقابل (بچ — نه حلقه‌ی کوئری به ازای هر پیام)
        try:
            c.execute("SELECT m.id FROM messages m WHERE m.private_chat_id = ? AND m.user_id != ? AND NOT EXISTS (SELECT 1 FROM message_reads mr WHERE mr.message_id = m.id AND mr.user_id = ?)",
                      (chat_id, current_user.id, current_user.id))
            unread_msgs = [r[0] for r in c.fetchall()]
            if unread_msgs:
                c.executemany("INSERT OR IGNORE INTO message_reads (message_id, user_id, read_at) VALUES (?, ?, ?)",
                              [(m, current_user.id, datetime.now()) for m in unread_msgs])
                conn.commit()
        except Exception:
            pass
        
        socketio.emit('all_pv_read', {
            'chat_id': chat_id,
            'reader': current_user.username
        }, room=f"pv_{chat_id}")

        # بج ناخوانده‌ی لیست چت — فقط روی کلاینت‌های دو طرف خود چت (بدون نشت عمومی)
        part = _pv_participants(chat_id)
        if part:
            for uid in set(part):
                socketio.emit('pv_chats_updated', {
                    'chat_id': chat_id,
                    'unread_count': 0
                }, room=f"user_{uid}")

@socketio.on('mark_single_read')
def handle_mark_single_read(data):
    if not current_user.is_authenticated:
        return
    message_id = data.get('message_id')
    chat_id = data.get('chat_id')
    # v1.4.0 امنیتی — عضویت چک شود
    if message_id and chat_id and _is_pv_member(chat_id, current_user.id):
        mark_message_read(message_id, current_user.id)
        socketio.emit('message_read_update', {
            'message_id': message_id
        }, room=f"pv_{chat_id}")

@socketio.on('group_read')
def handle_group_read(data):
    """باز کردن/بودن توی چت گروه = همه‌ی پیام‌ها خونده شدن — بج واقعی صفر میشه"""
    if not current_user.is_authenticated:
        return
    room_id = data.get('room_id')
    if not room_id: return
    room = get_room_by_id(str(room_id))
    if not room: return
    # v1.4.0 امنیتی — فقط عضو واقعی
    if not is_room_member(current_user.id, room['id']) and not current_user.is_admin:
        return
    conn = db_conn(); c = conn.cursor()
    c.execute("SELECT MAX(id) FROM messages WHERE room = ?", (f"private_{room['room_id']}",))
    mx = c.fetchone()[0] or 0
    conn.close()
    if mx:
        update_room_read(current_user.id, room['id'], mx)
        socketio.emit('group_unread_reset', {'room_id': room['room_id'], 'reader': current_user.id}, room='general')

# ==================== v1.6 — نگهداری دوره‌ای منابع ====================
def _maintenance_once():
    now = _time.time()
    for k in list(_login_attempts.keys()):
        dq = _login_attempts.get(k)
        if not dq or now - dq[-1] > 3600: _login_attempts.pop(k, None)
    for k in list(_send_times.keys()):
        dq = _send_times.get(k)
        if not dq or now - dq[-1] > 60: _send_times.pop(k, None)
    for r in list(typing_by_room.keys()):
        if not typing_by_room.get(r): typing_by_room.pop(r, None)
    for k, v in list(_token_cache.items()):
        if now - v[0] > _TOKEN_TTL * 4: _token_cache.pop(k, None)
    for k, v in list(_pv_membership_cache.items()):
        if now - v[0] > _PV_CACHE_TTL * 4: _pv_membership_cache.pop(k, None)
    for k, v in list(_user_enrich_cache.items()):
        if now - v[0] > 300: _user_enrich_cache.pop(k, None)
    for k, v in list(_reply_cache.items()):
        if now - v[0] > 600: _reply_cache.pop(k, None)
    if len(_session_last_touch) > 2000: _session_last_touch.clear()
    try:
        conn = db_conn(); c = conn.cursor()
        # توکن‌های بی‌استفاده‌تر از عمر کوکی (۴۵ روز + ۱ روز) و ردیف‌های سوکتِ مانده
        c.execute("DELETE FROM login_tokens WHERE last_active < ?", (datetime.now() - timedelta(days=46),))
        c.execute("DELETE FROM user_sessions WHERE last_active < ?", (datetime.now() - timedelta(days=2),))
        conn.commit()
        c.execute("PRAGMA wal_checkpoint(PASSIVE)")
    except Exception:
        pass

def _maintenance_loop():
    n = 0
    while True:
        _time.sleep(600)
        try:
            _maintenance_once()
            n += 1
            if n % 36 == 0:   # تقریباً هر ۶ ساعت
                conn = db_conn(); conn.execute("PRAGMA optimize")
        except Exception:
            pass

_maint_thread = threading.Thread(target=_maintenance_loop, daemon=True)
_maint_thread.start()

if __name__ == '__main__':
    socketio.run(app, debug=False, host='0.0.0.0', port=int(os.environ.get('PORT', 5000)), allow_unsafe_werkzeug=True, log_output=False)