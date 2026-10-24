<p align="center">
  <img src="./assets/cardboard.png" alt="The Panhandler banner" width="100%">
</p>

# The Panhandler

<p align="center">
  <a href="https://components101.com/microcontrollers/raspberry-pi-3-pinout-features-datasheet"><img src="https://img.shields.io/badge/Raspberry%20Pi%203B-A22846?style=for-the-badge&logo=raspberrypi&logoColor=white" alt="Raspberry Pi 3B"></a>
  <a href="https://nixos.org"><img src="https://img.shields.io/badge/NixOS-5277C3?style=for-the-badge&logo=nixos&logoColor=white" alt="NixOS"></a>
  <a href="https://svelte.dev"><img src="https://img.shields.io/badge/Svelte-4A4A55?style=for-the-badge&logo=svelte&logoColor=FF3E00" alt="Svelte"></a>
  <a href="pkgs/panhandler-webd/go.mod"><img src="https://img.shields.io/badge/Go-00ADD8?style=for-the-badge&logo=go&logoColor=white" alt="Go"></a>
  <a href="docs/TAILSCALE-POLICY.md"><img src="https://img.shields.io/badge/Tailscale-242424?style=for-the-badge&logo=tailscale&logoColor=white" alt="Tailscale"></a>
  <a href="modules/egress.nix"><img src="https://img.shields.io/badge/Tor-7D4698?style=for-the-badge&logo=torproject&logoColor=white" alt="Tor"></a>
  <br>
  <a href="flake.nix"><img src="https://img.shields.io/badge/arch-aarch64--linux-555" alt="aarch64-linux"></a>
  <a href="modules/secrets.nix"><img src="https://img.shields.io/badge/secrets-sops--nix-informational" alt="sops-nix"></a>
  <a href="docs/THREAT-MODEL.md"><img src="https://img.shields.io/badge/threat%20model-documented-success" alt="Threat model"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-yellow" alt="MIT license"></a>
  <a href="https://github.com/lowcache/thePanhandler/commits/main"><img src="https://img.shields.io/github/last-commit/lowcache/thePanhandler" alt="Last commit"></a>
</p>

---

## Panhandler /ˈpæn.hænd.lə(ɹ)/ noun

1. An urban beggar who typically stands on a street with a homemade cardboard sign  containing either a humorous appeal, a solemn oath, or a sorrowful lamentation. Always accompanied by  an outstretched hand or container for bills & loose change; One who panhandles.
2. A bum, Hobo, Traveler, Crusty, Street Urchin, Squatter, un-housed (in-between residences at the  moment), homeless (one without a home)
3. Grifter.

## So...What is The Panhandler Device?

A Raspberry Pi 3B that flies a cardboard sign on every hostile network while quietly guarding the
devices behind it, managed only from the mesh. The sensor side (its "hobo SOC") is v2. It exists to solve a problem the author actually has: living on rotating
public Wi-Fi where networks are hostile, discovery is off, and captive portals + client isolation
make normal homelab reach impossible.

A panhandler with claim to a busy intersection darts in and out of the flow of traffic gathering
spare change and other forms of charity, defending his claim to the location, and acting as a
silent witness to everything that passes through that single city block. The travel router in this
repo does the same for the small footprint its user occupies on the internet every time they go
online: an unassuming defender for the devices on the user's mesh today, and its watcher and
collector once the v2 sensors land.

One always-on, pocket-sized Linux node with two faces:

- **On the hostile LAN** (hotel/public Wi-Fi): the most forgettable device on the network — a
  per-network MAC, no DHCP hostname, no open ports, no mDNS. A panhandler no one looks at twice.
- **On the tailnet**: `panhandler` — a privacy gateway (and, in v2, a sensor platform) you reach
  from anywhere, through client isolation, with no captive-portal dance.

**Built on:** NixOS (aarch64, cross-built from the laptop) + nixos-hardware + nix modules.


