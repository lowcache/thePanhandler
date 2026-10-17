# The Panhandler — Blueprint

> Pans for gold, handles the dirt. A Raspberry Pi 3B that flies a cardboard sign
> on every hostile network while quietly running a full SOC off the mesh.

**Status:** design/blueprint. No implementation yet. Hardware assessed and PASSED
(see §10). Package specifics in *Verified Stack* (§8) are from a research pass;
items marked `[VERIFY]` are not yet confirmed.

**Read these two first — they gate everything here:**
[`THREAT-MODEL.md`](THREAT-MODEL.md) (who we defend against; what's out of scope)
and [`RISKS.md`](RISKS.md) (how this dies, the spine-first rule, and the v1
definition-of-done). A feature in this blueprint that doesn't map to a threat-model
line or survive the decision lens is scope creep.

---

## 1. What it is

One always-on, pocket-sized Linux node with two faces:

- **On the hostile LAN** (hotel/public Wi-Fi): the most forgettable device on the
  network — a randomized MAC, a boring cover hostname, no open ports, no mDNS.
  A panhandler no one looks at twice.
- **On the tailnet**: `volpanhandler` — a privacy gateway and a sensor platform
  you reach from anywhere, through client isolation, with no captive-portal dance.

It exists to solve a problem the author actually has: living on rotating public
Wi-Fi where networks are hostile, discovery is off, and captive portals + client
isolation make normal homelab reach impossible.

## 2. Three pillars

### A. Privacy-hardened roaming gateway
- Network-wide ad/tracker-blocking DNS.
- Tailscale mesh so all your devices behave as if on one trusted LAN, anywhere.
- Selectable egress: direct · Tor (via the volnix anon-box path) · optional home exit.
- nftables **kill-switch**: if the chosen tunnel drops, traffic is blackholed —
  never leaks onto the hostile LAN in the clear.
- **Automatic per-network policy**: detect the SSID, apply a profile
  (trusted → direct; unknown/hostile → full tunnel + kill-switch + sensors on).

### B. Stealth sensor platform ("hobo SOC")
- **Data-mining auditor** (passive, client-side only): on each network it joins,
  profile what the network does *to you* — DNS hijack, TLS interception, HTTP
  ad/JS injection, tracking beacons, captive-portal data harvesting. Log it.
  Feeds blog content (hotelevangelism / infernalcode).
- **CertStream keyword sentinel**: tap the global Certificate Transparency
  firehose, filter for your own brands/typosquats (defense) + chosen keywords.
- **FOIA / new-document watcher**: poll public gov reading rooms, alert + summarize
  on new drops.
- **Slot-machine dApp watchdog** (see §7): watch the contract + its web frontend;
  canary the RNG for fairness drift. The Pi does **not** host the dApp.

### C. Hobo-SOC operational disguise
- Per-network MAC randomization + boring cover hostname on hostile LANs.
- No mDNS/avahi broadcast; zero listening ports on the hostile side.
- Management reachable **only** over Tailscale or the break-glass Ethernet cable.
- Passive sensing only — never active-scan networks you're merely a guest on
  (keeps it defensible and off their IDS).

## 3. Architecture (two faces)

```
            HOSTILE LAN (hotel Wi-Fi)                 TAILNET (trusted mesh)
          ┌───────────────────────────┐            ┌────────────────────────┐
  uplink  │  wlan0  cover MAC/hostname │            │  volpanhandler         │
  ───────▶│  outbound-only, no ports  │            │  SSH, status page,     │
          │                           │  tailscale │  sensor API            │
          │  [ passive auditor taps ] │◀──────────▶│                        │
          └─────────────┬─────────────┘            └────────────────────────┘
                        │ egress selector
             direct ────┼──── Tor (anon-box) ──── [optional home exit]
                        │ nftables kill-switch (fail-closed)
     downlink (v1): eth0 ──cable── laptop (trusted subnet, defeats isolation)
     downlink (v2): hostapd AP on a USB Wi-Fi dongle  [optional, ~$8]
```

**Single-radio caveat:** the Pi 3B has one Wi-Fi radio, so it can't cleanly be a
Wi-Fi *client* and a Wi-Fi *AP* at once. v1 downlink is the **Ethernet cable to the
laptop** (already proven to work and to defeat client isolation). Serving the phone
over Wi-Fi is a later USB-dongle upgrade, not a v1 requirement.

## 4. Build phases (staged, each independently testable)

0. **DONE — prove the hardware.** Passed (see below).
1. **Base NixOS.** aarch64 `sd-image` built on the laptop (binfmt) + nixos-hardware
   `raspberry-pi-3`; SSH key + Tailscale pre-auth key baked in; onboard Wi-Fi up.
   *Done when:* boots headless, joins the tailnet on first non-captive network,
   reachable by tailnet name; cable link-local still works as break-glass.
2. **Gateway core.** Adblock DNS + Tailscale exit/subnet + NAT router over the cable.
   *Done when:* a device behind it is online, ad-filtered, and egressing as chosen.
3. **Stealth layer.** MAC randomization, cover hostname, port lockdown, no mDNS,
   kill-switch, per-network policy automation.
   *Done when:* on a hostile LAN it shows only a cover identity and no open ports,
   and a dropped tunnel fails closed.
4. **Sensors.** Data-mining auditor → CertStream sentinel → FOIA watcher, with
   on-device ML triage escalating hits to a bigger brain.
   *Done when:* each writes findings to the local store and alerts over push.
5. **dApp watchdog + status page.** Contract/endpoint monitors + a light tailnet UI.

## 5. Sensor / ML architecture — edge triage, cloud brain

A Pi 3B (aarch64, ~1 GB, no GPU) **cannot run a local LLM** usefully. The split:

- **On-device (cheap, always-on):** tiny classical models — IsolationForest for
  network-telemetry anomaly detection; a small scorer for CertStream hits
  (entropy, edit-distance to your brands, TLD risk); lightweight dedup for
  doc/leak diffs. Thousands of events → a handful of candidates.
- **Escalate on hits only:** ship the handful to the laptop or the Claude API for
  summarization/judgment. Pennies, not a melted SD card. The Pi stays a sensor.

This split is also stealthier: the box is doing boring math, not holding a model
that advertises "serious kit."

## 6. Networking model (hard-won — see memory `pi-networking-roaming-model`)

- **Reach-anywhere = Tailscale on the Pi.** Captive portals + AP client isolation
  make LAN tricks unreliable; the mesh sidesteps both.
- **Break-glass = direct Ethernet cable**, IPv6 link-local. Reliable *unless* the
  laptop end is in NetworkManager `shared`/NAT mode (that breaks link-local — keep
  the cable profile plain `link-local`).
- **Laptop internet-sharing over the cable is a dead end** here: the laptop's
  hardened firewall drops DHCP/forwarded traffic and can't be changed without sudo
  at a real terminal. Do Tailscale's one-time enrollment on a non-captive network.

## 7. Linkage placeholders — audit projects (SEPARATE repos/tracks)

The slot machines are **not** part of The Panhandler; the Pi only *watches* one.
Each gets its own focused security audit later.

- **CryptoSpin** — Solana + Rust (Anchor?) slot-machine contract. `[PLACEHOLDER]`
  repo/path TBD. Audit scope: RNG source/fairness, account/signer validation,
  payout & vault logic, arithmetic, upgrade authority.
- **Solidity slot machine** — EVM. `[PLACEHOLDER]` repo/path TBD. Audit scope:
  reentrancy, access control, integer/overflow, front-running/MEV, RNG
  manipulation, payout/withdrawal, economic soundness.
- **Panhandler integration point:** the dApp watchdog (§2B / phase 5) subscribes to
  the live contract's events and fairness-canaries the RNG. Fill contract addresses
  / endpoints here once each audit track establishes them.

> `[CONTEXT]` A slots dApp is regulated gambling in many jurisdictions — a legal
> question to settle before "side hustle," independent of the code.

## 8. Verified Stack (filled from research — `[VERIFY]` = not yet confirmed)

> Populated from the `panhandler-nixos-stack` and `panhandler-sensor-stack` research
> briefs. Until then, treat every attr/option below as `[VERIFY]`.

- Base image / Wi-Fi firmware: `[VERIFY]`
- Adblock DNS (blocky / adguardhome; pi-hole not native): `[VERIFY]`
- Tailscale exit-node / subnet-router options: `[VERIFY]`
- Tor transparent proxy / egress: `[VERIFY]`
- Encrypted/recursive DNS (unbound / dnscrypt-proxy): `[VERIFY]`
- NAT/router + optional hostapd: `[VERIFY]`
- MAC randomization + hostname spoofing: `[VERIFY]`
**Sensor side — verified (Gemini brief `panhandler-sensor-stack`, 2026-10-16):**
- **CertStream:** connect a thin client to `wss://certstream.calidog.io/domains-only`
  (keeps footprint <30 MB RAM). The full firehose or direct CT-log polling is too
  heavy for 1 GB. The `certstream` python lib is **unpackaged in nixpkgs** → vendor
  it or use `python3Packages.websocket-client`. Public server has no SLA / may drop
  frames `[UNVERIFIED]`.
- **On-device ML:** `python3Packages.scikit-learn` IsolationForest — FEASIBLE
  (<50 ms inference; ~100 MB RSS from numpy/scipy). `onnxruntime` — FEASIBLE on
  aarch64, CPU-only, keep models <10 MB. `tflite-runtime` — **NO** (absent / C++
  pkg `meta.broken`). Local LLM — **NO** (OOM on ~880 MB usable). Confirms the
  edge-triage → escalate split.
- **FOIA:** Federal Register (`federalregister.gov/api/v1/` + `search.rss`) — JSON
  REST **+ RSS**, best primary source. NARA catalog (`catalog.archives.gov/api/v2/`)
  — API, needs a free key. FBI Vault / CIA CREST / Pentagon AARO — **scrape-only**
  (no RSS/API), need scheduled change-detection.
- **Tor canary:** `services.tor.client.enable` → SOCKS `127.0.0.1:9050` (~30–45 MB).
  HIBP Pwned Passwords range API (k-anonymity) is free over SOCKS; `pkgs.h8mail`
  for account checks (full HIBP needs paid key). Pastebin blocks Tor exits and onion
  services increasingly enforce PoW captchas `[UNVERIFIED]`.

**Gateway/base side — verified (Gemini brief `panhandler-nixos-stack`, 2026-10-16;
option names match the known NixOS module set — re-confirm with `nixtastic` at build):**
- **Base image:** `nixos-hardware.nixosModules.raspberry-pi-3` + sd-image aarch64
  (`sdImage.populateFirmwareCommands`); chainloads U-Boot with DT/overlays.
- **Onboard Wi-Fi:** PARTIAL — `hardware.enableRedistributableFirmware` +
  `pkgs.raspberrypiWirelessFirmware`; firmware packaged but needs explicit
  `networking.networkmanager`/`networking.wireless` config (no net out of the box).
- **Adblock DNS:** pi-hole UNAVAILABLE (only `services.pihole-ftl`). Use
  **`services.blocky`** (light Go, fully declarative) or **`services.adguardhome`**
  (`mutableSettings = false` for pure-declarative). Blocky is the better fit for 1 GB.
- **Tailscale:** `services.tailscale.enable` + `authKeyFile` (non-interactive
  bootstrap); exit-node/subnet via `useRoutingFeatures = "both"` + `extraUpFlags`
  (`--advertise-exit-node`, `--advertise-routes`).
- **Tor egress:** PARTIAL — `services.tor.client.transparentProxy.enable` +
  `services.tor.settings.TransPort`; the redirect into Tor is our own nftables rules.
- **Encrypted/recursive DNS:** `services.unbound` (recursive validating) and/or
  `services.dnscrypt-proxy` (DoH/DNSCrypt). `[VERIFY]` the exact module name —
  `dnscrypt-proxy` vs `dnscrypt-proxy2` (Gemini's deprecation note may be inverted).
- **Router/NAT:** `networking.nat.enable` + `networking.nftables.enable` (auto
  masquerade/SNAT; keep raw `extraCommands` empty under nftables).
- **AP (optional USB dongle):** `services.hostapd` (`radios`/`interface`).
- **Concurrent AP+STA on the onboard BCM43438:** PARTIAL / **unfeasible in practice**
  — driver advertises it but `#channels <= 1` forces AP onto the STA channel and
  drops under time-slicing. Confirms cable-first downlink; dongle for AP.
- **MAC/hostname cloaking:** NetworkManager `networking.networkmanager.wifi.macAddress`
  (`"random"`/`"stable-ssid"`) + `connectionConfig` for DHCP hostname — supports
  **per-SSID**. systemd-networkd `MACAddressPolicy="random"` is per-link only
  (per-SSID needs `iwd`). → **NetworkManager** for the Hobo-SOC cover identity.
- **SD-wear:** `services.journald.storage = "volatile"` (log to RAM); tmpfs root via
  `fileSystems."/"` + community `impermanence` flake (mind 1 GB RAM headroom).

## 8.5 Egress model — RESOLVED 2026-10-16

No fixed home exit node exists; the **phone (S26 Ultra) on cellular is the one
constant, always-reachable node**. Therefore:

- **Primary egress = phone tether.** Uplink is cellular → egress is the trusted
  carrier; no portal, no hostile-LAN exposure; kill-switch = fail-closed if tether
  drops.
- **Hotel-Wi-Fi egress, two selectable profiles:**
  - **phone-exit** — Pi on hotel Wi-Fi, egress via the phone's Tailscale **exit
    node** (confirmed available on the S26 Ultra). Fast, trusted-carrier IP,
    WireGuard-wrapped; still spends cellular data, so it beats tether only by not
    needing a physical tether. Also benefits the whole tailnet (laptop/other devices
    get trusted egress anywhere, independent of the Pi).
  - **Tor** (`services.tor` transparent proxy) — the one **zero-cellular-data**
    option (egress via the hotel link); self-contained, slower, some sites block it.
    Runs the portal-auth state machine.
- **Selector:** "do I have cellular data to spend + need speed?" yes → tether/
  phone-exit; no → Tor.
- **Tailscale = mesh/management + the phone-exit path**; never egress *when
  tethered* (that's circular — you're already on cellular).

Kill-switch is a 3-state machine: `portal-auth` (allow only the portal
host) → `clamped` (drop all but the chosen egress iface) → `fail-closed` (tunnel
lost). Per-network auto-policy: tethered → direct/cellular; hostile Wi-Fi → Tor;
trusted → direct.

## 9. Open decisions for next session

- ~~Egress default~~ — RESOLVED (§8.5: tether-primary + Tor data-saver).
- ~~USB dongle now vs cable-only v1~~ — RESOLVED (cable-only v1; dongle is v2 for
  phone-over-Wi-Fi bubble).
- Alert channel: ntfy/Gotify self-hosted, or into Noctalia directly? (v2)
- Interface/status: event-contract now; Noctalia widget vs light web page later (v2).
- Where the "bigger brain" lives for ML escalation: laptop daemon vs Claude API (v2).
- THREAT-MODEL.md sign-off (your review) before any build.
- Measure real throughput on the built box (RISKS R3) early.

## 10. Hardware verdict (assessed 2026-10-15 — PASS)

Pi 3B Rev 1.2, serial `…b41feb6e`, bare/heatsink-less, cosmetically filthy.

- **Continuous uptime, zero reboots/panics** across the whole assessment.
- **`throttled=0x0` idle; zero undervoltage** ever (no `0x1`/`0x10000`) → PSU is solid.
- **RAM + SD clean** under a 5-min 4-core stress (no leak, no OOM, no I/O errors);
  real 29.1 GiB usable on the 32 GB card (not an obvious fake).
- **Only finding:** benign *thermal* ARM freq-capping (`0x20002`) at 80–85 °C under
  artificial all-core max — expected for a bare 3B, irrelevant to the light router
  workload; a ~$3 heatsink erases it if ever needed.

Conclusion: sound board, good power. Fit for the role. The "freezes" seen during
setup were a link-local/NAT artifact, not the Pi — see memory
`pi-networking-roaming-model`.
