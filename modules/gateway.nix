{ ... }:
let
  # Downlink = the trusted side the laptop plugs into over the cable.
  # 10.73/24 sits deliberately off the common 192.168.0/1.x hotel ranges.
  lan = "eth0";
  wan = "wlan0";
  gw = "10.73.0.1";
  prefix = 24;
in
{
  # eth0 is the downlink (static); wlan0 the uplink (DHCP to the phone hotspot).
  # base.nix sets useDHCP mkDefault true — fine for wlan0; eth0 must not DHCP-client.
  networking.interfaces.${lan} = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = gw;
        prefixLength = prefix;
      }
    ];
  };

  # Laptop (eth0) egresses through the phone-hotspot uplink (wlan0). nat.enable
  # turns on IP forwarding and masquerade for internalInterfaces → external.
  networking.nftables.enable = true;
  networking.nat = {
    enable = true;
    externalInterface = wan;
    internalInterfaces = [ lan ];
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
      blocking = {
        denylists.ads = [
          "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
        ];
        clientGroupsBlock.default = [ "ads" ];
      };
    };
  };

  # Open DNS + DHCP on the downlink only; wlan0 stays closed (base.nix default-deny).
  networking.firewall.interfaces.${lan} = {
    allowedUDPPorts = [
      53
      67
    ];
    allowedTCPPorts = [ 53 ];
  };
}
