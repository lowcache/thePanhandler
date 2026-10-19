# The Panhandler — Hardening

> Maps to THREAT-MODEL **A5** (the compromised chokepoint) and RISKS **R4**. The
> box sees all plaintext before it tunnels, so a breach inverts the whole project.
> This is a v1 requirement, not a later nicety. Options below are native NixOS;
> kernel/sysctl items marked `[VERIFY]` get confirmed on ARM via `/nixtastic` at build.

## Attack surface (what could get it popped)

1. **Hostile-side network exposure** — any listening port on the hotel-facing iface.
2. **Untrusted-input parsers** (v2 sensors: CertStream, scraped HTML, FOIA, onion).
3. **Third-party/vendored deps** (certstream lib, h8mail…) — supply chain.
4. **Management plane** (SSH, Tailscale).
5. **Secrets at rest** (Tailscale authkey, API keys) + physical theft of the SD.
6. **Router/DNS services themselves** listening on the wrong interface.

## v1 hardening checklist (spine)

### Network posture — the single most important control
- `networking.firewall` / nftables **default-deny**, scoped **per interface**:
  **zero** open ports on the hostile uplink (`wlan0`) — not even SSH/DNS.
- Blocky/DNS + any admin bind **only** to the trusted side (cable/`tailscale0`),
  never the uplink. (Another reason to prefer **blocky** over AdGuard: no web UI to
  expose.)
- Management reachable **only** over Tailscale or the break-glass cable.

### SSH
- `services.openssh`: `PasswordAuthentication = false`,
  `KbdInteractiveAuthentication = false`, `PermitRootLogin = "no"`, keys only,
  `openFirewall = false`, listen bound to the tailnet/cable address only.
- **Kill the throwaway password** (`0x29a`) — it does not exist on the NixOS image.

### Tailscale blast-radius
- Node is **tagged** (`tag:panhandler`, non-ephemeral since 2026-10-17) with **tight ACLs** so that if
  it's popped it can reach *nothing* else on the tailnet (it's the most-exposed
  node; give it the least tailnet reach).
- Pre-auth key via `authKeyFile` (sops), short-lived / single-use.

### Service sandboxing (rule for every daemon, enforced hard on v2 sensors)
- systemd hardening per unit: `DynamicUser`, `ProtectSystem="strict"`,
  `ProtectHome`, `PrivateTmp`, `PrivateDevices`, `NoNewPrivileges`,
  `CapabilityBoundingSet=""`, `SystemCallFilter="@system-service"`,
  `RestrictAddressFamilies`, `RestrictNamespaces`, `MemoryDenyWriteExecute`,
  `LockPersonality`, `ProtectKernel{Modules,Tunables,Logs}`.
- **Untrusted-input sensors**: constrain egress with `IPAddressAllow`/`IPAddressDeny`
  to exactly the endpoints they need (e.g. only `certstream.calidog.io`). Reserve a
  systemd-nspawn/`nixos-container` only for the riskiest parser — a full container
  is heavy on 1 GB, so prefer hardened plain units first.

### Secrets
- **sops-nix** for all secrets; **nothing sensitive in the Nix store** (world-readable).
- Minimize what lives on the device: prefer short-lived/ephemeral Tailscale auth,
  no long-lived high-value credentials on the Pi.

### Impermanence as a hardening bonus
- tmpfs root → a reboot wipes anything an attacker planted outside `/persist`.
  Keep `/persist` minimal and enumerated.
- `services.journald.storage = "volatile"` (also SD-wear; see RISKS R5).

### Kernel/sysctl `[VERIFY on ARM]`
- `security.lockKernelModules`, `security.protectKernelImage`, hardened
  `boot.kernel.sysctl` (rp_filter, ignore redirects, etc.). Some conflict with
  Tailscale's forwarding needs — reconcile at build.

## At-rest / physical — DECISION: physical theft is the PRIMARY vector (v1)

