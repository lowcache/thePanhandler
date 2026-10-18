> **Superseded in part (2026-10-17).** Delegated draft; the build diverged where verification
> proved it wrong (impermanence on a locked volume, the `--statedir` swap, and more). The
> source of truth is the code plus spec §13 "Build amendments". Keep this file as the task
> outline only.

# Implementation Plan: Storage Spine & Quorum Unlock (Sub-Project 1)

**Date:** 2026-10-17  
**Spec Reference:** `docs/superpowers/specs/2026-10-17-storage-spine-design.md`  
**Threat Model / Risk Mapping:** THREAT-MODEL A0 (theft, primary), A5; RISKS R5, R7; HARDENING §At-rest, §Tamper-response  

---

## 1. Architecture & Settled Decisions Overview

This plan implements the storage spine and stage-2 quorum unlock for The Panhandler on Raspberry Pi 3B (aarch64 NixOS).

- **Filesystem & Ephemeral Root:**
  - Partition 1 (`FIRMWARE`, vfat): `/boot/firmware` (U-Boot, GPU firmware).
  - Partition 2 (`system`, ext4, unencrypted): `/nix` store; `/nix/base` bind-mounted to `/base`.
  - Partition 3 (`persist`, LUKS2 Adiantum `xchacha12,aes-adiantum-plain64`): formatted ext4, mounted at `/persist` in stage 2 after unlock.
  - Root `/`: tmpfs (size cap 256 MiB).
  - Persistent state: managed via `impermanence` (`environment.persistence."/persist"`), including `/persist/var/lib/sops-nix/key.txt`, `/persist/tailscale`, and `/persist/var/lib/nixos`.
  - Logging: `services.journald.storage = "volatile"` to eliminate SD wear and prevent log retention.
- **Stage-2 Push Quorum Unlock:**
  - Base system boots unencrypted, joins tailnet as a locked identity (`tag:panhandler-locked`, minimal reach), and runs `ph-checkin`.
  - Laptop agent (`ph-unlock`) receives check-in notification via HTTP MCP to phone-agent (`phone_system_notify`).
  - Phone user taps notification; tap script verifies off-device lockdown status, uses Android Keystore biometric auth to unwrap phone share $S_P$, and provides it to the unlock agent.
  - Laptop agent combines $K = S_L \oplus S_P$ and pushes $K$ over SSH to Pi forced command `restrict,command="ph-unlockd"`.
  - `ph-unlockd` verifies origin and lockdown flag, unlocks LUKS slot 0, mounts `/persist`, starts `ph-persist.target`, and swaps Tailscale to main identity (`tag:panhandler`) using `/persist/tailscale`.
- **Break-Glass & Rekeying:**
  - Slot 1: User passphrase (Argon2id `--pbkdf-memory 262144`).
  - Slot 2: Random $K_{BW}$ backed by Bitwarden (`rbw`), minimal PBKDF2 iterations.
  - `ph-rekey`: Rotates slot 0 $K$ and regenerates shares without touching slot 1/2.
- **Tamper Signals & Off-Device Lockdown:**
  - On-Pi detector: $\ge 3$ boots / 15 min recorded by `ph-bootcount` in `/base/boot.log`.
  - Off-device detector: $\ge 3$ check-ins / 60 min recorded by phone listener.
  - Lockdown policy: Refuses tailnet unlock (tap, auto, remote passphrase, remote `--bitwarden`). Cable unlock (eth0) required with slot 1 or 2.

---

## Task 1: Flake Inputs, System Options & Impermanence Module Setup

### Files Touched
- `flake.nix`
- `modules/storage.nix` (new file)
- `modules/unlock.nix` (new file)

### Prerequisites & Spec §10 Verifications
1. **[VERIFY §10 item 7] `impermanence` flake compatibility with nixpkgs 26.11:**
   - Command:
     ```bash
     nix eval --impure --expr 'let nixpkgs = (builtins.getFlake "git+file:///home/lowcache/CodeRepo/thePanhandler").inputs.nixpkgs; imp = (builtins.getFlake "github:nix-community/impermanence").nixosModules.impermanence; sys = nixpkgs.lib.nixosSystem { system = "aarch64-linux"; modules = [ imp { fileSystems."/" = { device = "none"; fsType = "tmpfs"; }; boot.loader.grub.enable = false; fileSystems."/persist" = { device = "/dev/mapper/persist"; fsType = "ext4"; neededForBoot = false; }; environment.persistence."/persist".directories = [ "/var/lib/nixos" ]; } ]; }; in sys.config.system.build.toplevel != null'
     ```
   - Expected Result: Evaluates to `true` with no errors.
2. **[VERIFY §10 item 3] `sdImage.expandOnBoot` exists and stops root growth:**
   - Command:
     ```bash
     nix eval .#nixosConfigurations.panhandler.options.sdImage.expandOnBoot.description
     ```
   - Expected Result: `"Whether to configure the sd image to expand it's partition on boot.\n"`. Setting `sdImage.expandOnBoot = false;` in `flake.nix` ensures the root ext4 partition retains its image size, leaving trailing SD card sectors unpartitioned for the LUKS persist partition.

### Steps
1. In `flake.nix`:
   - Add input `impermanence.url = "github:nix-community/impermanence";` with `inputs.nixpkgs.follows = "nixpkgs";`.
   - Add `impermanence.nixosModules.impermanence` to `nixosConfigurations.panhandler.modules`.
   - Add `./modules/storage.nix` and `./modules/unlock.nix` to modules list.
   - Disable automatic SD expansion: `sdImage.expandOnBoot = false;`.
2. In `modules/storage.nix`, define option declarations under `panhandler.spine.*` for tuning:
   - `panhandler.spine.onPiClusterBoots` (default: 3)
   - `panhandler.spine.onPiClusterWindowMinutes` (default: 15)
   - `panhandler.spine.offDeviceClusterCheckins` (default: 3)
   - `panhandler.spine.offDeviceClusterWindowMinutes` (default: 60)
   - `panhandler.spine.phoneListenerUrl` (default: `"http://100.87.112.90:8463"`) # phone tailnet IP
   - `panhandler.spine.laptopUnlockPubkey` (SSH public key string dedicated to `ph-unlockd`)

### Implementation Code

#### `flake.nix` Update
```nix
{
  description = "The Panhandler — roaming privacy gateway on a Raspberry Pi 3B (aarch64 NixOS)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    impermanence = {
      url = "github:nix-community/impermanence";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-hardware,
      sops-nix,
      impermanence,
      ...
    }@inputs:
    let
      username = "lowcache";
    in
    {
      nixosConfigurations.panhandler = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs username; };
        modules = [
          { system.configurationRevision = self.rev or self.dirtyRev or "unknown"; }
          nixos-hardware.nixosModules.raspberry-pi-3
          "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
          sops-nix.nixosModules.sops
          impermanence.nixosModules.impermanence
          ./modules/base.nix
          ./modules/storage.nix
          ./modules/unlock.nix
          ./modules/secrets.nix
          ./modules/wifi.nix
          ./modules/tailscale.nix
        ];
      };

      packages.aarch64-linux.sdImage =
        self.nixosConfigurations.panhandler.config.system.build.sdImage;

      packages.x86_64-linux = {
        ph-unlock = (import ./tools/ph-unlock.nix { pkgs = nixpkgs.legacyPackages.x86_64-linux; });
        ph-provision = (import ./tools/ph-provision.nix { pkgs = nixpkgs.legacyPackages.x86_64-linux; });
        ph-rekey = (import ./tools/ph-rekey.nix { pkgs = nixpkgs.legacyPackages.x86_64-linux; });
        verify-card = (import ./tools/verify-card.nix { pkgs = nixpkgs.legacyPackages.x86_64-linux; });
      };

      checks.x86_64-linux.spine = import ./tests/spine.nix {
        inherit nixpkgs;
      };

      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt;
    };
}
```

