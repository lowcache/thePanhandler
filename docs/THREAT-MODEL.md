# The Panhandler — Threat Model

> Who we're defending against, what we're protecting, and — just as important —
> what we are explicitly **not** trying to stop. A feature that doesn't map to a
> line in this file is scope creep.

**Status:** draft for review. This document gates the feature list, not the other
way around. Last updated 2026-10-17.

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

**Two adversaries, two doctrines — and the words differ on purpose.** *Physical*
(A0) is an opportunist who does not know what they took: detect the box being carried
off (power-cycling / an unknown network), **seal the disk** (A0 **LOCKDOWN** =
cable-only unlock) and flip to lost mode; we never fight, the box is an empty,
unlabeled brick. *Online* (A2–A4, §2.5) is a network attacker on the wire: **absorb
and document** the attempt, then stand in **vector-lockdown** (§2.5) — a live host
that presents no vector. A0 LOCKDOWN seals the *disk*; §2.5 vector-lockdown seals the
*wire*; they are distinct states that happen to share a root word.

### A0 — Physical theft of the device (PRIMARY — elevated 2026-10-16)
- **Adversary profile (refined 2026-10-18):** a **crime of opportunity**, not a hunt.
  Whoever takes it does **not** know what it is — an unlabeled board they must first
  identify as a Raspberry Pi, then realize something is loaded on it, then get through
  LUKS. They are not device-versed and are not looking for *this* box. An attacker as
  versed in the device as the owner, hunting it specifically, is by definition
  *targeting you* — that is **A6, out of scope**, not A0.
- **Capability (realistic):** unplugs it to carry it off; maybe idly power-cycles it
  while the lights blink; at most reflashes or bins it when it does nothing obvious.
- **Wants:** the hardware's resale value — not your data, which they don't know exists.
- **Defense (defense-in-depth — Pi 3B has NO hardware root of trust):**
  1. **LUKS at-rest encryption** → a powered-*off* stolen Pi is an encrypted brick.
  2. **Obscurity** → it doesn't look like anything: no label, no screen, no obvious
     purpose. The opportunist rarely gets as far as discovering there's a disk to crack.
  3. **Ephemeral + tagged + minimal-ACL Tailscale node**, instantly revocable from
     your phone → a stolen identity is low-value and killed in seconds.
  4. **Minimize secrets/data on the device ("empty box")** → high-value creds live
     on the laptop (escalation pattern); sensor data streams off-box; tmpfs root +
     volatile logs. Theft yields config + a key that unlocks nothing of value.
  5. **Detection → lost mode (not prevention, not erase).** The opportunist unplugs it
     to carry it, so it powers back on somewhere it has never seen: ≥3 consecutive
     short boots (clock-free — no RTC) or a boot on an unknown network with no phone
     heartbeat → **LOCKDOWN** (cable-only unlock), then, once data is safe, **lost
     mode: recovery beacon** (HARDENING §Lost mode). This flips the box into a beacon
     after an opportunistic grab; it does not try to out-think a pro. A single unplug
     (someone moving or cleaning around it) is normal — an explicitly accepted non-event.
- **Response is LOCKDOWN, not crypto-erase (resolved 2026-10-18 — supersedes the earlier
  erase design).** For a powered-*off* opportunistic theft, LUKS + empty-box already
  yield an encrypted, unidentifiable brick, so destroying key slots buys nothing — and
  auto-erase would destroy *your own* data on a benign unplug. The physical response is
  therefore cable-only LOCKDOWN + lost mode, matching what the code implements.
  `[CONTEXT]` The dead-man/`luksErase` active response in HARDENING is retained only as
  a deferred option against the targeted powered-on case (A6-adjacent), not a v1 control.
- **Residual (honest) `[CEILING]`:** a powered-*on* seizure + immediate cold-boot RAM
  dump could recover the live key (A6/nation-state, out of scope). Against an
  opportunistic theft the box is powered off and the key is not on the card.

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
- **Defense:** tunnel + pinned encrypted DNS defeats most MITM value; auditor flags evil-twin/TLS-intercept signatures. We **detect and avoid**, we do not fight back — see §2.5 for the response.

### A5 — The compromised Panhandler (the inverted risk — HIGH)
- **Capability:** if popped, it is a perfect surveillance chokepoint — it already sees all your plaintext.
- **Vector:** hostile input parsed by sensors (CertStream feed, scraped pages), vendored deps (certstream lib, h8mail), exposed services.
- **Defense:** this is why hardening > features. Minimal attack surface, no listening ports on the hostile side, sensors sandboxed (systemd hardening / least privilege), untrusted-input parsers isolated, deps pinned and reviewed. **The Panhandler must be the most-hardened device you own.**

### A6 — Targeted / resourced attacker, nation-state (OUT OF SCOPE)
- We do **not** claim to defend against an adversary specifically targeting *you*
  with implants, 0-days, or legal compulsion of Tailscale/your exit. Saying so
  honestly is part of the model.
