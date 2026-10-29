{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.panhandler.egress;
  lan = config.panhandler.lanInterface;
  wans = builtins.concatStringsSep ", " (map (i: ''"${i}"'') config.panhandler.wanInterfaces);
  wanRe = builtins.concatStringsSep "|" config.panhandler.wanInterfaces;
  # Per-network policy: "<NM connection UUID> <mode>" lines. Inside LUKS: saved networks are a location trail.
  policy = "/persist/ph-egress-policy";
  # Sets $net to the connection UUID on the uplink holding the default route, or "".
  currentNet = ''
    wan=$(ip -4 route show default | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1)
    net=""
    if [[ $wan =~ ^(${wanRe})$ ]]; then net=$(nmcli -g GENERAL.CON-UUID device show "$wan" 2>/dev/null || true); fi
    [[ $net =~ ^[0-9a-f-]{36}$ ]] || net=""
    # A locked boot has /persist as a bare tmpfs-root directory: no policy to read or write.
    [ "$(stat -c %d /persist)" != "$(stat -c %d /)" ] || net=""
  '';
  learn = pkgs.writeShellScript "ph-egress-learn" ''
    set -eu
    ${currentNet}
    [ -n "$net" ] || exit 0
    umask 077
    { grep -sv "^$net " ${policy} || true; echo "$net $1"; } >${policy}.tmp
    mv ${policy}.tmp ${policy}
  '';
  auto = pkgs.writeShellScript "ph-egress-auto" ''
    set -eu
    ${currentNet}
    mode=""
    if [ -n "$net" ] && [ -e ${policy} ]; then mode=$(awk -v n="$net" '$1 == n { m = $2 } END { print m }' ${policy}); fi
    [ -n "$mode" ] || mode=${cfg.unknownNetwork}
    if [ "$mode" = keep ] || [ "$(cat /run/ph-egress/mode 2>/dev/null)" = "$mode" ]; then exit 0; fi
    exec ${applyMode} "$mode"
  '';
  policyPath = with pkgs; [
    networkmanager
    iproute2
    gnused
    gnugrep
    gawk
    coreutils
  ];
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
      tor) elements='add element inet ph-egress tor_interfaces { "${lan}", ${wans} }' ;;
      *) echo "invalid saved egress mode; keeping the Tor clamp" >&2; exit 1 ;;
    esac
    # /base/ph holds unlock state (tmpfiles: 0700); never loosen it.
    install -d -m700 /base/ph
    install -d -m755 /run/ph-egress
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
  imports = [ ./interfaces.nix ];

  options.panhandler.egress = {
    unknownNetwork = lib.mkOption {
      type = lib.types.enum [
        "keep"
        "direct"
        "tor"
      ];
      default = "keep";
      description = "Egress applied on joining a network with no learned mode.";
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
    # A deliberate choice (UI, phone, ph-egress) is also remembered for the current network.
    systemd.services.ph-egress-direct = {
      requires = [ "nftables.service" ];
      after = [ "nftables.service" ];
      path = policyPath;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${applyMode} direct";
        ExecStartPost = "${learn} direct";
      };
    };
    systemd.services.ph-egress-tor = {
      requires = [ "nftables.service" ];
      after = [ "nftables.service" ];
      path = policyPath;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${applyMode} tor";
        ExecStartPost = "${learn} tor";
      };
    };
    # Re-applies the learned mode when the default-route uplink changes, and once after unlock.
    systemd.services.ph-egress-auto = {
      wantedBy = [ "ph-persist.target" ];
      requires = [ "nftables.service" ];
      after = [
        "nftables.service"
        "persist.mount"
      ];
      path = policyPath;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = auto;
      };
    };
    networking.networkmanager.dispatcherScripts = [
      {
        source = pkgs.writeShellScript "ph-egress-on-uplink" ''
          if [[ $1 =~ ^(${wanRe})$ ]] && { [ "$2" = up ] || [ "$2" = down ]; }; then
            ${config.systemd.package}/bin/systemctl start --no-block ph-egress-auto.service
          fi
        '';
      }
    ];
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
    networking.firewall.interfaces.${lan}.allowedTCPPorts = [ 9040 ];
    networking.nftables.tables.ph-egress = {
      family = "inet";
      content = ''
        # Start/reload clamped; the post-load hook restores the persisted choice.
        set tor_interfaces { type ifname; elements = { "${lan}", ${wans} }; }
        set portal_clients { type ipv4_addr; flags timeout; timeout 600s; }
        set portal_dns { type ipv4_addr; flags timeout; timeout 600s; }
        chain prerouting {
          type nat hook prerouting priority dstnat - 5; policy accept;
          iifname "${lan}" ip saddr @portal_clients return
          iifname "${lan}" meta nfproto ipv4 udp dport 53 redirect to :53
          iifname "${lan}" meta nfproto ipv4 tcp dport 53 redirect to :53
          iifname "${lan}" ip daddr ${cfg.gateway} return
          iifname != @tor_interfaces return
          iifname "${lan}" meta nfproto ipv4 meta l4proto tcp redirect to :9040
        }
        chain output_nat {
          type nat hook output priority dstnat - 5; policy accept;
          oifname != { ${wans} } return
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
          iifname "${lan}" oifname { ${wans} } ip saddr @portal_clients tcp dport { 80, 443 } accept
          iifname "${lan}" oifname { ${wans} } ip saddr @portal_clients ip daddr @portal_dns udp dport 53 accept
          iifname "${lan}" oifname { ${wans} } ip saddr @portal_clients ip daddr @portal_dns tcp dport 53 accept
          iifname { ${wans} } oifname "${lan}" ip daddr @portal_clients ct state established,related accept
        }
        chain output {
          type filter hook output priority filter - 5; policy accept;
          # Local DNAT still carries the original output interface at this hook.
          ct status dnat ip daddr 127.0.0.1 tcp dport 9040 accept
          ct status dnat ip daddr 127.0.0.1 udp dport 9053 accept
          oifname != { ${wans} } return
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