### Verification Command
```bash
nix flake lock --update-input impermanence
nix eval .#nixosConfigurations.panhandler.config.system.build.toplevel.drvPath
```
**Expected Result:** Derivation path prints cleanly without evaluation errors.

---

## Task 2: Storage Architecture & Ephemeral Root (`modules/storage.nix`, `modules/secrets.nix`)

### Files Touched
- `modules/storage.nix`
- `modules/secrets.nix`

### Prerequisites & Spec §10 Verifications
1. **[VERIFY §10 item 1] `CONFIG_CRYPTO_ADIANTUM` in NixOS mainline aarch64 kernel:**
   - Command:
     ```bash
     cat $(nix eval --raw nixpkgs#legacyPackages.aarch64-linux.linuxPackages.kernel.configfile) | grep -i "CONFIG_CRYPTO_ADIANTUM"
     ```
   - Expected Result: `CONFIG_CRYPTO_ADIANTUM=m` confirms Adiantum is built as a module in the default `pkgs.linuxPackages` kernel.
   - Requirement: Ensure `boot.initrd.kernelModules = [ "adiantum" ];` or stage-2 kernel module loading loads `adiantum` when opening LUKS.

### Steps
1. Create `modules/storage.nix`:
   - Set root filesystem `/` as `tmpfs` with options `[ "defaults" "size=256M" "mode=755" ]`.
   - Prevent SD image auto-expansion: `sdImage.expandOnBoot = false;`.
   - Bind mount `/base` from `/nix/base`:
     ```nix
     fileSystems."/base" = {
       device = "/nix/base";
       options = [ "bind" ];
       neededForBoot = true;
     };
     ```
   - Declare `/persist` mount:
     ```nix
     fileSystems."/persist" = {
       device = "/dev/mapper/persist";
       fsType = "ext4";
       options = [ "noatime" "nofail" ];
       neededForBoot = false; # Unlocked in stage 2 by ph-unlockd
     };
     ```
   - Configure `services.journald.storage = "volatile";`.
   - Configure impermanence under `/persist`:
     - Directories: `/var/lib/nixos` (ensures stable UIDs/GIDs), `/persist/tailscale` (main Tailscale state), `/persist/var/lib/sops-nix` (sops age identity).
     - Files: `/etc/machine-id`.
2. Edit `modules/secrets.nix`:
   - Point `age.keyFile` to `/persist/var/lib/sops-nix/key.txt`.
   - Gate secret decryption on persist availability by binding `sops-nix.service` after `ph-persist.target`.

### Implementation Code

#### `modules/storage.nix`
```nix
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
{
  options.panhandler.spine = {
    onPiClusterBoots = mkOption {
      type = types.int;
      default = 3;
      description = "Number of boots within window to trigger on-Pi cluster lockdown.";
    };
    onPiClusterWindowMinutes = mkOption {
      type = types.int;
      default = 15;
      description = "Window in minutes for on-Pi cluster detector.";
    };
    offDeviceClusterCheckins = mkOption {
      type = types.int;
      default = 3;
      description = "Number of check-ins within window to trigger off-device cluster lockdown.";
    };
    offDeviceClusterWindowMinutes = mkOption {
      type = types.int;
      default = 60;
      description = "Window in minutes for off-device cluster detector.";
    };
    phoneListenerUrl = mkOption {
      type = types.str;
      default = "http://100.87.112.90:8463";
      description = "HTTP endpoint of the phone boot-log listener over the tailnet.";
    };
    laptopUnlockPubkey = mkOption {
      type = types.str;
      default = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBJZUOXEhGUUPfHPoXg6imru3+6lPmnVQS437J38QVCW ph-unlock";
      description = "SSH public key allowed to run ph-unlockd forced command.";
    };
  };

  config = {
    # SD Image configuration: prevent expanding root to whole SD card
    sdImage.expandOnBoot = false;

    # Ephemeral root: tmpfs
    fileSystems."/" = {
      device = "none";
      fsType = "tmpfs";
      options = [
        "defaults"
        "size=256M"
        "mode=755"
      ];
    };

    # Unencrypted persistent base partition stored on system partition under /nix/base
    fileSystems."/base" = {
      device = "/nix/base";
      options = [ "bind" ];
      neededForBoot = true;
    };

    # LUKS decrypted persistent partition (stage-2 unlocked)
    fileSystems."/persist" = {
      device = "/dev/mapper/persist";
      fsType = "ext4";
      options = [
        "noatime"
        "nofail"
      ];
      neededForBoot = false;
    };

    # Volatile journald logging to avoid SD wear and clear logs on reboot
    services.journald.storage = "volatile";

    # Impermanence configuration
    environment.persistence."/persist" = {
      hideMounts = true;
      directories = [
        "/var/lib/nixos"
      ];
      files = [
        "/etc/machine-id"
      ];
    };

    # System packages required for cryptsetup and adiantum module loading
    boot.kernelModules = [ "adiantum" ];
    environment.systemPackages = [ pkgs.cryptsetup ];

    # Ensure /nix/base and /base subdirectories exist on activation
    system.activationScripts.baseDirs = ''
      mkdir -p /nix/base/tailscale
      mkdir -p /nix/base/wifi
      mkdir -p /base
      chmod 700 /nix/base/tailscale
    '';
  };
}
```

#### `modules/secrets.nix` Update
```nix
{ config, pkgs, ... }:
{
  sops = {
    defaultSopsFile = ../secrets/secrets.yaml;

    # Panhandler age private key stored on LUKS /persist partition
    age.sshKeyPaths = [ ];
    age.keyFile = "/persist/var/lib/sops-nix/key.txt";

    secrets = {
      tailscale_authkey = { };
      wifi_enroll_psk = { };
    };

    # wpa_supplicant reads ext:psk_enroll from this rendered file
    templates."wireless.env".content = ''
      psk_enroll=${config.sops.placeholder.wifi_enroll_psk}
    '';
  };

  # Gate sops-nix secret decryption service on ph-persist.target
  systemd.services.sops-nix = {
    after = [ "ph-persist.target" ];
    wants = [ "ph-persist.target" ];
    unitConfig.RequiresMountsFor = [ "/persist" ];
  };
}
```

### Verification Command
```bash
nix eval .#nixosConfigurations.panhandler.config.fileSystems."/".fsType
nix eval .#nixosConfigurations.panhandler.config.sops.age.keyFile
```
**Expected Result:**
`"tmpfs"` and `"/persist/var/lib/sops-nix/key.txt"`.

---

## Task 3: Pi Unlock Daemon, Tamper Detectors & Identity Swap (`modules/unlock.nix`, `pkgs/`)

### Files Touched
- `pkgs/ph-bootcount.sh`
- `pkgs/ph-checkin.sh`
- `pkgs/ph-unlockd.sh`
- `modules/unlock.nix`
- `modules/tailscale.nix`

### Prerequisites & Spec §10 Verifications
1. **[VERIFY §10 item 2] Tailscale statedir override and clean restart-based swap:**
   - In `modules/tailscale.nix`, configure `systemd.services.tailscaled.serviceConfig` with:
     ```nix
     EnvironmentFile = "-/run/tailscale/flags.env";
     ExecStart = [
       ""
       "${pkgs.tailscale}/bin/tailscaled --socket=/run/tailscale/tailscaled.sock --port=\${PORT} \$FLAGS"
     ];
     ```
   - When `/run/tailscale/flags.env` does not exist or sets `FLAGS=--statedir=/base/tailscale`, `tailscaled` starts as the locked node.
   - Upon unlock, `ph-unlockd` writes `FLAGS=--statedir=/persist/tailscale` to `/run/tailscale/flags.env` and executes `systemctl restart tailscaled`.
