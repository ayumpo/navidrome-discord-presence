#!/usr/bin/env bash
# Builds proxmox/setup-proxmox.sh: the template with the companion embedded (tar.gz → base64).
# The output is reproducible, so CI can check the committed file matches the sources.
set -euo pipefail
cd "$(dirname "$0")/.."
payload=$(tar --owner=0 --group=0 --numeric-owner --mtime='2026-01-01 00:00:00Z' --mode=0644 --sort=name \
            -cf - navidrome_presence.py config.example.ini README.md | gzip -9 -n | base64 -w 76)
python3 - "$payload" <<'PY'
import sys
tpl = open("proxmox/setup-proxmox.template.sh").read()
assert tpl.count("\n__PAYLOAD__\n") == 1
open("proxmox/setup-proxmox.sh", "w").write(tpl.replace("\n__PAYLOAD__\n", "\n" + sys.argv[1] + "\n"))
PY
chmod 755 proxmox/setup-proxmox.sh
echo "Built proxmox/setup-proxmox.sh ($(wc -c < proxmox/setup-proxmox.sh) bytes)"
