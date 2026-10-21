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

# stdin: base64 slot-2 (Bitwarden) key, then base64 new quorum key. Slots are told apart by
# trial, not number, so a card's slot order does not matter.
rekey() {
  local s old=()
  # Global, not local: the EXIT trap runs after rekey() returns.
  d=$(mktemp -d /run/ph-rekey.XXXXXX)
  trap 'rm -rf "$d"' EXIT
  read -r s && base64 -d <<<"$s" >"$d/auth"
  read -r s && base64 -d <<<"$s" >"$d/new"
  [ "$(stat -c %s "$d/new")" = 64 ] || { echo "new key must be 64 bytes" >&2; return 64; }
  cryptsetup open --test-passphrase --key-file "$d/auth" "$PERSIST_DEV" ||
    { echo "authorizing key opens no slot" >&2; return 2; }
  # The quorum slot is the random-key (pbkdf2) slot the Bitwarden key does not open.
  for s in $(cryptsetup luksDump --dump-json-metadata "$PERSIST_DEV" |
    jq -r '.keyslots | to_entries[] | select(.value.kdf.type == "pbkdf2") | .key'); do
    cryptsetup open --test-passphrase --key-slot "$s" --key-file "$d/auth" "$PERSIST_DEV" 2>/dev/null || old+=("$s")
  done
  [ "${#old[@]}" -le 1 ] || { echo "ambiguous quorum slots: ${old[*]}" >&2; return 2; }
  cryptsetup luksAddKey -q --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file "$d/auth" "$PERSIST_DEV" "$d/new"
  cryptsetup open --test-passphrase --key-file "$d/new" "$PERSIST_DEV"
  if [ "${#old[@]}" = 1 ]; then
    cryptsetup luksKillSlot -q --key-file "$d/auth" "$PERSIST_DEV" "${old[0]}"
  fi
  echo "rekeyed: old quorum slot ${old[0]:-none} removed"
}

case $cmd in
  status) status; exit 0 ;;
  key | passphrase | clear-lockdown | rekey) ;;
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
  rekey)
    if [ "$origin" != cable ] || ! unlocked; then
      echo "rekey needs the cable and an unlocked /persist" >&2
      exit 3
    fi
    rekey
    ;;
esac
