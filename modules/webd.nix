{ pkgs, lib, ... }:
let
  webd = pkgs.callPackage ../pkgs/panhandler-webd { };
  port = 8080;
in
{
  # Static user, not DynamicUser: polkit's isInGroup resolves groups via NSS, and the NM module
  # grants org.freedesktop.NetworkManager.* to the networkmanager group.
  users.users.panhandler-webd = {
    isSystemUser = true;
    group = "panhandler-webd";
    extraGroups = [ "networkmanager" ];
  };
  users.groups.panhandler-webd = { };

  systemd.services.panhandler-webd = {
    description = "thePanhandler Wi-Fi control plane (web UI)";
    wantedBy = [ "multi-user.target" ];
    after = [ "NetworkManager.service" ];
    requires = [ "NetworkManager.service" ];
    serviceConfig = {
      # Binds per-device (SO_BINDTODEVICE) to the trusted side only; refuses wlan0.
      ExecStart = "${lib.getExe webd} --listen-devs eth0,tailscale0 --port ${toString port}";
      User = "panhandler-webd";
      Group = "panhandler-webd";
      Restart = "on-failure";
      RestartSec = 5;
      UMask = "0077";
      CapabilityBoundingSet = "";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      ProtectProc = "invisible";
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
      ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" ];
      # Peers: the cable subnet, the tailnet (v4 CGNAT + v6 ULA), link-local. D-Bus is AF_UNIX.
      IPAddressAllow = [
        "10.73.0.0/24"
        "100.64.0.0/10"
        "fd7a:115c:a1e0::/48"
        "fe80::/10"
      ];
      IPAddressDeny = "any";
      MemoryMax = "64M";
      CPUQuota = "50%";
    };
  };

  networking.firewall.interfaces = {
    eth0.allowedTCPPorts = [ port ];
    tailscale0.allowedTCPPorts = [ port ];
  };
}