Decided 2026-10-16. The Pi 3B has **no hardware root of trust** (no TPM/secure
element), so this is defense-in-depth, not one clean mechanism.

**Adversary (refined 2026-10-18):** the realistic thief is **opportunistic and
device-ignorant** — a crime of opportunity, not someone hunting this box or versed in
it (that targeted case is THREAT-MODEL **A6**, out of scope). This *simplifies* the
posture: a powered-off brick (LUKS) + empty box + obscurity + instant tailnet revoke is
the whole physical defense; detection exists only to flip into lost mode, not to
out-think a pro.

**v1 posture:**
1. **LUKS-encrypted persistent storage** (`boot.initrd.luks.devices`) → powered-off
   stolen Pi is an encrypted brick. Pairs well with tmpfs root: only `/persist`
   (and the Nix store = config, no secrets) need protecting.
2. **Unlock in stage 2, three independent keyslots** (superseded 2026-10-17; see
   `docs/superpowers/specs/2026-10-17-storage-spine-design.md`). The unencrypted base
   system boots fully, and `/persist` is unlocked afterwards by a key pushed over SSH to a
   forced command: slot 0 = laptop share ⊕ phone share (phone-tap consent), slot 1 =
   passphrase (memory/paper), slot 2 = Bitwarden. No initrd networking at all.
   *Origin of the earlier cable-vs-Wi-Fi conflict:* phone-hotspot data got rate-limited,
   which cast doubt on the Wi-Fi path and brought in the cable.
3. **Tagged, minimal-ACL Tailscale**, revocable from the phone in seconds. Non-ephemeral
   (superseded 2026-10-17): an ephemeral node is deleted while locked and would need a
   reusable key on the device. A second, zero-reach `tag:panhandler-locked` identity in
   `/base` keeps the box reachable while locked.
4. **Minimize on-device secrets/data:** API keys live on the laptop (escalation
   brain), not the Pi; sensor data streams off-box; volatile journald.

## Tamper-response & the "empty box" doctrine (enables 24/7 — decided 2026-10-16)

> **STATUS (2026-10-18): the v1 physical response is LOCKDOWN (cable-only unlock) +
> lost mode, not crypto-erase.** The dead-man / `luksErase` active response below was
> premised on a *targeted, powered-on* attacker — now THREAT-MODEL A6 (out of scope).
> For the opportunistic A0, LUKS already bricks the powered-off box, and auto-erase
> would risk destroying your own data on a benign unplug, so erase is **deferred, not
> wired**. The analysis below is retained as that deferred option.

The user wants 24/7 unattended operation *and* theft-primary. Resolved via an
anti-forensic posture, not a cold-boot-only LUKS:

**Core doctrine — the best anti-theft is an empty box.** Minimize so the Pi holds
no high-value secrets and no sensitive data: API keys live on the laptop
(escalation brain), sensor findings stream off-box, Tailscale is
ephemeral+tagged+**revocable from the phone in seconds**, impermanence wipes all
but a tiny enumerated `/persist`. Then theft yields config + a key that unlocks an
empty box, and **losing the device costs a re-flash, not data** — which is what
makes aggressive tamper-wipe safe to run.

**Offline theft (powered off / card pulled):** only LUKS protects it — no code of
ours runs, so "wipe on mount" is impossible; encryption with the key not trivially
on the card is the whole defense.

**Powered-on tamper (the 24/7-in-room case) — active response:**
- **Dead-man's switch:** a service expects a heartbeat from the phone over the
  tailnet every N min; miss the window (+ grace) → **`cryptsetup luksErase` / destroy
  key slots → lost mode** (crypto-erase is instant; never overwrite flash).
- **Optional enclosure intrusion switch:** microswitch/reed on the lid → GPIO →
  same crypto-erase → lost mode. (Destroys data only; not a physical trap.)
- Re-arm / false-positive handling: grace period + phone re-auth; cheap because the
  box is empty.

