{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.panhandler.spine;
  state = "${cfg.baseDir}/ph";

  script =
    name: runtimeInputs: runtimeEnv:
    pkgs.writeShellApplication {
      inherit name runtimeInputs runtimeEnv;
      text = builtins.readFile ../pkgs/${name}.sh;
    };

  unlockRoot =
    script "ph-unlock-root"
      (with pkgs; [
        coreutils
        cryptsetup
        gnugrep
        iproute2
        systemd
      ])
      {
        STATE = state;
        PERSIST_DEV = "/dev/disk/by-uuid/${cfg.persistUuid}";
        CABLE_IF = cfg.cableInterface;
        TS_IF = cfg.tailnetInterface;
      };
  unlockd = script "ph-unlockd" [ "/run/wrappers" ] { PH_UNLOCK_ROOT = lib.getExe unlockRoot; };
  checkin =
    script "ph-checkin"
      (with pkgs; [
        coreutils
        cryptsetup
        curl
        gnused
        jq
        wpa_supplicant
      ])
      {
        STATE = state;
        UPLINK_IF = cfg.uplinkInterface;
        CHECKIN_URL = cfg.checkinUrl;
      };
  tsState = script "ph-tailscale-state" (with pkgs; [
    coreutils
    util-linux
  ]) { };
  tsUp =
    script "ph-tailscale-up"
      [ pkgs.coreutils pkgs.jq pkgs.util-linux config.services.tailscale.package ]
      {
        STATE = state;
        MAIN_KEY = cfg.mainAuthKeyFile;
        MAIN_HOST = cfg.mainHostname;
        LOCKED_HOST = cfg.lockedHostname;
      };
  uptime = script "ph-uptime" [ pkgs.coreutils ] {
    STATE = state;
    STABLE_S = toString (cfg.shortBoot.stableMinutes * 60);
  };
in
{
  options.panhandler.spine = {
    persistUuid = mkOption {
      type = types.str;
      description = "LUKS UUID of the persist partition (set by ph-provision with --uuid).";
    };
    baseDir = mkOption {
      type = types.str;
      default = "/base";
    };
    initrdBase = {
      path = mkOption {
        type = types.str;
        default = "/sysroot/sd/base";
        description = "Where baseDir is visible inside the initrd.";
      };
      mount = mkOption {
        type = types.str;
        default = "sysroot-sd.mount";
      };
    };
    cableInterface = mkOption {
      type = types.str;
      default = "eth0";
    };
    tailnetInterface = mkOption {
      type = types.str;
      default = config.services.tailscale.interfaceName;
    };
    mainAuthKeyFile = mkOption {
      type = types.str;
      description = "Single-use authkey for the main identity (a sops secret; exists only after unlock).";
    };
    uplinkInterface = mkOption {
      type = types.str;
      default = "wlan0";
    };
    checkinUrl = mkOption {
      type = types.str;
      default = "";
      description = "Phone boot-log listener; empty = queue only.";
    };
    unlockKeys = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Public keys allowed to run only ph-unlockd.";
    };
    mainHostname = mkOption {
      type = types.str;
      default = "panhandler";
    };
    lockedHostname = mkOption {
      type = types.str;
      default = "panhandler-locked";
    };
    # Clock-free: the Pi has no RTC, so "N boots in M minutes" becomes
    # "N consecutive boots, each before it lived M minutes".
    shortBoot = {
      boots = mkOption {
        type = types.ints.positive;
        default = 3;
      };
      stableMinutes = mkOption {
        type = types.ints.positive;
        default = 15;
      };
    };
  };

  config = {
    environment.systemPackages = [ unlockd ];

    users.users.${username}.openssh.authorizedKeys.keys = map (
      k: ''restrict,pty,command="${lib.getExe unlockd}" ${k}''
    ) cfg.unlockKeys;

    # Same host key locked and unlocked, so it must live outside LUKS.
    services.openssh.hostKeys = [
      {
        path = "${cfg.baseDir}/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];

    # Counts boots as early as possible, before anything can be tampered with from stage 2.
    boot.initrd.systemd.services.ph-bootcount = {
      description = "Count consecutive short boots";
      wantedBy = [ "initrd.target" ];
      requires = [ cfg.initrdBase.mount ];
      after = [ cfg.initrdBase.mount ];
      before = [ "initrd.target" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig.Type = "oneshot";
      script = ''
        d=${cfg.initrdBase.path}/ph
        mkdir -p "$d"
        [ -f "$d/last-uptime" ] && mv "$d/last-uptime" "$d/prev-uptime"
        n=$(cat "$d/short-boots" 2>/dev/null || echo 0)
        case $n in "" | *[!0-9]*) n=0 ;; esac
        n=$((n + 1))
        echo "$n" > "$d/short-boots"
        if [ "$n" -ge ${toString cfg.shortBoot.boots} ] && [ ! -e "$d/lockdown" ]; then
          echo "local-cluster: $n consecutive boots under ${toString cfg.shortBoot.stableMinutes} min" > "$d/lockdown"
          : > "$d/theft"
        fi
        sync
      '';
    };

    systemd = {
      tmpfiles.rules = [ "d ${state} 0700 root root -" ];

      # A bare mount unit, not fileSystems: nothing pulls it in at boot, only ph-persist.target.
      mounts = [
        {
          what = "/dev/mapper/persist";
          where = "/persist";
          type = "ext4";
          options = "noatime";
        }
      ];
      targets.ph-persist = {
        description = "Unlocked /persist and everything that needs it";
        requires = [ "persist.mount" ];
        after = [ "persist.mount" ];
      };

      timers.ph-uptime = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1min";
          OnUnitActiveSec = "5min";
        };
      };

      services = {
        ph-uptime = {
          description = "Record uptime and reset the short-boot run";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe uptime;
          };
        };
        ph-checkin = {
          description = "Report this boot to the phone boot log";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [
            "network-online.target"
            "tailscaled.service"
          ];
          startLimitIntervalSec = 0;
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe checkin;
            Restart = "on-failure";
            RestartSec = 60;
          };
        };

        ph-tailscale-state = {
          description = "Bind the active Tailscale identity's state";
          before = [ "tailscaled.service" ];
          unitConfig.RequiresMountsFor = [ cfg.baseDir ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = lib.getExe tsState;
          };
        };
        tailscaled = {
          requires = [ "ph-tailscale-state.service" ];
          after = [ "ph-tailscale-state.service" ];
          partOf = [ "ph-tailscale-state.service" ];
        };
        ph-tailscale-up = {
          description = "Log the active Tailscale identity in";
          wantedBy = [ "multi-user.target" ];
          after = [ "tailscaled.service" ];
          requires = [ "tailscaled.service" ];
          partOf = [ "ph-tailscale-state.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = lib.getExe tsUp;
          };
        };
      };
    };
  };
}
