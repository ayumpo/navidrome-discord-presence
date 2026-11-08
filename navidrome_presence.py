#!/usr/bin/env python3
"""
navidrome-presence — show what you're playing on Navidrome in your Discord status,
without a Discord user token.

How it stays inside Discord's rules
-----------------------------------
The official Navidrome plugin logs into Discord's Gateway with *your user token*,
which is account automation ("self-botting") and is what violates the ToS.

This tool never touches a token. It runs on the same computer as the Discord
desktop app and talks to it over Discord's *local* Rich Presence IPC socket —
the same sanctioned mechanism games, Spotify-style music players and editors
use. All it needs is the public Application ID of a Discord app you create in
the Developer Portal.

    Navidrome (NAS) --getNowPlaying--> this script (your computer) --local IPC--> Discord app

Standard library only (Python 3.8+). See README.md for setup.
"""

from __future__ import annotations

import argparse
import configparser
import hashlib
import json
import logging
import os
import re
import secrets
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import uuid
from collections import OrderedDict
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Tuple

__version__ = "1.0.0"
CLIENT_NAME = "navidrome-presence"
USER_AGENT = f"{CLIENT_NAME}/{__version__}"

log = logging.getLogger(CLIENT_NAME)


# ──────────────────────────────────────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────────────────────────────────────

DEFAULT_CONFIG_LOCATIONS = [
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.ini"),
    os.path.expanduser("~/.config/navidrome-presence/config.ini"),
    os.path.expanduser("~/Library/Application Support/navidrome-presence/config.ini"),
    os.path.join(os.environ.get("APPDATA", ""), "navidrome-presence", "config.ini"),
]

STATUS_DISPLAY = {"app": 0, "name": 0, "artist": 1, "state": 1, "track": 2, "details": 2}
LINK_TEMPLATES = {
    "spotify": "https://open.spotify.com/search/{q}",
    "youtube": "https://music.youtube.com/search?q={q}",
    "deezer": "https://www.deezer.com/search/{q}",
    "apple": "https://music.apple.com/search?term={q}",
}
ACTIVITY_NAMES = ("app", "track", "artist", "album", "custom")
ARTWORK_SOURCES = ("caa", "deezer", "itunes", "upload")
NAVIDROME_LOGO = "https://raw.githubusercontent.com/navidrome/navidrome/master/ui/public/android-chrome-512x512.png"
# Pause badge (from the official Navidrome Discord plugin, GPL-3.0), hosted in this project's repo.
PAUSE_ICON = "https://raw.githubusercontent.com/ayumpo/navidrome-discord-presence/main/assets/pause.png"


@dataclass
class Config:
    # [navidrome]
    url: str
    username: str
    password: str
    watch_user: str
    players: List[str] = field(default_factory=list)
    ignore_players: List[str] = field(default_factory=list)
    # [discord]
    client_id: str = ""
    status_display: int = 0
    activity_name: str = "app"            # app | track | artist | album | custom
    activity_name_template: str = "{artist} - {track}"
    on_pause: str = "show"  # show | clear
    show_album_in_state: bool = False
    links: str = "none"
    # [artwork]
    artwork_sources: List[str] = field(default_factory=lambda: ["deezer", "itunes"])
    fallback_image: str = NAVIDROME_LOGO
    paused_image: str = PAUSE_ICON
    # [general]
    poll_interval: float = 5.0
    stop_grace: float = 12.0
    log_level: str = "INFO"


def _csv(value: str) -> List[str]:
    return [v.strip() for v in value.split(",") if v.strip()]


def load_config(path: Optional[str]) -> Tuple[Config, str]:
    candidates = [path] if path else DEFAULT_CONFIG_LOCATIONS
    found = next((p for p in candidates if p and os.path.isfile(p)), None)
    if not found:
        where = path or "\n  ".join(c for c in DEFAULT_CONFIG_LOCATIONS if c)
        raise SystemExit(
            f"No config file found. Copy config.example.ini to one of:\n  {where}"
        )

    cp = configparser.ConfigParser(interpolation=None, inline_comment_prefixes=("#", ";"))
    cp.read(found, encoding="utf-8")
    # Passwords are read without inline-comment stripping, so "pa ss #1" stays intact.
    raw = configparser.ConfigParser(interpolation=None)
    raw.read(found, encoding="utf-8")

    def get(section: str, key: str, default: Optional[str] = None) -> str:
        env = os.environ.get(f"NDP_{section}_{key}".upper())
        if env is not None:
            return env
        if cp.has_option(section, key):
            return cp.get(section, key).strip()
        if default is None:
            raise SystemExit(f"Missing required setting [{section}] {key} in {found}")
        return default

    url = get("navidrome", "url").rstrip("/")
    if not re.match(r"^https?://", url):
        raise SystemExit("[navidrome] url must start with http:// or https://")
    username = get("navidrome", "username")

    status_key = get("discord", "status_display", "app").lower()
    if status_key not in STATUS_DISPLAY:
        raise SystemExit("[discord] status_display must be one of: app, artist, track")
    on_pause = get("discord", "on_pause", "show").lower()
    if on_pause not in ("show", "clear"):
        raise SystemExit("[discord] on_pause must be 'show' or 'clear'")
    links = get("discord", "links", "none").lower()
    if links != "none" and links not in LINK_TEMPLATES:
        raise SystemExit(f"[discord] links must be none or one of: {', '.join(LINK_TEMPLATES)}")

    client_id = get("discord", "client_id")
    if not client_id.isdigit():
        raise SystemExit("[discord] client_id must be the numeric Application ID from the Developer Portal")
    activity_name = get("discord", "activity_name", "app").lower()
    if activity_name not in ACTIVITY_NAMES:
        raise SystemExit(f"[discord] activity_name must be one of: {', '.join(ACTIVITY_NAMES)}")

    sources = [s.lower() for s in _csv(get("artwork", "sources", "deezer, itunes"))]
    sources = [] if sources == ["none"] else sources
    unknown = [s for s in sources if s not in ARTWORK_SOURCES]
    if unknown:
        raise SystemExit(f"[artwork] unknown source(s): {', '.join(unknown)} (use {', '.join(ARTWORK_SOURCES)} or none)")

    cfg = Config(
        url=url,
        username=username,
        password=(os.environ.get("NDP_NAVIDROME_PASSWORD")
                  or (raw.get("navidrome", "password", fallback="") if raw.has_section("navidrome") else "")
                  or get("navidrome", "password")),
        watch_user=get("navidrome", "watch_user", "") or username,
        players=_csv(get("navidrome", "players", "")),
        ignore_players=_csv(get("navidrome", "ignore_players", "")),
        client_id=client_id,
        status_display=STATUS_DISPLAY[status_key],
        activity_name=activity_name,
        activity_name_template=get("discord", "activity_name_template", "{artist} - {track}") or "{artist} - {track}",
        on_pause=on_pause,
        show_album_in_state=get("discord", "show_album_in_state", "false").lower() in ("1", "true", "yes", "on"),
        links=links,
        artwork_sources=sources,
        fallback_image=get("artwork", "fallback_image", NAVIDROME_LOGO),
        paused_image=get("artwork", "paused_image", PAUSE_ICON),
        poll_interval=max(2.0, float(get("general", "poll_interval", "5"))),
        stop_grace=max(0.0, float(get("general", "stop_grace", "12"))),
        log_level=get("general", "log_level", "INFO").upper(),
    )
    return cfg, found


