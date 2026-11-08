#!/usr/bin/env bash
# navidrome-presence — installer for a Proxmox LXC (Debian 12+/Ubuntu 22.04+, x86_64)
#
# Runs the OFFICIAL Discord desktop app on a virtual screen inside this container and
# feeds it your Navidrome "now playing" over Discord's local Rich Presence IPC.
# No Discord token is ever read, stored or sent — you log in to Discord once yourself
# through a browser (noVNC), exactly like on a normal computer.
#
# Easiest: don't run this directly — run the one-liner from the README on your Proxmox HOST,
# which creates the container and runs this for you.
#
#   bash setup-proxmox.sh               install or update (safe to re-run; keeps your settings)
#   RECONFIGURE=1 bash setup-proxmox.sh   re-enter the Navidrome / Discord settings
#   bash setup-proxmox.sh --uninstall   remove services (keeps settings and Discord login)
#   bash setup-proxmox.sh --purge       remove everything, including the Discord login
#
# Download first, then run (don't pipe curl into bash — apt can swallow the rest of the script).
set -euo pipefail

APP=/opt/navidrome-presence
ETC=/etc/navidrome-presence
SVC_USER=discord
SVC_HOME=/var/lib/discord-headless
NOVNC_PORT="${NOVNC_PORT:-6080}"
UNITS=(discord-xvfb discord-client discord-vnc navidrome-presence discord-update)

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m✘\033[0m %s\n' "$*" >&2; exit 1; }

TTY=/dev/tty
[[ -r $TTY ]] || TTY=/dev/stdin
ask() {         # ask "Prompt" "default"
  local reply=""
  if [[ -n "${2:-}" ]]; then printf '%s [%s]: ' "$1" "$2" >&2; else printf '%s: ' "$1" >&2; fi
  IFS= read -r reply < "$TTY" || true
  printf '%s' "${reply:-${2:-}}"
}
ask_secret() {
  local reply=""
  printf '%s: ' "$1" >&2
  IFS= read -rs reply < "$TTY" || true
  printf '\n' >&2
  printf '%s' "$reply"
}

uninstall() {
  local purge="${1:-}"
  for u in "${UNITS[@]}"; do systemctl disable --now "$u.service" 2>/dev/null || true; done
  systemctl disable --now discord-update.timer 2>/dev/null || true
  rm -f /etc/systemd/system/{discord-xvfb,discord-client,discord-vnc,navidrome-presence,discord-update}.service \
        /etc/systemd/system/discord-update.timer /usr/local/bin/navidrome-presence-{login,check,logs,config}
  systemctl daemon-reload
  rm -rf "$APP"
  if [[ "$purge" == purge ]]; then
    rm -rf "$ETC"
    userdel -r "$SVC_USER" 2>/dev/null || rm -rf "$SVC_HOME"
    apt-get remove -y -qq discord >/dev/null 2>&1 || true
    ok "Removed everything, including the Discord login."
  else
    ok "Removed the services. Kept $ETC (settings) and $SVC_HOME (Discord login). Use --purge to remove those too."
  fi
}

case "${1:-}" in
  --uninstall) [[ $EUID -eq 0 ]] || die "Run as root"; uninstall; exit 0 ;;
  --purge)     [[ $EUID -eq 0 ]] || die "Run as root"; uninstall purge; exit 0 ;;
  "") ;;
  *) die "Unknown option: $1" ;;
esac

# ── preflight ───────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run this as root inside the container."
command -v apt-get >/dev/null || die "This installer needs a Debian or Ubuntu container."
[[ "$(dpkg --print-architecture)" == amd64 ]] || die "Discord's Linux app is x86_64 (amd64) only."
[[ -d /run/systemd/system ]] || die "systemd is required."
mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
if (( mem_mb < 1500 )); then
  warn "This container has ${mem_mb} MB of RAM. Discord needs about 1 GB — set Memory to 2048 MB in Proxmox (container → Resources)."
fi

bold "navidrome-presence for Proxmox"
echo "Installs the official Discord app on a virtual screen + the presence companion. No Discord token involved."
echo

# ── packages ────────────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
echo "Installing packages (a few minutes the first time)…"
apt-get update -qq </dev/null
apt-get install -y -qq --no-install-recommends \
  ca-certificates curl gzip tar python3 util-linux dbus dbus-x11 nano \
  xvfb openbox x11vnc novnc websockify \
  fonts-dejavu-core fonts-noto-color-emoji libgl1-mesa-dri xdg-utils \
  libpulse0 </dev/null >/dev/null   # libpulse0: without it Discord shows an "installation is corrupt" banner