**Key-custody decision (the real Pi-3B triangle — no hardware root of trust):**
SUPERSEDED 2026-10-17 by the stage-2 three-slot design (v1 posture item 2 above).
Historical record of the 2026-10-16 decision: **build-time spike on (3), fall back to (2).** Attempt
**(3) phone-custodied key over the tailnet** (key never on the card — the
theft-primary-purist answer, still 24/7) via Wi-Fi+Tailscale in initrd; if that
proves too fragile on brcmfmac `[VERIFY]`, fall back to **(2) key on device +
empty-box + tamper-response** (guaranteed working floor; at-rest weakness moot
because the key unlocks an empty box). (1) cable-unlock remains the strongest-at-rest
but non-blip-resilient alternative, not chosen.

`[CEILING]` Does NOT defend a powered-on seizure + immediate cold-boot RAM dump
(A6/nation-state, out of scope). Against ordinary theft, tamper-wipe wins.

## Lost mode — recovery beacon (added 2026-10-17)

Theft's worst cost is not knowing. After the crypto-erase, the device stops
being a vault and becomes a beacon, our own "Find My", for our own property.

**Triggers:** tamper-response (dead-man miss / enclosure switch), a manual
"lost" command from the phone, or a boot with no phone heartbeat on a network
it has never seen.

**Runs from:** the unencrypted base system (the Nix store and tmpfs root). It
needs no unlock, so it still works after the key is erased and with the
phone-custodied key (option 3). Its only credential is a beacon token that can
reach nothing else, so it's low-value if extracted.

**Beacon payload** (small, jittered, ordinary-looking HTTPS):
- timestamp, uptime, boot count since the trigger;
- connected SSID/BSSID, gateway MAC + vendor, DHCP-assigned domain, captive-portal
  page title (place names leak through all of these);
- **nearby BSSIDs + signal strength** from managed-mode scans, for Wi-Fi
  geolocation;
- optional: a GPS fix (USB GPS dongle) and a camera still (CSI camera). Both are
  off by default; see the legal note.

**Channels, redundantly:** an ntfy topic (secret topic + access token), a POST to
an endpoint you control (it records the public source IP → ISP + coarse
geo-IP), and Tailscale presence. The admin console shows last-seen and endpoint
IPs for free, as long as the node isn't revoked (see trade-off below).

**Location is resolved off-device** (laptop or phone). It turns BSSIDs into a
position with a Wi-Fi geolocation service and IPs into geo-IP, so no API keys
ever sit on the Pi (empty-box doctrine). Mozilla Location Service was retired
in 2024. BeaconDB is the open successor but still maturing; Google's
Geolocation API is accurate but paid. `[VERIFY]` coverage near home before
relying on it.

**Stealth:** no LED change, no visible behaviour change, nothing that tells the
thief it's reporting.

**Trade-off: revoke vs. watch.** The A0 plan revokes the tailnet node "in
seconds". Revoking kills the Tailscale signal. Because the node is tagged with a
minimal ACL, a stolen identity can reach almost nothing, so the default on theft
is **watch first, revoke after** (your call, per incident).

**Honest limits `[CEILING]`:**
- It only works if the thief powers it on **and** it can reach the internet: a
  known network, Ethernet into their router, or an open hotspot without a
  portal. Upgrade path: a USB LTE modem + IoT SIM is the only guaranteed uplink.
- **Reflashing the SD card erases it.** The Pi 3 has no persistent firmware we
  can hide in. Phones' Find My survives because activation lock lives in
  hardware. Here we get the window between theft and reflash.
- No GPS without a dongle, and GPS barely works indoors. Wi-Fi geolocation is
  the realistic primary.

**Legal note:** tracking your own stolen device is broadly fine. Photos of the
person holding it and recording other people's traffic vary by jurisdiction. The
camera stays opt-in, there's no audio ever, and network data stays passive
(what the device naturally sees). Give the findings to police; don't confront.
