#!/bin/bash
# navidrome-discord-presence — Mac installer
#
# Paste this into the Terminal app:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/ayumpo/navidrome-discord-presence/main/install-macos.sh)"
#
# It asks a few questions, then runs quietly in the background and starts when you log in.
# Run the same command again to update. To remove it, add --uninstall at the end:
#   bash -c "$(curl -fsSL …/install-macos.sh)" -- --uninstall
set -euo pipefail

REPO_RAW="${NDP_REPO_RAW:-https://raw.githubusercontent.com/ayumpo/navidrome-discord-presence/main}"
LABEL="io.github.ayumpo.navidrome-presence"
APP_DIR="$HOME/Library/Application Support/navidrome-presence"
CONFIG="$APP_DIR/config.ini"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/navidrome-presence.log"
DOMAIN="gui/$(id -u)"
HERE=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; fi

ok()   { printf ' \033[32m✔\033[0m %s\n' "$*"; }
info() { printf ' \033[36m•\033[0m %s\n' "$*"; }
warn() { printf ' \033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf ' \033[31m✘\033[0m %s\n' "$*" >&2; exit 1; }

unload() { launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true; }

if [[ "${1:-}" == "--uninstall" ]]; then
  unload
  rm -f "$PLIST"
  ok "Removed. Your settings are still in: $APP_DIR (delete that folder to remove them too)."
  exit 0
fi

[[ "$(uname -s)" == Darwin ]] || die "This installer is for macOS. On Linux use install-linux.sh."

echo
printf '\033[1m%s\033[0m\n' "Navidrome → Discord presence  ·  Mac setup"
echo

# Python ships with Apple's Command Line Tools; macOS offers to install them on first use.
if ! xcode-select -p >/dev/null 2>&1; then
  warn "macOS needs its free \"Command Line Tools\" (they include Python)."
  echo "   A window will pop up — click Install, wait until it finishes, then run this command again."
  xcode-select --install >/dev/null 2>&1 || true
  exit 1
fi
PYTHON="$(command -v python3 || true)"
if [[ -z "$PYTHON" ]] || ! "$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 7))' 2>/dev/null; then
  die "Python 3.7+ wasn't found. Install it from https://www.python.org/downloads/ and run this again."
fi

mkdir -p "$APP_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
for f in navidrome_presence.py config.example.ini; do
  if [[ -n "$HERE" && -f "$HERE/$f" ]]; then
    cp "$HERE/$f" "$APP_DIR/$f"
  else
    curl -fsSL "$REPO_RAW/$f" -o "$APP_DIR/$f.new" || die "Couldn't download $f — are you online?"
    mv "$APP_DIR/$f.new" "$APP_DIR/$f"
  fi
done
"$PYTHON" -c "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())" "$APP_DIR/navidrome_presence.py" || die "The download looks damaged — please run this again."
ok "Installed the latest version"

if [[ -f "$CONFIG" && "${RECONFIGURE:-0}" != 1 ]]; then
  ok "Keeping your existing settings (to change them: RECONFIGURE=1 and run again)"
else
  "$PYTHON" "$APP_DIR/navidrome_presence.py" --setup "$CONFIG" || die "Setup didn't finish — run the command again to retry."
fi
chmod 600 "$CONFIG"

echo
if ! pgrep -xq Discord; then
  if [[ -d "/Applications/Discord.app" ]]; then
    info "Opening Discord (it can stay in the background)…"
    open -ga Discord || true
    sleep 8
  else
    warn "The Discord app isn't installed. Get it from https://discord.com/download — this keeps working once it's open."
  fi
fi
info "Testing — a test status appears on your Discord profile for 15 seconds…"
"$PYTHON" "$APP_DIR/navidrome_presence.py" -c "$CONFIG" --check || die "The test failed — see the message above."

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PYTHON</string>
    <string>$APP_DIR/navidrome_presence.py</string>
    <string>-c</string>
    <string>$CONFIG</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>ProcessType</key><string>Background</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
unload
launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST"

echo
ok "All set! It runs in the background and starts when you log in."
echo "   • In Discord: Settings → Activity Privacy → turn on \"Share my activity\"."
echo "   • Discord must be open (a window isn't needed). Tip: System Settings → General → Login Items → add Discord."
echo "   • Logs: $LOG"