ok "System packages"

# ── service user ────────────────────────────────────────────────────────────
if ! id "$SVC_USER" >/dev/null 2>&1; then
  useradd --system --create-home --home-dir "$SVC_HOME" --shell /usr/sbin/nologin "$SVC_USER"
fi
ok "User '$SVC_USER' (home $SVC_HOME)"

# ── app files ───────────────────────────────────────────────────────────────
install -d -m 755 "$APP"
# Embedded: navidrome_presence.py, config.example.ini, README.md
base64 -d <<'__NDP_PAYLOAD__' | tar -xz -C "$APP" --no-same-owner
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
AQA=
__NDP_PAYLOAD__
chmod 755 "$APP/navidrome_presence.py"

cat > "$APP/update-discord.sh" <<'EOF'
#!/usr/bin/env bash
# Installs/updates the official Discord .deb.
#   no args:    exit 0 = already current, 10 = installed/updated
#   --restart:  also restart the headless client after an update; exit 0 on success
set -euo pipefail
url=$(curl -fsSL -r 0-0 -o /dev/null -w '%{url_effective}' "https://discord.com/api/download?platform=linux&format=deb")
latest=$(basename "$url" .deb); latest=${latest#discord-}
current=$(dpkg-query -W -f='${Version}' discord 2>/dev/null || true)
if [[ -n "$latest" && "$latest" == "$current" ]]; then echo "Discord $current is current"; exit 0; fi
tmp=$(mktemp --suffix=.deb); trap 'rm -f "$tmp"' EXIT
curl -fsSL "$url" -o "$tmp"
chmod 644 "$tmp"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$tmp" </dev/null >/dev/null
echo "Discord ${current:-none} -> $(dpkg-query -W -f='${Version}' discord)"
if [[ "${1:-}" == --restart ]]; then systemctl restart discord-client.service; exit 0; fi
exit 10
EOF

cat > "$APP/run-discord.sh" <<'EOF'
#!/usr/bin/env bash
# Starts the official Discord client on the virtual screen.
export DISPLAY=:99
for _ in $(seq 50); do [[ -S /tmp/.X11-unix/X99 ]] && break; sleep 0.2; done
openbox >/dev/null 2>&1 &
flags=(--disable-gpu)
# Chromium's sandbox needs user namespaces; unprivileged LXCs often don't allow them.
unshare -Ur true 2>/dev/null || flags+=(--no-sandbox)
exec dbus-run-session -- /usr/bin/discord "${flags[@]}"
EOF
chmod 755 "$APP/update-discord.sh" "$APP/run-discord.sh"
ok "Companion installed in $APP"

# ── Discord ─────────────────────────────────────────────────────────────────
echo "Downloading the official Discord app…"
set +e; "$APP/update-discord.sh" </dev/null; rc=$?; set -e
(( rc == 0 || rc == 10 )) || die "Couldn't download/install Discord (exit $rc). Check the container's internet access."
# Don't let Discord's 'update available' screen block a headless client; the weekly timer updates it instead.
install -d -o "$SVC_USER" -g "$SVC_USER" "$SVC_HOME/.config/discord"
python3 - "$SVC_HOME/.config/discord/settings.json" <<'EOF'
import json, sys, os
p = sys.argv[1]
try:
    s = json.load(open(p))
except Exception:
    s = {}
s["SKIP_HOST_UPDATE"] = True
json.dump(s, open(p, "w"), indent=2)
EOF
chown "$SVC_USER:$SVC_USER" "$SVC_HOME/.config/discord/settings.json"
ok "Discord $(dpkg-query -W -f='${Version}' discord)"

# ── settings ────────────────────────────────────────────────────────────────
install -d -m 750 -o root -g "$SVC_USER" "$ETC"
chown root:"$SVC_USER" "$ETC"; chmod 750 "$ETC"
if [[ -n "${NDP_CONFIG_FILE:-}" && -f "${NDP_CONFIG_FILE}" ]]; then
  # Settings handed over by the Proxmox host one-liner (create-lxc.sh).
  install -m 640 -o root -g "$SVC_USER" "$NDP_CONFIG_FILE" "$ETC/config.ini"
  rm -f "$NDP_CONFIG_FILE"
elif [[ ! -f "$ETC/config.ini" || "${RECONFIGURE:-0}" == 1 ]]; then
  echo
  bold "Settings"
  echo "Navidrome: use the address THIS container can reach (e.g. http://192.168.1.10:4533)."
  ND_URL=${ND_URL:-$(ask "Navidrome URL" "http://")}
  ND_USER=${ND_USER:-$(ask "Navidrome username")}
  ND_PASS=${ND_PASS:-$(ask_secret "Navidrome password (hidden)")}
  echo
  echo "Discord Application ID — one-time, 2 minutes:"
  echo "  1. Open https://discord.com/developers/applications and log in"
  echo "  2. Click 'New Application', name it what should follow \"Listening to\" (e.g. Navidrome), click Create"
  echo "  3. Copy the 'Application ID' and paste it here"
  CLIENT_ID=${CLIENT_ID:-$(ask "Discord Application ID")}
  [[ "$CLIENT_ID" =~ ^[0-9]{15,22}$ ]] || warn "That doesn't look like an Application ID (a long number). You can fix it later in $ETC/config.ini"
  if [[ -z "${SOURCES:-}" ]]; then
    echo
    echo "Album art: show the covers from your own Navidrome? They're uploaded to uguu.se, a temporary"
    echo "image host that deletes them after 3 hours. Otherwise covers are looked up on Deezer/iTunes."
    case "$(ask "Use your Navidrome covers? (Y/n)" "Y")" in
      [Nn]*) SOURCES="caa, deezer, itunes" ;;
      *)     SOURCES="upload, caa, deezer, itunes" ;;
    esac
  fi
  ND_URL="$ND_URL" ND_USER="$ND_USER" ND_PASS="$ND_PASS" CLIENT_ID="$CLIENT_ID" SOURCES="$SOURCES" \
  python3 - "$ETC/config.ini" <<'EOF'
