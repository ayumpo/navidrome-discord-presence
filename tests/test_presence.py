"""End-to-end tests against a fake Discord IPC socket and a fake Navidrome server.

Run:  python3 -m unittest discover -s tests -v
"""
import hashlib
import json
import logging
import os
import socket
import struct
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import navidrome_presence as ndp  # noqa: E402


# ── fake Discord desktop client ──────────────────────────────────────────────

class FakeDiscord:
    def __init__(self, path, client_id="1234567890", reject_activity=False, logged_out=False):
        self.path, self.client_id, self.reject_activity = path, client_id, reject_activity
        self.logged_out = logged_out
        self.activities = []      # every SET_ACTIVITY payload received
        self.handshakes = []
        self.raw_frames = []
        self.conns = []
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.srv.bind(path)
        self.srv.listen(4)
        self.alive = True
        threading.Thread(target=self._accept, daemon=True).start()

    def _read(self, c, n):
        buf = b""
        while len(buf) < n:
            chunk = c.recv(n - len(buf))
            if not chunk:
                raise ConnectionError
            buf += chunk
        return buf

    def _frame(self, c):
        header = self._read(c, 8)
        op, ln = struct.unpack("<II", header)
        body = self._read(c, ln)
        self.raw_frames.append((op, header, body))
        return op, json.loads(body)

    def _send(self, c, op, obj):
        b = json.dumps(obj).encode()
        c.sendall(struct.pack("<II", op, len(b)) + b)

    def _accept(self):
        while self.alive:
            try:
                c, _ = self.srv.accept()
            except OSError:
                return
            self.conns.append(c)
            threading.Thread(target=self._serve, args=(c,), daemon=True).start()

    def _serve(self, c):
        try:
            op, hs = self._frame(c)
            self.handshakes.append(hs)
            if self.logged_out:
                self._send(c, 2, {"code": 4006, "message": "User logged out"})
                c.close()
                return
            if hs.get("client_id") != self.client_id:
                self._send(c, 2, {"code": 4000, "message": "Invalid Client ID"})
                c.close()
                return
            self._send(c, 1, {"cmd": "DISPATCH", "evt": "READY",
                              "data": {"v": 1, "user": {"username": "alice", "global_name": "Alice"}}})
            while True:
                op, msg = self._frame(c)
                if msg.get("cmd") == "SET_ACTIVITY":
                    act = msg["args"]["activity"]
                    self.activities.append(act)
                    self.last_pid = msg["args"]["pid"]
                    if self.reject_activity:
                        self._send(c, 1, {"cmd": "SET_ACTIVITY", "evt": "ERROR", "nonce": msg["nonce"],
                                          "data": {"code": 4000, "message": "child \"activity\" fails"}})
                    else:
                        self._send(c, 1, {"cmd": "SET_ACTIVITY", "evt": None, "nonce": msg["nonce"], "data": act})
        except (ConnectionError, OSError, ValueError):
            pass

    def kick_all(self):
        """Simulate the user quitting Discord."""
        for c in self.conns:
            try:
                c.shutdown(socket.SHUT_RDWR)
                c.close()
            except OSError:
                pass
        self.conns.clear()

    def close(self):
        self.alive = False
        self.kick_all()
        self.srv.close()


# ── fake Navidrome ───────────────────────────────────────────────────────────

class FakeNavidrome:
    def __init__(self, user="alice", password="s3cret"):
        self.user, self.password = user, password
        self.entries = []
        self.down = False
        self.requests = []
        outer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                if outer.down:
                    self.send_response(503)
                    self.end_headers()
                    return
                u = urllib.parse.urlparse(self.path)
                q = dict(urllib.parse.parse_qsl(u.query))
                outer.requests.append((u.path, q))
                ok_auth = q.get("u", "").casefold() == outer.user.casefold() and q.get("t") == hashlib.md5(
                    (outer.password + q.get("s", "")).encode()).hexdigest()
                base = {"status": "ok", "version": "1.16.1", "type": "navidrome",
                        "serverVersion": "0.63.2", "openSubsonic": True}
                if "p" in q:  # we must never send the plaintext password
                    base = {"status": "failed", "error": {"code": 99, "message": "plaintext password sent"}}
                elif not ok_auth:
                    base = {"status": "failed", "error": {"code": 40, "message": "Wrong username or password"}}
                elif u.path.endswith("/getUser.view"):
                    base["user"] = {"username": outer.user, "adminRole": False}
                elif u.path.endswith("/getNowPlaying.view"):
                    base["nowPlaying"] = {"entry": list(outer.entries)} if outer.entries else {}
                body = json.dumps({"subsonic-response": base}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(body)

        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.srv.server_address[1]}"
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def close(self):
        self.srv.shutdown()
        self.srv.server_close()


