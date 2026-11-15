{
  config,
  lib,
  pkgs,
  ...
}:
let
  uid = config.panhandler.clockUid;
  wanRe = builtins.concatStringsSep "|" config.panhandler.wanInterfaces;
  fetchPath = with pkgs; [
    coreutils
    curl
    dig
    gnugrep
    gnused
    iproute2
    networkmanager
    systemd
  ];
  fetch = pkgs.writeShellScript "ph-clock-https" ''
    set -euo pipefail
    [ "$(timedatectl show -p NTPSynchronized --value)" = yes ] && exit 0
    # Hotel DNS, not blocky: blocky's DoH (and in Tor mode, Tor) may be waiting on this very clock.
    wan=$(ip -4 route show default | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1)
    dns=""
    if [[ $wan =~ ^(${wanRe})$ ]]; then dns=$(nmcli -g IP4.DNS device show "$wan" | sed 's/ | /\n/g' | head -n1); fi
    [[ $dns =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "no IPv4 uplink resolver" >&2; exit 0; }
    ts=()
    for h in ${lib.escapeShellArgs config.panhandler.clock.hosts}; do
      ip=$(dig +short +time=2 +tries=1 A "$h" @"$dns" | grep -m1 -E '^[0-9]+(\.[0-9]+){3}$') || continue
      d=$(curl -4 -sSI -m 8 --resolve "$h:443:$ip" "https://$h/" | sed -n 's/^[Dd]ate: //p' | tr -d '\r') || continue
      # An empty Date would parse as midnight today.
      [ -n "$d" ] || continue
      t=$(date -d "$d" +%s 2>/dev/null) && ts+=("$t")
    done
    # Two sources within 30 s of each other, or no step.
    mapfile -t ts < <(printf '%s\n' "''${ts[@]}" | sed '/^$/d' | sort -n)
    best=""
    for ((i = 1; i < ''${#ts[@]}; i++)); do
      if ((ts[i] - ts[i - 1] <= 30)); then best=''${ts[i]}; fi
    done
    [ -n "$best" ] || { echo "no two agreeing HTTPS dates (''${#ts[@]} fetched)" >&2; exit 0; }
    skew=$((best - $(date +%s)))
    # Forward only: a rollback is the useful attack, and the floor already bounds how far behind we are.
    if [ "$skew" -gt 30 ]; then
      date -u -s "@$best" >/dev/null
      echo "clock stepped forward ''${skew}s from HTTPS"
      touch "$RUNTIME_DIRECTORY/stepped"
    fi
    touch "$RUNTIME_DIRECTORY/https"
  '';
in
{
  imports = [ ./interfaces.nix ];

  # TLS-authenticated Date headers. The /base floor keeps the clock close enough for TLS to verify.
  options.panhandler.clock.hosts = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [
      "www.google.com"
      "www.cloudflare.com"
      "www.wikipedia.org"
    ];
    description = "HTTPS hosts whose Date headers step the clock (two must agree within 30 s).";
  };

  config = {
    users.users.ph-clock = {
      isSystemUser = true;
      inherit uid;
      group = "ph-clock";
    };
    users.groups.ph-clock = { };

    # Cloudflare's anycast NTP first (no DNS needed pre-blocky), the pool after.
    services.timesyncd.servers = [
      "162.159.200.1"
      "162.159.200.123"
    ]
    ++ config.networking.timeServers;

    systemd.services.ph-clock-https = {
      description = "Step the clock forward from HTTPS Date headers when NTP has not synced";
      path = fetchPath;
      serviceConfig = {
        Type = "oneshot";
        User = "ph-clock";
        ExecStart = fetch;
        # Root only for the follow-up: save the /base floor and reset blocky's TLS state.
        ExecStartPost = "+${pkgs.writeShellScript "ph-clock-https-post" ''
          [ -e /run/ph-clock/https ] && touch /base/ph/clock
          if [ -e /run/ph-clock/stepped ]; then
            rm /run/ph-clock/stepped
            ${config.systemd.package}/bin/systemctl try-restart blocky.service || true
          fi
        ''}";
        RuntimeDirectory = "ph-clock";
        RuntimeDirectoryPreserve = true;
        AmbientCapabilities = [ "CAP_SYS_TIME" ];
        CapabilityBoundingSet = [ "CAP_SYS_TIME" ];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_UNIX"
          # ip route (finding the uplink)
          "AF_NETLINK"
        ];
      };
    };
    systemd.timers.ph-clock-https = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "45s";
        OnUnitActiveSec = "5min";
      };
    };
  };
}
