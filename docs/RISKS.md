# The Panhandler — Risks & Scope Discipline

> The point of this file is to keep an enthusiastic project from becoming a
> half-finished pile of rubble. It names the ways this dies, the mitigations, and
> — critically — the **kill criteria**: the moment we cut a thing rather than
> nurse it. Written against a known failure pattern: getting drunk on the idea and
> plowing into over-engineered, underused software (see: the lesson we're not
> repeating).

**Status:** draft for review. 2026-10-16.

## 1. The failure modes

### R1 — Scope collapse (LIKELIHOOD: high · IMPACT: fatal)
Gateway + 4 sensors + ML + watchdog + stealth + UI is enormous for one person on
1 GB. The death isn't one feature failing — it's **60% of eight things, none
daily-driven.**
- **Mitigation:** spine-first (see §2). One feature reaches "I use this every day"
  before the next starts.
- **Kill criterion:** if a sensor isn't daily-useful 2 weeks after it "works," it
  gets cut or parked, not polished.

### R2 — Captive-portal auth for a headless router (RESOLVED — was: high/fatal)
A headless Pi can't click a portal. Resolved 2026-10-16 with two independent
working paths, so this is no longer a blocker:

- **Primary (hotel Wi-Fi): portal-proxy over the cable.** The Pi associates to the
  hotel (wlan0 STA) and NATs the laptop over the Ethernet cable; the laptop's
  browser hits the portal *through the Pi's uplink*, so completing it authorizes
  **the Pi's MAC** on the hotel gateway. This is the Roku "Hotel & Dorm" mechanism
  (concurrent AP+STA + proxy → device-MAC authorized), but the **cable replaces the
  Roku's companion-AP**, so it sidesteps the Pi 3B single-radio AP+STA limit
  entirely. Verified-in-principle against this network via the author's Roku.
- **Default when cellular is available: phone tether.** S26 Ultra as uplink (USB or
  hotspot) → no captive portal at all. Simplest, most robust.
- **Dongle demoted to v2:** a USB Wi-Fi dongle is only needed to let the *phone*
  join the Pi's bubble over Wi-Fi (true `DIRECT-Roku`-style AP). Not required for
  portal auth.
- **Residual caveat:** portals requiring explicit *device registration* or that
  block companion-device links can defeat even the proxy trick (Roku fails these
  too). Fallback = tether. Also: how the proxy flow coexists with the kill-switch
  (the portal must reach the net *before* the tunnel is up) is an R-interaction to
  settle under egress design.

### R3 — Throughput disappointment (LIKELIHOOD: medium-high · IMPACT: abandonment)
Pi 3B shares Ethernet+USB on one USB 2.0 bus, Cortex-A53, 1 GB. Routing + DNS +
Tor realistically caps low — [ESTIMATE] tens of Mbps, far less through Tor;
[UNVERIFIED] exact figure, settle by `iperf3` through the built box.
- **Mitigation:** set expectations now — this is a *browsing/email* shield, not a
  streaming VPN. Measure early.
- **Kill criterion:** if measured throughput is below what your real usage needs,
  the board is wrong — stop; don't optimize a dead end.

### R4 — The Panhandler gets popped (LIKELIHOOD: low · IMPACT: catastrophic/inverted)
It's a plaintext chokepoint; a breach inverts the whole premise (see THREAT-MODEL A5).
- **Mitigation:** hardening is a phase-1 requirement, not a later nicety — no
  hostile-side listening ports, systemd-sandbox the sensors, isolate untrusted-input
  parsers, pin + review vendored deps.
- **Kill criterion:** a sensor that can't be run sandboxed/least-privilege doesn't
  ship.

### R5 — SD death / no recovery story (LIKELIHOOD: medium · IMPACT: dead mid-trip)
SD cards fail; ours is new but they do.
- **Mitigation:** "re-flash from the flake in ~10 min" must be real and tested
  once. Secrets via sops-nix, reproducible. Log to RAM (`journald volatile`) to
  reduce wear.
- **Kill criterion:** none — this is a hard requirement for v1, not optional.

### R6 — Sensor rabbit holes (LIKELIHOOD: high · IMPACT: time-sink)
CertStream tuning, flaky onion scraping, ML feature engineering can eat all the
time while the useful gateway sits unfinished.
- **Mitigation:** sensors are strictly *after* the daily-driven gateway. Each
  sensor timeboxed; ship the cheap version (Federal Register RSS) before the
  expensive one (scraping FBI Vault).

### R7 — Physical theft / custody (LIKELIHOOD: medium · IMPACT: high — PRIMARY vector)
Elevated 2026-10-16: physical theft is the **primary** threat (THREAT-MODEL A0).
The board has no hardware root of trust, so defense is layered (LUKS + ephemeral
revocable Tailscale + minimal on-device secrets). Also: power everywhere; throttles
in an enclosure (seen 85 °C).
- **Mitigation:** LUKS at-rest (cable-unlock), ephemeral/tagged/revocable tailnet
  node, keep high-value secrets + sensor data off the device; cheap heatsink;
  plan power.
- **24/7 unattended: RESOLVED possible** via the "empty box" doctrine + tamper-
  response (dead-man phone heartbeat + optional enclosure switch → crypto-erase +
  poweroff). Because the box holds nothing of value, a wipe/loss costs a re-flash,
  not data — which is what makes aggressive tamper-wipe safe. See HARDENING.
- **Kill criterion:** if the "empty box" can't be kept empty (something of real
  value must persist on-device AND it runs unattended in untrusted spaces),
  reconsider — don't pretend LUKS covers the powered-on case (`[CEILING]`:
  cold-boot RAM dump, A6, out of scope).

## 2. Scope discipline — the spine-first rule

**Build order is non-negotiable:**

1. **SPINE (v1):** base NixOS + hardening + the gateway (blocky + Tailscale +
   kill-switch + auto per-network policy) + a tested re-flash path.
2. **Daily-drive the spine for ~1 month.** No new features until it's a thing you
   actually trust and use on real hostile networks.
3. **Then** one sensor at a time, cheapest-useful first, each behind the
   event-contract, each timeboxed, each subject to R1's kill criterion.

A boring router you trust beats a dazzling demo you don't.

## 3. Definition of done for v1 (anchor against drift)

v1 is done — and *only* done — when all of these are true:
- [ ] Boots headless from a flake-built image; joins the tailnet unattended.
- [ ] A device behind it (laptop over the cable) is online, ad-filtered, egressing
      as configured, on a real hostile network.
- [ ] Kill-switch verified fail-closed (tunnel drop → no clear-net leak; checked
      with tcpdump).
- [ ] A working answer to the captive-portal crux (R2), even if it's approach #4.
- [ ] Hostile-side surface verified minimal (no listening ports; nmap from the LAN).
- [ ] Re-flash-from-flake tested once, end to end.
- [ ] Measured throughput known and acceptable for real use.

Everything else — sensors, ML, CertStream, FOIA, dApp watchdog, Noctalia widget —
is **v2+**, and each earns its place against THREAT-MODEL.md or it doesn't ship.

## 4. The decision lens (for the piece-by-piece breakdown)

Every component gets placed at the intersection of four questions:
- **Impossible** — can the hardware/laws of physics even do it? (cut if no)
- **Available** — does it exist in nixpkgs / as a maintained tool? (vendor-cost if no)
- **Achievable** — can *we* build+maintain it solo, realistically? (defer if no)
- **Necessary** — does it map to a THREAT-MODEL line or a real daily need? (cut if no)

Only what survives all four is in v1's spine; the rest is honestly labeled v2,
parked, or killed.