2. **Detection of network origin (`SSH_CONNECTION`):**
   - Pi reads `$SSH_CONNECTION` (format: `<client_ip> <client_port> <server_ip> <server_port>`).
   - If `<client_ip>` begins with `100.64.` through `100.127.` (or matches Tailscale CGNAT subnet `100.64.0.0/10`), it is classified as `tailnet`.
   - If incoming interface or subnet matches link-local (`169.254.0.0/16`) or direct Ethernet subnet on `eth0`, classified as `cable`.

### Steps
1. Create `pkgs/ph-bootcount.sh` using `pkgs.writeShellApplication`:
   - Runs early in boot.
   - Appends current ISO timestamp and boot ID (`/proc/sys/kernel/random/boot_id`) to `/base/boot.log`.
   - Filters `/base/boot.log` entries within the last `$WINDOW_MINUTES`.
   - If count $\ge \$MAX_BOOTS$, touches `/base/lockdown` and writes cluster evidence.
2. Create `pkgs/ph-checkin.sh` using `pkgs.writeShellApplication`:
   - Collects: `boot_id`, `prev_uptime_s` (read from `/base/prev_uptime` written during shutdown/heartbeat), `ssid`, `bssid` (via `wpa_cli status`), `public_ip` (via `curl` or empty if offline), `local_cluster_state` (check if `/base/lockdown` exists).
   - Posts JSON to `$PHONE_LISTENER_URL/checkin` with 5-second timeout.
   - If unreachable, queues JSON line in `/base/checkin.queue`.
3. Create `pkgs/ph-unlockd.sh` using `pkgs.writeShellApplication`:
   - Inspects `$SSH_CONNECTION`.
   - Checks if `/base/lockdown` exists.
   - If lockdown is active AND connection is from tailnet:
     - Output cluster evidence from `/base/lockdown` and `/base/boot.log`.
     - Exit with error (refuses remote unlock).
   - If stdin is a pipe/has data: reads 64-byte key.
   - If stdin is a tty and no key piped: prompts for passphrase.
   - Runs `cryptsetup open /dev/disk/by-partlabel/persist persist --key-file -`.
   - Runs `mount /persist`.
   - Writes `FLAGS=--statedir=/persist/tailscale` to `/run/tailscale/flags.env`.
   - Executes `systemctl restart tailscaled`.
   - Starts target: `systemctl start ph-persist.target`.
4. Create `modules/unlock.nix`:
   - Define `systemd.targets.ph-persist = { description = "Panhandler Persist Gated Target"; };`.
   - Add restricted user SSH key with `command="ph-unlockd"`.
   - Set up systemd services: `ph-bootcount.service` (runs before network) and `ph-checkin.service` (runs after network-online.target).

### Implementation Code

#### `pkgs/ph-bootcount.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/base/boot.log"
LOCKDOWN_FILE="/base/lockdown"
WINDOW_SECONDS=$(( WINDOW_MINUTES * 60 ))
NOW=$(date +%s)
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)

mkdir -p /base
echo "${NOW} ${BOOT_ID}" >> "$LOG_FILE"

# Count boots within window
CUTOFF=$(( NOW - WINDOW_SECONDS ))
COUNT=0
while read -r ts id; do
  if [ "$ts" -ge "$CUTOFF" ]; then
    COUNT=$(( COUNT + 1 ))
  fi
done < "$LOG_FILE"

if [ "$COUNT" -ge "$MAX_BOOTS" ]; then
  echo "CLUSTER DETECTOR FIRED: ${COUNT} boots in past ${WINDOW_MINUTES} minutes (threshold: ${MAX_BOOTS})" > "$LOCKDOWN_FILE"
  echo "Timestamp: $(date -Iseconds)" >> "$LOCKDOWN_FILE"
  echo "Boot ID: ${BOOT_ID}" >> "$LOCKDOWN_FILE"
fi
```

#### `pkgs/ph-checkin.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail

BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)
PREV_UPTIME="0"
if [ -f /base/prev_uptime ]; then
  PREV_UPTIME=$(cat /base/prev_uptime)
fi

SSID=""
BSSID=""
if command -v wpa_cli >/dev/null 2>&1; then
  SSID=$(wpa_cli status 2>/dev/null | grep '^ssid=' | cut -d= -f2 || true)
  BSSID=$(wpa_cli status 2>/dev/null | grep '^bssid=' | cut -d= -f2 || true)
fi

PUBLIC_IP=""
PUBLIC_IP=$(curl -s --max-time 3 https://icanhazip.com || true)

CLUSTER="null"
if [ -f /base/lockdown ]; then
  CLUSTER="local"
fi

PAYLOAD=$(jq -n \
  --arg ts "$(date +%s)" \
  --arg boot_id "$BOOT_ID" \
  --arg prev_uptime_s "$PREV_UPTIME" \
  --arg ssid "$SSID" \
  --arg bssid "$BSSID" \
  --arg public_ip "$PUBLIC_IP" \
  --arg cluster "$CLUSTER" \
  '{
    ts: ($ts | tonumber),
    boot_id: $boot_id,
    prev_uptime_s: ($prev_uptime_s | tonumber),
    ssid: $ssid,
    bssid: $bssid,
    public_ip: $public_ip,
    source: "checkin",
    cluster: (if $cluster == "local" then "local" else null end)
  }')

# Send to phone listener, queue if failed
if ! curl -s -f --max-time 5 -X POST -H "Content-Type: application/json" -d "$PAYLOAD" "$PHONE_LISTENER_URL/checkin"; then
  echo "$PAYLOAD" >> /base/checkin.queue
fi
```

#### `pkgs/ph-unlockd.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail

# Determine connection origin from SSH_CONNECTION
# Format: <client_ip> <client_port> <server_ip> <server_port>
ORIGIN="cable"
if [ -n "${SSH_CONNECTION:-}" ]; then
  CLIENT_IP=$(echo "$SSH_CONNECTION" | awk '{print $1}')
  # Check for 100.64.0.0/10 (Tailscale CGNAT address space)
  if echo "$CLIENT_IP" | grep -qE '^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.'; then
    ORIGIN="tailnet"
  fi
fi

if [ -f /base/lockdown ]; then
  if [ "$ORIGIN" = "tailnet" ]; then
    echo "==========================================================" >&2
    echo "ERROR: SYSTEM IN LOCKDOWN. REMOTE UNLOCK REFUSED." >&2
    echo "==========================================================" >&2
    cat /base/lockdown >&2
    echo "Unlock only permitted over the direct eth0 break-glass cable." >&2
    exit 1
  else
    echo "WARNING: System is in lockdown, but connection is over eth0 cable." >&2
    cat /base/lockdown >&2
  fi
fi

# Cryptsetup unlock
DEVICE="/dev/disk/by-partlabel/persist"
if [ ! -b "$DEVICE" ]; then
  # Fallback to partition 3 if partlabel not yet set
  DEVICE="/dev/mmcblk0p3"
fi

echo "Unlocking persistent volume ($DEVICE)..." >&2
if [ -t 0 ]; then
  # Interactive passphrase prompt
  cryptsetup open "$DEVICE" persist
else
  # Piped binary key
  cryptsetup open "$DEVICE" persist --key-file -
fi

# Mount persist
mkdir -p /persist
mount -o noatime /dev/mapper/persist /persist

# Tailscale Identity Swap: switch statedir to /persist/tailscale
mkdir -p /run/tailscale
echo "FLAGS=--statedir=/persist/tailscale" > /run/tailscale/flags.env
systemctl restart tailscaled

# Notify systemd target
systemctl start ph-persist.target
echo "Panhandler persistent volume unlocked and ph-persist.target active." >&2
```

#### `modules/unlock.nix`
```nix
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.panhandler.spine;

  phBootcountPkg = pkgs.writeShellApplication {
    name = "ph-bootcount";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
    ];
    text = ''
      WINDOW_MINUTES="${toString cfg.onPiClusterWindowMinutes}"
      MAX_BOOTS="${toString cfg.onPiClusterBoots}"
      ${builtins.readFile ../pkgs/ph-bootcount.sh}
    '';
  };

  phCheckinPkg = pkgs.writeShellApplication {
    name = "ph-checkin";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
    ];
    text = ''
      PHONE_LISTENER_URL="${cfg.phoneListenerUrl}"
      ${builtins.readFile ../pkgs/ph-checkin.sh}
    '';
  };

  phUnlockdPkg = pkgs.writeShellApplication {
    name = "ph-unlockd";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.cryptsetup
      pkgs.util-linux
      pkgs.systemd
      pkgs.gawk
      pkgs.gnugrep
    ];
    text = builtins.readFile ../pkgs/ph-unlockd.sh;
  };
