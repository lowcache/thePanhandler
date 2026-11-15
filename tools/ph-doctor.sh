#!/usr/bin/env bash
# ph-doctor SSH_ARGS... — read-only, layer by layer: laptop cable → Pi clock → persist → uplink → portal →
# egress/Tor → DNS → tailnet. Each line is ok/warn/FAIL plus the next move.
set -u
SSH=("$@")
ETH=enp3s0
GW=10.73.0.1
# shellcheck disable=SC2016  # the check functions are expanded on whichever side runs them
FNS='ok() { printf "\033[32m  ok\033[0m %-9s %s\n" "$1" "$2"; }
warn() { printf "\033[33mwarn\033[0m %-9s %s\n" "$1" "$2"; }
bad() { printf "\033[31mFAIL\033[0m %-9s %s\n" "$1" "$2"; }'
eval "$FNS"

cable=$(nmcli -g GENERAL.CONNECTION device show "$ETH" 2>/dev/null || true)
bubble=$(systemctl is-active vol-bubble.service 2>/dev/null || true)
case "$cable" in
  pi-share) ok laptop "cable pi-share (laptop routes via the Pi), bubble $bubble" ;;
  pi-diag) warn laptop "cable pi-diag: Pi reachable, laptop NOT routed via it (make cable-share)" ;;
  *) bad laptop "cable '${cable:-down}': no Pi link (make up)" ;;
esac

{
  echo "$FNS"
  cat <<'REMOTE'
skew=$(($(date +%s) - $1))
sync=$(timedatectl show -p NTPSynchronized --value)
if ((skew > 60 || skew < -60)); then bad clock "Pi is ${skew}s off the laptop (no RTC; Tor stalls until fixed): make up sets it"
elif [ "$sync" != yes ]; then warn clock "${skew}s off, NTP not synced yet"
else ok clock "${skew}s off, NTP synced"; fi

if [ "$(stat -c %d /persist)" != "$(stat -c %d /)" ]; then ok persist unlocked
else bad persist "locked: no Tor, no saved networks (make unlock)"; fi

wan=$(ip -4 route show default | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1)
if [ -z "$wan" ]; then bad uplink "no default route: join a network in the web UI (http://10.73.0.1:8080)"
else
  con=$(nmcli -g GENERAL.CONNECTION device show "$wan")
  sig=$(iw dev "$wan" link 2>/dev/null | sed -n 's/.*signal: //p')
  ok uplink "$wan '$con' ${sig:+($sig) }via $(ip -4 route show default | awk '{print $3; exit}')"
fi

conn=$(nmcli -g CONNECTIVITY general)
# Root port 80 skips Tor in both modes, so this is the raw uplink. Portals pass the well-known check
# URLs (ElevenOS: nmcheck, detectportal) and silently drop some hosts, so try several plain pages.
probe=""
for u in http://example.com/ http://httpforever.com/ http://neverssl.com/; do
  body=$(sudo -n curl -4 -s -m 6 "$u" 2>/dev/null)
  case "$body" in *"Example Domain"* | *"HTTP Forever"* | *NeverSSL*) probe=ok && break ;; esac
  [ -n "$probe" ] || probe=$body
done
case "$probe" in
  ok) ok internet "NM $conn, raw HTTP probe ok" ;;
  *[Pp]ortal* | *refresh* | *[Ll]ocation*)
    bad internet "captive portal (NM says $conn, it lies): sign in through the Pi (make portal)"
    printf '          %s\n' "$(grep -oiE 'url=https?://[^/"; ]+' <<<"$probe" | head -1 | cut -c5-)" ;;
  ?*) bad internet "raw HTTP probe got an unexpected page (portal?), NM $conn" ;;
  *) bad internet "NM $conn, raw HTTP probe got nothing: the uplink itself is dead" ;;
esac
# The Pi's own uplink probe (modules/probe.nix), with its recent verdict changes.
if [ -r /run/ph-uplink/state.json ]; then
  v=$(jq -r '"\(.verdict) (checked \(.checkedAt))"' /run/ph-uplink/state.json)
  case "$v" in open*) ok probe "$v" ;; *) bad probe "$v" ;; esac
  tail -n 3 /run/ph-uplink/history 2>/dev/null | sed 's/^/          /'
fi
[ "$(systemctl is-active ph-portal-bypass)" = active ] && warn portal "bypass ON: cable DNS goes to the hotel resolver (auto-off in 10 min)"

mode=$(cat /run/ph-egress/mode 2>/dev/null)
uuid=$(nmcli -g GENERAL.CON-UUID device show "$wan" 2>/dev/null)
saved=$(sudo -n awk -v n="$uuid" '$1 == n { m = $2 } END { print m }' /persist/ph-egress-policy 2>/dev/null)
mem="saved for this network: ${saved:-none (keeps the current mode)}"
if [ "$mode" = tor ]; then
  boot=$(sudo -n journalctl -u tor -b -o cat 2>/dev/null | grep -o 'Bootstrapped [0-9]*%' | tail -1)
  if [ "$(systemctl is-active tor)" != active ]; then bad egress "tor mode but tor is down: clients get nothing (sudo ph-egress direct)"
  elif [ "$boot" != "Bootstrapped 100%" ]; then bad egress "tor mode, ${boot:-not started}: clients get nothing until 100% (check clock/portal) | $mem"
  else warn egress "tor (TCP + DNS only: ping, UDP, QUIC fail by design) | $mem"; fi
elif [ "$mode" = direct ]; then ok egress "direct | $mem"
else bad egress "mode '$mode' unknown"; fi

t=$(curl -4 -s -o /dev/null -m 20 -w '%{http_code} %{time_total}' https://www.google.com/generate_204)
case "$t" in 204*) ok path "HTTPS via $mode egress: ${t#* }s" ;; *) bad path "HTTPS via $mode egress failed ($t)" ;; esac

[ "$(systemctl is-active blocky)" = active ] || bad dns "blocky down: cable clients have no DNS"
ts=$(tailscale status --json 2>/dev/null | jq -r '"\(.BackendState) online=\(.Self.Online)"')
case "$ts" in "Running online=true") ok tailnet "$ts" ;; *) warn tailnet "${ts:-tailscaled down}$([ "$mode" = tor ] && echo ' (tor mode: DERP over Tor, slow)')" ;; esac

failed=$(systemctl --failed --no-legend --plain | awk '{print $1}' | tr '\n' ' ')
[ -z "$failed" ] || bad units "$failed"
awk '{printf "     up       %.1f h\n", $1/3600}' /proc/uptime
REMOTE
} | ssh "${SSH[@]}" bash -s -- "$(date +%s)" || bad pi "unreachable over ssh (${SSH[*]: -1})"

# Client view: one DNS query to blocky from the laptop (DoH upstream dies behind an unopened portal).
python3 - "$GW" <<'PY' 2>/dev/null || bad dns "blocky at $GW did not answer the laptop in 5 s (portal? make health again after Open portal)"
import random, socket, struct, sys, time
q = struct.pack(">HHHHHH", random.randrange(65536), 0x100, 1, 0, 0, 0) + b"\x07example\x03com\x00" + struct.pack(">HH", 1, 1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(5); t = time.time()
s.sendto(q, (sys.argv[1], 53)); r = s.recv(512); dt = time.time() - t
rc = r[3] & 15
print(("\033[32m  ok\033[0m" if rc == 0 else "\033[31mFAIL\033[0m") + " %-9s blocky answered the laptop in %.2fs (rcode %d)" % ("dns", dt, rc))
PY
