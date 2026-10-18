# Log the active identity in once, with the single-use key that belongs to it.
s=NoState
for _ in $(seq 30); do
  s=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "NoState"' || echo NoState)
  [ "$s" != NoState ] && break
  sleep 1
done
[ "$s" = NeedsLogin ] || exit 0

if mountpoint -q /persist; then key=$MAIN_KEY host=$MAIN_HOST; else key=$STATE/ts-locked-authkey host=$LOCKED_HOST; fi
if [ ! -s "$key" ]; then echo "no authkey for $host; staying logged out" >&2; exit 0; fi
tailscale up --auth-key="file:$key" --hostname="$host"
# The locked key is single-use and now spent; don't leave it in /base.
if [ "$key" = "$STATE/ts-locked-authkey" ]; then rm -f "$key"; fi
