#!/usr/bin/env bash
# navidrome-discord-presence — Linux desktop installer (for the computer where you use Discord)
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/ayumpo/navidrome-discord-presence/main/install-linux.sh)"
#
# Asks a few questions, then runs in the background and starts when you log in.
# Run it again to update. Remove with:  bash -c "$(curl -fsSL …/install-linux.sh)" -- --uninstall
# (For an always-on server, use the Proxmox one-liner instead — see the README.)
set -euo pipefail

REPO_RAW="${NDP_REPO_RAW:-https://raw.githubusercontent.com/ayumpo/navidrome-discord-presence/main}"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/navidrome-presence"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/navidrome-presence/config.ini"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="$UNIT_DIR/navidrome-presence.service"
AUTOSTART="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/navidrome-presence.desktop"
HERE=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; fi

ok()   { printf ' \033[32m✔\033[0m %s\n' "$*"; }
info() { printf ' \033[36m•\033[0m %s\n' "$*"; }
warn() { printf ' \033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf ' \033[31m✘\033[0m %s\n' "$*" >&2; exit 1; }

have_user_systemd() { command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; }

if [[ "${1:-}" == "--uninstall" ]]; then
  if have_user_systemd; then systemctl --user disable --now navidrome-presence.service 2>/dev/null || true; fi
  pkill -f "$APP_DIR/navidrome_presence.py" 2>/dev/null || true
  rm -f "$UNIT" "$AUTOSTART"
  have_user_systemd && systemctl --user daemon-reload || true
  ok "Removed. Your settings are still in $(dirname "$CONFIG") (delete it to remove them too)."
  exit 0
fi

[[ $EUID -ne 0 ]] || die "Run this as your normal user (not root/sudo) — Discord runs in your desktop session."
[[ "$(uname -s)" == Linux ]] || die "This installer is for Linux. On a Mac use install-macos.sh."

echo
printf '\033[1m%s\033[0m\n' "Navidrome → Discord presence  ·  Linux setup"
echo

PYTHON="$(command -v python3 || true)"
if [[ -z "$PYTHON" ]] || ! "$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 7))' 2>/dev/null; then
  die "Python 3.7+ is needed. Install it with your package manager (e.g. sudo apt install python3) and run this again."
fi
command -v curl >/dev/null || [[ -n "$HERE" ]] || die "curl is needed (e.g. sudo apt install curl)."

mkdir -p "$APP_DIR" "$(dirname "$CONFIG")"
for f in navidrome_presence.py config.example.ini; do
  if [[ -n "$HERE" && -f "$HERE/$f" ]]; then
    cp "$HERE/$f" "$APP_DIR/$f"
  else
    curl -fsSL "$REPO_RAW/$f" -o "$APP_DIR/$f.new" || die "Couldn't download $f — are you online?"
    mv "$APP_DIR/$f.new" "$APP_DIR/$f"
  fi
done
"$PYTHON" -c "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())" "$APP_DIR/navidrome_presence.py" || die "The download looks damaged — please run this again."
ok "Installed the latest version in $APP_DIR"

if [[ -f "$CONFIG" && "${RECONFIGURE:-0}" != 1 ]]; then
  ok "Keeping your existing settings (to change them: RECONFIGURE=1 and run again)"
else
  "$PYTHON" "$APP_DIR/navidrome_presence.py" --setup "$CONFIG" || die "Setup didn't finish — run the command again to retry."
fi
chmod 600 "$CONFIG"

echo
info "Testing — if Discord is open, a test status appears on your profile for 15 seconds…"
"$PYTHON" "$APP_DIR/navidrome_presence.py" -c "$CONFIG" --check || die "The test failed — see the message above."

if have_user_systemd; then
  mkdir -p "$UNIT_DIR"
  cat > "$UNIT" <<EOF
[Unit]
Description=Navidrome to Discord Rich Presence (local IPC, no token)
After=graphical-session.target network-online.target

[Service]
ExecStart=$PYTHON $APP_DIR/navidrome_presence.py -c $CONFIG
Restart=on-failure
RestartSec=30

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable navidrome-presence.service >/dev/null 2>&1
  systemctl --user restart navidrome-presence.service
  ok "Running in the background (systemd user service)"
  LOGS="journalctl --user -u navidrome-presence -f"
else
  mkdir -p "$(dirname "$AUTOSTART")"
  cat > "$AUTOSTART" <<EOF
[Desktop Entry]
Type=Application
Name=Navidrome Discord presence
Exec=$PYTHON "$APP_DIR/navidrome_presence.py" -c "$CONFIG"
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF
  pkill -f "$APP_DIR/navidrome_presence.py" 2>/dev/null || true
  nohup "$PYTHON" "$APP_DIR/navidrome_presence.py" -c "$CONFIG" >/dev/null 2>&1 &
  ok "Running in the background (desktop autostart)"
  LOGS="$PYTHON $APP_DIR/navidrome_presence.py -c $CONFIG -v   (runs in the foreground)"
fi

echo
ok "All set! It starts automatically when you log in."
echo "   • In Discord: Settings → Activity Privacy → turn on \"Share my activity\"."
echo "   • The Discord desktop app must be running (Flatpak, Snap and Vesktop work too)."
echo "   • Logs: $LOGS"
