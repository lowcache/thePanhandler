# Root half of ph-unlockd. Args: <local address the SSH client connected to> <command>.
server_ip=${1%%%*}
cmd=$2

addr_on() { [ -n "$server_ip" ] && ip -o addr show dev "$1" 2>/dev/null | grep -qwF -- "$server_ip"; }
origin=other
if addr_on "$CABLE_IF"; then origin=cable; elif addr_on "$TS_IF"; then origin=tailnet; fi

num() { local v; v=$(cat "$STATE/$1" 2>/dev/null || true); [[ $v =~ ^[0-9]+$ ]] && echo "$v" || echo 0; }
unlocked() { cryptsetup status persist >/dev/null 2>&1; }
in_lockdown() { [ -e "$STATE/lockdown" ]; }

status() {
  printf 'origin=%s persist=%s short_boots=%s failed_unlocks=%s\n' \
    "$origin" "$(unlocked && echo unlocked || echo locked)" "$(num short-boots)" "$(num failed-unlocks)"
  if in_lockdown; then printf 'LOCKDOWN: %s\n' "$(cat "$STATE/lockdown")"; fi
}

# stdin = key material.
open_with() {
  if cryptsetup open --key-file=- "$PERSIST_DEV" persist; then
    echo 0 >"$STATE/failed-unlocks"
    systemctl start ph-persist.target
    # Swap tailscaled to the main identity once this session has reported back.
    systemd-run --quiet --on-active=3 systemctl restart ph-tailscale-state.service
    systemctl start --no-block ph-checkin.service
    echo unlocked
  else
    echo $(($(num failed-unlocks) + 1)) >"$STATE/failed-unlocks"
    sync
    systemctl start --no-block ph-checkin.service
    sleep 3
    echo "unlock failed" >&2
    return 2
  fi
}

case $cmd in
  status) status; exit 0 ;;
  key | passphrase | clear-lockdown) ;;
  *) echo "unknown command" >&2; exit 64 ;;
esac
if [ "$origin" = other ]; then echo "refused: unknown origin" >&2; exit 3; fi
if in_lockdown && [ "$origin" != cable ]; then
  status
  echo "lockdown: unlock only over the $CABLE_IF cable" >&2
  exit 3
fi

case $cmd in
  key)
    if unlocked; then echo "already unlocked"; exit 0; fi
    base64 -d | open_with
    ;;
  passphrase)
    if unlocked; then echo "already unlocked"; exit 0; fi
    status
    IFS= read -rs -p "passphrase: " pass </dev/tty
    echo >&2
    printf '%s' "$pass" | open_with
    ;;
  clear-lockdown)
    if [ "$origin" != cable ] || ! unlocked; then
      echo "clear-lockdown needs the cable and an unlocked /persist" >&2
      exit 3
    fi
    rm -f "$STATE/lockdown" "$STATE/theft"
    echo 0 >"$STATE/short-boots"
    sync
    echo "lockdown cleared"
    ;;
esac
