# Bind the active identity's state at /var/lib/tailscale: main once /persist is up, locked otherwise.
src=/base/tailscale
if mountpoint -q /persist; then src=/persist/tailscale; fi
mkdir -p "$src" /var/lib/tailscale
chmod 700 "$src"
while mountpoint -q /var/lib/tailscale; do umount /var/lib/tailscale; done
mount --bind "$src" /var/lib/tailscale
