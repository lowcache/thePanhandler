# Uplink truth: portal detection, clock, Pi DNS (2026-11-02)

Trigger: Hilton Honors (ElevenOS). The portal whitelists the OS connectivity-check URLs, so NM
reported FULL behind an unauthenticated portal; the web UI hid "Open portal", the bypass watcher
ended the bypass on FULL, and the opened probe URL was whitelisted. The laptop could not sign the Pi
in. Separately: unknownNetwork=keep carried tor to a new network, NTP did not sync (593 s skew), and
the Pi's own DNS went to the hotel resolver in plaintext via MagicDNS forwarding.

Maps to THREAT-MODEL A2 (portal operator: logs by MAC, controls DNS, intercepts) and A1 (no
cleartext DNS to the hotel resolver), and RISKS R2 (portal auth for a headless router).

## Decisions (user, 2026-11-02)

- D1 Clock: HTTPS Date fallback; one new direct exception in tor mode for a dedicated uid.
- D2 NM connectivity URI: `connectivitycheck.gstatic.com/generate_204` (blends with Android).
- D3 MAC: per-profile (`connection.stable-id=${CONNECTION}`), not per-SSID. Stable through a stay;
  forget + rejoin rotates it. Every saved network gets a new MAC on deploy (one re-auth).
- D4 unknownNetwork default: `direct`, and the UI shows the mode on join.

## Design

1. **Uplink probe** (`modules/probe.nix`). Root oneshot `ph-uplink-probe`, timer 2 min, NM
   dispatcher on uplink up/connectivity-change, startable by webd (polkit, exact unit). Resolves
   each target via the uplink's DHCP DNS (`drill`, generic names only; blocky's DoH is dead pre-auth),
   fetches over IPv4 with `curl --resolve` on port 80 (root's port-80 exception, both modes). Verdict:
   `open` (a target returned its marker), `portal` (a redirect/refresh; URL captured), `dead`.
   Writes `/run/ph-uplink/state.json` (verdict, portalUrl, wan, ssid-free, checkedAt) and appends
   transitions to `/run/ph-uplink/history` (RAM; no location trail on disk). On `* -> open` it
   try-restarts blocky (DoH pool reset after login). Targets are an option (testable, generic).
2. **Web UI.** Status carries the probe. Banner shows on NM `portal`, probe `portal`, or an active
   bypass. The watcher ends the bypass on probe `open` and re-runs the probe every tick. The button
   opens the captured portal URL (http/https only) or `http://neverssl.com/`. The banner says the
   browser must route through the Pi (`pi-share`), else `make portal`. The uplink card shows the
   egress mode and whether it was learned or defaulted for this network.
3. **Clock** (`modules/clock.nix`). `ph-clock-https` (uid `ph-clock`, CAP_SYS_TIME only) runs when
   timesyncd is not synced: HEAD over HTTPS to 3 hosts, names resolved via the uplink DNS, connect
   direct. Needs 2 Date headers within 30 s; steps only forward, by > 30 s; then marks
   `/run/ph-clock/https`, saves the /base floor, try-restarts blocky. TLS validates because the /base
   floor keeps the clock within ~15 min. timesyncd gets Cloudflare's anycast IPs first (no DNS), the
   pool after. Egress: `ph-clock` may send udp 53 and tcp 443 direct in tor mode (as timesync has
   udp 53/123).
4. **Pi DNS through blocky.** `tailscale set --accept-dns=false`, NM `dns=none`,
   `networking.nameservers = [ 127.0.0.1 ]`; blocky also listens on 127.0.0.1:53 and maps `ts.net`
   to 100.100.100.100. Only the probe, the clock and the portal bypass use the hotel resolver, each
   explicitly. Pre-auth NM reports `limited` instead of a false `full` (it resolves via blocky).
5. **Phone notice.** On a verdict transition the probe queues `{verdict, at}` (no SSID) for the
   listener's new `POST /uplink` (pi role) → termux-notification. A portal usually takes the tailnet
   down with it, so delivery is "when the link is back", not real time.
6. `make portal` (SOCKS through the Pi, throwaway browser profile) stays the fallback for portals
   the bypass cannot carry.

## Tests

- `checks.uplink` (new VM test): hostile node serves a portal (meta refresh) then real pages; probe
  verdicts portal → open → dead; state.json and history; blocky restart on open.
- `checks.egress`: in tor mode, uid ph-clock reaches hostile tcp 443 and udp 53 direct; another
  non-root uid on tcp 443 is still redirected; ph-clock tcp 80/123/other is not exempt.
- webd Go tests: probe state parsing, portal URL scheme validation, banner/watch logic.

## Not in scope

Real-time alerting while the uplink is down (needs an out-of-band channel), hostile-network nmap,
phone-exit egress.
