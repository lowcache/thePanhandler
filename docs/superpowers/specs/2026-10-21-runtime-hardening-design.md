# Runtime Hardening — Sub-project 2 (Design)

**Status:** approved 2026-10-21; implemented, VM-tested; hardware acceptance pending.
**Maps to:** THREAT-MODEL A5 (compromised chokepoint), §2.5 vector-lockdown (identity);
RISKS R3 (throughput), R4; v1 DoD "hostile-side surface verified minimal".

## Scope

Box integrity plus the static wlan0 posture. Selection rule: only controls with no
bandwidth or day-to-day usability cost (forwarding stays in the kernel, so daemon
sandboxes cost no throughput).

Out: kill-switch and egress selector (gateway core); per-network policy (stealth phase).
Rejected for cost: `linux_hardened` (not cached, binfmt compile), hardened allocator and
`init_on_free` (CPU on a 1 GB A53), per-connect random MAC (captive-portal re-auth),
sshd `ListenAddress` (breaks across the locked/main tailnet identity swap; the firewall
already covers it). Deferred: `lockKernelModules` (breaks post-boot module loads such as
a USB dongle) and trimming the installer packages from `profiles/base.nix`.

## Baseline (live Pi, 2026-10-21)

Already set: nftables rpfilter (loose), kptr/dmesg restrict, unprivileged BPF off,
ptrace_scope 1, source routing off, IPv6 link-local stable-privacy.
Gaps found: wlan0 used the factory MAC (`b8:27:eb`, Raspberry Pi OUI); DHCP sent hostname
`panhandler`; DHCPv6 DUID derived from machine-id; ping answered on every interface (and
the NixOS nftables firewall accepts ICMPv6 echo unconditionally, before extraInputRules);
`send_redirects=1`, IPv6 `accept_redirects=1`, kexec allowed; ZFS modules and `zfs-zed`
loaded via `profiles/base.nix`; `systemd-analyze security`: dnsmasq 9.0, tailscaled 9.6.

## Design

### `modules/hardening.nix` (option `panhandler.hardening.wanInterface`, default `wlan0`)
- sysctls (`all` + `default`): IPv4 `send_redirects`, `accept_redirects`,
  `secure_redirects` = 0; IPv6 `accept_redirects` = 0.
- `security.protectKernelImage = true`; `boot.supportedFilesystems.zfs = mkForce false`.
- nftables table `inet ph-wan`, input hook at `filter - 1`: drop icmp and icmpv6
  echo-request arriving on the uplink. eth0 and tailscale0 still answer ping.
- tailscaled: PrivateTmp, ProtectHome=read-only, ProtectKernelLogs, ProtectClock,
  ProtectControlGroups, LockPersonality, RestrictRealtime, RestrictSUIDSGID. No
  SystemCallFilter (per-packet cost on WireGuard), no ProtectSystem (openresolv writes
  /etc/resolv.conf), no ProtectKernelModules (modprobe for the v6 NAT check).
- dnsmasq: full sandbox; capability set NET_ADMIN, NET_BIND_SERVICE, NET_RAW, SETUID,
  SETGID, CHOWN; ProtectSystem=strict; @system-service syscall filter.

The uplink ping rule and the dnsmasq sandbox live here (not base.nix/gateway.nix) so the
VM test can import them; those modules hardcode the Pi's interface names.

### `modules/wifi.nix`
- `networking.networkmanager.wifi.macAddress = "stable-ssid"` (scan MAC randomization
  stays on).
- NM `[connection]` defaults: `ipv4.dhcp-send-hostname=0`,
  `ipv6.dhcp-send-hostname=0` (integer-parsed; `false` is silently ignored, found on hardware), `ipv6.dhcp-duid=stable-uuid`. NM sends no vendor class
  (option 60) unless configured (NM 1.58.1 man page). The IPv4 client-id defaults to the
  current (random) MAC.
- NM's `secret_key` persists in `/base/ph/nm-secret_key` (decision: unencrypted /base, so
  a portal-authorised MAC survives reboots). `ph-nm-key-load` installs it before NM;
  `ph-nm-key-save` (path unit on the key) adopts NM's first generated key. Seen-BSSIDs and
  leases stay ephemeral. The key maps SSID → MAC and holds no location history.

## Verification

- `checks.x86_64-linux.hardening` (VM): sysctls, kexec disabled, no ZFS, uplink drops v4
  and v6 echo with a link control, cable answers v4 and v6, sandboxed dnsmasq leases,
  exposure scores dnsmasq < 5.0 (measured 3.0), tailscaled < 9.6 (measured 8.0).
- Pi eval: `boot.supportedFilesystems.zfs = false`.
- Hardware acceptance, after deploy:
  1. DHCP DISCOVER on wlan0 (tcpdump): source MAC not `b8:27:eb`, no option 12 or 60.
  2. MAC identical across a reboot on the same SSID; differs on another SSID.
  3. From a host on the same uplink: ping fails v4 and v6; nmap shows all ports filtered.
  4. Tailnet up, MagicDNS resolves, locked → unlocked identity swap still works.
  5. Throughput before vs after, same bench (laptop → Pi → Cloudflare).

## Deploy note

The first boot with `stable-ssid` presents a new MAC to every network, so a captive
portal that authorised the factory MAC asks again once (ph-portal-bypass handles it).