def entry(**kw):
    e = {"id": "song1", "title": "Weird Fishes/Arpeggi", "artist": "Radiohead", "album": "In Rainbows",
         "albumId": "al1", "duration": 318, "username": "alice", "playerName": "Narjo", "playerId": 1,
         "minutesAgo": 0, "state": "playing", "positionMs": 60000, "playbackRate": 1.0, "coverArt": "mf-x"}
    e.update(kw)
    return e


def make_cfg(nav, **kw):
    c = ndp.Config(url=nav.url, username="alice", password="s3cret", watch_user="alice",
                   client_id="1234567890", artwork_sources=[], fallback_image="navidrome",
                   poll_interval=2, stop_grace=0)
    for k, v in kw.items():
        setattr(c, k, v)
    return c


# ── tests ────────────────────────────────────────────────────────────────────

class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(dir=os.environ.get("TEST_TMP"))
        self.sock_path = os.path.join(self.tmp, "discord-ipc-0")
        self.discord = FakeDiscord(self.sock_path)
        self.nav = FakeNavidrome()

    def tearDown(self):
        for a in getattr(self, "_apps", []):
            if a.discord:
                a.discord.close()
        self.discord.close()
        self.nav.close()

    def app(self, **kw):
        cfg = make_cfg(self.nav, **kw)
        app = ndp.App(cfg)
        self._apps = getattr(self, "_apps", []) + [app]
        app.discord = ndp.DiscordIPC(cfg.client_id, candidates=[self.sock_path])
        app.pub.discord = app.discord
        app.pub.MIN_GAP = 0
        return app

    def wait_for(self, n, timeout=2.0):
        end = time.time() + timeout
        while len(self.discord.activities) < n and time.time() < end:
            time.sleep(0.01)
        return self.discord.activities


class TestIPC(Base):
    def test_handshake_and_frame_format(self):
        d = ndp.DiscordIPC("1234567890", candidates=[self.sock_path])
        d.connect()
        self.assertEqual(d.user, "Alice")
        self.assertEqual(self.discord.handshakes[0], {"v": 1, "client_id": "1234567890"})
        d.set_activity({"type": 2, "details": "x1", "state": "y1"})
        op, header, body = self.discord.raw_frames[-1]
        self.assertEqual(op, 1)
        self.assertEqual(struct.unpack("<II", header)[1], len(body))  # little-endian length prefix
        self.assertEqual(self.discord.last_pid, os.getpid())
        d.set_activity(None)
        self.assertIsNone(self.discord.activities[-1])
        d.close()

    def test_bad_client_id_is_reported(self):
        d = ndp.DiscordIPC("999", candidates=[self.sock_path])
        with self.assertRaises(ndp.DiscordError) as cm:
            d.connect()
        self.assertIn("Invalid Client ID", str(cm.exception))
        self.assertNotIsInstance(cm.exception, ndp.DiscordNotRunning)

    def test_logged_out_is_a_wait_not_a_config_error(self):
        self.discord.logged_out = True
        d = ndp.DiscordIPC("1234567890", candidates=[self.sock_path])
        with self.assertRaises(ndp.DiscordNotLoggedIn) as cm:
            d.connect()
        self.assertNotIn("client_id", str(cm.exception))
        # the daemon keeps waiting and connects once the user logs in
        app = self.app()
        self.nav.entries = [entry()]
        app.tick()
        self.assertEqual(app._warned_discord, "login")
        self.discord.logged_out = False
        app.next_discord_try = 0
        app.tick()
        self.assertEqual(self.wait_for(1)[-1]["details"], "Weird Fishes/Arpeggi")

    def test_not_running(self):
        d = ndp.DiscordIPC("1234567890", candidates=[os.path.join(self.tmp, "nope-0")])
        with self.assertRaises(ndp.DiscordNotRunning):
            d.connect()


class TestNavidrome(Base):
    def test_token_auth_never_sends_password(self):
        nd = ndp.Navidrome(self.nav.url, "alice", "s3cret")
        self.nav.entries = [entry()]
        self.assertEqual(len(nd.now_playing()), 1)
        path, q = self.nav.requests[-1]
        self.assertNotIn("p", q)
        self.assertNotIn("s3cret", json.dumps(q))
        self.assertEqual(q["c"], "navidrome-presence")

    def test_wrong_password(self):
        nd = ndp.Navidrome(self.nav.url, "alice", "nope")
        with self.assertRaises(ndp.NavidromeError) as cm:
            nd.now_playing()
        self.assertIn("Wrong username", str(cm.exception))

    def test_single_entry_object_is_normalised(self):
        nd = ndp.Navidrome(self.nav.url, "alice", "s3cret")
        self.assertEqual(nd.now_playing(), [])


