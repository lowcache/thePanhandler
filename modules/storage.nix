{ lib, ... }:
let
  sd = "/dev/disk/by-label/NIXOS_SD";
  bindFromSd = path: {
    device = "/sd/${path}";
    fsType = "none";
    options = [ "bind" ];
    depends = [ "/sd" ];
    neededForBoot = true;
  };
in
{
  # tmpfs root: a reboot wipes everything outside /nix, /boot, /base and (after unlock) /persist.
  # mkForce replaces sd-image's ext4 "/" on purpose; that partition moves to /sd.
  fileSystems = {
    "/" = lib.mkForce {
      device = "none";
      fsType = "tmpfs";
      options = [
        "defaults"
        "size=256M"
        "mode=755"
      ];
    };
    "/sd" = {
      device = sd;
      fsType = "ext4";
      options = [ "noatime" ];
      neededForBoot = true;
    };
    # The image keeps the store at <partition>/nix/store and extlinux at <partition>/boot.
    "/nix" = bindFromSd "nix";
    "/boot" = bindFromSd "boot";
    # Pre-unlock identity: nothing here may be worth stealing.
    "/base" = bindFromSd "base";
    # Stable uid/gid allocation is needed at activation, before any unlock.
    "/var/lib/nixos" = bindFromSd "base/nixos";
  };

  sdImage = {
    # Leave the card's tail unallocated for the LUKS persist partition (ph-provision).
    expandOnBoot = false;
    nixPathRegistrationFile = "/sd/nix-path-registration";
    populateRootCommands = lib.mkAfter ''
      mkdir -p ./files/base/nixos ./files/base/ssh ./files/base/tailscale
    '';
  };

  services.journald.settings.Journal.Storage = "volatile";

  # No RTC: the clock boots at systemd's build date, months behind, and TLS fails until NTP.
  # Keep the last synced time in /base; timesyncd takes its clock file's mtime as a floor.
  systemd = {
    services.ph-clock-seed = {
      description = "Seed timesyncd's clock floor from /base";
      wantedBy = [ "systemd-timesyncd.service" ];
      before = [ "systemd-timesyncd.service" ];
      unitConfig = {
        DefaultDependencies = false;
        RequiresMountsFor = [ "/base" ];
        ConditionPathExists = "/base/ph/clock";
      };
      serviceConfig.Type = "oneshot";
      script = ''
        install -d -m755 -o systemd-timesync -g systemd-timesync /var/lib/systemd/timesync
        touch -r /base/ph/clock /var/lib/systemd/timesync/clock
        chown systemd-timesync:systemd-timesync /var/lib/systemd/timesync/clock
      '';
    };
    # Periodic, not at shutdown: the Pi is usually just unplugged.
    services.ph-clock-save = {
      description = "Record the synced time in /base";
      unitConfig.ConditionPathExists = "/run/systemd/timesync/synchronized";
      serviceConfig.Type = "oneshot";
      script = "touch /base/ph/clock";
    };
    timers.ph-clock-save = {
      wantedBy = [ "timers.target" ];
      timerConfig.OnCalendar = "*:0/15";
    };
  };
}
