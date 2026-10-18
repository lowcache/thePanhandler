# Record uptime for the next boot's check-in; a boot that lives past the threshold resets the short-boot run.
up=$(cut -d. -f1 /proc/uptime)
echo "$up" >"$STATE/last-uptime"
if [ "$up" -ge "$STABLE_S" ] && [ "$(cat "$STATE/short-boots" 2>/dev/null || echo 0)" != 0 ]; then
  echo 0 >"$STATE/short-boots"
fi