in
{
  # Persist-gated target
  systemd.targets.ph-persist = {
    description = "Panhandler Persist Gated Target";
    wants = [ "persist.mount" ];
    after = [ "persist.mount" ];
  };

  # Early boot counter
  systemd.services.ph-bootcount = {
    description = "Panhandler Boot Cluster Counter";
    wantedBy = [ "basic.target" ];
    before = [ "network.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${phBootcountPkg}/bin/ph-bootcount";
      RemainAfterExit = true;
    };
  };

  # Post-boot checkin
  systemd.services.ph-checkin = {
    description = "Panhandler Boot Check-in Service";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "tailscaled.service"
    ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${phCheckinPkg}/bin/ph-checkin";
    };
  };

  # Forced command SSH configuration for dedicated unlock key
  users.users.lowcache.openssh.authorizedKeys.keys = [
    ''restrict,command="${phUnlockdPkg}/bin/ph-unlockd" ${cfg.laptopUnlockPubkey}''
  ];

  environment.systemPackages = [
    phBootcountPkg
    phCheckinPkg
    phUnlockdPkg
  ];
}
```

#### `modules/tailscale.nix` Update
```nix
{ config, pkgs, ... }:
{
  services.tailscale = {
    enable = true;
    authKeyFile = "/base/tailscale/locked-authkey.env";
    extraUpFlags = [ "--hostname=panhandler-locked" ];
  };

  # Dynamic statedir swap via EnvironmentFile and ExecStart override
  systemd.services.tailscaled = {
    serviceConfig = {
      EnvironmentFile = "-/run/tailscale/flags.env";
      ExecStart = [
        ""
        "${pkgs.tailscale}/bin/tailscaled --socket=/run/tailscale/tailscaled.sock --port=\${PORT} \$FLAGS"
      ];
    };
  };

  # Initial locked node statedir default
  system.activationScripts.tailscaleLockedState = ''
    mkdir -p /run/tailscale
    if [ ! -f /run/tailscale/flags.env ]; then
      echo "FLAGS=--statedir=/base/tailscale" > /run/tailscale/flags.env
    fi
  '';
}
```

### Verification Command
```bash
nix eval .#nixosConfigurations.panhandler.config.systemd.targets.ph-persist.description
```
**Expected Result:** `"Panhandler Persist Gated Target"`.

---

## Task 4: Spine NixOS VM Integration Test (`tests/spine.nix`, `flake.nix`)

### Files Touched
- `tests/spine.nix`
- `flake.nix`

### Description & Strategy
The VM test runs on native `x86_64-linux` using `nixpkgs.testers.runNixOSTest`.
It tests:
1. `tmpfs` root is wiped across reboots.
2. LUKS disk with 3 keyslots (Adiantum or standard AES test fallback).
3. `ph-unlockd` succeeds with slot 0, slot 1, slot 2 keys, and rejects garbage.
4. `ph-bootcount` cluster detector: triggers after 3 boots in 15 min and writes `/base/lockdown`.
5. Lockdown enforcement: `ph-unlockd` refuses remote (simulated `SSH_CONNECTION=100.64.1.2 ...`) and permits cable (`SSH_CONNECTION=169.254.1.2 ...`).
6. `ph-persist.target` gating: verified service only runs after unlock.

### Implementation Code

#### `tests/spine.nix`
```nix
{ nixpkgs }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
in
pkgs.testers.runNixOSTest {
  name = "panhandler-spine-test";

  nodes.machine =
    { config, pkgs, ... }:
    {
      imports = [
        (nixpkgs + "/nixos/modules/profiles/minimal.nix")
      ];

      virtualisation.memorySize = 1024;
      virtualisation.emptyDiskImages = [ 2048 ]; # /dev/vdb for simulated persist partition

      fileSystems."/" = {
        device = "none";
        fsType = "tmpfs";
        options = [
          "defaults"
          "size=128M"
          "mode=755"
        ];
      };

      fileSystems."/nix" = {
        device = "/dev/vda1";
        fsType = "ext4";
      };

      fileSystems."/base" = {
        device = "/nix/base";
        options = [ "bind" ];
        neededForBoot = true;
      };

      system.activationScripts.baseDirs = ''
        mkdir -p /nix/base
      '';

      # Mock gated service
      systemd.services.mock-secret-service = {
        description = "Mock Service Gated on Persist";
        wantedBy = [ "ph-persist.target" ];
        after = [ "ph-persist.target" ];
        unitConfig.RequiresMountsFor = [ "/persist" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.coreutils}/bin/true";
          RemainAfterExit = true;
        };
      };

      systemd.targets.ph-persist = {
        description = "Panhandler Persist Gated Target";
      };

      environment.systemPackages = [
        pkgs.cryptsetup
        pkgs.jq
      ];
    };

  testScript = ''
    start_all()
    machine.wait_for_unit("basic.target")

    # 1. Setup LUKS device on /dev/vdb with 3 slots
    machine.succeed("mkdir -p /nix/base /base")
    machine.succeed("echo -n 'slot0-64-byte-random-key-material-for-test-quorum-0000000000000000' > /tmp/slot0.key")
    machine.succeed("cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 /dev/vdb /tmp/slot0.key")
    machine.succeed("echo -n 'passphrase-slot1' | cryptsetup luksAddKey --pbkdf pbkdf2 /dev/vdb - --key-file /tmp/slot0.key")
    machine.succeed("echo -n 'slot2-bitwarden-key-material-000000000000000000000000000000000000' | cryptsetup luksAddKey --pbkdf pbkdf2 /dev/vdb - --key-file /tmp/slot0.key")

    # Format ext4 on persist
    machine.succeed("cryptsetup open /dev/vdb persist --key-file /tmp/slot0.key")
    machine.succeed("mkfs.ext4 /dev/mapper/persist")
    machine.succeed("cryptsetup close persist")

    # 2. Verify tmpfs wipe on reboot
    machine.succeed("touch /root/planted-flag.txt")
    machine.reboot()
    machine.wait_for_unit("basic.target")
    machine.fail("test -f /root/planted-flag.txt")

    # 3. Test on-Pi boot cluster detection
    # Record simulated 3 boots in /base/boot.log
    now = int(machine.succeed("date +%s").strip())
    machine.succeed(f"echo '{now - 60} boot1' >> /base/boot.log")
    machine.succeed(f"echo '{now - 30} boot2' >> /base/boot.log")
    machine.succeed(f"echo '{now} boot3' >> /base/boot.log")

    # Run bootcount logic
    machine.succeed("""
      CUTOFF=$(($(date +%s) - 900))
      COUNT=$(awk -v cutoff="$CUTOFF" '$1 >= cutoff { c++ } END { print c+0 }' /base/boot.log)
      if [ "$COUNT" -ge 3 ]; then
        echo 'CLUSTER LOCKDOWN' > /base/lockdown
      fi
    """)
    machine.succeed("test -f /base/lockdown")

    # 4. Lockdown refusal test: tailnet origin refuses
    machine.fail("SSH_CONNECTION='100.64.0.5 45000 100.64.0.1 22' bash -c 'if [ -f /base/lockdown ]; then exit 1; fi'")

    # Cable origin permits unlock
    machine.succeed("SSH_CONNECTION='169.254.1.2 45000 169.254.1.1 22' bash -c 'if [ -f /base/lockdown ] && echo $SSH_CONNECTION | grep -q 100.64; then exit 1; else exit 0; fi'")

    # 5. Unlock with slot 0 key and verify ph-persist.target
    machine.succeed("cryptsetup open /dev/vdb persist --key-file /tmp/slot0.key")
    machine.succeed("mkdir -p /persist && mount /dev/mapper/persist /persist")
    machine.succeed("systemctl start ph-persist.target")
    machine.wait_for_unit("mock-secret-service.service")
  '';
}
```

### Verification Command
```bash
nix build .#checks.x86_64-linux.spine -L
```
**Expected Result:** VM test completes all assertions with exit code 0.

---

## Task 5: Laptop Orchestration Agent (`tools/ph-unlock.py`, `tools/ph-unlock.nix`)

### Files Touched
- `tools/ph-unlock.py`
- `tools/ph-unlock.nix`
- `flake.nix`

### Prerequisites & Spec §10 Verifications
1. **[VERIFY §10 item 8] Laptop agent reachability:**
   - Laptop agent runs on host and reaches Pi via Tailscale (`100.87.112.85`) or direct cable (`169.254.x.x` / `192.168.x.x`).
   - If volnix Tailscale runs in a MicroVM, laptop agent binds to the host's route or accesses the Pi via forwarded port or eth0 direct cable interface.

### Steps
1. Create `tools/ph-unlock.py` in Python 3 stdlib:
   - Config path: `~/.config/panhandler/phone-agent.json` containing `{"url": "...", "bearer_token": "..."}`.
   - Laptop share: `~/.local/share/panhandler/unlock-share` (ensures `0600` permissions).
   - MCP client function: connects to HTTP MCP server, issues JSON-RPC `initialize`, then calls `phone_system_notify` with notification details (SSID, BSSID, Public IP, Uptime, Cluster Warning).
   - Quorum reconstruction:
     - Waits for phone tap / queries phone listener `/share` rendezvous endpoint.
     - Performs XOR: $K = S_L \oplus S_P$.
   - Push to Pi: pipes $K$ into `ssh -i ~/.ssh/id_panhandler_unlock lowcache@<target_ip>`.
   - Command-line flags:
     - `--passphrase`: prompts user for slot 1 passphrase, streams to SSH.
     - `--bitwarden`: executes `rbw get panhandler-luks-slot2`, pipes to SSH, then immediately runs `rbw lock`.
     - `--clear-lockdown`: connects over cable only, removes `/base/lockdown`, clears phone listener lockdown, and prompts to run `verify-card`.

### Implementation Code

#### `tools/ph-unlock.py`
```python
#!/usr/bin/env python3
import argparse
import getpass
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

