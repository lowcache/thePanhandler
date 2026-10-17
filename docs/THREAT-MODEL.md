# The Panhandler — Threat Model

> Who we're defending against, what we're protecting, and — just as important —
> what we are explicitly **not** trying to stop. A feature that doesn't map to a
> line in this file is scope creep.

**Status:** draft for review. This document gates the feature list, not the other
way around. Last updated 2026-10-16.

## 1. What we're protecting (assets)

| Asset | Why it matters |
|---|---|
| **Traffic content** | What you actually send/receive on hostile Wi-Fi. |
| **Traffic metadata** | DNS lookups, SNI, destinations, timing — often more revealing than content. |
| **Location / identity linkage** | MAC + hostname + behavior that ties "this device" to "this person" across networks. |
| **The devices behind the Panhandler** | Your laptop/phone, shielded from the hostile LAN. |
| **The Panhandler itself** | It sees everything in the clear before tunneling. Its integrity is the whole premise. |
| **The author's exposure** | Credentials/handles leaking (the self-canary's job). |

## 2. Adversaries (ranked by how much we actually care)

### A0 — Physical theft of the device (PRIMARY — elevated 2026-10-16)
- **Capability:** takes the physical Pi + SD; reads it offline, extracts secrets and
  stored data, impersonates the device on the tailnet, or plants persistence.
- **Wants:** your data, your tailnet identity/access, intel on your setup.
- **Defense (defense-in-depth — Pi 3B has NO hardware root of trust):**
  1. **LUKS at-rest encryption** → a powered-*off* stolen Pi is an encrypted brick.
  2. **Ephemeral + tagged + minimal-ACL Tailscale node**, instantly revocable from
     your phone → a stolen identity is low-value and killed in seconds.
  3. **Minimize secrets/data on the device ("empty box")** → high-value creds live
     on the laptop (escalation pattern); sensor data streams off-box; tmpfs root +
     volatile logs. Theft yields config + a key that unlocks nothing of value.
  4. **Tamper-response** → dead-man heartbeat from the phone + optional enclosure
     intrusion switch → crypto-erase the LUKS key + poweroff. Covers the
     powered-*on* grab (within the ceiling below). See HARDENING.
- **Residual (honest) `[CEILING]`:** a powered-*on* seizure followed by an immediate
  cold-boot RAM dump could recover the live key (A6/nation-state, out of scope).
  Against ordinary theft the tamper-wipe fires first.

### A1 — Ad-tech / trackers (primary, always-on)
- **Capability:** DNS/HTTP-level tracking, beacons, fingerprinting.
- **Wants:** profile you, sell it.
- **Defense:** adblock DNS (blocky), encrypted upstream DNS, no DNS leak to the hotel resolver.

### A2 — Captive-portal operator / hotel ISP (primary)
- **Capability:** sees all unencrypted traffic, controls DNS, can inject into HTTP, logs by MAC, may hijack DNS or attempt TLS interception.
- **Wants:** analytics, "marketing," compliance logging, upsell.
- **Defense:** full tunnel (Tailscale/Tor egress) so they see only encrypted transport; MAC/hostname cloaking so logs don't link across visits; the data-mining auditor to *catch and document* hijack/injection.

### A3 — Passive sniffer on open/shared Wi-Fi (primary)
- **Capability:** captures anything in the clear on the local segment.
- **Wants:** opportunistic credential/data theft.
- **Defense:** nothing leaves the Panhandler unencrypted (kill-switch enforces fail-closed); devices behind it never touch the hostile segment directly.

### A4 — Active LAN attacker / rogue AP (secondary)
- **Capability:** ARP/DNS spoofing, evil-twin AP, MITM attempts.
- **Wants:** intercept/redirect.
- **Defense:** tunnel + pinned encrypted DNS defeats most MITM value; auditor flags evil-twin/TLS-intercept signatures. We **detect and avoid**, we do not fight back.

### A5 — The compromised Panhandler (the inverted risk — HIGH)
- **Capability:** if popped, it is a perfect surveillance chokepoint — it already sees all your plaintext.
- **Vector:** hostile input parsed by sensors (CertStream feed, scraped pages), vendored deps (certstream lib, h8mail), exposed services.
- **Defense:** this is why hardening > features. Minimal attack surface, no listening ports on the hostile side, sensors sandboxed (systemd hardening / least privilege), untrusted-input parsers isolated, deps pinned and reviewed. **The Panhandler must be the most-hardened device you own.**

### A6 — Targeted / resourced attacker, nation-state (OUT OF SCOPE)
- We do **not** claim to defend against an adversary specifically targeting *you*
  with implants, 0-days, or legal compulsion of Tailscale/your exit. Saying so
  honestly is part of the model.

## 3. Explicitly out of scope

- Endpoint security of the laptop/phone themselves (that's their own problem).
- Anonymity against a global passive adversary (Tor's own threat model caveats apply; we inherit, not improve, them).
- Defending the *hotel's* network or other guests — we are a guest, we observe
  passively, we do not scan or attack their infrastructure.
- Forensic recovery from a Pi stolen while **powered-on and unlocked** (keys in
  RAM; cold-boot/chip-off attacks) — A0 defends the powered-*off* case only.
- Nation-state forensic/legal compulsion (inherits A6).
- Being a high-throughput VPN appliance (hardware can't; see RISKS).

## 4. Trust assumptions (if any break, the model breaks)

1. The Panhandler's image is built from a flake *you* control, from trusted nixpkgs.
2. Tailscale's coordination and your chosen exit are trusted (A6 excepted).
3. The laptop behind it is not already compromised.
4. The upstream DNS resolver you encrypt *to* is more trustworthy than the hotel's.
5. Secrets (Tailscale authkey, API keys) are managed via sops-nix and not on the SD in cleartext.

## 5. The one sentence

> On hostile public Wi-Fi, keep the network operator, trackers, and passive
> sniffers from reading or linking your traffic — while the box doing it stays
> clean enough that trusting it is justified — and **document** what the network
> tried to do. We do not promise protection from an adversary hunting *you*.