class TestEndToEnd(Base):
    def test_playing_then_dedupe_then_seek_then_pause_then_stop(self):
        app = self.app()
        self.nav.entries = [entry(positionMs=60000)]
        t0 = time.time()
        app.tick()
        acts = self.wait_for(1)
        a = acts[-1]
        self.assertEqual(a["type"], 2)
        self.assertEqual(a["details"], "Weird Fishes/Arpeggi")
        self.assertEqual(a["state"], "Radiohead")
        self.assertEqual(a["assets"], {"large_image": "navidrome", "large_text": "In Rainbows"})
        self.assertAlmostEqual(a["timestamps"]["start"], t0 - 60, delta=2)
        self.assertEqual(a["timestamps"]["end"] - a["timestamps"]["start"], 318)
        self.assertNotIn("status_display_type", a)

        # Same track, position advanced naturally → nothing new sent
        self.nav.entries = [entry(positionMs=60000 + int((time.time() - t0) * 1000) + 500)]
        app.tick()
        time.sleep(0.1)
        self.assertEqual(len(self.discord.activities), 1)

        # Seek forward 90 s → resend with a new start time
        self.nav.entries = [entry(positionMs=150000)]
        app.tick()
        a = self.wait_for(2)[-1]
        self.assertAlmostEqual(a["timestamps"]["start"], time.time() - 150, delta=2)

        # Pause → pause badge + "paused for" timer (start only, no end)
        self.nav.entries = [entry(state="paused", positionMs=150000)]
        t_pause = time.time()
        app.tick()
        a = self.wait_for(3)[-1]
        self.assertEqual(a["state"], "Radiohead")
        self.assertEqual(a["assets"]["small_image"], ndp.PAUSE_ICON)
        self.assertEqual(a["assets"]["small_text"], "Paused")
        self.assertAlmostEqual(a["timestamps"]["start"], t_pause, delta=2)
        self.assertNotIn("end", a["timestamps"])
        # Still paused on the next poll → same timer start, nothing re-sent
        app.tick()
        time.sleep(0.1)
        self.assertEqual(len(self.discord.activities), 3)

        # Stopped (entry gone) → cleared
        self.nav.entries = []
        app.tick()
        self.assertIsNone(self.wait_for(4)[-1])
        app.shutdown()

    def test_pause_clear_mode(self):
        app = self.app(on_pause="clear")
        self.nav.entries = [entry()]
        app.tick()
        self.wait_for(1)
        self.nav.entries = [entry(state="paused")]
        app.tick()
        self.assertIsNone(self.wait_for(2)[-1])

    def test_grace_bridges_track_change(self):
        app = self.app(stop_grace=5)
        self.nav.entries = [entry()]
        app.tick()
        self.wait_for(1)
        self.nav.entries = []
        app.tick()
        time.sleep(0.1)
        self.assertEqual(len(self.discord.activities), 1)  # still showing during grace
        self.nav.entries = [entry(id="song2", title="Reckoner", positionMs=1000)]
        app.tick()
        a = self.wait_for(2)[-1]
        self.assertEqual(a["details"], "Reckoner")  # went straight to the next track, no blank

    def test_filters_other_users_and_players(self):
        app = self.app(players=["Narjo"])
        self.nav.entries = [entry(username="someone-else", title="Not Mine"),
                            entry(playerName="Feishin", title="Wrong Player")]
        app.tick()
        time.sleep(0.1)
        # Only a silent initial clear, nothing displayed
        self.assertTrue(all(a is None for a in self.discord.activities))
        self.nav.entries.append(entry(title="Mine"))
        app.tick()
        self.assertEqual(self.wait_for(2)[-1]["details"], "Mine")

    def test_username_and_player_matching_ignores_case(self):
        # Navidrome accepts "alice" for an account stored as "Alice" and reports entries as "Alice".
        app = self.app(watch_user="alice", players=["narjo"])
        self.nav.entries = [entry(username="Alice", playerName="Narjo", title="Case Test")]
        app.tick()
        self.assertEqual(self.wait_for(1)[-1]["details"], "Case Test")

    def test_prefers_playing_over_paused(self):
        app = self.app()
        self.nav.entries = [entry(playerName="Desktop", playerId=2, state="paused", title="Paused One"),
                            entry(title="Playing One", minutesAgo=2)]
        app.tick()
        self.assertEqual(self.wait_for(1)[-1]["details"], "Playing One")

    def test_old_navidrome_without_position(self):
        app = self.app()
        e = entry(minutesAgo=1)
        del e["positionMs"], e["state"], e["playbackRate"]
        self.nav.entries = [e]
        app.tick()
        a = self.wait_for(1)[-1]
        self.assertAlmostEqual(a["timestamps"]["start"], time.time() - 60, delta=2)
        # an entry that's clearly past its end is ignored
        stale = entry(id="old", minutesAgo=20, duration=200)
        del stale["positionMs"], stale["state"]
        self.nav.entries = [stale]
        app.tick()
        self.assertIsNone(self.wait_for(2)[-1])

    def test_playback_rate(self):
        app = self.app()
        self.nav.entries = [entry(positionMs=100000, playbackRate=2.0, duration=300)]
        app.tick()
        a = self.wait_for(1)[-1]
        self.assertEqual(a["timestamps"]["end"] - a["timestamps"]["start"], 150)
        self.assertAlmostEqual(a["timestamps"]["start"], time.time() - 50, delta=2)

    def test_discord_restart_resends(self):
        app = self.app()
        self.nav.entries = [entry()]
        app.tick()
        self.wait_for(1)
        self.discord.kick_all()
        time.sleep(0.1)
        app.tick()  # same song still playing: must notice the dead socket, reconnect, re-send
        acts = self.wait_for(2)
        self.assertEqual(len(self.discord.handshakes), 2)
        self.assertEqual(acts[-1]["details"], "Weird Fishes/Arpeggi")

    def test_keepalive_resends_unchanged_activity(self):
        app = self.app()
        app.pub.KEEPALIVE = 0.2
        self.nav.entries = [entry()]
        app.tick()
        self.wait_for(1)
        app.tick()
        time.sleep(0.05)
        self.assertEqual(len(self.discord.activities), 1)
        time.sleep(0.25)
        with self.assertLogs(ndp.log, level="DEBUG") as logs:
            app.tick()
        self.assertEqual(len(self.wait_for(2)), 2)
        presence = [r for r in logs.records if r.getMessage().startswith("Presence:")]
        self.assertEqual([r.levelname for r in presence], ["DEBUG"])  # resends don't fill the log

    def test_navidrome_outage_clears_after_three_failures(self):
        app = self.app()
        self.nav.entries = [entry()]
        app.tick()
        self.wait_for(1)
        self.nav.down = True
        app.tick()
        app.tick()
        time.sleep(0.1)
        self.assertEqual(len(self.discord.activities), 1)  # blips don't clear
        app.tick()
        self.assertIsNone(self.wait_for(2)[-1])

    def test_status_display_and_links(self):
        app = self.app(status_display=1, links="spotify", show_album_in_state=True)
        calls = []
        def fake_lb(url, payload):
            calls.append((url, payload))
            return [{"spotify_track_ids": ["4wajJ1o7jWIg62YqpkHC7S"]}] if "metadata" in url else [{"spotify_track_ids": []}]
        app.links._post_json = fake_lb
        self.nav.entries = [entry(musicBrainzId="mbid-123")]
        app.tick()
        a = self.wait_for(1)[-1]
        self.assertEqual(a["status_display_type"], 1)
        self.assertEqual(a["state"], "Radiohead — In Rainbows")
        self.assertEqual(a["details_url"], "https://open.spotify.com/track/4wajJ1o7jWIg62YqpkHC7S")
        self.assertEqual(a["assets"]["large_url"], a["details_url"])
        self.assertEqual(a["state_url"], "https://open.spotify.com/search/Radiohead")
        # MBID tried first, then metadata
        self.assertIn("spotify-id-from-mbid", calls[0][0])
        self.assertEqual(calls[0][1], [{"recording_mbid": "mbid-123"}])
        self.assertEqual(calls[1][1], [{"artist_name": "Radiohead", "track_name": "Weird Fishes/Arpeggi", "release_name": "In Rainbows"}])

    def test_activity_name_override(self):
        app = self.app(activity_name="custom", activity_name_template="{artist} - {track}")
        self.nav.entries = [entry()]
        app.tick()
        self.assertEqual(self.wait_for(1)[-1]["name"], "Radiohead - Weird Fishes/Arpeggi")
        app2 = self.app(activity_name="album")
        app2.selector = ndp.Selector(app2.cfg)
        self.assertEqual(ndp.activity_name(app2.cfg, ndp.parse_entry(entry())), "In Rainbows")
        self.assertIsNone(ndp.activity_name(self.app().cfg, ndp.parse_entry(entry())))  # app = Discord app name

    def test_pause_without_badge_uses_text_marker(self):
        app = self.app(paused_image="")
        self.nav.entries = [entry(state="paused")]
        app.tick()
        a = self.wait_for(1)[-1]
        self.assertEqual(a["state"], "⏸ Radiohead")
        self.assertNotIn("small_image", a["assets"])

    def test_rejected_payload_is_not_retried_every_poll(self):
        self.discord.reject_activity = True
        app = self.app()
        self.nav.entries = [entry()]
        app.tick()
        app.tick()
        app.tick()
        time.sleep(0.1)
        self.assertEqual(len(self.discord.activities), 1)