- **Targeted physical / evil-maid (moved here from A0, 2026-10-18):** an attacker who
  knows the box, hunts *this* device, and pulls the card to plant key-capture code for
  the next unlock. The Pi 3B has no secure boot and `/base` + store are unencrypted, so
  this is undefendable cryptographically here. It is by definition *targeting you*, so
  it lives here, not in A0. Detection, not prevention: boot-counting + an offline
  `verify-card` check are the only backstops, and we don't claim they stop a pro.

## 2.5 Response doctrine — record, alert, vanish as a target (added 2026-10-17)

When the Panhandler detects an attack (A2 hijack/injection, A4 spoofing/rogue AP,
or inbound probing of the Pi itself), it **absorbs it, documents it, and stays
online with nothing to attack**. It never touches the attacker's systems.
"Vanish" means vanishing *as a viable target*, not dropping off the network: the
attacker still sees a live host, but every attempt yields nothing. The first
attack that seemed to land turns out to have been our information grab.
Goals: evidence ("information is power") and denial.

1. **Record (passive only).** Everything is taken from traffic that reached us or
   was broadcast to the segment. Nothing is probed or scanned:
   - attacker MAC + OUI vendor, IP(s), and any hostnames they announce themselves
     (DHCP option 12, mDNS/LLMNR/NetBIOS they emit);
   - passive OS fingerprint (TTL / TCP window / options, p0f-style) of packets
     they sent us;
   - the offending packets: an in-RAM pcap ring buffer, snapshotted on trigger;
   - network context: SSID, BSSID, channel, gateway MAC/IP, what was targeted, and
     NTP-synced timestamps.
2. **Preserve.** Records are hash-chained and **shipped off-device over the tailnet
   immediately** (the Pi may be stolen next, and its logs are volatile).
   Evidence that only lives on the Pi doesn't count.
3. **Alert.** Push a notification to the phone with the summary and the record ID
   (alert channel: open decision, BLUEPRINT §9).
4. **Vector-lockdown (stay live, present nothing).** This is the *standing* posture on
   any hostile network, not a reaction; detection only tightens it (A0 **LOCKDOWN**
   seals the disk, this seals the wire):
   - inbound on the hostile interface: drop everything, silently. Every port reads
     "filtered"; no service answers. ICMP echo off on wlan0. ARP and DHCP still
     happen, so the host is visibly alive, and that visibility is deliberate.
   - egress: tunnel-only (Tailscale/Tor) behind the kill-switch. A MITM that
     "works" (ARP spoof, DNS hijack) captures only encrypted transport. Our DNS
     never uses theirs.
   - identity: randomized MAC, cover hostname, and no OS-revealing DHCP options
     (option 12 hostname, option 60 vendor class). No mDNS/LLMNR/NetBIOS.
   - on detection: pin the real gateway's ARP entry (an ongoing spoof stops
     working), tighten anything else that's loose, log every further attempt.
     Escalate to disconnect only on a manual call.
   - optional exit: disconnect, rotate identity, rejoin, as a manual choice.

**Hard boundaries:** no scanning, probing, or fingerprinting the attacker
*actively*; no counter-intrusion; no deception that touches their systems. Canary
tokens live only on our own assets. This keeps us on the right side of the CFAA
and consistent with the stealth pillar.

**Design risks this must answer:**
- **Induced reaction.** Lockdown is the default, so detection changes little, and
  an attacker can't trigger a self-inflicted outage. Keep it that way: any
  automatic reaction must never cost us connectivity (no auto-disconnect).
- **Unavoidable visibility.** On a shared L2 segment we can't hide that a host
  exists (ARP/DHCP), or that it speaks WireGuard/Tor (traffic shape, DERP
  endpoints). "No vector" is the goal; "no presence" isn't achievable.
- **Below the firewall.** The Wi-Fi chip's firmware and the kernel's packet
  handling process frames before any firewall rule runs. Broadcom Wi-Fi firmware
  has had remotely exploitable bugs before (e.g. Broadpwn, 2017). We minimize
  this with updates; we can't eliminate it.
- **The attacker learns they were recorded only through our legitimate actions:**
  visible adaptation (their spoof stops working) and reports with evidence to the
  network operator or abuse contacts. We never contact or message them directly.
- **False positives.** Pre-auth captive portals hijack DNS *by design*, and hotel
  gear does odd ARP. The `portal-auth` state must expect these, not flag them.
- **Hostile-input parsing (A5).** The capture/fingerprint path parses
  attacker-crafted packets, which is classic exploit surface. Sandbox it like the
  sensors: least privilege, no network, memory-safe parsers where possible.
- **Radio ceiling.** [CEILING]: the onboard brcmfmac has no monitor mode on stock
  firmware, so deauth floods and evil twins are seen only through managed-mode
  scans (BSSID/beacon changes). Upgrade path: the v2 USB dongle with monitor mode.
- **Deterrence is a design aim, not a measurable property.** Scans are automated,
  but a human reviews the results. A target that absorbed an attack, then
  visibly adapted and offered nothing, signals capability. The effect on a given
  attacker can't be measured [UNVERIFIED]. Denial of the target is the guaranteed
  part.

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
