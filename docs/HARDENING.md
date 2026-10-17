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
- Node is **ephemeral + tagged** (`tag:panhandler`) with **tight ACLs** so that if
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

**v1 posture:**
1. **LUKS-encrypted persistent storage** (`boot.initrd.luks.devices`) → powered-off
   stolen Pi is an encrypted brick. Pairs well with tmpfs root: only `/persist`
   (and the Nix store = config, no secrets) need protecting.
2. **Unlock = over the break-glass cable** (`boot.initrd.network` on eth0 +
   `boot.initrd.network.ssh`, unlock via SSH over link-local). Ethernet-in-initrd is
   tractable; **Wi-Fi-in-initrd on brcmfmac is not — avoid it.**
3. **Ephemeral + `tag:panhandler` + minimal-ACL Tailscale**, revocable from the
   phone in seconds → stolen identity is low-value and killable.
4. **Minimize on-device secrets/data:** API keys live on the laptop (escalation
   brain), not the Pi; sensor data streams off-box; volatile journald.

## Tamper-response & the "empty box" doctrine (enables 24/7 — decided 2026-10-16)

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
  key slots → `poweroff`** (crypto-erase is instant; never overwrite flash).
- **Optional enclosure intrusion switch:** microswitch/reed on the lid → GPIO →
  same crypto-erase + poweroff. (Destroys data only; not a physical trap.)
- Re-arm / false-positive handling: grace period + phone re-auth; cheap because the
  box is empty.

**Key-custody decision (the real Pi-3B triangle — no hardware root of trust):**
DECIDED 2026-10-16 = **build-time spike on (3), fall back to (2).** Attempt
**(3) phone-custodied key over the tailnet** (key never on the card — the
theft-primary-purist answer, still 24/7) via Wi-Fi+Tailscale in initrd; if that
proves too fragile on brcmfmac `[VERIFY]`, fall back to **(2) key on device +
empty-box + tamper-response** (guaranteed working floor; at-rest weakness moot
because the key unlocks an empty box). (1) cable-unlock remains the strongest-at-rest
but non-blip-resilient alternative, not chosen.

`[CEILING]` Does NOT defend a powered-on seizure + immediate cold-boot RAM dump
(A6/nation-state, out of scope). Against ordinary theft, tamper-wipe wins.