class TestText(unittest.TestCase):
    def test_lengths(self):
        self.assertEqual(len(ndp._txt("X")), 2)
        self.assertEqual(len(ndp._txt("y" * 300)), 128)
        self.assertEqual(ndp._txt(""), "Unknown")


class TestArtwork(unittest.TestCase):
    def test_deezer_match(self):
        r = ndp.ArtworkResolver(["deezer"])
        r._get_json = lambda url: {"data": [
            {"title": "In Rainbows Disk 2", "artist": {"name": "Radiohead"}, "cover_xl": "https://wrong"},
            {"title": "In Rainbows", "artist": {"name": "Radiohead"}, "cover_xl": "https://cdn-images.dzcdn.net/x/1000x1000.jpg"},
        ]} if "deezer" in url else {}
        # "In Rainbows Disk 2" partially matches, but the exact title must win
        self.assertEqual(r.resolve("Radiohead", "In Rainbows (Deluxe Edition)"),
                         "https://cdn-images.dzcdn.net/x/1000x1000.jpg")

    def test_itunes_resize_and_mismatch(self):
        r = ndp.ArtworkResolver(["itunes"])
        r._get_json = lambda url: {"results": [
            {"collectionName": "OK Computer", "artistName": "Radiohead",
             "artworkUrl100": "https://is1-ssl.mzstatic.com/a/100x100bb.jpg"}]}
        self.assertEqual(r.resolve("Radiohead", "OK Computer"), "https://is1-ssl.mzstatic.com/a/600x600bb.jpg")
        self.assertIsNone(r.resolve("Radiohead", "Kid A"))  # never show the wrong album

    def test_fallback_order_and_cache(self):
        calls = []
        r = ndp.ArtworkResolver(["deezer", "itunes"])

        def fake(url):
            calls.append(url)
            if "deezer" in url:
                raise OSError("timeout")
            return {"results": [{"collectionName": "Discovery", "artistName": "Daft Punk",
                                 "artworkUrl100": "https://x/100x100bb.jpg"}]}
        r._get_json = fake
        self.assertEqual(r.resolve("Daft Punk", "Discovery"), "https://x/600x600bb.jpg")
        r.resolve("Daft Punk", "Discovery")
        self.assertEqual(len(calls), 2)  # second call served from cache

    def test_norm(self):
        self.assertEqual(ndp.norm("Beyoncé feat. Jay-Z"), "beyonce")
        self.assertEqual(ndp.norm("Abbey Road (Remastered 2019)"), "abbey road")
        self.assertTrue(ndp._close("Simon & Garfunkel", "Simon and Garfunkel"))


