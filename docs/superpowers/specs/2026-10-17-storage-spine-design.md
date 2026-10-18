# Hardening sub-project 1 — Storage spine (design)

**Date:** 2026-10-17 · **Status:** approved in brainstorming, pending spec review
**Maps to:** THREAT-MODEL A0 (theft, primary), A5; RISKS R5, R7; HARDENING §At-rest, §Tamper-response.

## 0. Context and decomposition

Hardening is four sub-projects, each with its own spec → plan → build:

1. **Storage spine** (this spec): LUKS `/persist`, tmpfs root + impermanence, unlock quorum, locked identity, boot-cluster detection, provisioning + reflash.
2. Runtime hardening: kernel/sysctl, sshd bind addresses, systemd sandbox baseline, per-interface ICMP, DHCP option 12/60 leaks, nix `trusted-users`. Live-deployable, no reflash.
3. Tamper-response: dead-man heartbeat, `ph-erase`, re-arm. Consumes interfaces defined in §7.
4. Lost mode beacon. Consumes interfaces defined in §7.

Order: 1 first (forces the reflash); 2 may run in parallel; 3 then 4.

## 1. Decisions

| # | Decision | Supersedes |
|---|---|---|
| D1 | `/persist` unlocks in **stage 2** (systemd unit), not initrd. The unencrypted base system boots fully. | HARDENING §At-rest item 2 (initrd cable unlock) and §Key-custody options (2)/(3) |
| D2 | Three LUKS keyslots with **three independent trust roots**: device quorum, your memory, Bitwarden. | — |
| D3 | Device quorum = laptop share ⊕ phone share (2-of-2 XOR). Phone share gated by a hardware-Keystore signature (biometric/screen unlock). | — |
| D4 | Push model: the laptop agent pushes the key into the Pi over SSH, to a forced command. The Pi holds no credential that can pull a key. | — |
| D5 | Second, **locked** Tailscale identity (`tag:panhandler-locked`, zero-reach ACL), state in unencrypted `/base`. One `tailscaled`, identity swapped on unlock. | — |
| D6 | Single unordered reboot = normal: notification flagged, tap allowed. | — |
| D7 | Two cluster detectors, either → **LOCKDOWN** (cable-only unlock). | — |
| D8 | Main Tailscale node is **non-ephemeral**, tagged `tag:panhandler`, single-use key spent at provisioning, revoked manually on theft. | decisions.md "ephemeral auth key" |
| D9 | LUKS cipher **Adiantum**; explicit PBKDF parameters sized for the Pi. | — |

Why D1: initrd networking on brcmfmac is intractable. Wi-Fi PSK and Tailscale state would have to sit outside LUKS anyway. Stage 2 lets the beacon run while locked. Cost: the base system runs unattended on hostile networks without secrets. The default-deny firewall already covers that, and sub-project 2 tightens it.

Origin of the HARDENING conflict (for the doc fix): phone-hotspot data got rate-limited, which cast doubt on the Wi-Fi path and brought in the cable.

## 2. Storage layout (card #2; card #1 retained as rollback)

| Partition | Format | Mount | Contents |
|---|---|---|---|
| FIRMWARE | vfat | `/boot/firmware` | GPU firmware, U-Boot (unchanged) |
| system | ext4, unencrypted | `/nix`; `/nix/base` bind-mounted at `/base` | Nix store (public config only); `/base` |
| persist | LUKS2 (Adiantum) → ext4 | `/persist` after unlock | all secrets and state |
| — | tmpfs | `/` | everything else; size cap 256M `[ESTIMATE]`, tune after measuring |

Sizes `[ESTIMATE]`: system ≈ 26 GB, persist ≈ 4 GB.

**`/base` (unencrypted). Holds only what a thief gains nothing from:**
- SSH host key (used both locked and unlocked);
- locked Tailscale identity state (`/base/tailscale`);
- current network's Wi-Fi credentials only, overwritten on each join, never a history (an SSID list is a location trail);
- beacon token (sub-project 4);
- on-Pi boot-cluster log + lockdown flag (§6).

**`/persist` (LUKS):** main Tailscale state, sops age key (`/persist/var/lib/sops-nix/key.txt`), enumerated state dirs via the nix-community `impermanence` flake (new input).

**Services:** anything needing secrets declares `RequiresMountsFor=/persist`. Before unlock those services don't start. `services.journald.storage = "volatile"`.

**Locked-node ACL** (the user applies it in the admin console):
- `tag:panhandler-locked` inbound: only laptop + phone, only `:22`.
- Outbound: only the phone boot-log listener port and the beacon endpoint.
- Nothing else reachable.
- `tag:panhandler` keeps its existing minimal ACL.