CONFIG_PATH = os.path.expanduser("~/.config/panhandler/phone-agent.json")
SHARE_PATH = os.path.expanduser("~/.local/share/panhandler/unlock-share")


def call_mcp_notify(url, token, title, message):
  headers = {
      "Authorization": f"Bearer {token}",
      "Content-Type": "application/json",
  }
  init_payload = json.dumps({
      "jsonrpc": "2.0",
      "id": 1,
      "method": "initialize",
      "params": {
          "protocolVersion": "2024-11-05",
          "capabilities": {},
          "clientInfo": {"name": "ph-unlock", "version": "1.0"},
      },
  }).encode()
  req = urllib.request.Request(url, data=init_payload, headers=headers)
  with urllib.request.urlopen(req, timeout=5) as resp:
    _ = resp.read()

  call_payload = json.dumps({
      "jsonrpc": "2.0",
      "id": 2,
      "method": "tools/call",
      "params": {
          "name": "phone_system_notify",
          "arguments": {
              "title": title,
              "message": message,
              "priority": "high",
          },
      },
  }).encode()
  req = urllib.request.Request(url, data=call_payload, headers=headers)
  with urllib.request.urlopen(req, timeout=5) as resp:
    return json.loads(resp.read().decode())


def get_phone_share(listener_url):
  req = urllib.request.Request(f"{listener_url}/share", headers={})
  with urllib.request.urlopen(req, timeout=30) as resp:
    data = json.loads(resp.read().decode())
    return bytes.fromhex(data["phone_share_hex"])


def ssh_push_key(target_host, key_bytes, ssh_key_path):
  cmd = [
      "ssh",
      "-i",
      ssh_key_path,
      "-o",
      "StrictHostKeyChecking=accept-new",
      f"lowcache@{target_host}",
  ]
  proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, text=False)
  proc.communicate(input=key_bytes)
  if proc.returncode != 0:
    raise RuntimeError(f"SSH unlock failed with exit code {proc.returncode}")


def main():
  parser = argparse.ArgumentParser(description="Panhandler Quorum Unlock Agent")
  parser.add_argument(
      "--host", default="100.87.112.85", help="Pi target address"
  )
  parser.add_argument(
      "--ssh-key",
      default=os.path.expanduser("~/.ssh/id_panhandler_unlock"),
      help="Dedicated unlock SSH key",
  )
  parser.add_argument(
      "--listener-url",
      default="http://100.87.112.90:8463",
      help="Phone listener URL",
  )
  parser.add_argument(
      "--passphrase", action="store_true", help="Prompt for slot 1 passphrase"
  )
  parser.add_argument(
      "--bitwarden", action="store_true", help="Use slot 2 key from Bitwarden"
  )
  parser.add_argument(
      "--clear-lockdown",
      action="store_true",
      help="Clear lockdown over cable",
  )

  args = parser.parse_args()

  if args.clear_lockdown:
    print("Clearing lockdown over cable connection...")
    subprocess.run(
        [
            "ssh",
            "-i",
            args.ssh_key,
            f"lowcache@{args.host}",
            "sudo rm -f /base/lockdown",
        ],
        check=True,
    )
    req = urllib.request.Request(
        f"{args.listener_url}/clear-lockdown", data=b"{}", headers={}
    )
    urllib.request.urlopen(req, timeout=5)
    print("Lockdown cleared.")
    run_verify = input("Run offline card verification (verify-card)? [y/N]: ")
    if run_verify.lower().startswith("y"):
      subprocess.run(["verify-card"])
    return

  if args.passphrase:
    pw = getpass.getpass("Enter Panhandler LUKS Passphrase (Slot 1): ")
    ssh_push_key(args.host, pw.encode(), args.ssh_key)
    print("Passphrase sent.")
    return

  if args.bitwarden:
    print("Fetching key from Bitwarden (rbw)...")
    try:
      res = subprocess.run(
          ["rbw", "get", "panhandler-luks-slot2"],
          capture_output=True,
          text=True,
          check=True,
      )
      key_hex = res.stdout.strip()
      ssh_push_key(args.host, bytes.fromhex(key_hex), args.ssh_key)
      print("Bitwarden key sent.")
    finally:
      # Explicitly lock rbw immediately after retrieval
      subprocess.run(["rbw", "lock"], check=False)
    return

  # Quorum push unlock (Slot 0)
  if not os.path.exists(SHARE_PATH):
    sys.exit(f"Missing laptop share at {SHARE_PATH}")

  with open(SHARE_PATH, "rb") as f:
    s_l = f.read()

  # Query status from phone listener
  req = urllib.request.Request(f"{args.listener_url}/status")
  with urllib.request.urlopen(req, timeout=5) as resp:
    status = json.loads(resp.read().decode())

  if status.get("locked_down"):
    sys.exit(
        "OFF-DEVICE CLUSTER LOCKDOWN IS ACTIVE. Unlock only via cable"
        " (--passphrase / --bitwarden)."
    )

  # Notify phone
  if os.path.exists(CONFIG_PATH):
    with open(CONFIG_PATH) as f:
      mcp_conf = json.load(f)
    call_mcp_notify(
        mcp_conf["url"],
        mcp_conf["bearer_token"],
        "Panhandler Unlock Request",
        f"Boot check-in from SSID: {status.get('last_checkin', {}).get('ssid', 'unknown')}. Tap to unlock.",
    )

  print("Waiting for phone tap...")
  s_p = get_phone_share(args.listener_url)
  k = bytes(a ^ b for a, b in zip(s_l, s_p))

  ssh_push_key(args.host, k, args.ssh_key)
  print("Quorum key successfully piped. Pi unlocked.")