class TestLinks(unittest.TestCase):
    def test_spotify_fallback_and_cache(self):
        r = ndp.LinkResolver("spotify")
        calls = []
        def boom(url, payload):
            calls.append(url)
            raise OSError("offline")
        r._post_json = boom
        url = r.track("Luigi Castro", "Jesús", "Muéstrame Tu Gloria")
        self.assertEqual(url, "https://open.spotify.com/search/Luigi%20Castro%20Jes%C3%BAs")
        r.track("Luigi Castro", "Jesús", "Muéstrame Tu Gloria")
        self.assertEqual(len(calls), 1)  # miss cached

    def test_other_services_use_search(self):
        r = ndp.LinkResolver("youtube")
        self.assertEqual(r.track("A", "B", "C"), "https://music.youtube.com/search?q=A%20B")
        self.assertIsNone(ndp.LinkResolver("none").track("A", "B", "C"))

    def test_rejects_bad_ids(self):
        self.assertIsNone(ndp.LinkResolver._first_spotify_id([{"spotify_track_ids": ["../evil"]}]))
        self.assertEqual(ndp.LinkResolver._first_spotify_id([{"spotify_track_ids": ["", "abc123"]}]), "abc123")


class _Resp:
    def __init__(self, body, headers=None):
        self.body, self.headers = body, headers or {}
    def read(self):
        return self.body
    def __enter__(self):
        return self
    def __exit__(self, *a):
        return False