**Identity swap:** `tailscaled` starts on `--statedir=/base/tailscale` (locked node). `ph-unlockd` restarts it on `/persist/tailscale` (main node) after mount. `ph-erase` (sub-project 3) swaps it back.

## 3. Key material

| Item | Where | In Bitwarden |
|---|---|---|
| `K` (64 B random, slot 0) | nowhere at rest; exists only in the agent's memory / on stdin during unlock | **no** (would duplicate the quorum) |
| `S_L` (laptop share) | `~/.local/share/panhandler/unlock-share`, 0600, never in any repo | yes (lost-laptop recovery: S_L from BW + phone tap) |
| `S_P' = S_P ⊕ SHA256(sig)` | phone, Termux home | no (useless without the Keystore key) |
| Keystore RSA key (signs fixed message; PKCS#1 v1.5 → deterministic `sig`) | Android hardware Keystore, user-auth required, non-exportable | no (cannot be exported) |
| Passphrase (slot 1, Argon2id) | your memory / paper | **no** (keeps root independent) |
| `K_BW` (64 B random, slot 2) | Bitwarden only | yes, this slot *is* Bitwarden |
| Panhandler sops age key | `/persist` | yes (replaces the ephemeral scratchpad `.bak`) |
| SSH host key, unlock-command SSH key, beacon token | `/base` / laptop | yes |
| `tailscale_authkey`, Wi-Fi PSKs | sops | optional |

`S_P = K ⊕ S_L`. Each share alone is uniformly random.

**Why the Keystore wrap:** `phone_system_termux_exec` runs as the Termux uid, so a plain-file share would be readable by whoever controls the laptop's MCP, with no tap. The Keystore key only signs after recent user authentication, so the tap becomes hardware-enforced consent.

**PBKDF:** slot 1 Argon2id with `--pbkdf-memory` ≈ 256 MiB, set explicitly. Formatting happens on the laptop, and cryptsetup's auto-tuning there could OOM the Pi at unlock. Slots 0 and 2 hold random keys, so minimal PBKDF.

**Re-key** (`ph-rekey`, run after phone loss/reset or suspected share exposure): unlock via slot 1 or 2 → new `K` → add to a fresh slot → `luksKillSlot` old slot 0 → re-split → re-enroll phone → update Bitwarden copies of `S_L`.

## 4. Components

| Unit | Runs on | Purpose |
|---|---|---|
| `ph-unlockd` | Pi | Forced command for the unlock SSH key (`restrict,command="ph-unlockd"`). Reads a key on stdin or prompts for the passphrase. Checks the lockdown flag and session origin (eth0 vs tailnet). `cryptsetup open` → mount → start gated target → identity swap. |
| `ph-checkin` | Pi | On each boot: post `{boot_id, prev_uptime, ssid, bssid, public_ip, local_cluster_state}` to the phone listener. Queue in `/base` if offline. |
| `ph-bootcount` | Pi (initrd) | Append boot timestamp to the `/base` log at the earliest reliable point; evaluate the on-Pi cluster rule. |
| boot-log listener | phone (Termux) | **Authoritative** boot log + lockdown state. Answers lockdown queries from the tap script and the laptop agent. |
| tap script | phone | `click_action` target: query lockdown → biometric → rebuild `S_P` → send to agent. |
| `ph-unlock` agent | laptop (shipped from this repo, not wired into volnix) | Watch check-ins; notify via phone-agent `phone_system_notify`; combine shares; push `K`. Also `--passphrase`, `--bitwarden` (`rbw get`, then `rbw lock` immediately), `--clear-lockdown`. Mirrors the boot log. |
| `ph-provision`, `ph-rekey`, `verify-card` | laptop | §8. `verify-card`: offline `nix store verify` against the flake build + hashes of firmware and boot files. Opt-in, never a gate. |

`rbw` `lock_timeout` set short (value chosen in the plan).

## 5. Unlock flow

1. Pi base system boots. `ph-bootcount` records the boot. The locked node joins the tailnet. `ph-checkin` posts to the phone listener.
2. Laptop agent sees the check-in, then sends a high-priority notification: SSID, BSSID, public IP, previous uptime, plus **⚠ CLUSTER** if either detector fired.
3. Tap → tap script checks lockdown (refuses if set) → biometric → `S_P` → agent over tailnet.
4. Agent computes `K = S_L ⊕ S_P` and pipes it over SSH to `ph-unlockd`.
5. `ph-unlockd`: `cryptsetup open` → mount `/persist` → gated target → tailscaled swaps to the main identity.

**Break-glass:** same forced command, passphrase prompt. Reached from the laptop over eth0 or from the phone (Termux ssh over the tailnet, locked node `:22`). Slot 2: `ph-unlock --bitwarden`.

**Failures:** a wrong key leaves the Pi locked, and failed attempts are counted and alerted. Laptop away → passphrase from the phone. Phone dead → cable + passphrase or Bitwarden.

## 6. Tamper signals and lockdown

| Detector | Counts | Rule (config knob) | Targets |
|---|---|---|---|
| On-Pi | boots recorded by `ph-bootcount` in `/base` | **≥3 boots / 15 min** | the "monkey" thief: rapid plug cycles, mostly offline, won't touch `/base` |
| Off-device | check-ins in the phone log | **≥3 check-ins / 60 min** | careful prober: slow card-pull cycles, may wipe `/base` |

| Signal | Action |
|---|---|
| single unordered reboot | normal notification, tap allowed |
| either cluster rule | **⚠ CLUSTER + LOCKDOWN**, plus a theft flag for sub-project 4 |
| boot on never-seen BSSID with no phone heartbeat | handed to sub-project 4 |
| repeated failed unlocks | logged + phone alert |

**LOCKDOWN:**
- Remote paths refuse: tap, phone passphrase over tailnet, agent auto, agent `--bitwarden` over tailnet.
- Unlock only over the **eth0 cable** with slot 1 or slot 2. `ph-unlockd` prints the cluster evidence first.
- Cleared only by `ph-unlock --clear-lockdown` over the cable, which prompts (skippable) for `verify-card`.

**Enforcement is off-device.** The phone log is authoritative. The `/base` flag is defense in depth only: whoever holds the card can erase it, but gains nothing because the keys come only from us. On-Pi cluster state is reported in the next check-in, and the phone then holds it.

**Limits [CEILING]:**
- Plug cycles shorter than reaching initrd (≈10 s `[ESTIMATE]`) are invisible. Upgrade path: U-Boot bootcount `[VERIFY]` in the nixos-hardware build.
- A careful single-pull evil maid is indistinguishable from an unplug. Accepted, given room access control. `verify-card` remains available.
- Probing somewhere with no network is invisible off-device. The on-Pi counter covers the monkey case, and lost mode covers theft.
- A compromised Pi cannot attest its own integrity. Detection, not prevention, on hardware with no root of trust.

## 7. Interfaces for sub-projects 3 and 4 (specified, not built)

- `ph-erase`: `cryptsetup luksErase` on the persist device, then tailscaled swap to the locked identity.
- Boot-log record: JSON lines `{ts, boot_id, prev_uptime_s, ssid, bssid, public_ip, source: "pi"|"checkin", cluster: null|"local"|"remote"}`.
- Theft flag + "never-seen network" check: read by lost mode.

## 8. Provisioning and reflash (`ph-provision`)

1. `nix build .#sdImage` (binfmt) with auto-expand disabled `[VERIFY sdImage.expandOnBoot]`.
2. Flash card #2. Interactive confirmation of the target device path (destructive).
3. Partition system / persist (§2).
4. `luksFormat --type luks2 --cipher xchacha12,aes-adiantum-plain64` with slots 0/1/2 (§3 PBKDF rules).
5. Populate `/persist` (sops age key) and `/base` (SSH host key; **single-use** `tag:panhandler-locked` authkey, spent at first boot). Mint a single-use `tag:panhandler` key into sops for the main identity.
6. Split `K`. Write `S_L`. Run phone enrollment (Keystore key, `S_P'`). `rbw add` the Bitwarden-backed items.
7. Boot on the Pi; run the acceptance list (§9).

## 9. Verification

**VM test (x86_64, native, in `flake checks`):** tmpfs root wiped on reboot; LUKS on a virtual disk with three slots; `ph-unlockd` accepts slot 0/1/2 keys and rejects garbage; both cluster rules; lockdown refuses non-eth0 sessions; `RequiresMountsFor` gating.

**On device:**
- [ ] Boot locked → check-in → notification → tap → unlocked → `tailscale status` shows `tag:panhandler`.
- [ ] Passphrase over the cable; `--bitwarden` path; `rbw` locked afterwards.
- [ ] 3 plug cycles in 15 min → LOCKDOWN; remote paths refuse; cable unlock + `--clear-lockdown` works.
- [ ] `nmap` from the LAN: nothing on wlan0, locked and unlocked.
- [ ] File planted in `/root` is gone after reboot.
- [ ] Unlock does not OOM; measure tmpfs and RAM headroom.
- [ ] Full reflash timed end to end (R5).

## 10. `[VERIFY]` list (resolve in the plan, before code depends on it)

- `CONFIG_CRYPTO_ADIANTUM` in the NixOS mainline aarch64 kernel.
- NixOS `services.tailscale` statedir override (e.g. `extraDaemonFlags`) and a clean restart-based swap.
- `sdImage.expandOnBoot` exists and stops root growth.
- `termux-keystore`: user-auth validity flag; RSA signing is PKCS#1 v1.5 (deterministic). Fallback if not: plain-file share, with the consent gap recorded as `[CEILING]`.
- Termux listener survives Android background limits (piggyback on phone-agent's persistence).
- Tailscale ephemeral-node removal timing (justifies D8; documentation only).
- `impermanence` flake compatibility with nixpkgs 26.11.
- Laptop agent reachability given volnix Tailscale runs in a MicroVM.

## 11. Doc fixes bundled with this sub-project

- HARDENING: resolve the cable/Wi-Fi key-custody conflict → D1–D4; record its origin.
- THREAT-MODEL A0: add the evil-maid / persistence gap and the detection-not-prevention ceiling.
- RISKS R7: "crypto-erase + poweroff" → "crypto-erase + lost mode" (matches HARDENING).
- decisions.md (via memd inbox): mark "LUKS deferred" and "ephemeral authkey" superseded.

## 12. Out of scope

Dead-man heartbeat logic, beacon payload/channels (3, 4); runtime hardening (2); gateway features (blueprint phase 2+); Tailscale ACL authoring beyond the policy stated in §2 (applied by the user in the admin console).

## 13. Build amendments (2026-10-17, from verification during the build)

| Spec said | Built | Evidence |
|---|---|---|
| tailscaled `--statedir` swap | `/var/lib/tailscale` bind-mount swap (`ph-tailscale-state`); tailscaled is `partOf` it | packaged unit hardcodes `--state=/var/lib/tailscale/tailscaled.state` |
| `impermanence` flake | dropped | its mounts are boot-time; `/persist` isn't mounted while locked → boot hangs. `/var/lib/nixos` binds from `/base`; `/persist` is a bare `systemd.mounts` unit pulled in only by `ph-persist.target` |
| tmpfs `/` + `/nix` | also `/boot` bound from the SD | extlinux lives on the root partition; a tmpfs `/boot` loses the bootloader on every rebuild |
| persist by partlabel | by LUKS UUID (`panhandler.spine.persistUuid`, set with `luksFormat --uuid`) | sd-image uses a DOS table: no partlabels |
| on-Pi rule "3 boots / 15 min" | "3 consecutive boots, each dying before 15 min uptime" | the Pi has no RTC; early-boot wall time is garbage offline, uptime is monotonic |
| boot counter in initrd | `boot.initrd.systemd.services.ph-bootcount` | 26.11 initrd is systemd-based |
| sops at sysinit | `sops-install-secrets.wantedBy = mkForce [ "ph-persist.target" ]` | upstream `RequiresMountsFor` the key would stall every locked boot |
| Wi-Fi PSK via sops template | `/base/ph/wireless.env`, written by `ph-provision` | Wi-Fi must work while locked; sops stays the source of truth |
| tailscale module autoconnect | `ph-tailscale-up`: single-use key for whichever identity is active | `authKeyFile` takes one path; there are two identities |
| laptop agent notifies via phone-agent MCP | the phone listener notifies itself (`termux-notification`); the agent only fetches the tapped share | removes the MCP bearer token from the unlock path, and alerts still fire with the laptop away |
| lockdown on Pi only from the local rule | the listener's check-in reply carries lockdown; `ph-checkin` mirrors it to `/base` | a phone-held lockdown must also stop manual tailnet unlocks |
| Keystore: biometric per use | `termux-keystore -u 15`: key usable 15 s after any device unlock | `termux-keystore` help text. `[CEILING]` laptop malware holding the listener allowlist could sign inside that window; the bag thief cannot. Upgrade: a small dedicated Android app with per-use BiometricPrompt |
| phone share = SHA-256 pad | SHA-512 pad | the share is 64 bytes |

Verified facts: `CONFIG_CRYPTO_ADIANTUM=m` + `NHPOLY1305_NEON=m` in the 6.18.56 aarch64 config; the live Pi's CPU flags `fp asimd evtstrm crc32 cpuid` (no `aes`); `sdImage.expandOnBoot` (default true) and `nixPathRegistrationFile` exist; `SHA256withRSA` is PKCS#1 v1.5 (deterministic).

`[UNVERIFIED]`, settled at first boot of card #2 (card #1 = rollback): systemd-initrd prefixes `/sysroot` onto bind-mount *sources* (`/sd/nix`, `/sd/boot`, `/sd/base`).

Not yet built: `verify-card`, `ph-rekey` (neither gates the unlock path; slots 1 and 2 cover phone loss until `ph-rekey` exists).
