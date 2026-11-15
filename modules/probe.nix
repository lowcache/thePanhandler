{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.panhandler.probe;
  unit = "ph-uplink-probe";
  wanRe = builtins.concatStringsSep "|" config.panhandler.wanInterfaces;
  targets = lib.concatMapStringsSep "\n" (t: "${t.url} ${t.marker}") cfg.targets;
  probePath = with pkgs; [
    coreutils
    curl
    dig
    gawk
    gnugrep
    gnused
    iproute2
    jq
    networkmanager
    systemd
  ];
  probe = pkgs.writeShellScript unit ''
    set -euo pipefail
    # ASCII ranges in [[ =~ ]] (the portal URL check) mean ASCII only in the C locale.
    export LC_ALL=C
    dir=/run/ph-uplink
    now=$(date -u +%FT%TZ)
    wan=$(ip -4 route show default | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1)
    verdict=dead portal="" page=""
    if [[ $wan =~ ^(${wanRe})$ ]]; then
      # The hotel's resolver, not blocky: pre-auth, DoH is dead and the portal is what we're looking for.
      dns=$(nmcli -g IP4.DNS device show "$wan" | sed 's/ | /\n/g' | head -n1)
      [[ $dns =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || dns=""
      while read -r url marker; do
        host=$(sed -E 's#^https?://([^/:]+).*#\1#' <<<"$url")
        ip=""
        if [ -n "$dns" ]; then ip=$(dig +short +time=2 +tries=1 A "$host" @"$dns" | grep -m1 -E '^[0-9]+(\.[0-9]+){3}$' || true); fi
        [ -n "$ip" ] || ip=$(getent ahostsv4 "$host" | awk 'NR == 1 { print $1 }' || true)
        [ -n "$ip" ] || continue
        # Root's port-80 exception skips Tor, so this is the raw uplink in either egress mode.
        out=$(curl -4 -s -m 6 --max-filesize 262144 --resolve "$host:80:$ip" -w '\n%{http_code} %{redirect_url}' "$url" || true)
        code=$(tail -n1 <<<"$out")
        body=$(sed '$d' <<<"$out")
        if grep -qF -- "$marker" <<<"$body"; then verdict=open; break; fi
        [ -n "$code" ] || continue
        loc=''${code#* }
        [ -n "$loc" ] || loc=$(grep -oiE 'url=["'"'"']?https?://[^"'"'"' >]+' <<<"$body" | head -n1 | sed -E 's/^[Uu][Rr][Ll]=["'"'"']?//; s/&amp;/\&/g' || true)
        if [ -n "$body$loc" ] && [ "''${code%% *}" != 000 ]; then
          verdict=portal
          # Hotel-controlled: keep only a plain http(s) URL of printable ASCII.
          if [ -z "$portal" ] && [[ $loc =~ ^https?://[!-~]{1,1024}$ ]]; then portal=$loc; fi
          page=$host
        fi
      done <<'EOF'
    ${targets}
    EOF
    fi

    st=$(cat "$dir/state.json" 2>/dev/null || echo '{}')
    prev=$(jq -r '.verdict // "unknown"' <<<"$st" 2>/dev/null || echo unknown)
    held=false
    # Pre-auth portals skip answers (Hilton: portal<->dead every 2-6 min). Same uplink: hold portal for one dead run.
    if [ "$prev" = portal ] && [ "$verdict" = dead ] && [ -n "$wan" ] \
      && [ "$(jq -r '"\(.wan // "")|\(.held // false)"' <<<"$st")" = "$wan|false" ]; then
      verdict=portal held=true
      portal=$(jq -r '.portalUrl // ""' <<<"$st") page=$(jq -r '.interceptedHost // ""' <<<"$st")
    fi
    jq -n --arg v "$verdict" --arg p "$portal" --arg w "$wan" --arg t "$now" --arg h "$page" --argjson held "$held" \
      '{verdict: $v, portalUrl: $p, wan: $w, checkedAt: $t, interceptedHost: $h, held: $held}' >"$dir/.state.json"
    mv "$dir/.state.json" "$dir/state.json"

    if [ "$prev" != "$verdict" ]; then
      # RAM only: no location trail on disk, no SSID in the record.
      echo "$now $prev -> $verdict" >>"$dir/history"
      tail -n 200 "$dir/history" >"$dir/.history" && mv "$dir/.history" "$dir/history"
      jq -nc --arg v "$verdict" --arg p "$prev" --arg t "$now" '{verdict: $v, prev: $p, at: $t}' >"$dir/outbox/$now.json"
      # Logged in (or back): blocky's pooled DoH connections died with the old network state.
      if [ "$verdict" = open ]; then systemctl try-restart blocky.service || true; fi
    fi
    ${lib.optionalString (cfg.noticeUrl != "") ''
      # The portal usually takes the tailnet down too; notices wait here until the phone answers.
      for f in "$dir"/outbox/*.json; do
        [ -e "$f" ] || break
        curl -fsS -m 5 -H 'Content-Type: application/json' --data @"$f" ${lib.escapeShellArg cfg.noticeUrl} >/dev/null || break
        rm -f "$f"
      done
      find "$dir/outbox" -name '*.json' | sort | head -n -50 | xargs -r rm -f
    ''}
    echo "uplink $verdict''${portal:+ portal=$portal}"
  '';
in
{
  imports = [ ./interfaces.nix ];

  options.panhandler.probe = {
    targets = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            url = lib.mkOption { type = lib.types.str; };
            marker = lib.mkOption { type = lib.types.str; };
          };
        }
      );
      # Plain-HTTP pages portals don't allowlist (ElevenOS passes the OS check URLs). Several, because
      # some portals silently drop a host instead of redirecting it.
      default = [
        {
          url = "http://neverssl.com/";
          marker = "NeverSSL";
        }
        {
          url = "http://httpforever.com/";
          marker = "HTTP Forever";
        }
        {
          url = "http://example.com/";
          marker = "Example Domain";
        }
      ];
      description = "Probe pages and the text each returns when the uplink is really open.";
    };
    noticeUrl = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Where verdict changes are POSTed (the phone listener); empty = history only.";
    };
  };

  config = {
    systemd.services.${unit} = {
      description = "Uplink truth: open, captive portal, or dead (ignores NM's whitelisted check)";
      path = probePath;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = probe;
        RuntimeDirectory = "ph-uplink ph-uplink/outbox";
        RuntimeDirectoryPreserve = true;
        RuntimeDirectoryMode = "0755";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
          "AF_NETLINK"
        ];
      };
    };
    systemd.timers.${unit} = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "2min";
      };
    };
    networking.networkmanager.dispatcherScripts = [
      {
        source = pkgs.writeShellScript "${unit}-on-change" ''
          if [[ $1 =~ ^(${wanRe})$ ]] && { [ "$2" = up ] || [ "$2" = down ]; } || [ "$2" = connectivity-change ]; then
            ${config.systemd.package}/bin/systemctl start --no-block ${unit}.service
          fi
        '';
      }
    ];
    # webd re-runs it while a portal bypass is open; start only, nothing else.
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units"
            && subject.user == "panhandler-webd"
            && action.lookup("unit") == "${unit}.service"
            && action.lookup("verb") == "start")
          return polkit.Result.YES;
      });
    '';
  };
}
