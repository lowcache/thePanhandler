{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.panhandler.egress;
  torUid = toString config.ids.uids.tor;
  clockUid = toString config.ids.uids.systemd-timesync;
  transport = "meta mark & 0xff0000 == 0x80000";
  bootstrap = ''
    meta skuid { 0, ${clockUid} } udp dport 53 return
    meta skuid 0 tcp dport 80 return
  '';
  applyMode = pkgs.writeShellScript "ph-egress-mode" ''
    set -eu
    exec 9>/run/ph-egress.lock
    ${pkgs.util-linux}/bin/flock 9
    mode=$1
    if [ "$mode" = restore ]; then
      mode=direct
      if [ -e /base/ph/egress-mode ]; then mode=$(cat /base/ph/egress-mode); fi
    fi
    case "$mode" in
      direct) elements="" ;;
      tor) elements='add element inet ph-egress tor_interfaces { "${cfg.lanInterface}", "${cfg.wanInterface}" }' ;;
      *) echo "invalid saved egress mode; keeping the Tor clamp" >&2; exit 1 ;;
    esac
    install -d -m755 /base/ph /run/ph-egress
    printf '%s\n' "$mode" > /base/ph/.egress-mode
    chmod 644 /base/ph/.egress-mode
    ${pkgs.nftables}/bin/nft -f - <<EOF
    flush set inet ph-egress tor_interfaces
    $elements
    EOF
    # fsync file then directory: an acknowledged mode must survive an immediate power cut.
    sync /base/ph/.egress-mode
    mv /base/ph/.egress-mode /base/ph/egress-mode
    sync /base/ph
    # Old direct/NAT flows must not survive a deliberate mode change.
    ${pkgs.conntrack-tools}/bin/conntrack -D -s 10.73.0.0/24 >/dev/null 2>&1 || true
    printf '%s\n' "$mode" > /run/ph-egress/.mode
    chmod 644 /run/ph-egress/.mode
    mv /run/ph-egress/.mode /run/ph-egress/mode
    echo "egress mode applied: $mode"
  '';
