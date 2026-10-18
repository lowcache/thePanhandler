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
}