class TestArtworkSources(unittest.TestCase):
    def test_caa_uses_album_mbid_redirect(self):
        from unittest import mock
        nd = mock.Mock(); nd.album_mbid.return_value = "rel-1"
        r = ndp.ArtworkResolver(["caa"], navidrome=nd)
        err = ndp.urllib.error.HTTPError("u", 307, "Temporary Redirect", {"Location": "https://archive.org/x/front.jpg"}, None)
        opener = mock.Mock(); opener.open.side_effect = err
        with mock.patch.object(ndp.urllib.request, "build_opener", return_value=opener):
            self.assertEqual(r.resolve("A", "B", album_id="al1", cover_id="al1"), "https://archive.org/x/front.jpg")
        req = opener.open.call_args[0][0]
        self.assertEqual(req.full_url, "https://coverartarchive.org/release/rel-1/front-500")
        self.assertEqual(req.get_method(), "HEAD")

    def test_caa_skipped_without_mbid(self):
        from unittest import mock
        nd = mock.Mock(); nd.album_mbid.return_value = None
        r = ndp.ArtworkResolver(["caa", "itunes"], navidrome=nd)
        r._get_json = lambda url: {"results": [{"collectionName": "B", "artistName": "A", "artworkUrl100": "https://x/100x100bb.jpg"}]}
        self.assertEqual(r.resolve("A", "B", album_id="al1"), "https://x/600x600bb.jpg")

    def test_upload_sends_navidrome_cover_to_uguu(self):
        from unittest import mock
        nd = mock.Mock(); nd.cover_art.return_value = ("image/jpeg", b"JPEGDATA")
        r = ndp.ArtworkResolver(["upload"], navidrome=nd)
        seen = {}
        def fake_urlopen(req, timeout=None):
            seen["url"], seen["body"], seen["ct"] = req.full_url, req.data, req.headers.get("Content-type")
            return _Resp(b'{"success": true, "files": [{"url": "https://n.uguu.se/abc.jpg"}]}')
        with mock.patch.object(ndp.urllib.request, "urlopen", side_effect=fake_urlopen):
            self.assertEqual(r.resolve("A", "B", album_id="al1", cover_id="mf-1"), "https://n.uguu.se/abc.jpg")
        nd.cover_art.assert_called_once_with("mf-1", 600)
        self.assertEqual(seen["url"], "https://uguu.se/upload")
        self.assertIn(b'name="files[]"; filename="cover.jpg"', seen["body"])
        self.assertIn(b"JPEGDATA", seen["body"])
        self.assertTrue(seen["ct"].startswith("multipart/form-data; boundary="))
        # cached for 2.5 h, not forever (uguu deletes after 3 h)
        self.assertLessEqual(r.cache["al1"][1] - time.time(), ndp.ArtworkResolver.UPLOAD_TTL + 1)

    def test_upload_first_then_fallback(self):
        from unittest import mock
        nd = mock.Mock(); nd.cover_art.side_effect = ndp.NavidromeError("down")
        r = ndp.ArtworkResolver(["upload", "itunes"], navidrome=nd)
        r._get_json = lambda url: {"results": [{"collectionName": "B", "artistName": "A", "artworkUrl100": "https://x/100x100bb.jpg"}]}
        self.assertEqual(r.resolve("A", "B", album_id="al1", cover_id="c1"), "https://x/600x600bb.jpg")