## What it does today (v1 spine)

| Area | Implementation |
|---|---|
| **Gateway** | Laptop on `eth0` (10.73.0.1/24, DHCP); hotel Wi-Fi on `wlan0`; NAT plus forward filtering ([`gateway.nix`](modules/gateway.nix)) |
| **DNS** | Blocky ad and tracker blocking, DoH upstream to Quad9, bound to the trusted side only |
| **Egress** | **Direct** (default) or **Tor** (transparent proxy, fail-closed, no fallback) ([`egress.nix`](modules/egress.nix)) |
| **Captive portals** | A cable client gets a 600 s window to log in through the Pi's uplink ([`portal.nix`](modules/portal.nix)) |
| **Disguise** | Per-SSID stable MAC, no DHCP hostname, no mDNS, ICMP echo dropped on `wlan0` |
| **At rest** | tmpfs root; secrets in LUKS2 (Adiantum) `/persist`; three independent unlock keyslots |
| **Theft response** | Boot-cluster detection triggers **LOCKDOWN** (unlock over the cable only) |
| **Control plane** | `panhandler-webd`: Go and Svelte UI on `:8080` for Wi-Fi scan, join and forget, egress, portal |
| **Tailnet** | Restricted ACL: a compromised Pi can reach nothing except phone check-ins ([policy](docs/TAILSCALE-POLICY.md)) |

**Roadmap (v2+, not built):** passive network auditor, CertStream sentinel, FOIA watcher,
on-device ML triage, slot-machine dApp fairness watchdog, lost-mode beacon, USB Wi-Fi AP. The
contracts the watchdog will watch (CryptoSpin on Solana/Rust, and a Solidity slot) are audited as
separate projects ([BLUEPRINT §7](docs/BLUEPRINT.md)). See [`RISKS.md` §2](docs/RISKS.md) for why the
spine comes first.

## How it works

### Topology

```mermaid
flowchart LR
  subgraph trusted["Trusted side"]
    L["Laptop (volnix)<br/>10.73.0.x"]
    P["Phone<br/>Termux listener :8463"]
  end
  subgraph pi["Panhandler (Pi 3B)"]
    E["eth0 10.73.0.1<br/>DHCP · Blocky · UI :8080"]
    F{{"nftables<br/>default-deny"}}
    W["wlan0<br/>cover MAC · 0 open ports"]
    T["tailscale0"]
  end
  H(("Hostile Wi-Fi")) --> I(("Internet"))
  L == cable ==> E --> F --> W --> H
  F -. Tor mode .-> TOR["tor TransPort"] --> W
  T <-. WireGuard mesh .-> L
  T <-. WireGuard mesh .-> P
```

### Egress states

```mermaid
stateDiagram-v2
  [*] --> Clamped: firewall start or reload
  Clamped --> Direct: saved mode = direct
  Clamped --> Tor: saved mode = tor and /persist unlocked
  Direct --> Tor: UI or ph-egress tor
  Tor --> Direct: UI (tailnet laptop or phone only) or cable SSH
  Tor --> Portal: cable client requests portal access
  Portal --> Tor: logged in or 600 s expiry
  note left of Tor: tor down = traffic blocked, never falls back to Direct
```

### Unlock (device quorum)

`/persist` stays sealed until the laptop and phone agree. The phone share is wrapped by a
hardware-Keystore key that requires a fingerprint.

```mermaid
sequenceDiagram
  participant Pi
  participant Phone
  participant Laptop
  Pi->>Pi: boot base system, locked tailnet identity
  Pi->>Phone: check-in (boot log, cluster count)
  Phone-->>Phone: notification, fingerprint tap
  Laptop->>Phone: fetch phone share (released for 2 min)
  Laptop->>Laptop: key = laptop share ⊕ phone share
  Laptop->>Pi: SSH forced command, pushes key
  Pi->>Pi: open LUKS /persist, swap to main identity, start Tor
```