in
{
  options.panhandler.egress = {
    lanInterface = lib.mkOption {
      type = lib.types.str;
      default = "eth0";
    };
    wanInterface = lib.mkOption {
      type = lib.types.str;
      default = "wlan0";
    };
    gateway = lib.mkOption {
      type = lib.types.str;
      default = "10.73.0.1";
    };
  };
  config = {
    environment.systemPackages = [
      (pkgs.writeShellApplication {
        name = "ph-egress";
        runtimeInputs = [
          config.systemd.package
          pkgs.coreutils
        ];
        text = ''
          case "''${1:-status}" in
            direct|tor) systemctl start "ph-egress-$1.service" ;;
            status) cat /run/ph-egress/mode ;;
            *) echo "usage: sudo ph-egress direct|tor; ph-egress status" >&2; exit 2 ;;
          esac
        '';
      })
    ];
    systemd.services.nftables = {
      unitConfig.RequiresMountsFor = [ "/base" ];
      serviceConfig = {
        ExecStartPost = lib.mkAfter [ "${applyMode} restore" ];
        ExecReload = lib.mkAfter [ "${applyMode} restore" ];
      };
    };
    systemd.services.ph-egress-direct = {
      requires = [ "nftables.service" ];
      after = [ "nftables.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${applyMode} direct";
      };
    };
    systemd.services.ph-egress-tor = {
      requires = [ "nftables.service" ];
      after = [ "nftables.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${applyMode} tor";
      };
    };
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units"
            && subject.user == "panhandler-webd"
            && (action.lookup("unit") == "ph-egress-direct.service" || action.lookup("unit") == "ph-egress-tor.service")
            && action.lookup("verb") == "start")
          return polkit.Result.YES;
      });
    '';
    services.tor = {
      enable = true;
      client.enable = true;
      settings = {
        DataDirectory = "/persist/tor";
        SOCKSPort = lib.mkForce [ 0 ];
        TransPort = [
          {
            addr = "127.0.0.1";
            port = 9040;
          }
          {
            addr = cfg.gateway;
            port = 9040;
          }
        ];
        DNSPort = [
          {
            addr = "127.0.0.1";
            port = 9053;
          }
        ];
        MaxMemInQueues = "64 MB";
      };
    };
    # Guard state belongs inside LUKS. Locked boots keep management up and clients clamped.
    systemd.services.ph-tor-state = {
      requires = [ "persist.mount" ];
      after = [ "persist.mount" ];
      before = [ "tor.service" ];
      serviceConfig.Type = "oneshot";
      script = "install -d -m700 -o tor -g tor /persist/tor";
    };
    systemd.services.tor = {
      wantedBy = lib.mkForce [ "ph-persist.target" ];
      requires = [ "ph-tor-state.service" ];
      after = [ "ph-tor-state.service" ];
      partOf = [ "ph-persist.target" ];
      serviceConfig = {
        BindPaths = [ "/persist/tor" ];
        MemoryMax = "192M";
      };
    };
    networking.firewall.interfaces.${cfg.lanInterface}.allowedTCPPorts = [ 9040 ];
    networking.nftables.tables.ph-egress = {
      family = "inet";
      content = ''
        # Start/reload clamped; the post-load hook restores the persisted choice.
        set tor_interfaces { type ifname; elements = { "${cfg.lanInterface}", "${cfg.wanInterface}" }; }
        set portal_clients { type ipv4_addr; flags timeout; timeout 600s; }
        set portal_dns { type ipv4_addr; flags timeout; timeout 600s; }
        chain prerouting {
          type nat hook prerouting priority dstnat - 5; policy accept;
          iifname "${cfg.lanInterface}" ip saddr @portal_clients return
          iifname "${cfg.lanInterface}" meta nfproto ipv4 udp dport 53 redirect to :53
          iifname "${cfg.lanInterface}" meta nfproto ipv4 tcp dport 53 redirect to :53
          iifname "${cfg.lanInterface}" ip daddr ${cfg.gateway} return
          iifname != @tor_interfaces return
          iifname "${cfg.lanInterface}" meta nfproto ipv4 meta l4proto tcp redirect to :9040
        }
        chain output_nat {
          type nat hook output priority dstnat - 5; policy accept;
          oifname != "${cfg.wanInterface}" return
          oifname != @tor_interfaces return
          meta skuid ${torUid} return
          ${transport} return
          # Root/NM portal probes and time-sync DNS must work before Tor/clock bootstrap.
          ${bootstrap}
          meta nfproto ipv4 udp dport 53 redirect to :9053
          meta nfproto ipv4 meta l4proto tcp redirect to :9040
        }
        chain forward {
          type filter hook forward priority filter - 5; policy drop;
          iifname != @tor_interfaces accept
          # Every packet is checked, including already-established portal connections.
          iifname "${cfg.lanInterface}" oifname "${cfg.wanInterface}" ip saddr @portal_clients tcp dport { 80, 443 } accept
          iifname "${cfg.lanInterface}" oifname "${cfg.wanInterface}" ip saddr @portal_clients ip daddr @portal_dns udp dport 53 accept
          iifname "${cfg.lanInterface}" oifname "${cfg.wanInterface}" ip saddr @portal_clients ip daddr @portal_dns tcp dport 53 accept
          iifname "${cfg.wanInterface}" oifname "${cfg.lanInterface}" ip daddr @portal_clients ct state established,related accept
        }
        chain output {
          type filter hook output priority filter - 5; policy accept;
          # Local DNAT still carries the original output interface at this hook.
          ct status dnat ip daddr 127.0.0.1 tcp dport 9040 accept
          ct status dnat ip daddr 127.0.0.1 udp dport 9053 accept
          oifname != "${cfg.wanInterface}" return
          oifname != @tor_interfaces return
          meta skuid ${torUid} meta l4proto tcp accept
          ${transport} accept
          ${bootstrap}
          meta skuid ${clockUid} udp dport 123 accept
          udp sport 68 udp dport 67 accept
          icmpv6 type { nd-router-solicit, nd-neighbor-solicit, nd-neighbor-advert } accept
          drop
        }
      '';
    };
  };
}