# ──────────────────────────────────────────────────────────────────────────────
# Discord local IPC (Rich Presence) — no tokens, no Gateway
# ──────────────────────────────────────────────────────────────────────────────

class DiscordError(Exception):
    pass


class DiscordNotRunning(DiscordError):
    pass


class DiscordNotLoggedIn(DiscordNotRunning):
    """Discord is running but nobody is logged in yet (e.g. a fresh headless install)."""


class _UnixTransport:
    def __init__(self, path: str):
        self.path = path
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(10)
        try:
            self.sock.connect(path)
        except OSError:
            self.sock.close()
            raise

    def write(self, data: bytes) -> None:
        self.sock.sendall(data)

    def peer_closed(self) -> bool:
        prev = self.sock.gettimeout()
        try:
            self.sock.settimeout(0)  # a timed socket would wait for data before peeking
            return self.sock.recv(1, socket.MSG_PEEK) == b""
        except (BlockingIOError, InterruptedError):
            return False
        except OSError:
            return True
        finally:
            try:
                self.sock.settimeout(prev)
            except OSError:
                pass

    def read_exact(self, n: int) -> bytes:
        buf = bytearray()
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("Discord closed the IPC socket")
            buf.extend(chunk)
        return bytes(buf)

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass


class _PipeTransport:  # Windows named pipe
    def __init__(self, path: str):
        self.path = path
        self.f = open(path, "r+b", buffering=0)

    def write(self, data: bytes) -> None:
        self.f.write(data)

    def read_exact(self, n: int) -> bytes:
        buf = bytearray()
        while len(buf) < n:
            chunk = self.f.read(n - len(buf))
            if not chunk:
                raise ConnectionError("Discord closed the IPC pipe")
            buf.extend(chunk)
        return bytes(buf)

    def close(self) -> None:
        try:
            self.f.close()
        except OSError:
            pass


def _darwin_user_temp_dir() -> Optional[str]:
    """launchd agents don't always inherit TMPDIR; Discord's socket lives there on macOS."""
    try:
        return os.confstr("CS_DARWIN_USER_TEMP_DIR")  # type: ignore[arg-type]
    except (ValueError, OSError, AttributeError):
        pass
    try:
        out = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True, timeout=3)
        return out.stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


def discord_ipc_candidates() -> List[str]:
    if sys.platform == "win32":
        return [rf"\\?\pipe\discord-ipc-{i}" for i in range(10)]
    bases: List[str] = []
    for var in ("XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"):
        v = os.environ.get(var)
        if v:
            bases.append(v)
    if sys.platform == "darwin":
        d = _darwin_user_temp_dir()
        if d:
            bases.append(d)
    if sys.platform.startswith("linux"):
        bases.append(f"/run/user/{os.getuid()}")
    bases.append("/tmp")
    # Flatpak / Snap / Vesktop builds put the socket in a sub-folder.
    subdirs = ["", "app/com.discordapp.Discord", "app/com.discordapp.DiscordCanary",
               "snap.discord", "snap.discord-canary", ".flatpak/dev.vencord.Vesktop/xdg-run",
               "app/dev.vencord.Vesktop"]
    seen, out = set(), []
    for b in bases:
        for s in subdirs:
            for i in range(10):
                p = os.path.join(b, s, f"discord-ipc-{i}") if s else os.path.join(b, f"discord-ipc-{i}")
                if p not in seen:
                    seen.add(p)
                    out.append(p)
    return out


