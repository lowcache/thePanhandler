# Post this boot's record, plus any still queued, to the phone's boot-log listener.
q="$STATE/pending"
mkdir -p "$q"
boot_id=$(cat /proc/sys/kernel/random/boot_id)

num() { local v; v=$(cat "$STATE/$1" 2>/dev/null || true); [[ $v =~ ^[0-9]+$ ]] && echo "$v" || echo null; }
st=$(wpa_cli -i "$UPLINK_IF" status 2>/dev/null || true)
field() { sed -n "s/^$1=//p" <<<"$st"; }
persist=locked
if cryptsetup status persist >/dev/null 2>&1; then persist=unlocked; fi

jq -nc \
  --arg boot_id "$boot_id" --arg ssid "$(field ssid)" --arg bssid "$(field bssid)" \
  --argjson prev_uptime_s "$(num prev-uptime)" --argjson short_boots "$(num short-boots)" \
  --argjson failed_unlocks "$(num failed-unlocks)" \
  --arg lockdown "$(cat "$STATE/lockdown" 2>/dev/null || true)" --arg persist "$persist" \
  '{boot_id: $boot_id, prev_uptime_s: $prev_uptime_s, ssid: $ssid, bssid: $bssid,
    short_boots: $short_boots, failed_unlocks: $failed_unlocks,
    lockdown: (if $lockdown == "" then null else $lockdown end), persist: $persist, source: "pi"}' \
  >"$q/$boot_id.json.tmp"
mv "$q/$boot_id.json.tmp" "$q/$boot_id.json"

[ -n "$CHECKIN_URL" ] || exit 0
rc=0
for f in "$q"/*.json; do
  if resp=$(curl -fsS --max-time 10 -H 'Content-Type: application/json' --data @"$f" "$CHECKIN_URL"); then
    rm -f "$f"
    # The phone holds the authoritative lockdown (remote cluster); mirror it so manual tailnet unlocks refuse too.
    reason=$(jq -r '.lockdown // empty' <<<"$resp" 2>/dev/null || true)
    if [ -n "$reason" ] && [ ! -e "$STATE/lockdown" ]; then echo "$reason" >"$STATE/lockdown"; fi
  else
    rc=1
  fi
done
exit "$rc"
