<div align="center">

# RAVI Backend

**The official RAVI-compatible server — fast to run, easy to deploy.**

[![Python](https://img.shields.io/badge/Python-3.10+-3776AB?style=flat-square&logo=python&logoColor=white)](https://www.python.org)
[![Flask](https://img.shields.io/badge/Flask-3.x-white?style=flat-square&logo=flask&logoColor=black)](https://flask.palletsprojects.com)
[![Socket.IO](https://img.shields.io/badge/Realtime-Socket.IO-white?style=flat-square&logo=socketdotio&logoColor=white)](https://socket.io)
[![SQLite](https://img.shields.io/badge/Storage-SQLite%20(WAL)-003B57?style=flat-square&logo=sqlite&logoColor=white)](https://www.sqlite.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-F7DF1E?style=flat-square)](../LICENSE)

*One file. One process. Your whole messenger backend — running in under a minute.*

</div>

---

## What it is

A complete, production-minded **REST + Socket.IO** backend for the **RAVI** Flutter client.

### <img src="../docs/icons/zap.svg" width="20"> Realtime messaging
Private chats, groups, the public room and channels over **Socket.IO**: typing, read receipts, reactions, replies, forwards, deletes, edits and live unread badges.

### <img src="../docs/icons/lock.svg" width="20"> Accounts and sessions
Register/login with hashed passwords (Flask-Login), session cookies, multi-device session list, profile editing with avatars and bios.

### <img src="../docs/icons/shield.svg" width="20"> Moderation
Two-way block system, user reporting, per-room admins with custom titles and permissions, slow mode, chat locks, media/GIF permissions, bans with in-chat system messages.

### <img src="../docs/icons/users.svg" width="20"> Groups and channels
Public/private rooms, join links, member visibility modes, channel post view counters.

### <img src="../docs/icons/image.svg" width="20"> Media
Image/video/audio/file upload, HTTP **Range** streaming for video and audio, ffmpeg-powered **GIF conversion**, server-side avatar frames.

### <img src="../docs/icons/star.svg" width="20"> Extras
Pro accounts, follows/followers, saved GIFs gallery, global search, an offline keyword-based AI assistant, and optional **OpenRouter**-powered AI Pro chat.

### <img src="../docs/icons/folder.svg" width="20"> Storage
SQLite with WAL mode; no database server required.

## Quick run

> Requires **Python 3.10+**. No database setup, no config files — it just works.

```bash
cd backend

# 1. (optional but recommended) virtual environment
python -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate

# 2. install dependencies
pip install -r requirements.txt

# 3. run
python app.py
```

Done — the server is live at **`http://0.0.0.0:5000`**.

Now point the RAVI app at it: set `kBaseUrl` in `lib/core/constants.dart` to `http://YOUR_SERVER_IP:5000` and rebuild the app.

## Configuration

Environment variables:

| Variable              | Default   | Purpose                                              |
| --------------------- | --------- | ---------------------------------------------------- |
| `PORT`                | `5000`    | HTTP/Socket.IO listen port                           |
| `SECRET_KEY`          | *(auto)*  | Session secret — set it for multi-process deploys    |
| `OPENROUTER_API_KEY`  | *(none)*  | Enables the AI Pro chat; the endpoint answers "disabled" without it |

If `SECRET_KEY` is not set, the server creates a persistent local `.secret` file on first start, so sessions survive restarts.

## Production tips

- Put the server behind **nginx** and proxy both HTTP and the Socket.IO WebSocket upgrade; keep `X-Forwarded-For` so client IPs are recorded correctly.
- Open **only port 5000** (or your custom `PORT`) to the app, never the SQLite file.
- ffmpeg is bundled automatically via `imageio-ffmpeg`; if you prefer the system binary, just make sure `ffmpeg` is on `PATH`.
- For heavier loads, run multiple processes (gunicorn + `flask-socketio` workers) with a shared `SECRET_KEY` env var.

## API surface

**REST** — `/api/user`, `/api/sessions`, `/api/rooms`, `/api/room`, `/api/pv/…`, `/api/frames`, `/api/health`, media upload/download endpoints, admin panel routes, and more.

**Socket.IO** — namespace `/`: `send_message`, `typing`, `group_read`, `reactions`, `delete_message`, `forward` … with per-user rooms (`user_<id>`), private-chat rooms (`pv_<chat_id>`) and group rooms (`private_<room_id>`).

## Security notes

- Passwords are stored **hashed** (werkzeug `scrypt`).
- Private content is emitted **only** to the rooms of the chat's actual participants — never broadcast to everyone.
- Block checks run in **both directions** on every send path; admin-only posting is enforced server-side, not just in the UI.
- `OPENROUTER_API_KEY` is read from the environment — **never hardcode API keys**.

---

<div align="center">

**RAVI Backend v1.5.1** · MIT licensed — see [LICENSE](../LICENSE)

</div>
