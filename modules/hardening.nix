# Runtime hardening (sub-project 2): host-wide kernel settings and daemon sandboxes.
# Data-plane cost is zero: forwarding stays in the kernel, so nothing here touches throughput.
{ config, lib, ... }:
let
  cfg = config.panhandler.hardening;
  wan = cfg.wanInterface;
in
{
  options.panhandler.hardening.wanInterface = lib.mkOption {
    type = lib.types.str;
    default = "wlan0";
    description = "Hostile uplink; echo requests arriving here are dropped.";
  };

  config = {
    boot.kernel.sysctl = {
      # A router that sends redirects tells the hostile LAN about its topology.
      "net.ipv4.conf.all.send_redirects" = 0;
      "net.ipv4.conf.default.send_redirects" = 0;
      "net.ipv4.conf.all.accept_redirects" = 0;
      "net.ipv4.conf.default.accept_redirects" = 0;
      "net.ipv4.conf.all.secure_redirects" = 0;
      "net.ipv4.conf.default.secure_redirects" = 0;
      "net.ipv6.conf.all.accept_redirects" = 0;
      "net.ipv6.conf.default.accept_redirects" = 0;
    };
    # No kexec or hibernation: a root compromise can't swap in another kernel.
    security.protectKernelImage = true;
    # profiles/base.nix (via sd-image) turns ZFS on; nothing here uses it.
    boot.supportedFilesystems.zfs = lib.mkForce false;

    # The NixOS firewall accepts ICMPv6 echo on every interface before extraInputRules, so
    # allowPing can't silence the uplink. An earlier base chain drops it there, v4 and v6.
    networking.nftables.tables.ph-wan = {
      family = "inet";
      content = ''
        chain input {
          type filter hook input priority filter - 1; policy accept;
          iifname "${wan}" icmp type echo-request drop
          iifname "${wan}" icmpv6 type echo-request drop
        }
      '';
    };

    # File-system and privilege limits only: a SystemCallFilter would sit on every WireGuard packet.
    # No ProtectSystem (openresolv writes /etc/resolv.conf for MagicDNS), no ProtectKernelModules
    # (modprobe for its IPv6 NAT check).
    systemd.services.tailscaled.serviceConfig = {
      PrivateTmp = true;
      ProtectHome = "read-only";
      ProtectKernelLogs = true;
      ProtectClock = true;
      ProtectControlGroups = true;
      LockPersonality = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
    };

    # dnsmasq starts as root and drops to its user; preStart chowns the lease dir.
    systemd.services.dnsmasq.serviceConfig = {
      CapabilityBoundingSet = [
        "CAP_NET_ADMIN"
        "CAP_NET_BIND_SERVICE"
        "CAP_NET_RAW"
        "CAP_SETUID"
        "CAP_SETGID"
        "CAP_CHOWN"
      ];
      NoNewPrivileges = true;
      ProtectSystem = lib.mkForce "strict";
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
        "AF_PACKET"
      ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" ];
    };
  };
}
