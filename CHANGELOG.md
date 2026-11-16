# Changelog

Notable changes, newest first. Dates are commit dates.

## Unreleased

### 2026-11-16: hoboSEC split
- The generic router is `nixosModules.hobosec` (`modules/` plus the Pi 3, SD-image and sops-nix
  modules it builds on); the author's host values live in `hosts/panhandler.nix`. The login user is
  an option (`panhandler.adminUser`/`adminKeys`), not a flake specialArg. The Pi's system and every
  check derivation are byte-identical to before the split.
- The web UI takes its interfaces from `panhandler.lanInterface` and
  `services.tailscale.interfaceName` instead of hardcoding `eth0`/`tailscale0`, and the unlock
  spine's cable defaults to the same option. New VM check `webui` runs the service as deployed
  (sandbox, journal access, per-device listeners): log stream and its gate, the bubble-report gate,
  the device list. It fails as it should when the journal group is removed.

### 2026-11-16: no DNS query log
- blocky no longer journals every client lookup (its default console query log). The journal is
  RAM-only, but it still held a running browsing history of every device behind the Pi.

### 2026-11-15: web UI phase B
- Live logs over SSE for webd, NetworkManager, dnsmasq, blocky and the uplink probe. Off until
  started; at most 3 viewers; only the cable or a management peer over Tailscale may read them.
  Header tabs switch between Wi-Fi and Logs.
- Devices tab: the travel bubble's clients as volnix reports them (its DHCP leases and live
  neighbors, every 30 s, over the tailnet only; the cable is refused because bubble clients look
  like volnix there). Held in RAM; vendor from nmap's MAC-prefix table; stale reports are flagged.

### 2026-11-15: uplink truth (burned in across several hotels since 2026-11-02)
- Portal detection no longer trusts NetworkManager: `ph-uplink-probe` fetches plain-HTTP pages
  portals don't allowlist and reports open, portal (with the captured login URL) or dead. A portal
  that skips one answer stays a portal until a second silent run. The web UI banner and the bypass
  follow the probe, so allowlist-faking portals (Hilton ElevenOS) show up.
- Clock without NTP: `ph-clock-https` steps the clock forward from two agreeing HTTPS Date headers.
- Wi-Fi MAC per saved network, not per brand; the NM check URL blends in with Android's.
- Unknown networks start in Direct and the UI says so; known networks keep their learned mode.
- The USB tether is the last-resort uplink (route metric 700; Wi-Fi 600).
- The Pi resolves through blocky, with only `ts.net` forwarded to MagicDNS.

## v1.0 — 2026-10-29: the spine

v1 is the daily-driven gateway: every item in the RISKS.md §3 definition of done has hardware
or VM evidence. Sensors and the SOC pillar are v2+.

v1 acceptance on the Pi 3B (Super8 hotel Wi-Fi, 2026-10-29):
- Headless boot from the flake image, tailnet join, cable unlock; `wlan0` MAC identical across a reboot.
- Kill-switch: Tor mode with Tor stopped let 0 packets from the laptop out of `wlan0`/`usb0`
  (23 in the Direct control), counted with nftables after filtering.
- Hostile side: full TCP scan from a peer on the uplink (phone hotspot; Super8 isolates clients)
  found all 65,535 ports filtered. The probes were seen arriving and dropped. UDP was not scanned
  (no root in Termux).
- Throughput 20–38 Mbit/s down through the Pi; captive portals via `ph-portal-bypass`;
  re-flash verified with `verify-card`.

### 2026-10-29: uplinks and policy
- One WAN set (`wlan0` + `usb0`): plugging in the phone's USB tether moves the default route and
  NAT, the Tor clamp, the portal bypass and the echo-drop rules follow; unplugging falls back to Wi-Fi.
- Learned per-network egress: a Direct/Tor choice is remembered per network (inside LUKS) and
  reapplied on reconnect and after unlock. Unknown networks keep the current mode.
- Boot check-ins keep no SSID/BSSID on disk; the phone listener bounds and validates records and
  keeps late-delivered boots out of the theft-cluster count.
- `verify-card` fails entries it cannot verify; provisioning cleanup survives errors.

### 2026-10-21 – 2026-10-23: security audit and egress
- Selectable **Direct/Tor egress** with a fail-closed Tor clamp and a persisted mode (`ph-egress`).
- Forward filtering: unsolicited upstream traffic can no longer reach downstream clients.
- Web UI accepts only exact hostnames and same-origin mutations.
- Wi-Fi joins are bound to the selected BSSID and security; the old profile is kept until the
  replacement works.
- Restricted Tailscale policy published (`security/tailscale-policy.json`).
- Persistent machine-id, so stable-ssid MACs survive reboots.
- `make up` cold start, Makefile front door and `make bench`.
- Blocky dials its upstreams over IPv4 only; the phone tap asks for a fingerprint and signs once.

### 2026-10-18 – 2026-10-20: control plane
- `panhandler-webd` (Go and Svelte) for Wi-Fi scan, join and forget, and the captive-portal bypass.
- NetworkManager on `wlan0`; the laptop routes through the Pi over the cable ("bubble").
- Runtime hardening: sysctl, ICMP dropped on `wlan0`, no DHCP hostname, systemd sandboxes.

### 2026-10-17: storage spine
- tmpfs root, LUKS2 `/persist`, three-keyslot unlock (laptop ⊕ phone, passphrase, Bitwarden).
- Locked and main tailnet identities; boot-cluster LOCKDOWN; `ph-provision` and `verify-card`.
- Mainline kernel and U-Boot boot fix; threat model signed off.
