#!/usr/bin/env bash
# navidrome-discord-presence — one-command setup for Proxmox VE
#
# Run this on your Proxmox HOST (web UI → Datacenter → your node → Shell):
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/ayumpo/navidrome-discord-presence/main/proxmox/create-lxc.sh)"
#
# It asks a few questions, creates a small container, installs the official Discord app on a
# virtual screen plus the presence companion, and prints a link where you log in to Discord once.
# Run it again any time to update an existing install. No Discord token is ever used.
#
# Optional overrides (environment variables):
#   NDP_HOSTNAME=discord-presence  NDP_MEMORY=2048  NDP_DISK=8  NDP_CORES=2  NDP_BRIDGE=vmbr0
#   NDP_STORAGE=<rootfs storage>   NDP_TEMPLATE_STORAGE=<template storage>  NDP_CTID=<id>
set -euo pipefail

REPO_RAW="${NDP_REPO_RAW:-https://raw.githubusercontent.com/ayumpo/navidrome-discord-presence/main}"
CT_HOSTNAME="${NDP_HOSTNAME:-discord-presence}"
MEMORY="${NDP_MEMORY:-2048}"
DISK="${NDP_DISK:-8}"
CORES="${NDP_CORES:-2}"
BRIDGE="${NDP_BRIDGE:-vmbr0}"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf ' \033[32m✔\033[0m %s\n' "$*"; }
info() { printf ' \033[36m•\033[0m %s\n' "$*"; }
warn() { printf ' \033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf ' \033[31m✘\033[0m %s\n' "$*" >&2; exit 1; }

TTY=/dev/tty
[[ -r $TTY ]] || TTY=/dev/stdin
ask() {         # ask "Question" "default"
  local reply=""
  if [[ -n "${2:-}" ]]; then printf ' %s [%s]: ' "$1" "$2" >&2; else printf ' %s: ' "$1" >&2; fi
  IFS= read -r reply < "$TTY" || true
  printf '%s' "${reply:-${2:-}}"
}
ask_secret() {
  local reply=""
  printf ' %s: ' "$1" >&2
  IFS= read -rs reply < "$TTY" || true
  printf '\n' >&2
  printf '%s' "$reply"
}
yes_no() {      # yes_no "Question" Y|N  → exit status 0 for yes
  local def="$2" reply=""
  [[ "${NDP_YES:-0}" == 1 ]] && return 0
  reply=$(ask "$1 ($( [[ $def == Y ]] && echo "Y/n" || echo "y/N" ))" "")
  reply=${reply:-$def}
  [[ $reply == [Yy]* ]]
}

# ── preflight ───────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Please run this as root on the Proxmox host."
command -v pct >/dev/null && command -v pveam >/dev/null \
  || die "This must run on the Proxmox HOST shell (Datacenter → your node → Shell), not inside a container."
command -v curl >/dev/null || die "curl is missing (apt install curl)."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
umask 077

fetch_installer() {
  curl -fsSL "$REPO_RAW/proxmox/setup-proxmox.sh" -o "$tmp/setup-proxmox.sh" \
    || die "Couldn't download the installer from GitHub. Is the Proxmox host online?"
  bash -n "$tmp/setup-proxmox.sh" || die "The downloaded installer looks damaged — please try again."
}

wait_for_network() {
  local id=$1
  for _ in $(seq 45); do
    pct exec "$id" -- getent hosts deb.debian.org >/dev/null 2>&1 && return 0
    sleep 2
  done
  die "Container $id has no internet access. Check its network (DHCP on bridge $BRIDGE)."
}

run_installer() {   # run_installer <ctid> [VAR=value ...]
  local id=$1; shift
  pct push "$id" "$tmp/setup-proxmox.sh" /root/setup-proxmox.sh --perms 700
  pct exec "$id" -- env "$@" bash /root/setup-proxmox.sh
}

echo
bold "Navidrome → Discord presence  ·  Proxmox setup"
echo "  Shows what you play on Navidrome as your Discord status, 24/7, without a Discord token."
echo

# ── existing install? → update ──────────────────────────────────────────────
existing=$(pct list 2>/dev/null | awk -v h="$CT_HOSTNAME" 'NR>1 && $NF==h {print $1; exit}')
if [[ -n "$existing" ]]; then
  info "Found an existing install: container $existing ($CT_HOSTNAME)."
  if ! yes_no "Update it to the latest version? Your settings and Discord login are kept." Y; then
    echo " Nothing changed."; exit 0
  fi
  [[ "$(pct status "$existing" | awk '{print $2}')" == running ]] || pct start "$existing"
  wait_for_network "$existing"
  fetch_installer
  run_installer "$existing" NDP_SKIP_LOGIN=1
  echo
  ok "Updated container $existing. Nothing else to do."
  exit 0
fi

# ── questions ───────────────────────────────────────────────────────────────
bold "1/5  Your Navidrome server"
echo "  The address you open Navidrome with on your home network, e.g. http://192.168.1.10:4533"
for attempt in 1 2 3; do
  ND_URL=${ND_URL:-$(ask "Navidrome address" "")}
  ND_URL=$(printf '%s' "$ND_URL" | tr -d '[:space:]')
  if [[ -z "$ND_URL" ]]; then
    warn "Please type your Navidrome address."
    [[ $attempt == 3 ]] && die "No address given — run this again when you have it."
    continue
  fi
  ND_URL=${ND_URL%%/app*}; ND_URL=${ND_URL%/}
  [[ "$ND_URL" =~ ^https?:// ]] || ND_URL="http://$ND_URL"
  if curl -fsS -m 8 "$ND_URL/rest/ping.view?f=json" 2>/dev/null | grep -q 'subsonic-response'; then
    ok "Found Navidrome at $ND_URL"; break
  fi
  warn "Couldn't reach a Navidrome server at $ND_URL from this Proxmox host."
  [[ $attempt == 3 ]] && die "Check the address (including the :port) and run this again."
  ND_URL=""
done

echo
bold "2/5  Your Navidrome login"
echo "  Whose listening should appear on Discord. The password stays on your server."
for attempt in 1 2 3; do
  ND_USER=${ND_USER:-$(ask "Navidrome username" "")}
  ND_PASS=${ND_PASS:-$(ask_secret "Navidrome password (hidden as you type)")}
  salt=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
  token=$(printf '%s%s' "$ND_PASS" "$salt" | md5sum | cut -d' ' -f1)
  if curl -fsS -m 8 --get "$ND_URL/rest/ping.view" \
       --data-urlencode "u=$ND_USER" --data-urlencode "t=$token" --data-urlencode "s=$salt" \
       --data-urlencode "v=1.16.1" --data-urlencode "c=navidrome-presence" --data-urlencode "f=json" 2>/dev/null \
       | grep -Eq '"status" *: *"ok"'; then
    ok "Logged in as $ND_USER"; break
  fi
  warn "Navidrome didn't accept that username/password."
  [[ $attempt == 3 ]] && die "Please double-check the login and run this again."
  ND_USER=""; ND_PASS=""
done

echo
bold "3/5  Your Discord application (one-time, about 2 minutes)"
echo "  Discord needs an \"application\" to show the status. It's free and just a name:"
echo "    1. On any computer, open  https://discord.com/developers/applications  and log in"
echo "    2. Click \"New Application\", type a name — it appears after \"Listening to\" (e.g. Navidrome)"
echo "    3. Tick the box, click Create, then click \"Copy\" next to \"Application ID\""
for attempt in 1 2 3; do
  CLIENT_ID=${CLIENT_ID:-$(ask "Paste the Application ID" "")}
  CLIENT_ID=$(printf '%s' "$CLIENT_ID" | tr -dc '0-9')
  if [[ "$CLIENT_ID" =~ ^[0-9]{17,20}$ ]]; then ok "Application ID looks good"; break; fi
  warn "That doesn't look like an Application ID (a 17–20 digit number)."
  [[ $attempt == 3 ]] && die "Copy the Application ID from the Developer Portal and run this again."
  CLIENT_ID=""
done

echo
bold "4/5  Album art"
echo "  Show the covers from your own Navidrome? They're uploaded to uguu.se, a temporary image host"
echo "  that deletes them after 3 hours. Otherwise covers are looked up on Deezer and iTunes."
if [[ -n "${NDP_COVERS:-}" ]]; then covers=$NDP_COVERS
elif yes_no "Use your Navidrome covers?" Y; then covers=y; else covers=n; fi
if [[ $covers == [Yy]* ]]; then SOURCES="upload, caa, deezer, itunes"; else SOURCES="caa, deezer, itunes"; fi

# ── pick storage, template, id ──────────────────────────────────────────────
pick_storage() {   # pick_storage <content> <preferred>
  local content=$1 preferred=$2
  local list; list=$(pvesm status -content "$content" 2>/dev/null | awk 'NR>1 && $3=="active" {print $1, $6}')
  [[ -n "$list" ]] || return 1
  if awk -v p="$preferred" '$1==p {f=1} END {exit !f}' <<<"$list"; then echo "$preferred"; return; fi
  sort -k2 -n -r <<<"$list" | head -1 | cut -d' ' -f1
}
RSTORE=${NDP_STORAGE:-$(pick_storage rootdir local-lvm)} || die "No storage for containers found."
TSTORE=${NDP_TEMPLATE_STORAGE:-$(pick_storage vztmpl local)} || die "No storage for templates found."
CTID=${NDP_CTID:-$(pvesh get /cluster/nextid)}

echo
bold "5/5  Ready to create the container"
echo "  Container $CTID \"$CT_HOSTNAME\": Debian, ${MEMORY} MB RAM, ${DISK} GB disk on $RSTORE, network $BRIDGE (DHCP)"
echo "  Navidrome $ND_URL as $ND_USER · Discord app $CLIENT_ID · covers: $( [[ $covers == [Yy]* ]] && echo "your Navidrome" || echo "Deezer/iTunes")"
yes_no "Create it now?" Y || { echo " Cancelled — nothing was changed."; exit 0; }

echo
info "Getting the Debian template (first time only)…"
pveam update >/dev/null 2>&1 || warn "Couldn't refresh the template list; using what's known."
TEMPLATE=""
for v in 13 12; do
  TEMPLATE=$(pveam available --section system 2>/dev/null | awk '{print $2}' \
             | grep -E "^debian-${v}-standard_.*_amd64\.tar\.(zst|xz|gz)$" | sort -V | tail -1 || true)
  [[ -n "$TEMPLATE" ]] && break
done
[[ -n "$TEMPLATE" ]] || die "Couldn't find a Debian template to download."
if ! pveam list "$TSTORE" 2>/dev/null | grep -q "$TEMPLATE"; then
  pveam download "$TSTORE" "$TEMPLATE" >/dev/null || die "Template download failed."
fi
ok "Template $TEMPLATE"

info "Creating container $CTID…"
pct create "$CTID" "$TSTORE:vztmpl/$TEMPLATE" \
  --hostname "$CT_HOSTNAME" --cores "$CORES" --memory "$MEMORY" --swap 512 \
  --rootfs "$RSTORE:$DISK" --net0 "name=eth0,bridge=$BRIDGE,ip=dhcp" \
  --unprivileged 1 --features nesting=1 --onboot 1 --ostype debian --tags discord --timezone host \
  --description "Navidrome → Discord presence (official Discord app on a virtual screen, no token). https://github.com/ayumpo/navidrome-discord-presence" \
  --start 1 >/dev/null
ok "Container $CTID created and started"
wait_for_network "$CTID"
ok "Container is online"

# Hand the answers to the in-container installer as a ready-made settings file.
cat > "$tmp/config.ini" <<EOF
# navidrome-presence settings — every option is explained in /opt/navidrome-presence/config.example.ini
# After editing run: navidrome-presence-config
[navidrome]
url = $ND_URL
username = $ND_USER
password = $ND_PASS

[discord]
client_id = $CLIENT_ID
status_display = track
activity_name = app
activity_name_template = {artist} - {track}
on_pause = show
show_album_in_state = false
links = spotify

[artwork]
sources = $SOURCES
fallback_image = https://raw.githubusercontent.com/navidrome/navidrome/master/ui/public/android-chrome-512x512.png

[general]
poll_interval = 5
stop_grace = 12
log_level = INFO
EOF
unset ND_PASS
pct push "$CTID" "$tmp/config.ini" /root/ndp-config.ini --perms 600
rm -f "$tmp/config.ini"

fetch_installer
info "Installing Discord and the presence companion inside the container (a few minutes)…"
echo
run_installer "$CTID" NDP_CONFIG_FILE=/root/ndp-config.ini

echo
bold "All set! Two quick things left:"
echo "  1. Open the link above in your browser, enter the one-time password, and log in to Discord"
echo "     (easiest: scan the QR code with the Discord app on your phone)."
echo "  2. In Discord: Settings → Activity Privacy → turn on \"Share my activity\"."
echo
echo "  Play a song in any Navidrome app — your Discord status updates within a few seconds."
echo "  To update later, just run the same command again."
