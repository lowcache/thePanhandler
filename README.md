# The Panhandler

A Raspberry Pi 3B that pans for gold and handles the dirt — a privacy-hardened
roaming gateway and a stealth sensor platform (a scrappy "hobo SOC") for the
volnix homelab. It flies a cardboard sign on every hostile network while running
a full SOC reachable only over the tailnet.

**Built for:** living on rotating public/hotel Wi-Fi where networks are hostile,
discovery is off, and captive portals + client isolation break normal reach.

**Does:**
- Privacy gateway — adblock DNS, Tailscale mesh, Tor egress, fail-closed kill-switch,
  automatic per-network policy.
- Stealth sensors — hotel-network data-mining auditor, CertStream keyword sentinel,
  FOIA new-doc watcher, on-device ML triage, a slot-machine dApp fairness watchdog.
- Disguise — per-network MAC/hostname randomization, no open ports or mDNS on the
  hostile side; true identity lives on the mesh.

**Built on:** NixOS (aarch64, cross-built from the laptop) + nixos-hardware.

See [`docs/BLUEPRINT.md`](docs/BLUEPRINT.md) for the full design, build phases, and
the hardware assessment.

---

*Not in this repo:* the slot-machine contracts it watches (CryptoSpin — Solana/Rust;
and a separate Solidity slot) are audited as their own focused projects. See the
blueprint's linkage section.
