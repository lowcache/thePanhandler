# Changelog

Notable changes, newest first. Dates are commit dates. No releases have been tagged yet.

## Unreleased

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