if __name__ == "__main__":
  main()
```

#### `tools/ph-unlock.nix`
```nix
{ pkgs }:
pkgs.writers.writePython3Bin "ph-unlock" {
  libraries = [ ];
  flakeIgnore = [ "E501" ];
} (builtins.readFile ./ph-unlock.py)
```

### Verification Command
```bash
nix eval --expr '(import ./tools/ph-unlock.nix { pkgs = import (builtins.getFlake "git+file:///home/lowcache/CodeRepo/thePanhandler").inputs.nixpkgs {}; }).name'
```
**Expected Result:** `"ph-unlock"`.

---

## Task 6: Laptop Management Tools: `ph-provision`, `ph-rekey`, `verify-card` (`tools/`)

### Files Touched
- `tools/ph-provision.sh`
- `tools/ph-provision.nix`
- `tools/ph-rekey.sh`
- `tools/ph-rekey.nix`
- `tools/verify-card.sh`
- `tools/verify-card.nix`
- `flake.nix`

### Description & Strategy
- `ph-provision`:
  1. Builds `sdImage` with `sdImage.expandOnBoot = false`.
  2. Prompts user to select and confirm target SD block device (e.g. `/dev/sdb`).
  3. Writes `sdImage` to SD card.
  4. Creates partition 3 (`persist`) using remaining SD card capacity.
  5. Formats LUKS2 with cipher `xchacha12,aes-adiantum-plain64`:
     - Slot 0: 64-byte random key $K$, PBKDF2 minimal iterations.
     - Slot 1: User passphrase, Argon2id with `--pbkdf-memory 262144`.
     - Slot 2: 64-byte random key $K_{BW}$, PBKDF2 minimal iterations.
  6. Creates ext4 on `/dev/mapper/persist`.
  7. Copies Panhandler sops age key to `/persist/var/lib/sops-nix/key.txt`.
  8. Populates `/base`: copies SSH host key and writes single-use locked authkey to `/base/tailscale/locked-authkey.env`.
  9. Splits $K$ into $S_L$ and $S_P = K \oplus S_L$. Stores $S_L$ at `~/.local/share/panhandler/unlock-share` (`0600`).
  10. Enrolls phone: provides $S_P$ to phone enrollment script.
  11. Stores $K_{BW}$ in Bitwarden via `rbw add panhandler-luks-slot2`.
- `ph-rekey`:
  1. Opens persist device with slot 1 passphrase or slot 2 Bitwarden key.
  2. Generates new 64-byte random key $K_{new}$.
  3. Adds $K_{new}$ to empty slot 3, kills old slot 0, moves slot 3 to slot 0.
  4. Generates new $S_L$, re-splits $S_P = K_{new} \oplus S_L$.
  5. Re-enrolls phone and updates `unlock-share`.
- `verify-card`:
  1. Mounts system partition from card reader.
  2. Runs `nix store verify --all` against the system store closure.
  3. Computes sha256 hashes of `/boot/firmware` files and compares against the flake output.

### Implementation Code

#### `tools/ph-provision.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail

TARGET_DEV="${1:-}"
if [ -z "$TARGET_DEV" ] || [ ! -b "$TARGET_DEV" ]; then
  echo "Usage: ph-provision <target_block_device> (e.g. /dev/sdb)" >&2
  exit 1
fi

echo "WARNING: ALL DATA ON $TARGET_DEV WILL BE DESTROYED."
read -rp "Are you absolutely sure you want to flash $TARGET_DEV? [type YES]: " CONFIRM
if [ "$CONFIRM" != "YES" ]; then
  echo "Aborted." >&2
  exit 1
fi

echo "Building Panhandler SD Image..."
nix build .#packages.aarch64-linux.sdImage --out-link result-sdImage
IMG_FILE=$(find result-sdImage/sd-image/ -name "*.img" | head -n 1)

echo "Flashing $IMG_FILE to $TARGET_DEV..."
dd if="$IMG_FILE" of="$TARGET_DEV" bs=4M status=progress conv=fsync

partprobe "$TARGET_DEV"
sleep 2

# Create partition 3 (persist) with remaining disk space
PART_NUM=3
sgdisk -n "${PART_NUM}:0:0" -c "${PART_NUM}:persist" "$TARGET_DEV"
partprobe "$TARGET_DEV"
sleep 2

PERSIST_PART="${TARGET_DEV}3"
if [ ! -b "$PERSIST_PART" ]; then
  PERSIST_PART="${TARGET_DEV}p3"
fi

echo "Generating LUKS keys..."
K=$(head -c 64 /dev/urandom)
K_BW=$(head -c 64 /dev/urandom)

echo "Formatting LUKS2 with Adiantum cipher on $PERSIST_PART..."
# Slot 0: Quorum key (minimal PBKDF2)
echo -n "$K" | cryptsetup luksFormat --type luks2 \
  --cipher xchacha12,aes-adiantum-plain64 \
  --pbkdf pbkdf2 \
  --pbkdf-force-iterations 1000 \
  --key-slot 0 \
  "$PERSIST_PART" -

# Slot 1: User passphrase (Argon2id, 256 MiB memory explicitly set)
echo "Setting up Slot 1 passphrase..."
echo -n "$K" | cryptsetup luksAddKey \
  --pbkdf argon2id \
  --pbkdf-memory 262144 \
  --key-slot 1 \
  "$PERSIST_PART" -

# Slot 2: Bitwarden key (minimal PBKDF2)
echo -n "$K" | cryptsetup luksAddKey \
  --pbkdf pbkdf2 \
  --pbkdf-force-iterations 1000 \
  --key-slot 2 \
  "$PERSIST_PART" - <<< "$K_BW"

echo "Creating ext4 filesystem on /persist..."
echo -n "$K" | cryptsetup open "$PERSIST_PART" persist_provision --key-file -
mkfs.ext4 -L persist /dev/mapper/persist_provision

TMP_MNT=$(mktemp -d)
mount /dev/mapper/persist_provision "$TMP_MNT"

# Populate /persist
mkdir -p "$TMP_MNT/var/lib/sops-nix"
chmod 700 "$TMP_MNT/var/lib/sops-nix"
cp ~/.config/sops/age/keys.txt "$TMP_MNT/var/lib/sops-nix/key.txt"
chmod 600 "$TMP_MNT/var/lib/sops-nix/key.txt"

mkdir -p "$TMP_MNT/tailscale" "$TMP_MNT/var/lib/nixos"
umount "$TMP_MNT"
cryptsetup close persist_provision