import configparser, os, sys
cp = configparser.ConfigParser(interpolation=None)
cp["navidrome"] = {"url": os.environ["ND_URL"].rstrip("/"), "username": os.environ["ND_USER"],
                   "password": os.environ["ND_PASS"]}
cp["discord"] = {"client_id": os.environ["CLIENT_ID"], "status_display": "track", "activity_name": "app",
                 "activity_name_template": "{artist} - {track}", "on_pause": "show",
                 "show_album_in_state": "false", "links": "spotify"}
cp["artwork"] = {"sources": os.environ["SOURCES"], "fallback_image": "https://raw.githubusercontent.com/navidrome/navidrome/master/ui/public/android-chrome-512x512.png"}
cp["general"] = {"poll_interval": "5", "stop_grace": "12", "log_level": "INFO"}
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o640)
with os.fdopen(fd, "w") as f:
    f.write("# navidrome-presence settings — every option is explained in /opt/navidrome-presence/config.example.ini\n")
    f.write("# After editing: systemctl restart navidrome-presence   (or just run navidrome-presence-config)\n")
    cp.write(f)
EOF
  unset ND_PASS
fi
chown root:"$SVC_USER" "$ETC/config.ini"; chmod 640 "$ETC/config.ini"
ok "Settings in $ETC/config.ini"

nd_check=$(runuser -u "$SVC_USER" -- python3 - "$APP" "$ETC/config.ini" <<'EOF' 2>&1
import sys
sys.path.insert(0, sys.argv[1])
import navidrome_presence as n
try:
    c, _ = n.load_config(sys.argv[2])
    r = n.Navidrome(c.url, c.username, c.password).ping()
    print(f"OK {r.get('type', 'server')} {r.get('serverVersion', '')}")
except SystemExit as e:
    print(f"FAIL {e}")
except Exception as e:
    print(f"FAIL {e}")
EOF
) || true
if [[ "$nd_check" == OK* ]]; then
  ok "Navidrome login works (${nd_check#OK })"
else
  warn "Navidrome check failed: ${nd_check#FAIL }"
  warn "Fix it afterwards with  navidrome-presence-config  — the rest of the install continues."
fi

# ── systemd ─────────────────────────────────────────────────────────────────
cat > /etc/systemd/system/discord-xvfb.service <<EOF
[Unit]
Description=Virtual screen for headless Discord
[Service]
User=$SVC_USER
ExecStart=/usr/bin/Xvfb :99 -screen 0 1280x800x24 -nolisten tcp
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/discord-client.service <<EOF
[Unit]
Description=Official Discord desktop app (headless, for Rich Presence)
Requires=discord-xvfb.service
After=discord-xvfb.service network-online.target
Wants=network-online.target
[Service]
User=$SVC_USER
WorkingDirectory=$SVC_HOME
Environment=HOME=$SVC_HOME
ExecStart=$APP/run-discord.sh
Restart=always
RestartSec=15
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/discord-vnc.service <<EOF
[Unit]
Description=Temporary browser access to the headless Discord screen (noVNC)
Requires=discord-xvfb.service
After=discord-xvfb.service
[Service]
User=$SVC_USER
ExecStart=/bin/sh -c 'x11vnc -display :99 -rfbauth $ETC/vncpass -localhost -rfbport 5900 -forever -shared -quiet -noxdamage & exec websockify --web /usr/share/novnc $NOVNC_PORT localhost:5900'
# Shuts itself off after 30 minutes; run navidrome-presence-login to open it again.
RuntimeMaxSec=1800
Restart=no
EOF

