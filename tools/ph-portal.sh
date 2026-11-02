#!/usr/bin/env bash
# ph-portal SSH_ARGS... — sign the Pi into a captive portal from the laptop. A throwaway Brave profile
# goes out through an SSH SOCKS tunnel, so the portal sees the Pi's MAC while the laptop stays online.
set -euo pipefail
PORT=${PORT:-1080}
dir=$(mktemp -d "${TMPDIR:-/tmp}/ph-portal.XXXXXX")
ssh -f -N -o ExitOnForwardFailure=yes -o ControlMaster=no -o ControlPath=none \
  -D "127.0.0.1:$PORT" "$@"
pid=$(pgrep -nf "^ssh .*-D 127\.0\.0\.1:$PORT")
trap 'kill "$pid" 2>/dev/null; rm -rf "$dir"' EXIT
echo ">> sign in, then close the window (http://neverssl.com if no portal shows)"
# Chromium resolves names through a socks5 proxy, so DNS also comes from the Pi's side.
brave --user-data-dir="$dir/profile" --no-first-run --proxy-server="socks5://127.0.0.1:$PORT" \
  http://neverssl.com/ >/dev/null 2>&1
