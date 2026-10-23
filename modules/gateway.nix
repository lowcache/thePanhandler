{ config, pkgs, ... }:
let
  # Downlink = the trusted side the laptop plugs into over the cable.
  # 10.73/24 sits deliberately off the common 192.168.0/1.x hotel ranges.
  lan = "eth0";
  wan = "wlan0";
  gw = "10.73.0.1";
  prefix = 24;
in
{
  networking = {
    # eth0 is the static downlink; wlan0 the uplink (NetworkManager, wifi.nix).
    interfaces.${lan} = {
      useDHCP = false;
      ipv4.addresses = [
        {
          address = gw;
          prefixLength = prefix;
        }
      ];
    };

    # Laptop (eth0) egresses through the uplink (wlan0). nat.enable turns on IP
    # forwarding and masquerade for internalInterfaces → external.
    nftables.enable = true;
    # NAT is not an inbound boundary; allow downstream-initiated flows and their replies only.
    firewall.filterForward = true;
    nat = {
      enable = true;
      externalInterface = wan;
      internalInterfaces = [ lan ];
    };

    # blocky fetches its denylist and opens its DoH connections once, at start. A boot with no
    # uplink leaves it list-less; a network change (or portal login) leaves pooled connections
    # dead, so every query waits out the 2 s upstream timeout. Restart it each time NM reaches FULL.
    networkmanager.dispatcherScripts = [
      {
        source = pkgs.writeShellScript "blocky-on-online" ''
          if [ "$2" = connectivity-change ] && [ "$CONNECTIVITY_STATE" = FULL ]; then
            ${config.systemd.package}/bin/systemctl try-restart blocky.service
          fi
        '';
      }
    ];

    # Open DNS + DHCP on the downlink only; wlan0 stays closed (base.nix default-deny).
    firewall.interfaces.${lan} = {
      allowedUDPPorts = [
        53
        67
      ];
      allowedTCPPorts = [ 53 ];
    };
  };

  # FULL comes from NM's plain-HTTP probe and can precede NTP. With no RTC the clock is months
  # behind until then, so TLS (DoH, list download) fails: restart blocky once more when time syncs.
  systemd.paths.blocky-on-timesync = {
    wantedBy = [ "multi-user.target" ];
    pathConfig.PathExists = "/run/systemd/timesync/synchronized";
  };
  systemd.services.blocky-on-timesync.serviceConfig = {
    Type = "oneshot";
    # Stays active, or PathExists re-triggers it in a loop.
    RemainAfterExit = true;
    ExecStart = "${config.systemd.package}/bin/systemctl try-restart blocky.service";
  };

  # DHCP for the one downstream client. DHCP only (port 0 = no DNS listener here);
  # blocky owns :53. resolveLocalQueries off so dnsmasq never rewrites the Pi's
  # own resolv.conf (the uplink DHCP from the phone owns that).
  services.dnsmasq = {
    enable = true;
    resolveLocalQueries = false;
    settings = {
      port = 0;
      interface = lan;
      bind-interfaces = true;
      dhcp-authoritative = true;
      dhcp-range = [ "10.73.0.50,10.73.0.150,24h" ];
      dhcp-option = [
        "option:router,${gw}"
        "option:dns-server,${gw}"
      ];
    };
  };

  # Adblock DNS for clients, bound to the trusted side only (blocky has no web UI
  # to expose — a hardening win over AdGuard, see HARDENING.md).
  services.blocky = {
    enable = true;
    settings = {
      ports.dns = "${gw}:53";
      # Encrypted upstream (THREAT-MODEL A1: no cleartext DNS to the hotel resolver).
      upstreams.groups.default = [ "https://dns.quad9.net/dns-query" ];
      # Resolve the DoH host itself without a chicken-and-egg loop.
      bootstrapDns = [ "9.9.9.9" ];
      # Most uplinks are IPv4-only; dual-stack dials pick Quad9's AAAA and fail "network unreachable".
      connectIPVersion = "v4";
      blocking = {
        denylists.ads = [
          "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
        ];
        clientGroupsBlock.default = [ "ads" ];
      };
    };
  };
}