class TestSetupWizard(unittest.TestCase):
    def setUp(self):
        self.nav = FakeNavidrome(user="alice", password="p@ss #1;{x}")
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "sub", "config.ini")
        for k in ("ND_URL", "ND_USER", "ND_PASS", "CLIENT_ID", "NDP_COVERS"):
            os.environ.pop(k, None)

    def tearDown(self):
        self.nav.close()

    def run_wizard(self, answers, secrets):
        answers, secrets, said = list(answers), list(secrets), []
        def ask(_):
            if not answers:
                raise EOFError
            return answers.pop(0)
        def ask_secret(_):
            if not secrets:
                raise EOFError
            return secrets.pop(0)
        rc = ndp.cmd_setup(self.path, ask=ask, ask_secret=ask_secret, say=said.append)
        return rc, "\n".join(said)

    def test_happy_path_with_pasted_browser_url(self):
        rc, out = self.run_wizard([self.nav.url + "/app/#/album/1/show", "alice", " 1234567890123456789 ", "n"], ["p@ss #1;{x}"])
        self.assertEqual(rc, 0, out)
        self.assertIn("Found Navidrome", out)
        self.assertEqual(oct(os.stat(self.path).st_mode & 0o777), "0o600")
        cfg, _ = ndp.load_config(self.path)
        self.assertEqual((cfg.url, cfg.username, cfg.password, cfg.client_id), (self.nav.url, "alice", "p@ss #1;{x}", "1234567890123456789"))
        self.assertEqual(cfg.artwork_sources, ["caa", "deezer", "itunes"])
        self.assertEqual((cfg.links, cfg.status_display, cfg.activity_name_template), ("spotify", 2, "{artist} - {track}"))

    def test_saves_the_servers_spelling_of_the_username(self):
        rc, out = self.run_wizard([self.nav.url, "ALICE", "12345678901234567890", "n"], ["p@ss #1;{x}"])
        self.assertEqual(rc, 0, out)
        cfg, _ = ndp.load_config(self.path)
        self.assertEqual(cfg.username, "alice")

    def test_retries_wrong_password_and_defaults_to_navidrome_covers(self):
        rc, out = self.run_wizard([self.nav.url, "alice", "alice", "12345678901234567890", ""], ["wrong", "p@ss #1;{x}"])
        self.assertEqual(rc, 0, out)
        self.assertIn("didn't accept", out)
        cfg, _ = ndp.load_config(self.path)
        self.assertEqual(cfg.artwork_sources, ["upload", "caa", "deezer", "itunes"])

    def test_gives_up_cleanly(self):
        rc, out = self.run_wizard(["http://127.0.0.1:9"], [])
        self.assertEqual(rc, 1)
        self.assertIn("run setup again", out)
        self.assertFalse(os.path.exists(self.path))

    def test_ctrl_c_cancels_without_a_traceback(self):
        import io
        from unittest import mock
        out = io.StringIO()
        with mock.patch.object(ndp, "cmd_setup", side_effect=KeyboardInterrupt), mock.patch.object(ndp.sys, "stdout", out):
            self.assertEqual(ndp.main(["--setup", self.path]), 1)
        self.assertIn("Setup cancelled.", out.getvalue())

    def test_normalize_url(self):
        self.assertEqual(ndp.normalize_url(" 192.168.1.10:4533/ "), "http://192.168.1.10:4533")
        self.assertEqual(ndp.normalize_url("https://music.example.com/app/#/album/x"), "https://music.example.com")
        self.assertEqual(ndp.normalize_url("http://nas:4533/rest/ping.view"), "http://nas:4533")


class TestLogging(unittest.TestCase):
    def tearDown(self):
        ndp.configure_logging(logging.WARNING)

    def test_log_file_when_running_without_a_console(self):
        from unittest import mock
        path = os.path.join(tempfile.mkdtemp(), "sub", "navidrome-presence.log")
        with mock.patch.object(ndp.sys, "stderr", None):
            ndp.configure_logging(logging.INFO, path)
            ndp.log.info("hello from pythonw ✔")
        for h in logging.getLogger().handlers:
            h.flush()
        with open(path, encoding="utf-8") as f:
            self.assertIn("hello from pythonw ✔", f.read())

    def test_main_picks_a_log_file_next_to_the_config_under_pythonw(self):
        from unittest import mock
        d = tempfile.mkdtemp()
        cfgp = os.path.join(d, "config.ini")
        with open(cfgp, "w") as f:
            f.write("[navidrome]\nurl=http://127.0.0.1:9\nusername=a\npassword=b\n[discord]\nclient_id=123\n")
        seen = {}
        with mock.patch.object(ndp.sys, "stderr", None), \
             mock.patch.object(ndp, "configure_logging", side_effect=lambda lvl, lf=None: seen.update(lf=lf)), \
             mock.patch.object(ndp, "cmd_check", return_value=0):
            ndp.main(["-c", cfgp, "--check"])
        self.assertEqual(seen["lf"], os.path.join(d, "navidrome-presence.log"))

    def test_settings_error_under_pythonw_lands_in_the_log(self):
        from unittest import mock
        d = tempfile.mkdtemp()
        cfgp = os.path.join(d, "config.ini")
        with open(cfgp, "w") as f:
            f.write("url = no section header\n")
        with mock.patch.object(ndp.sys, "stderr", None), self.assertRaises(SystemExit):
            ndp.main(["-c", cfgp])
        for h in logging.getLogger().handlers:
            h.flush()
        with open(os.path.join(d, "navidrome-presence.log"), encoding="utf-8") as f:
            self.assertIn("Can't start: Can't read", f.read())


