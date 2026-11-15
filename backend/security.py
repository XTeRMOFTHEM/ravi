"""Centralized security helpers for the RAVI backend.

Covers upload URL validation, path-traversal-proof file deletion,
client file_type sanitization, open-redirect prevention, and strict
extension filtering.
"""

from __future__ import annotations

import os
import re
from urllib.parse import urlparse

ALLOWED_CLIENT_FILE_TYPES = frozenset({'text', 'image', 'video', 'audio', 'gif', 'file'})

BANNED_UPLOAD_EXTS = frozenset({
    'html', 'htm', 'svg', 'svgz', 'xhtml', 'shtml', 'xht',
    'xml', 'xsl', 'xslt', 'mht', 'mhtml', 'js', 'mjs', 'cjs',
    'swf', 'php', 'phtml', 'jsp', 'asp', 'aspx', 'cgi',
})

_SAFE_UPLOAD_BASENAME_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,180}$')
_UPLOAD_URL_PREFIXES = ('/static/uploads/', '/files/')


def sanitize_upload_ext(filename: str) -> str:
    """Extract a clean lowercase file extension, stripping trailing spaces/dots."""
    if not filename:
        return ''
    cleaned = filename.strip().rstrip('. ')
    if '.' not in cleaned:
        return ''
    ext = cleaned.rsplit('.', 1)[-1].strip().lower()
    # Keep only ASCII alphanumeric chars in extension
    ext = re.sub(r'[^a-z0-9]', '', ext)
    return ext[:16]


def is_safe_upload_url(url: str | None) -> bool:
    """Return True iff `url` points strictly to a local uploaded filename.

    Blocks external URLs (cookie-theft / SSRF), protocol-relative URLs,
    path traversal (`..`), backslashes, null bytes, and nested directories.
    """
    if not url or not isinstance(url, str):
        return False
    u = url.strip()
    if any(ch in u for ch in ('\\', '\x00', '\r', '\n', '?', '#')):
        return False
    matched_prefix = None
    for prefix in _UPLOAD_URL_PREFIXES:
        if u.startswith(prefix):
            matched_prefix = prefix
            break
    if not matched_prefix:
        return False
    basename = u[len(matched_prefix):]
    if not basename or '/' in basename or '..' in basename:
        return False
    return bool(_SAFE_UPLOAD_BASENAME_RE.match(basename))


def sanitize_client_file_url(url: str | None) -> str | None:
    """Accept only validated local upload URLs; return None otherwise."""
    if not url:
        return None
    u = str(url).strip()
    return u if is_safe_upload_url(u) else None


def sanitize_client_file_type(file_type: str | None, has_file_url: bool) -> str:
    """Block clients from spoofing server-only types like `sys_join_link`."""
    ft = (str(file_type) if file_type is not None else 'text').strip().lower()
    if ft not in ALLOWED_CLIENT_FILE_TYPES:
        return 'file' if has_file_url else 'text'
    if not has_file_url and ft != 'text':
        return 'text'
    return ft


def resolve_upload_path(upload_folder: str, file_url_or_name: str) -> str | None:
    """Resolve a local upload URL or filename to a verified path inside upload_folder."""
    if not file_url_or_name or not isinstance(file_url_or_name, str):
        return None
    raw = file_url_or_name.strip()
    if raw.startswith('/static/uploads/'):
        if not is_safe_upload_url(raw):
            return None
        name = raw[len('/static/uploads/'):]
    elif raw.startswith('/files/'):
        if not is_safe_upload_url(raw):
            return None
        name = raw[len('/files/'):]
    else:
        if '/' in raw or '\\' in raw or '..' in raw or not _SAFE_UPLOAD_BASENAME_RE.match(raw):
            return None
        name = raw
    root = os.path.realpath(upload_folder)
    candidate = os.path.realpath(os.path.join(root, name))
    if not candidate.startswith(root + os.sep):
        return None
    return candidate


def safe_remove_upload_file(upload_folder: str, file_url_or_name: str) -> bool:
    """Delete an uploaded file only if its canonical path sits inside upload_folder."""
    target = resolve_upload_path(upload_folder, file_url_or_name)
    if not target:
        return False
    if os.path.isfile(target):
        try:
            os.remove(target)
            return True
        except OSError:
            return False
    return False


def safe_redirect_target(referrer: str | None, host: str | None, fallback: str = '/') -> str:
    """Ensure redirect targets stay strictly on the same origin (no open redirects)."""
    if not referrer:
        return fallback
    try:
        parsed = urlparse(referrer)
    except Exception:
        return fallback
    if not parsed.scheme and not parsed.netloc:
        if referrer.startswith('/') and not referrer.startswith('//'):
            return referrer
        return fallback
    if parsed.scheme in ('http', 'https') and host and parsed.netloc.lower() == host.lower():
        path = parsed.path or '/'
        if parsed.query:
            path += '?' + parsed.query
        return path
    return fallback