class DiscordIPC:
    OP_HANDSHAKE, OP_FRAME, OP_CLOSE, OP_PING, OP_PONG = 0, 1, 2, 3, 4

    def __init__(self, client_id: str, candidates: Optional[List[str]] = None):
        self.client_id = client_id
        self._candidates = candidates
        self.t: Optional[Any] = None
        self.user: Optional[str] = None

    @property
    def connected(self) -> bool:
        return self.t is not None

    def connect(self) -> None:
        last_err: Optional[Exception] = None
        for path in (self._candidates or discord_ipc_candidates()):
            if sys.platform != "win32" and not os.path.exists(path):
                continue
            try:
                t = _PipeTransport(path) if sys.platform == "win32" else _UnixTransport(path)
            except OSError as e:
                last_err = e
                continue
            self.t = t
            try:
                self._send(self.OP_HANDSHAKE, {"v": 1, "client_id": self.client_id})
                op, data = self._recv()
            except (OSError, ConnectionError, ValueError) as e:
                self.close()
                last_err = e
                continue
            if op == self.OP_CLOSE or data.get("evt") == "ERROR":
                self.close()
                msg = str(data.get("message") or (data.get("data") or {}).get("message") or data)
                if "logged out" in msg.lower() or "not authenticated" in msg.lower():
                    raise DiscordNotLoggedIn("Discord is running but isn't logged in yet")
                raise DiscordError(f"Discord rejected the handshake: {msg} (check client_id)")
            user = (data.get("data") or {}).get("user") or {}
            self.user = user.get("global_name") or user.get("username")
            log.info("Connected to Discord via %s%s", path, f" as {self.user}" if self.user else "")
            return
        raise DiscordNotRunning(f"Discord desktop app not found{f' ({last_err})' if last_err else ''}")

    def close(self) -> None:
        if self.t:
            self.t.close()
        self.t = None

    def check_alive(self) -> bool:
        """Notices Discord quitting even when we have nothing new to send."""
        if not self.t:
            return False
        if getattr(self.t, "peer_closed", lambda: False)():
            self.close()
            return False
        return True

    def _send(self, op: int, payload: Dict[str, Any]) -> None:
        assert self.t is not None
        body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        self.t.write(struct.pack("<II", op, len(body)) + body)

    def _recv(self) -> Tuple[int, Dict[str, Any]]:
        assert self.t is not None
        op, length = struct.unpack("<II", self.t.read_exact(8))
        raw = self.t.read_exact(length) if length else b"{}"
        return op, json.loads(raw.decode("utf-8") or "{}")

    def set_activity(self, activity: Optional[Dict[str, Any]]) -> None:
        if not self.t:
            raise DiscordNotRunning("not connected")
        nonce = str(uuid.uuid4())
        try:
            self._send(self.OP_FRAME, {"cmd": "SET_ACTIVITY", "args": {"pid": os.getpid(), "activity": activity}, "nonce": nonce})
            while True:
                op, data = self._recv()
                if op == self.OP_PING:
                    self._send(self.OP_PONG, data)
                    continue
                if op == self.OP_CLOSE:
                    raise ConnectionError(f"Discord closed the connection: {data.get('message', data)}")
                if data.get("nonce") == nonce:
                    break
        except (OSError, ConnectionError, ValueError, struct.error) as e:
            self.close()
            raise DiscordNotRunning(str(e)) from e
        if data.get("evt") == "ERROR":
            err = data.get("data") or {}
            raise DiscordError(f"Discord refused the activity: {err.get('message', err)}")


# ──────────────────────────────────────────────────────────────────────────────
# Navidrome / OpenSubsonic
# ──────────────────────────────────────────────────────────────────────────────

class NavidromeError(Exception):
    pass


