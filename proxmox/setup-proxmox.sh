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