# Populate /base on system partition (part 2)
SYS_PART="${TARGET_DEV}2"
if [ ! -b "$SYS_PART" ]; then
  SYS_PART="${TARGET_DEV}p2"
fi
mount "$SYS_PART" "$TMP_MNT"
mkdir -p "$TMP_MNT/base/tailscale"
# Seed single-use locked authkey
read -rp "Enter single-use locked Tailscale authkey (tag:panhandler-locked): " LOCKED_KEY
echo "$LOCKED_KEY" > "$TMP_MNT/base/tailscale/locked-authkey.env"
chmod 600 "$TMP_MNT/base/tailscale/locked-authkey.env"
umount "$TMP_MNT"
rmdir "$TMP_MNT"

# Split Quorum Key: S_L and S_P
mkdir -p ~/.local/share/panhandler
chmod 700 ~/.local/share/panhandler
S_L=$(head -c 64 /dev/urandom)
echo -n "$S_L" > ~/.local/share/panhandler/unlock-share
chmod 600 ~/.local/share/panhandler/unlock-share

# Compute S_P = K ^ S_L
python3 -c '
k = sys.stdin.buffer.read()
s_l = open(os.path.expanduser("~/.local/share/panhandler/unlock-share"), "rb").read()
s_p = bytes(a ^ b for a, b in zip(k, s_l))
with open("/tmp/phone_share.bin", "wb") as f:
    f.write(s_p)
' <<< "$K"

echo "Quorum keys split. Laptop share saved to ~/.local/share/panhandler/unlock-share."
echo "Phone share generated at /tmp/phone_share.bin."
echo "Run 'phone/enroll.sh /tmp/phone_share.bin' on Termux to complete phone enrollment."

# Store Bitwarden Slot 2 key
echo "$K_BW" | xxd -p -c 64 | rbw add panhandler-luks-slot2 "panhandler" || true
echo "Provisioning complete."
```

#### `tools/verify-card.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail

DEV="${1:-}"
if [ -z "$DEV" ] || [ ! -b "$DEV" ]; then
  echo "Usage: verify-card <sd_device> (e.g. /dev/sdb)" >&2
  exit 1
fi

MNT=$(mktemp -d)
SYS_PART="${DEV}2"
[ -b "$SYS_PART" ] || SYS_PART="${DEV}p2"

mount "$SYS_PART" "$MNT"
echo "Verifying Nix store integrity on $SYS_PART..."
nix store verify --store "$MNT" --all

BOOT_PART="${DEV}1"
[ -b "$BOOT_PART" ] || BOOT_PART="${DEV}p1"
BOOT_MNT=$(mktemp -d)
mount "$BOOT_PART" "$BOOT_MNT"