class Navidrome:
    API_VERSION = "1.16.1"

    def __init__(self, url: str, username: str, password: str, timeout: float = 8.0):
        self.url, self.username, self.password, self.timeout = url, username, password, timeout

    def _auth(self) -> Dict[str, str]:
        salt = secrets.token_hex(8)
        token = hashlib.md5((self.password + salt).encode("utf-8")).hexdigest()
        return {"u": self.username, "t": token, "s": salt, "v": self.API_VERSION, "c": CLIENT_NAME, "f": "json"}

    def call(self, endpoint: str, **params: Any) -> Dict[str, Any]:
        q = urllib.parse.urlencode({**self._auth(), **params})
        req = urllib.request.Request(f"{self.url}/rest/{endpoint}.view?{q}", headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                payload = json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            raise NavidromeError(f"HTTP {e.code} from {endpoint}") from e
        except (urllib.error.URLError, OSError, ValueError) as e:
            raise NavidromeError(f"{endpoint}: {getattr(e, 'reason', e)}") from e
        resp = payload.get("subsonic-response") or {}
        if resp.get("status") != "ok":
            err = resp.get("error") or {}
            raise NavidromeError(f"{endpoint}: {err.get('message', 'unknown error')} (code {err.get('code')})")
        return resp

    def now_playing(self) -> List[Dict[str, Any]]:
        entries = (self.call("getNowPlaying").get("nowPlaying") or {}).get("entry") or []
        return entries if isinstance(entries, list) else [entries]

    def ping(self) -> Dict[str, Any]:
        return self.call("ping")

    def album_mbid(self, album_id: str) -> Optional[str]:
        """MusicBrainz release ID of an album, if the files are tagged with one."""
        album = self.call("getAlbum", id=album_id).get("album") or {}
        return album.get("musicBrainzId") or None

    def cover_art(self, cover_id: str, size: int = 600) -> Tuple[str, bytes]:
        q = urllib.parse.urlencode({**self._auth(), "id": cover_id, "size": size})
        req = urllib.request.Request(f"{self.url}/rest/getCoverArt.view?{q}", headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                ctype = r.headers.get("Content-Type", "image/jpeg").split(";")[0]
                data = r.read()
        except (urllib.error.URLError, OSError) as e:
            raise NavidromeError(f"getCoverArt: {getattr(e, 'reason', e)}") from e
        if not ctype.startswith("image/"):
            raise NavidromeError(f"getCoverArt returned {ctype}, not an image")
        return ctype, data


# ──────────────────────────────────────────────────────────────────────────────
# Album art: Discord needs a public https URL. Sources, tried in the configured order:
#   caa     Cover Art Archive (needs MusicBrainz-tagged albums)
#   deezer  / itunes  look the album up by artist + album name
#   upload  last resort: upload Navidrome's own cover to uguu.se (temporary, 3 h)
# ──────────────────────────────────────────────────────────────────────────────

class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args: Any, **kwargs: Any) -> None:  # type: ignore[override]
        return None


def _http_json(url: str, payload: Any = None, timeout: float = 6.0) -> Any:
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    headers = {"User-Agent": USER_AGENT, "Accept": "application/json"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def _multipart(field_name: str, filename: str, ctype: str, data: bytes) -> Tuple[str, bytes]:
    boundary = "----navidrome-presence-" + uuid.uuid4().hex
    head = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{field_name}\"; filename=\"{filename}\"\r\n"
            f"Content-Type: {ctype}\r\n\r\n").encode("utf-8")
    return f"multipart/form-data; boundary={boundary}", head + data + f"\r\n--{boundary}--\r\n".encode("utf-8")

_PAREN = re.compile(r"[\(\[\{][^\)\]\}]*[\)\]\}]")
_FEAT = re.compile(r"\s+(feat\.?|ft\.?|featuring|with)\s+.*$", re.I)
_NONWORD = re.compile(r"[^\w]+", re.UNICODE)


def norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", s or "")
    s = "".join(c for c in s if not unicodedata.combining(c)).lower()
    s = _PAREN.sub(" ", s)
    s = _FEAT.sub("", s)
    s = s.replace("&", " and ")
    s = re.sub(r"\s+-\s+(single|ep|remaster(ed)?.*|deluxe.*)$", "", s)
    return _NONWORD.sub(" ", s).strip()


def _close(a: str, b: str) -> bool:
    a, b = norm(a), norm(b)
    return bool(a and b) and (a == b or a in b or b in a)


def _best_match(items: List[Dict[str, Any]], album: str, artist: str, title_key, artist_key) -> Optional[Dict[str, Any]]:
    """Exact (normalised) album+artist beats a partial match; no artist match → no art."""
    best, best_score = None, 0
    na, nr = norm(album), norm(artist)
    for item in items:
        t, a = title_key(item), artist_key(item)
        if not (_close(t, album) and _close(a, artist)):
            continue
        score = 1 + (norm(t) == na) * 2 + (norm(a) == nr)
        if score > best_score:
            best, best_score = item, score
    return best


class ArtworkResolver:
    HIT_TTL = 24 * 3600
    MISS_TTL = 3600
    UPLOAD_TTL = 150 * 60  # uguu.se deletes files after 3 h

    def __init__(self, sources: List[str], timeout: float = 4.0, max_items: int = 512,
                 navidrome: Optional["Navidrome"] = None):
        self.sources, self.timeout, self.max_items, self.nd = sources, timeout, max_items, navidrome
        # key -> (url or None, expires_at)
        self.cache: "OrderedDict[str, Tuple[Optional[str], float]]" = OrderedDict()
        self.mbids: Dict[str, Optional[str]] = {}

    def _get_json(self, url: str) -> Any:
        return _http_json(url, timeout=self.timeout)

    def _caa(self, artist: str, album: str, ctx: Dict[str, Any]) -> Optional[str]:
        album_id = ctx.get("album_id")
        if not self.nd or not album_id:
            return None
        if album_id not in self.mbids:
            self.mbids[album_id] = self.nd.album_mbid(album_id)
        mbid = self.mbids[album_id]
        if not mbid:
            return None
        opener = urllib.request.build_opener(_NoRedirect)
        req = urllib.request.Request(f"https://coverartarchive.org/release/{mbid}/front-500",
                                     method="HEAD", headers={"User-Agent": USER_AGENT})
        try:
            opener.open(req, timeout=self.timeout)
        except urllib.error.HTTPError as e:
            if e.code in (301, 302, 303, 307, 308):
                return e.headers.get("Location") or None
            if e.code == 404:
                return None
            raise
        return None

    def _upload(self, artist: str, album: str, ctx: Dict[str, Any]) -> Optional[str]:
        cover_id = ctx.get("cover_id")
        if not self.nd or not cover_id:
            return None
        ctype, data = self.nd.cover_art(cover_id, 600)
        ext = {"image/png": "png", "image/webp": "webp", "image/gif": "gif"}.get(ctype, "jpg")
        content_type, body = _multipart("files[]", f"cover.{ext}", ctype, data)
        req = urllib.request.Request("https://uguu.se/upload", data=body,
                                     headers={"Content-Type": content_type, "User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=max(self.timeout, 15)) as r:
            res = json.loads(r.read().decode("utf-8"))
        files = res.get("files") or []
        return files[0].get("url") if res.get("success") and files else None

    def _deezer(self, artist: str, album: str, ctx: Optional[Dict[str, Any]] = None) -> Optional[str]:
        clean = lambda s: s.replace('"', " ")
        q = f'artist:"{clean(artist)}" album:"{clean(album)}"'
        data = self._get_json("https://api.deezer.com/search/album?" + urllib.parse.urlencode({"q": q, "limit": 10}))
        item = _best_match(data.get("data") or [], album, artist,
                           lambda i: i.get("title", ""), lambda i: (i.get("artist") or {}).get("name", ""))
        return (item.get("cover_xl") or item.get("cover_big")) if item else None

    def _itunes(self, artist: str, album: str, ctx: Optional[Dict[str, Any]] = None) -> Optional[str]:
        term = f"{artist} {album}"
        data = self._get_json("https://itunes.apple.com/search?" + urllib.parse.urlencode(
            {"term": term, "entity": "album", "media": "music", "limit": 15}))
        item = _best_match(data.get("results") or [], album, artist,
                           lambda i: i.get("collectionName", ""), lambda i: i.get("artistName", ""))
        art = (item or {}).get("artworkUrl100") or ""
        return re.sub(r"/\d+x\d+bb\.", "/600x600bb.", art) or None

    def resolve(self, artist: str, album: str, album_id: Optional[str] = None,
                cover_id: Optional[str] = None) -> Optional[str]:
        if not self.sources or not (album_id or cover_id or (artist and album)):
            return None
        key = album_id or f"{norm(artist)}|{norm(album)}"
        hit = self.cache.get(key)
        now = time.time()
        if hit and now < hit[1]:
            self.cache.move_to_end(key)
            return hit[0]
        ctx = {"album_id": album_id, "cover_id": cover_id}
        url: Optional[str] = None
        ttl = self.MISS_TTL
        for src in self.sources:
            if src in ("deezer", "itunes") and not (artist and album):
                continue
            try:
                url = getattr(self, f"_{src}")(artist, album, ctx)
            except Exception as e:  # network hiccups must never stop presence updates
                log.debug("artwork lookup via %s failed: %s", src, e)
                url = None
            if url:
                ttl = self.UPLOAD_TTL if src == "upload" else self.HIT_TTL
                log.debug("artwork for %r / %r from %s: %s", artist, album, src, url)
                break
        self.cache[key] = (url, now + ttl)
        self.cache.move_to_end(key)
        while len(self.cache) > self.max_items:
            self.cache.popitem(last=False)
        return url


class LinkResolver:
    """Clickable links. Spotify resolves a direct track link via ListenBrainz Labs (like the
    official plugin) and falls back to a search; other services use their search pages."""
    HIT_TTL = 30 * 24 * 3600
    MISS_TTL = 4 * 3600
    LB = "https://labs.api.listenbrainz.org"

    def __init__(self, service: str, timeout: float = 4.0, max_items: int = 1024):
        self.service, self.timeout, self.max_items = service, timeout, max_items
        self.cache: "OrderedDict[str, Tuple[str, float]]" = OrderedDict()

    def _post_json(self, url: str, payload: Any) -> Any:
        return _http_json(url, payload, timeout=self.timeout)

    @staticmethod
    def _first_spotify_id(body: Any) -> Optional[str]:
        for row in body if isinstance(body, list) else []:
            for tid in (row or {}).get("spotify_track_ids") or []:
                if isinstance(tid, str) and re.fullmatch(r"[0-9A-Za-z]+", tid):
                    return tid
        return None

    def search(self, *terms: str) -> Optional[str]:
        q = " ".join(t for t in terms if t).strip()
        if not q or self.service == "none":
            return None
        return LINK_TEMPLATES[self.service].format(q=urllib.parse.quote(q, safe=""))

    def track(self, artist: str, title: str, album: str, mbid: str = "") -> Optional[str]:
        if self.service == "none":
            return None
        if self.service != "spotify":
            return self.search(artist, title)
        key = "\x00".join(s.lower() for s in (artist, title, album))
        now = time.time()
        hit = self.cache.get(key)
        if hit and now < hit[1]:
            return hit[0]
        tid = None
        try:
            if mbid:
                tid = self._first_spotify_id(self._post_json(f"{self.LB}/spotify-id-from-mbid/json", [{"recording_mbid": mbid}]))
            if not tid and artist and title:
                tid = self._first_spotify_id(self._post_json(
                    f"{self.LB}/spotify-id-from-metadata/json",
                    [{"artist_name": artist, "track_name": title, "release_name": album}]))
        except Exception as e:
            log.debug("ListenBrainz lookup failed: %s", e)
        url = f"https://open.spotify.com/track/{tid}" if tid else self.search(artist, title)
        self.cache[key] = (url or "", now + (self.HIT_TTL if tid else self.MISS_TTL))
        while len(self.cache) > self.max_items:
            self.cache.popitem(last=False)
        return url


# ──────────────────────────────────────────────────────────────────────────────
# Turning a Navidrome now-playing entry into a Discord activity
# ──────────────────────────────────────────────────────────────────────────────

def _txt(s: Any, fallback: str = "Unknown") -> str:
    """Discord requires 2–128 characters for text fields."""
    s = str(s or "").strip() or fallback
    if len(s) < 2:
        s += "\u200b"
    return s if len(s) <= 128 else s[:127] + "…"


@dataclass
class Track:
    key: str
    id: str
    title: str
    artist: str
    album: str
    album_artist: str
    duration: float
    state: str            # playing | paused
    position: Optional[float]  # seconds, None if server doesn't report it
    rate: float
    player: str
    minutes_ago: int
    mbid: str = ""                  # MusicBrainz recording ID (for exact Spotify links)
    album_id: str = ""
    cover_id: str = ""
    artists: List[str] = field(default_factory=list)
    paused_since: Optional[float] = None


def parse_entry(e: Dict[str, Any]) -> Track:
    state = str(e.get("state") or "playing").lower()
    state = "paused" if state == "paused" else "playing"  # starting → playing
    pos = e.get("positionMs")
    rate = e.get("playbackRate") or 1.0
    try:
        rate = float(rate) if float(rate) > 0 else 1.0
    except (TypeError, ValueError):
        rate = 1.0
    artist = e.get("displayArtist") or e.get("artist") or ""
    artists = [a.get("name") for a in (e.get("artists") or []) if isinstance(a, dict) and a.get("name")]
    return Track(
        mbid=str(e.get("musicBrainzId") or ""),
        album_id=str(e.get("albumId") or ""),
        cover_id=str(e.get("coverArt") or e.get("albumId") or ""),
        artists=artists or ([artist] if artist else []),
        key=f"{e.get('id')}|{e.get('playerId', '')}|{e.get('playerName', '')}",
        id=str(e.get("id", "")),
        title=e.get("title") or "",
        artist=artist,
        album=e.get("album") or "",
        album_artist=e.get("displayAlbumArtist") or artist,
        duration=float(e.get("duration") or 0),
        state=state,
        position=(float(pos) / 1000.0) if isinstance(pos, (int, float)) else None,
        rate=rate,
        player=e.get("playerName") or "",
        minutes_ago=int(e.get("minutesAgo") or 0),
    )


class Selector:
    """Picks the entry to show and estimates position on servers without positionMs."""

    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.first_seen: Dict[str, float] = {}
        self.paused_since: Dict[str, float] = {}

    def pick(self, entries: List[Dict[str, Any]], now: float) -> Optional[Tuple[Track, float]]:
        tracks: List[Track] = []
        for e in entries:
            if e.get("username") and e.get("username") != self.cfg.watch_user:
                continue
            player = e.get("playerName") or ""
            if self.cfg.players and player not in self.cfg.players:
                continue
            if player in self.cfg.ignore_players:
                continue
            if e.get("isVideo"):
                continue
            tracks.append(parse_entry(e))

        live_keys = {t.key for t in tracks}
        for k in list(self.first_seen):
            if k not in live_keys:
                del self.first_seen[k]
        for k in list(self.paused_since):
            if k not in live_keys:
                del self.paused_since[k]

        candidates: List[Tuple[Track, float]] = []
        for t in tracks:
            if t.key not in self.first_seen:
                self.first_seen[t.key] = now - t.minutes_ago * 60
            if t.state == "paused":
                t.paused_since = self.paused_since.setdefault(t.key, now)
            else:
                self.paused_since.pop(t.key, None)
            if t.position is not None:
                elapsed = t.position
            else:  # old Navidrome: guess from when we first saw the entry
                elapsed = (now - self.first_seen[t.key]) * t.rate
                if t.duration and elapsed > t.duration + 30:
                    log.debug("ignoring stale entry %s (%.0fs past end)", t.title, elapsed - t.duration)
                    continue
            candidates.append((t, elapsed))

        if not candidates:
            return None
        # Prefer something actually playing, then the freshest report.
        candidates.sort(key=lambda c: (c[0].state != "playing", c[0].minutes_ago))
        return candidates[0]


def activity_name(cfg: Config, track: Track) -> Optional[str]:
    """The text after "Listening to". None = the Discord application's own name."""
    if cfg.activity_name == "track":
        return track.title or None
    if cfg.activity_name == "artist":
        return track.artist or None
    if cfg.activity_name == "album":
        return track.album or None
    if cfg.activity_name == "custom":
        name = (cfg.activity_name_template.replace("{track}", track.title).replace("{artists}", " • ".join(track.artists))
                .replace("{artist}", track.artist).replace("{album}", track.album)).strip(" -•")
        return name or None
    return None


def build_activity(cfg: Config, track: Track, elapsed: float, now: float, art: ArtworkResolver,
                   links: Optional[LinkResolver] = None) -> Optional[Dict[str, Any]]:
    if track.state == "paused" and cfg.on_pause == "clear":
        return None
    paused = track.state == "paused"

    state_line = track.artist or "Unknown artist"
    if cfg.show_album_in_state and track.album:
        state_line = f"{state_line} — {track.album}"
    if paused and not cfg.paused_image:
        state_line = "⏸ " + state_line  # no badge configured: mark the pause in text

    activity: Dict[str, Any] = {
        "type": 2,  # Listening to …
        "details": _txt(track.title, "Unknown track"),
        "state": _txt(state_line),
        "instance": False,
    }
    name = activity_name(cfg, track)
    if name:
        activity["name"] = _txt(name)
    if cfg.status_display:
        activity["status_display_type"] = cfg.status_display

    image = art.resolve(track.album_artist or track.artist, track.album, track.album_id, track.cover_id) or cfg.fallback_image
    assets: Dict[str, Any] = {}
    if image:
        assets["large_image"] = image
        assets["large_text"] = _txt(track.album or track.title)
    if paused:
        if cfg.paused_image:
            assets["small_image"] = cfg.paused_image
        assets["small_text"] = "Paused"

    if paused:
        # Discord shows an elapsed timer from `start` — i.e. "paused for 1:23".
        activity["timestamps"] = {"start": int(round(track.paused_since or now))}
    elif track.duration > 0:
        start = now - elapsed / track.rate
        activity["timestamps"] = {"start": int(round(start)), "end": int(round(start + track.duration / track.rate))}

    if links and cfg.links != "none":
        track_url = links.track(track.artists[0] if track.artists else track.artist, track.title, track.album, track.mbid)
        if track_url:
            activity["details_url"] = track_url[:256]
            if image:
                assets["large_url"] = track_url[:256]
        artist_url = links.search(track.artist)
        if artist_url:
            activity["state_url"] = artist_url[:256]
    if assets:
        activity["assets"] = assets
    return activity


# ──────────────────────────────────────────────────────────────────────────────
# Publishing (de-duplicated, rate-limit friendly, survives Discord restarts)
# ──────────────────────────────────────────────────────────────────────────────

def _signature(a: Optional[Dict[str, Any]]) -> Optional[str]:
    if a is None:
        return None
    b = {k: v for k, v in a.items() if k != "timestamps"}
    return json.dumps(b, sort_keys=True, ensure_ascii=False)


class Publisher:
    SEEK_TOLERANCE = 3  # seconds of drift before we treat it as a seek
    MIN_GAP = 4.0       # Discord allows ~5 SET_ACTIVITY per 20 s
    KEEPALIVE = 60.0    # re-send the current activity this often (also detects a dead pipe on Windows)

    def __init__(self, cfg: Config, discord: Optional[DiscordIPC]):
        self.cfg, self.discord = cfg, discord
        self.last: Optional[Dict[str, Any]] = None
        self.last_sent_at = 0.0
        self.empty_since: Optional[float] = None
        self.sent_once = False

    def reset(self) -> None:
        self.last, self.sent_once, self.empty_since = None, False, None

    def _changed(self, new: Optional[Dict[str, Any]], now: float) -> bool:
        if not self.sent_once:
            return True
        if new is not None and now - self.last_sent_at >= self.KEEPALIVE:
            return True
        if _signature(new) != _signature(self.last):
            return True
        if new and self.last:
            a = (new.get("timestamps") or {}).get("start")
            b = (self.last.get("timestamps") or {}).get("start")
            if (a is None) != (b is None):
                return True
            if a is not None and abs(a - b) > self.SEEK_TOLERANCE:
                return True
        return False

    def publish(self, desired: Optional[Dict[str, Any]], now: float) -> bool:
        """Returns True if something was sent."""
        if desired is None and self.last is not None:
            if self.empty_since is None:
                self.empty_since = now
            if now - self.empty_since < self.cfg.stop_grace:
                return False  # bridge the gap between tracks
        if desired is not None:
            self.empty_since = None
        if not self._changed(desired, now):
            return False
        same_track = _signature(desired) == _signature(self.last)
        if same_track and now - self.last_sent_at < self.MIN_GAP:
            return False

        if desired is None:
            if self.last is not None:
                log.info("Clearing presence")
        else:
            log.info("Presence: %s — %s%s", desired.get("details"), desired.get("state"),
                     "" if desired.get("timestamps") else " (no timer)")
            log.debug("activity payload: %s", json.dumps(desired, ensure_ascii=False))

        try:
            if self.discord is not None:
                self.discord.set_activity(desired)
        except DiscordNotRunning:
            raise
        except DiscordError:
            # Remember the bad payload so we don't resend it every poll.
            self.last, self.last_sent_at, self.sent_once = desired, now, True
            raise
        self.last, self.last_sent_at, self.sent_once = desired, now, True
        return True


# ──────────────────────────────────────────────────────────────────────────────
# Main loop
# ──────────────────────────────────────────────────────────────────────────────

class App:
    DISCORD_RETRY = 15.0

    def __init__(self, cfg: Config, dry_run: bool = False):
        self.cfg = cfg
        self.nd = Navidrome(cfg.url, cfg.username, cfg.password)
        self.art = ArtworkResolver(cfg.artwork_sources, navidrome=self.nd)
        self.links = LinkResolver(cfg.links)
        self.selector = Selector(cfg)
        self.discord = None if dry_run else DiscordIPC(cfg.client_id)
        self.pub = Publisher(cfg, self.discord)
        self.stop = threading.Event()
        self.nd_failures = 0
        self.next_discord_try = 0.0
        self._warned_discord = False

    def _ensure_discord(self, now: float) -> bool:
        if self.discord is None:
            return True
        if self.discord.connected:
            if self.discord.check_alive():
                return True
            log.info("Discord closed the connection; reconnecting")
            self.pub.reset()
            self.next_discord_try = 0.0
        if now < self.next_discord_try:
            return False
        try:
            self.discord.connect()
            self.pub.reset()
            self._warned_discord = False
            return True
        except DiscordNotLoggedIn as e:
            if self._warned_discord != "login":
                log.info("%s — waiting for you to log in. (Headless install: run navidrome-presence-login)", e)
                self._warned_discord = "login"
        except DiscordNotRunning as e:
            if not self._warned_discord:
                log.info("Waiting for the Discord desktop app… (%s)", e)
                self._warned_discord = True
        except DiscordError as e:
            log.error("%s", e)
        self.next_discord_try = now + self.DISCORD_RETRY
        return False

    def desired_activity(self, now: float) -> Tuple[bool, Optional[Dict[str, Any]]]:
        """Returns (ok, activity). ok=False means 'keep whatever is showing'."""
        try:
            entries = self.nd.now_playing()
        except NavidromeError as e:
            self.nd_failures += 1
            lvl = logging.WARNING if self.nd_failures in (1, 3) or self.nd_failures % 60 == 0 else logging.DEBUG
            log.log(lvl, "Navidrome request failed (%d): %s", self.nd_failures, e)
            return (self.nd_failures >= 3, None)
        if self.nd_failures:
            log.info("Navidrome reachable again")
        self.nd_failures = 0
        picked = self.selector.pick(entries, now)
        if not picked:
            return True, None
        track, elapsed = picked
        return True, build_activity(self.cfg, track, elapsed, now, self.art, self.links)

    def tick(self) -> None:
        now = time.time()
        if not self._ensure_discord(now):
            return
        ok, desired = self.desired_activity(now)
        if not ok:
            return
        try:
            self.pub.publish(desired, time.time())
        except DiscordNotRunning as e:
            log.info("Lost connection to Discord (%s); will reconnect", e)
            self.pub.reset()
            self.next_discord_try = time.time() + 2
        except DiscordError as e:
            log.error("%s", e)

    def run(self) -> None:
        log.info("navidrome-presence %s watching %s on %s", __version__, self.cfg.watch_user, self.cfg.url)
        while not self.stop.is_set():
            try:
                self.tick()
            except Exception:  # keep the daemon alive no matter what
                log.exception("Unexpected error")
            self.stop.wait(self.cfg.poll_interval)
        self.shutdown()

    def shutdown(self) -> None:
        if self.discord and self.discord.connected:
            try:
                self.discord.set_activity(None)
            except DiscordError:
                pass
            self.discord.close()
        log.info("Stopped")


def cmd_check(cfg: Config) -> int:
    ok = True
    nd = Navidrome(cfg.url, cfg.username, cfg.password)
    try:
        r = nd.ping()
        log.info("Navidrome OK: %s %s (OpenSubsonic: %s)", r.get("type", "server"), r.get("serverVersion", ""), r.get("openSubsonic", False))
        entries = nd.now_playing()
        mine = [e for e in entries if e.get("username") in (None, cfg.watch_user)]
        log.info("Now playing for %s: %d entr%s", cfg.watch_user, len(mine), "y" if len(mine) == 1 else "ies")
        for e in mine:
            log.info("  • %s — %s [%s, player=%s, state=%s, positionMs=%s]", e.get("artist"), e.get("title"),
                     e.get("album"), e.get("playerName"), e.get("state", "n/a"), e.get("positionMs", "n/a"))
    except NavidromeError as e:
        ok = False
        log.error("Navidrome check failed: %s", e)
    d = DiscordIPC(cfg.client_id)
    try:
        d.connect()
        d.set_activity({"type": 2, "details": "navidrome-presence test", "state": "If you can see this, IPC works",
                        "assets": {"large_image": cfg.fallback_image, "large_text": "Test"} if cfg.fallback_image else {},
                        "timestamps": {"start": int(time.time())}})
        log.info("Discord OK — check your profile now; clearing in 15 seconds…")
        time.sleep(15)
        d.set_activity(None)
        d.close()
    except DiscordNotLoggedIn as e:
        log.warning("%s. Log in to Discord (headless install: navidrome-presence-login); presence starts after that.", e)
    except DiscordNotRunning as e:
        log.warning("Discord desktop app isn't running (%s). That's fine — presence starts once it is.", e)
    except DiscordError as e:
        ok = False
        log.error("Discord check failed: %s", e)
    return 0 if ok else 1


# ──────────────────────────────────────────────────────────────────────────────
# Setup wizard (used by the Mac/Linux/Windows installers): asks, checks, writes config.ini
# ──────────────────────────────────────────────────────────────────────────────

CONFIG_TEMPLATE = """\
# navidrome-presence settings. Every option is explained in config.example.ini.
# Change anything here, then restart navidrome-presence (or re-run the installer).
[navidrome]
url = {url}
username = {username}
password = {password}

[discord]
client_id = {client_id}
status_display = track
activity_name = app
activity_name_template = {{artist}} - {{track}}
on_pause = show
show_album_in_state = false
links = spotify

[artwork]
sources = {sources}
fallback_image = {logo}

[general]
poll_interval = 5
stop_grace = 12
log_level = INFO
"""


def default_config_path() -> str:
    if sys.platform == "win32":
        return os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")), "navidrome-presence", "config.ini")
    if sys.platform == "darwin":
        return os.path.expanduser("~/Library/Application Support/navidrome-presence/config.ini")
    return os.path.expanduser("~/.config/navidrome-presence/config.ini")


def normalize_url(url: str) -> str:
    url = "".join((url or "").split())
    if not url:
        return ""
    if not re.match(r"^https?://", url, re.I):
        url = "http://" + url
    url = re.sub(r"/app(/.*)?$", "", url)          # pasted from the browser: http://host:4533/app/#/album/…
    url = re.sub(r"/rest(/.*)?$", "", url)
    return url.rstrip("/")


def navidrome_reachable(url: str, timeout: float = 8.0) -> bool:
    try:
        req = urllib.request.Request(f"{url}/rest/ping.view?f=json", headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return "subsonic-response" in r.read(4096).decode("utf-8", "replace")
    except Exception:
        return False


def cmd_setup(path: str, ask: Any = input, ask_secret: Any = None, say: Any = print) -> int:
    import getpass
    ask_secret = ask_secret or getpass.getpass
    env = os.environ.get

    def prompt(text: str, env_key: str, secret: bool = False) -> str:
        v = env(env_key)
        if v is not None:
            return v
        try:
            return (ask_secret if secret else ask)(f"  {text}: ")
        except EOFError:
            return ""

    say("\nNavidrome → Discord presence · setup\n")
    say("1/4  Your Navidrome server — the address you open it with, e.g. http://192.168.1.10:4533")
    url = ""
    for attempt in range(3):
        url = normalize_url(prompt("Navidrome address", "ND_URL") if attempt == 0 else prompt("Navidrome address", "_none_"))
        if url and navidrome_reachable(url):
            say(f"  ✔ Found Navidrome at {url}")
            break
        say(f"  ! Couldn't reach a Navidrome server at {url or '(nothing typed)'}.")
        url = ""
    if not url:
        say("  ✘ Check the address (including the :port) and run setup again.")
        return 1

    say("\n2/4  Your Navidrome login — whose listening should show on Discord")
    user = pw = ""
    for attempt in range(3):
        key_u, key_p = ("ND_USER", "ND_PASS") if attempt == 0 else ("_none_", "_none_")
        user = prompt("Username", key_u).strip()
        pw = prompt("Password (hidden as you type)", key_p, secret=True)
        try:
            Navidrome(url, user, pw).ping()
            say(f"  ✔ Logged in as {user}")
            break
        except NavidromeError:
            say("  ! Navidrome didn't accept that username/password.")
            user = ""
    if not user:
        say("  ✘ Double-check the login and run setup again.")
        return 1

    say("\n3/4  Your Discord application (one-time, about 2 minutes)")
    say("  1. Open https://discord.com/developers/applications and log in")
    say("  2. Click \"New Application\", give it a name — it appears after \"Listening to\" (e.g. Navidrome)")
    say("  3. Click Create, then \"Copy\" next to \"Application ID\"")
    client_id = ""
    for attempt in range(3):
        raw_id = prompt("Paste the Application ID", "CLIENT_ID" if attempt == 0 else "_none_")
        client_id = re.sub(r"\D", "", raw_id or "")
        if 17 <= len(client_id) <= 20:
            say("  ✔ Application ID looks good")
            break
        say("  ! That doesn't look like an Application ID (a 17–20 digit number).")
        client_id = ""
    if not client_id:
        say("  ✘ Copy the Application ID from the Developer Portal and run setup again.")
        return 1

    say("\n4/4  Album art — show the covers from your own Navidrome?")
    say("  They're uploaded to uguu.se, a temporary image host that deletes them after 3 hours.")
    say("  Otherwise covers are looked up on Deezer and iTunes.")
    covers = env("NDP_COVERS")
    if covers is None:
        try:
            covers = ask("  Use your Navidrome covers? [Y/n]: ")
        except EOFError:
            covers = ""
    sources = "caa, deezer, itunes" if (covers or "y").strip().lower().startswith("n") else "upload, caa, deezer, itunes"

    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(CONFIG_TEMPLATE.format(url=url, username=user, password=pw, client_id=client_id,
                                       sources=sources, logo=NAVIDROME_LOGO))
    if os.name == "posix":
        os.chmod(path, 0o600)
    say(f"\n  ✔ Saved your settings to {path}")
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Navidrome → Discord Rich Presence over local IPC (no user token).")
    ap.add_argument("-c", "--config", help="path to config.ini")
    ap.add_argument("--setup", nargs="?", const="", metavar="PATH",
                    help="answer a few questions and write config.ini (default location if PATH is omitted)")
    ap.add_argument("--dry-run", action="store_true", help="poll Navidrome and log what would be shown, without Discord")
    ap.add_argument("--once", action="store_true", help="run a single poll and exit")
    ap.add_argument("--check", action="store_true", help="test the Navidrome login and the Discord connection, then exit")
    ap.add_argument("-v", "--verbose", action="store_true", help="debug logging")
    ap.add_argument("--version", action="version", version=__version__)
    args = ap.parse_args(argv)

    if args.setup is not None:
        return cmd_setup(args.setup or args.config or default_config_path())

    cfg, path = load_config(args.config)
    logging.basicConfig(level=logging.DEBUG if args.verbose else getattr(logging, cfg.log_level, logging.INFO),
                        format="%(asctime)s %(levelname)-7s %(message)s", datefmt="%Y-%m-%d %H:%M:%S")
    log.debug("config: %s", path)

    if args.check:
        return cmd_check(cfg)

    app = App(cfg, dry_run=args.dry_run)

    def _stop(*_: Any) -> None:
        app.stop.set()
    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGTERM, _stop)

    if args.once:
        app.tick()
        app.shutdown()
        return 0
    app.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
