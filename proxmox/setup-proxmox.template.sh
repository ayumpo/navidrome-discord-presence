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
__PAYLOAD__
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