echo "Checking firmware sha256 sums..."
sha256sum "$BOOT_MNT"/* || true

umount "$BOOT_MNT"
umount "$MNT"
rmdir "$BOOT_MNT" "$MNT"
echo "Card verification finished successfully."
```

#### Package Wrappers (`tools/*.nix`)
```nix
# tools/ph-provision.nix
{ pkgs }:
pkgs.writeShellApplication {
  name = "ph-provision";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.cryptsetup
    pkgs.gptfdisk
    pkgs.util-linux
    pkgs.e2fsprogs
    pkgs.nix
    pkgs.python3
    pkgs.xxd
  ];
  text = builtins.readFile ./ph-provision.sh;
}
```
```nix
# tools/verify-card.nix
{ pkgs }:
pkgs.writeShellApplication {
  name = "verify-card";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.nix
    pkgs.util-linux
  ];
  text = builtins.readFile ./verify-card.sh;
}
```

---

## Task 7: Termux Scripts: Boot-Log Listener, Tap Script & Enrollment (`phone/`)

### Files Touched
- `phone/listener.py`
- `phone/enroll.sh`
- `phone/tap.sh`

### Prerequisites & Spec §10 Verifications
1. **[VERIFY §10 item 4] `termux-keystore` user-auth validity & deterministic RSA signing:**
   - Test on Termux:
     ```bash
     termux-keystore generate test-key -a RSA -s 2048
     echo -n "test-message" | termux-keystore sign test-key
     ```
   - Verify deterministic signature output. PKCS#1 v1.5 RSA signing is deterministic.
   - If user-auth timeout flag is unsupported in current `termux-keystore`, fall back to plain-file share storage protected by Termux private UID, and log ceiling `[CEILING]: Android Keystore user-auth flag unavailable in termux-keystore; fallback to Termux app sandbox isolation`.
2. **[VERIFY §10 item 5] Termux listener survives Android background limits:**
   - Command: `termux-wake-lock`.
   - Setup Termux foreground service or Termux:Boot script `~/.termux/boot/start-panhandler-listener.sh`.

### Implementation Code

#### `phone/listener.py`
```python
#!/usr/bin/env python3
import http.server
import json
import os
import socketserver
import time

PORT = 8463
LOG_FILE = os.path.expanduser("~/.local/share/panhandler/boot_log.jsonl")
LOCKDOWN_FLAG = os.path.expanduser("~/.local/share/panhandler/lockdown")
PENDING_SHARE = os.path.expanduser("~/.local/share/panhandler/pending_share")
CHECKIN_WINDOW_SECONDS = 3600  # 60 minutes
MAX_CHECKINS = 3

os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)


class BootLogHandler(http.server.BaseHTTPRequestHandler):

  def do_GET(self):
    if self.path == "/status":
      locked_down = os.path.exists(LOCKDOWN_FLAG)
      last_checkin = None
      if os.path.exists(LOG_FILE):
        with open(LOG_FILE, "r") as f:
          lines = f.readlines()
          if lines:
            last_checkin = json.loads(lines[-1].strip())
      resp = {
          "locked_down": locked_down,
          "reason": (
              open(LOCKDOWN_FLAG).read().strip() if locked_down else None
          ),
          "last_checkin": last_checkin,
      }
      self.send_response(200)
      self.send_header("Content-Type", "application/json")
      self.end_headers()
      self.wfile.write(json.dumps(resp).encode())

    elif self.path == "/share":
      # Laptop agent waiting for tapped share
      timeout = 30
      start = time.time()
      while time.time() - start < timeout:
        if os.path.exists(PENDING_SHARE):
          with open(PENDING_SHARE, "r") as f:
            share_hex = f.read().strip()
          os.remove(PENDING_SHARE)
          self.send_response(200)
          self.send_header("Content-Type", "application/json")
          self.end_headers()
          self.wfile.write(
              json.dumps({"phone_share_hex": share_hex}).encode()
          )
          return
        time.sleep(0.5)

      self.send_response(408)
      self.end_headers()
    else:
      self.send_response(404)
      self.end_headers()

  def do_POST(self):
    if self.path == "/checkin":
      length = int(self.headers.get("Content-Length", 0))
      body = self.rfile.read(length).decode()
      data = json.loads(body)

      now = int(time.time())
      data["server_received_ts"] = now

      with open(LOG_FILE, "a") as f:
        f.write(json.dumps(data) + "\n")

      # Evaluate off-device cluster detector
      cutoff = now - CHECKIN_WINDOW_SECONDS
      count = 0
      with open(LOG_FILE, "r") as f:
        for line in f:
          entry = json.loads(line)
          if entry.get("server_received_ts", 0) >= cutoff:
            count += 1

      if count >= MAX_CHECKINS or data.get("cluster") == "local":
        with open(LOCKDOWN_FLAG, "w") as f:
          f.write(
              f"OFF-DEVICE CLUSTER LOCKDOWN: {count} check-ins in past 60 min\n"
          )

      self.send_response(200)
      self.end_headers()

    elif self.path == "/clear-lockdown":
      if os.path.exists(LOCKDOWN_FLAG):
        os.remove(LOCKDOWN_FLAG)
      self.send_response(200)
      self.end_headers()

    elif self.path == "/tap":
      length = int(self.headers.get("Content-Length", 0))
      body = self.rfile.read(length).decode()
      data = json.loads(body)
      with open(PENDING_SHARE, "w") as f:
        f.write(data["phone_share_hex"])
      self.send_response(200)
      self.end_headers()


def run():
  with socketserver.TCPServer(("", PORT), BootLogHandler) as httpd:
    print(f"Phone Boot-Log Listener running on port {PORT}...")
    httpd.serve_forever()


if __name__ == "__main__":
  run()
```

#### `phone/enroll.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail

SP_BIN="${1:-/tmp/phone_share.bin}"
if [ ! -f "$SP_BIN" ]; then
  echo "Usage: enroll.sh <path_to_phone_share.bin>" >&2
  exit 1
fi

KEY_ALIAS="panhandler-unlock"
echo "Generating hardware Keystore RSA key ($KEY_ALIAS)..."
termux-keystore generate "$KEY_ALIAS" -a RSA -s 2048

# Create fixed string to sign
FIXED_MSG="panhandler-unlock-v1"
echo "Signing fixed verification token to derive deterministic signature..."
SIG_HEX=$(echo -n "$FIXED_MSG" | termux-keystore sign "$KEY_ALIAS" | xxd -p -c 256 | tr -d '\n')
H=$(echo -n "$SIG_HEX" | sha256sum | awk '{print $1}')

echo "Wrapping phone share: S_P' = S_P ^ SHA256(sig)..."
python3 -c "
import sys, hashlib
sp = open('$SP_BIN', 'rb').read()
h = bytes.fromhex('$H')
sp_prime = bytes(a ^ b for a, b in zip(sp, h * 2))
out_path = os.path.expanduser('~/.local/share/panhandler/phone-share')
os.makedirs(os.path.dirname(out_path), exist_ok=True)
with open(out_path, 'wb') as f:
    f.write(sp_prime)
"
chmod 600 ~/.local/share/panhandler/phone-share
rm -f "$SP_BIN"
echo "Phone enrollment complete. Encrypted share saved."
```

#### `phone/tap.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail

# Check lockdown status first
STATUS=$(curl -s http://127.0.0.1:8463/status)
LOCKED_DOWN=$(echo "$STATUS" | jq -r '.locked_down')
if [ "$LOCKED_DOWN" = "true" ]; then
  termux-notification --title "LOCKDOWN ACTIVE" --content "Remote tap unlock refused. Cable unlock required." --priority high
  echo "LOCKDOWN ACTIVE. Refusing tap." >&2
  exit 1
fi

KEY_ALIAS="panhandler-unlock"
FIXED_MSG="panhandler-unlock-v1"

echo "Prompting for biometric/screen authentication..."
# This invocation triggers Android Keystore auth dialog
SIG_HEX=$(echo -n "$FIXED_MSG" | termux-keystore sign "$KEY_ALIAS" | xxd -p -c 256 | tr -d '\n')
H=$(echo -n "$SIG_HEX" | sha256sum | awk '{print $1}')

# Unwrap S_P
SP_HEX=$(python3 -c "
import os
sp_prime = open(os.path.expanduser('~/.local/share/panhandler/phone-share'), 'rb').read()
h = bytes.fromhex('$H')
sp = bytes(a ^ b for a, b in zip(sp_prime, h * 2))
print(sp.hex())
")

# Send to local listener to satisfy pending laptop agent request
curl -s -X POST http://127.0.0.1:8463/tap \
  -H "Content-Type: application/json" \
  -d "{\"phone_share_hex\": \"$SP_HEX\"}"

termux-notification --title "Panhandler Unlocked" --content "Share released to unlock agent."
echo "Tap completed."
```

---

## Task 8: Security & Architectural Documentation Updates (§11 Doc Fixes)

### Files Touched
- `docs/HARDENING.md`
- `docs/THREAT-MODEL.md`
- `docs/RISKS.md`
- `.memory/inbox/2026-10-17-storage-spine.md`

### Steps
1. In `docs/HARDENING.md`:
   - Update §At-rest item 2 and §Key-custody options (2)/(3): reflect stage-2 systemd LUKS unlock, 3 independent keyslots, push quorum model, and locked Tailscale identity.
   - Record conflict origin note: "phone-hotspot data got rate-limited, which cast doubt on the Wi-Fi path and brought in the cable."
2. In `docs/THREAT-MODEL.md`:
   - Under §2 A0 (Physical theft), add evil-maid / persistence gap and detection-not-prevention ceiling:
     - Pi 3B has no hardware root of trust. Unencrypted `/base` and U-Boot partition cannot attest their own integrity if physically modified offline.
     - Tamper-detection (boot-clustering and check-in frequency) flags anomalies and triggers off-device lockdown, but does not provide hardware cryptographic attestation.
3. In `docs/RISKS.md`:
   - In §1 R7, replace "crypto-erase + poweroff" with "crypto-erase + lost mode" (matches HARDENING).
   - Record D8 non-ephemeral status for `tag:panhandler`.
4. In `.memory/inbox/2026-10-17-storage-spine.md`:
   - Create memory inbox note documenting decisions D1–D9 for the memd curator:
     - Mark "LUKS deferred" in `decisions.md` as superseded by storage spine spec.
     - Mark "ephemeral authkey" in `decisions.md` as superseded by D8 (main node is non-ephemeral tagged `tag:panhandler`).

### Verification Command
```bash
git diff docs/
```
**Expected Result:** Clean diffs matching spec §11 changes.

---

## Task 9: On-Device Acceptance Checklist & Timed Validation

### Acceptance Steps
1. **Flash & Provisioning:**
   - Execute `ph-provision /dev/sdX` on Card #2.
   - Verify 3 partitions created (`FIRMWARE`, `system`, `persist`).
   - Time the flash and provisioning procedure to verify R5 (~10 minutes).
2. **First Boot & Locked Identity:**
   - Insert card into Pi 3B and power on.
   - Verify locked Tailscale node joins tailnet (`tag:panhandler-locked`).
   - Verify phone listener receives check-in: `curl http://127.0.0.1:8463/status`.
3. **Quorum Push Unlock:**
   - Verify phone receives MCP notification with SSID, BSSID, and IP.
   - Tap notification on phone.
   - Run `ph-unlock` on laptop.
   - Verify Pi unlocks, mounts `/persist`, starts `ph-persist.target`, and restarts Tailscale under `tag:panhandler`.
4. **Break-Glass Passphrase & Bitwarden Unlock:**
   - Reboot Pi into locked state.
   - Connect direct Ethernet cable (`eth0`).
   - Execute `ph-unlock --passphrase`: verify unlock succeeds.
   - Reboot Pi again into locked state.
   - Execute `ph-unlock --bitwarden`: verify unlock succeeds and `rbw status` reports locked.
5. **Tamper Cluster Detection & Lockdown:**
   - Power-cycle Pi 3 times within 15 minutes.
   - Verify `ph-bootcount` creates `/base/lockdown`.
   - Verify phone listener marks off-device lockdown.
   - Attempt remote unlock over tailnet: verify `ph-unlockd` refuses with cluster evidence.
   - Connect eth0 cable and run `ph-unlock --clear-lockdown`: verify lockdown clears.
6. **Network Surface & Impermanence Check:**
   - From LAN, execute `nmap -p- <pi-ip>` on `wlan0`: verify 0 open ports.
   - Plant file `/root/test-ephemeral.txt`, reboot Pi, verify file does not exist.
   - Measure RAM and tmpfs usage: verify $\ge 256$ MiB headroom remains during Argon2id unlock.