If the phone records three boots inside its cluster window, or the Pi counts consecutive short
boots, the box enters **LOCKDOWN**: the phone refuses to release its share, and only the passphrase
or Bitwarden slot over the cable will unlock it.

### Storage

| Mount | Encrypted | Holds |
|---|---|---|
| `/` | tmpfs | Everything else, wiped on reboot |
| `/nix`, `/base` | No | Public config, SSH host key, locked tailnet identity, current Wi-Fi only |
| `/persist` | LUKS2 | Main tailnet identity, sops age key, saved Wi-Fi profiles, Tor state |

## Install

**You need:** a Nix host with flakes and `boot.binfmt.emulatedSystems = [ "aarch64-linux" ]`;
`age`, `sops` and `rbw` (Bitwarden); a Pi 3B with a ≥ 32 GB SD card; an Ethernet cable; and an
Android phone with Termux and Termux:API for the quorum share.

```sh
git clone https://github.com/lowcache/thePanhandler && cd thePanhandler
make provision-keys                      # 1. unlock SSH key → keys/unlock-keys.pub
git add keys/unlock-keys.pub             #    flakes ignore untracked files
make image                               # 2. build the SD image (cross-built via binfmt)
make provision-card IMAGE=$TMPDIR/ph-build/sd-image/sd-image/*.img.zst DEVICE=/dev/sdX
                                         # 3. flash, partition, LUKS, split key (destructive, asks first)
make up                                  # 4. cable, wait, unlock, uplink, laptop routes via Pi
```

Adapt the hard-coded values to your setup first: `username` and `panhandler.managementPeers` in
[`flake.nix`](flake.nix), the `PI_*` and `LAPTOP_ETH` addresses in the [`Makefile`](Makefile),
[`.sops.yaml`](.sops.yaml) recipients, and the tailnet policy in [`security/`](security/).
On the phone, run [`phone/enroll.py`](phone/enroll.py) once, then run the listener under
`termux-services` ([`phone/sv/`](phone/sv/)).

## Use

```sh
make            # list every target
make health     # uplink, connectivity, failed units, uptime
make deploy     # build, copy and activate over the cable (VIA=tailnet for remote)
make rollback   # previous generation
make checks     # NixOS VM tests (spine, hardening)
```

| Task | How |
|---|---|
| Join hotel Wi-Fi | UI at `http://10.73.0.1:8080` (cable) or the Pi's MagicDNS name (tailnet) |
| Log in to a captive portal | Cable UI, then **Open portal**, log in, then **End bypass** |
| Switch to Tor or Direct | UI egress control, or `ssh … sudo ph-egress {tor,direct,status}` |
| Laptop keeps its own internet | `make cable-debug`; return with `make cable-share` |
| Measure throughput | `make bench` (run once per egress mode) |

Expect a browsing and email shield, not a streaming VPN. The Pi 3B shares one USB 2.0 bus between
Ethernet and Wi-Fi ([R3](docs/RISKS.md)).

## Docs

[Blueprint](docs/BLUEPRINT.md) · [Threat model](docs/THREAT-MODEL.md) · [Risks](docs/RISKS.md) ·
[Hardening](docs/HARDENING.md) · [Security fixes](docs/SECURITY-FIXES.md) ·
[Tailnet policy](docs/TAILSCALE-POLICY.md) · [Specs and plans](docs/superpowers/)

**Out of scope:** targeted or nation-state attackers, a powered-on seizure, and active scanning of
networks you're a guest on. The Panhandler observes passively and never touches anyone else's
systems ([THREAT-MODEL §2.5](docs/THREAT-MODEL.md)).

[Contributing](CONTRIBUTING.md) · [Security policy](SECURITY.md) · [Code of conduct](CODE_OF_CONDUCT.md) ·
[Sponsors](SPONSORS.md) · [Changelog](CHANGELOG.md) · [MIT License](LICENSE)
