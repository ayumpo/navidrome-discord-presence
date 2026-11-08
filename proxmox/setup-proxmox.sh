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
