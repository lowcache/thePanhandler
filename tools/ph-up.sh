#!/usr/bin/env bash
# Cold start from the laptop: cable → Pi reachable → unlock /persist → uplink up → bubble on.
# Usage: ph-up.sh [bitwarden|passphrase|auto]   (env BUBBLE=no keeps the laptop off the Pi's uplink)
set -euo pipefail
HOW=${1:-bitwarden}
ETH=enp3s0
PI=lowcache@10.73.0.1
SSHOPTS=(-o HostKeyAlias=100.81.123.86 -o ConnectTimeout=4 -o BatchMode=yes)
cd "$(dirname "$0")/.."

say() { printf '\033[33m>> %s\033[0m\n' "$*"; }
die() { printf '\033[31m!! %s\033[0m\n' "$*" >&2; exit 1; }
pi() { ssh "${SSHOPTS[@]}" "$PI" "$@"; }
# wait_for SECS CMD...: poll CMD every 3 s; nonzero on timeout.
wait_for() {
  local secs=$1; shift
  for ((t = 0; t < secs; t += 3)); do "$@" >/dev/null 2>&1 && return 0; sleep 3; done
  return 1
}
unlock() { nix run .#ph-unlock -- "$@"; }
persist_state() { unlock status --via cable 2>/dev/null | sed -n 's/.*persist=\([a-z]*\).*/\1/p'; }

[ -f "$HOME/.config/panhandler/agent.json" ] || die "$HOME/.config/panhandler/agent.json missing (volnix tmpfs wiped it?)"
# BatchMode can't prompt for a passphrase; failed probes earn sshd PerSourcePenalties (resets).
ssh-add -l >/dev/null 2>&1 || { say "loading your SSH key into the agent"; ssh-add || die "ssh-add failed"; }

active=$(nmcli -g GENERAL.CONNECTION device show "$ETH" 2>/dev/null || true)
case "$active" in
  pi-share | pi-diag) say "cable: $active" ;;
  *) say "cable: bringing up pi-share"; nmcli --wait 30 con up pi-share >/dev/null || die "pi-share failed; is the cable in?" ;;
esac

say "waiting for the Pi on the cable (boot takes ~1-2 min)"
# Probe with the passphrase-less unlock key's forced `status`, not a login.
wait_for 240 bash -c '[ -n "$(nix run .#ph-unlock -- status --via cable 2>/dev/null)" ]' || die "Pi not reachable at $PI after 4 min (power/cable/ACT LED?)"

case "$(persist_state)" in
  unlocked) say "persist already unlocked" ;;
  locked)
    say "persist locked: unlocking via $HOW"
    unlock "$HOW" --via cable || die "unlock failed (make status / make log)"
    [ "$(persist_state)" = unlocked ] || die "unlock ran but persist is still locked"
    ;;
  *) die "could not read persist state: $(unlock status --via cable 2>&1 | tail -1)" ;;
esac

say "waiting for the Pi's uplink (connectivity=full)"
wait_for 120 pi '[ "$(nmcli -g CONNECTIVITY general)" = full ]' ||
  say "uplink not full yet (captive portal? open http://10.73.0.1:8080)"

if [ "${BUBBLE:-yes}" = yes ] && [ "$active" = pi-diag ]; then
  say "switching cable to pi-share (bubble follows)"
  nmcli con down pi-diag >/dev/null 2>&1 || true
  nmcli --wait 30 con up pi-share >/dev/null
fi

say "status"
unlock status --via cable
pi 'nmcli -t -f DEVICE,STATE,CONNECTION device | grep -v unmanaged; echo "connectivity: $(nmcli -g CONNECTIVITY general)"; tailscale status --self --peers=false 2>/dev/null | head -1; systemctl --failed --no-legend'
if systemctl is-active --quiet vol-bubble.service; then say "bubble: on"; else say "bubble: off"; fi
