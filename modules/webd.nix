{
  config,
  pkgs,
  lib,
  ...
}:
let
  webd = pkgs.callPackage ../pkgs/panhandler-webd { };
  port = 8080;
  flags = lib.cli.toCommandLineShellGNU { } {
    listen-devs = "eth0,tailscale0";
    inherit port;
    allowed-hosts = lib.concatStringsSep "," config.panhandler.webd.allowedHostnames;
    direct-peers = lib.concatStringsSep "," (lib.attrValues config.panhandler.managementPeers);
    journalctl = "${config.systemd.package}/bin/journalctl";
    log-units = lib.concatStringsSep "," config.panhandler.webd.logUnits;
  };
in
{
  options.panhandler.managementPeers = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    description = "Named Tailscale management peer IPs; source for the UI downgrade allowlist and policy hosts.";
  };
  options.panhandler.webd.allowedHostnames = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Exact additional hostnames permitted by the management HTTP server.";
  };
  options.panhandler.webd.logUnits = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [
      "panhandler-webd.service"
      "NetworkManager.service"
      "dnsmasq.service"
      "blocky.service"
      "ph-uplink-probe.service"
    ];
    description = "Units the web UI log view follows (cable or management peers only).";
  };
  config = {
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
        ExecStart = "${lib.getExe webd} ${flags}";
        User = "panhandler-webd";
        Group = "panhandler-webd";
        # Read-only journal access for the log view.
        SupplementaryGroups = [ "systemd-journal" ];
        Restart = "on-failure";
        RestartSec = 5;
        UMask = "0077";
        RuntimeDirectory = "panhandler-webd";
        RuntimeDirectoryMode = "0700";
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
  };
}
