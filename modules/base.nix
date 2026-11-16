{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [ ./interfaces.nix ];

  nixpkgs.hostPlatform = "aarch64-linux";
  # Mainline over nixos-hardware's mkDefault vendor kernel: mainline is in
  # cache.nixos.org, linux-rpi compiles for hours under binfmt on every bump.
  boot.kernelPackages = pkgs.linuxPackages;
  # nixos-hardware mkForces the SD firmware partition and skips U-Boot unless
  # asked; without it the GPU firmware finds no kernel (7 ACT blinks).
  hardware.raspberry-pi.firmware.uboot.enable = true;
  # uboot.enable defaults this off (keep firmware-overlaid vendor DTB); the
  # mainline kernel wants its own DTBs via extlinux FDTDIR, as stock sd-image-aarch64.
  boot.loader.generic-extlinux-compatible.useGenerationDeviceTree = true;

  time.timeZone = lib.mkDefault "UTC";

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # DHCP on every uplink (wlan0 for the hotel radio, eth0 for the OOB cable).
  networking.useDHCP = lib.mkDefault true;

  # --- Users: keys-only, no mutable state, no throwaway password on this image ---
  users.mutableUsers = false;
  users.users.root.hashedPassword = "!";
  users.users.${config.panhandler.adminUser} = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = config.panhandler.adminKeys;
  };
  # Headless + keys-only: wheel sudo needs no password (the box holds nothing).
  security.sudo.wheelNeedsPassword = false;

  # --- SSH: keys only, root denied, firewall opened narrowly (see below) ---
  services.openssh = {
    enable = true;
    openFirewall = false;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # Default-deny inbound. SSH reachable ONLY over the tailnet and the
  # break-glass Ethernet cable — never on the hostile Wi-Fi uplink (wlan0).
  # Classic names: the USB-attached NIC otherwise isn't "eth0" and the rule misses.
  networking.usePredictableInterfaceNames = false;
  networking.firewall = {
    enable = true;
    interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts = [ 22 ];
    interfaces.${config.panhandler.lanInterface}.allowedTCPPorts = [ 22 ];
  };

  # Keep the closure lean for a 1 GB board.
  documentation.enable = lib.mkDefault false;
  # iw: on-device wifi diagnosis/regdomain for a roaming router (reg get/set, scan).
  environment.systemPackages = [ pkgs.iw ];
}
