{ config, pkgs, ... }:
let
  unit = "ph-portal-bypass";
  lan = config.panhandler.egress.lanInterface;
  wan = config.panhandler.egress.wanInterface;
  gw = config.panhandler.egress.gateway;
  # Captive portals block DoH pre-auth, so blocky can't resolve the portal for the cable client.
  # While this unit runs, client DNS to the gateway is DNAT'd to the hotel's own resolver.
  up = pkgs.writeShellScript "${unit}-up" ''
    set -eu
    client=$(cat /run/panhandler-webd/portal-client)
    [[ $client =~ ^10\.73\.0\.([0-9]{1,3})$ ]] && [ "''${BASH_REMATCH[1]}" -ge 2 ] && [ "''${BASH_REMATCH[1]}" -le 254 ] || exit 1
    dns=$(nmcli -g IP4.DNS device show ${wan} | sed 's/ | /\n/g' | head -n1)
    # DHCP-supplied (hostile) input: accept only a bare IPv4 literal.
    [[ $dns =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "no IPv4 uplink resolver: '$dns'" >&2; exit 1; }
    nft -f - <<EOF
    add element inet ph-egress portal_clients { $client timeout 600s }
    add element inet ph-egress portal_dns { $dns timeout 600s }
    table ip ${unit} {
      chain pre {
        type nat hook prerouting priority dstnat - 10;
        iifname "${lan}" ip saddr $client ip daddr ${gw} udp dport 53 dnat to $dns
        iifname "${lan}" ip saddr $client ip daddr ${gw} tcp dport 53 dnat to $dns
      }
    }
    EOF
    # Existing flows to blocky would otherwise keep their old NAT mapping.
    conntrack -D -p udp --dport 53 >/dev/null 2>&1 || true
    # Remove the client's old transparent-proxy mappings before opening its portal tab.
    conntrack -D -s "$client" -p tcp --dport 80 >/dev/null 2>&1 || true
    conntrack -D -s "$client" -p tcp --dport 443 >/dev/null 2>&1 || true
    echo "portal access on: $client web ports + DNS -> $dns"
  '';
  down = pkgs.writeShellScript "${unit}-down" ''
    nft flush set inet ph-egress portal_clients 2>/dev/null || true
    nft flush set inet ph-egress portal_dns 2>/dev/null || true
    nft delete table ip ${unit} 2>/dev/null || true
    conntrack -D -p udp --dport 53 >/dev/null 2>&1 || true
    if client=$(cat /run/panhandler-webd/portal-client 2>/dev/null) && [[ $client =~ ^10\.73\.0\.[0-9]{1,3}$ ]]; then
      conntrack -D -s "$client" -p tcp --dport 80 >/dev/null 2>&1 || true
      conntrack -D -s "$client" -p tcp --dport 443 >/dev/null 2>&1 || true
    fi
    echo "portal bypass off: cable DNS -> blocky"
  '';
in
{
  # Started/stopped by panhandler-webd ("Open portal"); the 10 min cap is the unit expiring,
  # so a crash or a forgotten tab can't leave plaintext DNS on.
  systemd.services.${unit} = {
    description = "Captive-portal DNS bypass for cable clients (time-boxed)";
    after = [ "NetworkManager.service" ];
    requires = [ "nftables.service" ];
    path = with pkgs; [
      networkmanager
      nftables
      conntrack-tools
      gnused
      coreutils
      bash
    ];
    serviceConfig = {
      Type = "simple";
      ExecStartPre = up;
      ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
      ExecStopPost = down;
      RuntimeMaxSec = 600;
    };
  };

  # webd may start/stop exactly this unit, nothing else.
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id == "org.freedesktop.systemd1.manage-units"
          && subject.user == "panhandler-webd"
          && action.lookup("unit") == "${unit}.service"
          && (action.lookup("verb") == "start" || action.lookup("verb") == "stop"))
        return polkit.Result.YES;
    });
  '';
}