cat > /etc/systemd/system/navidrome-presence.service <<EOF
[Unit]
Description=Navidrome to Discord Rich Presence (local IPC, no token)
After=discord-client.service network-online.target
Wants=discord-client.service network-online.target
[Service]
User=$SVC_USER
Environment=HOME=$SVC_HOME
ExecStart=/usr/bin/python3 $APP/navidrome_presence.py -c $ETC/config.ini
Restart=always
RestartSec=15
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/discord-update.service <<EOF
[Unit]
Description=Update the headless Discord app
After=network-online.target
[Service]
Type=oneshot
ExecStart=$APP/update-discord.sh --restart
EOF

cat > /etc/systemd/system/discord-update.timer <<EOF
[Unit]
Description=Weekly update check for the headless Discord app
[Timer]
OnCalendar=weekly
RandomizedDelaySec=6h
Persistent=true
[Install]
WantedBy=timers.target
EOF

# ── helper commands ─────────────────────────────────────────────────────────
cat > /usr/local/bin/navidrome-presence-login <<EOF
#!/usr/bin/env bash
# Opens the Discord screen in your browser for 30 minutes with a fresh one-time password.
set -euo pipefail
pass=\$(python3 -c "import secrets; a='ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'; print(''.join(secrets.choice(a) for _ in range(8)))")
x11vnc -storepasswd "\$pass" $ETC/vncpass >/dev/null 2>&1
chown root:$SVC_USER $ETC/vncpass; chmod 640 $ETC/vncpass
systemctl restart discord-vnc.service
ip=\$(hostname -I | awk '{print \$1}')
echo
echo "  Open:      http://\$ip:$NOVNC_PORT/vnc.html?autoconnect=1&resize=scale"
echo "  Password:  \$pass"
echo "  (closes automatically in 30 minutes, or: systemctl stop discord-vnc)"
echo
EOF

cat > /usr/local/bin/navidrome-presence-check <<EOF
#!/usr/bin/env bash
# Tests Navidrome + the Discord connection; puts a test status on your profile for 15 s.
exec runuser -u $SVC_USER -- python3 $APP/navidrome_presence.py -c $ETC/config.ini --check
EOF

cat > /usr/local/bin/navidrome-presence-logs <<'EOF'
#!/usr/bin/env bash
exec journalctl -u navidrome-presence -u discord-client -n 50 -f
EOF

cat > /usr/local/bin/navidrome-presence-config <<EOF
#!/usr/bin/env bash
# Edit the settings, then restart the companion so they take effect.
\${EDITOR:-nano} $ETC/config.ini && systemctl restart navidrome-presence.service && echo "Restarted navidrome-presence."
EOF
chmod 755 /usr/local/bin/navidrome-presence-{login,check,logs,config}

systemctl daemon-reload
systemctl enable --now discord-xvfb.service >/dev/null 2>&1
systemctl enable discord-client.service navidrome-presence.service discord-update.timer >/dev/null 2>&1
systemctl restart discord-client.service navidrome-presence.service
systemctl start discord-update.timer
ok "Services enabled (start automatically with the container)"

# ── next steps ──────────────────────────────────────────────────────────────
echo
if [[ "${NDP_SKIP_LOGIN:-0}" == 1 ]]; then
  ok "Update complete — Discord stays logged in."
  echo "Need the Discord screen again (e.g. after a logout)? Run:  navidrome-presence-login"
  exit 0
fi
bold "Last step: log in to Discord once (skip if you already did on a previous install)"
/usr/local/bin/navidrome-presence-login
echo "In that browser tab, scan the QR code with the Discord app on your phone (or log in normally)."
echo "Then close the tab. To confirm everything works, play a song and run:  navidrome-presence-check"
echo "Nothing on your profile? Discord → Settings → Activity Privacy → turn on \"Share my activity\"."
echo
echo "Later:  navidrome-presence-logs   ·   navidrome-presence-config   ·   navidrome-presence-login"