class TestConsoleText(unittest.TestCase):
    class Stream:
        def __init__(self, encoding):
            self.encoding = encoding

    def test_windows_console_gets_plain_check_marks_but_keeps_accents(self):
        from unittest import mock
        with mock.patch.object(ndp.sys, "platform", "win32"):
            out = ndp.console_text("  ✔ Logged in as José — ok", self.Stream("utf-8"))
        self.assertEqual(out, "  OK Logged in as José — ok")

    def test_unencodable_output_is_simplified_instead_of_crashing(self):
        out = ndp.console_text("Navidrome → Discord ✔ 日本", self.Stream("cp1252"))
        self.assertEqual(out, "Navidrome -> Discord OK ??")
        out.encode("cp1252")

    def test_unicode_terminals_are_left_alone(self):
        from unittest import mock
        with mock.patch.object(ndp.sys, "platform", "linux"):
            self.assertEqual(ndp.console_text("  ✔ Found it", self.Stream("utf-8")), "  ✔ Found it")


class TestConfig(unittest.TestCase):
    def write(self, text):
        fd, p = tempfile.mkstemp(suffix=".ini")
        with os.fdopen(fd, "w") as f:
            f.write(text)
        return p

    def test_example_config_parses(self):
        example = os.path.join(os.path.dirname(__file__), "..", "config.example.ini")
        with open(example) as f:
            text = f.read().replace("000000000000000000", "1234567890")
        cfg, _ = ndp.load_config(self.write(text))
        self.assertEqual(cfg.artwork_sources, ["deezer", "itunes"])
        self.assertEqual(cfg.status_display, 2)  # example defaults to the song title
        self.assertEqual(cfg.watch_user, "your-navidrome-username")

    def test_password_with_hash_and_semicolon_survives(self):
        cfg, _ = ndp.load_config(self.write("[navidrome]\nurl=http://x\nusername=a\npassword = p@ss #1; x\n[discord]\nclient_id=123  # my app\n"))
        self.assertEqual(cfg.password, "p@ss #1; x")
        self.assertEqual(cfg.client_id, "123")  # inline comments still work elsewhere

    def test_utf8_bom_from_notepad_is_accepted(self):
        fd, p = tempfile.mkstemp(suffix=".ini")
        with os.fdopen(fd, "w", encoding="utf-8-sig") as f:
            f.write("[navidrome]\nurl=http://x\nusername=a\npassword=pässword\n[discord]\nclient_id=123\n")
        cfg, _ = ndp.load_config(p)
        self.assertEqual((cfg.watch_user, cfg.password), ("a", "pässword"))

    def test_env_override_and_validation(self):
        p = self.write("[navidrome]\nurl=http://x:4533/\nusername=a\npassword=b\n[discord]\nclient_id=123\n")
        os.environ["NDP_DISCORD_STATUS_DISPLAY"] = "artist"
        try:
            cfg, _ = ndp.load_config(p)
        finally:
            del os.environ["NDP_DISCORD_STATUS_DISPLAY"]
        self.assertEqual(cfg.url, "http://x:4533")
        self.assertEqual(cfg.status_display, 1)
        bad = self.write("[navidrome]\nurl=x\nusername=a\npassword=b\n[discord]\nclient_id=123\n")
        with self.assertRaises(SystemExit):
            ndp.load_config(bad)
        good = self.write("[navidrome]\nurl=http://x\nusername=a\npassword=b\n[discord]\nclient_id=123\nactivity_name=custom\n[artwork]\nsources=upload, caa, deezer\n")
        cfg, _ = ndp.load_config(good)
        self.assertEqual((cfg.activity_name, cfg.artwork_sources, cfg.paused_image), ("custom", ["upload", "caa", "deezer"], ndp.PAUSE_ICON))
        for bad_line in ("[discord]\nclient_id=123\nactivity_name=song\n", "[discord]\nclient_id=123\n[artwork]\nsources=flickr\n"):
            with self.assertRaises(SystemExit):
                ndp.load_config(self.write("[navidrome]\nurl=http://x\nusername=a\npassword=b\n" + bad_line))


if __name__ == "__main__":
    unittest.main()
