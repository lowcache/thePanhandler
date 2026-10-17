{
  lib,
  pkgs,
  username,
  ...
}:
{
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

  networking.hostName = "panhandler";
  time.timeZone = lib.mkDefault "UTC";
  # New host: current release. Never bump after first deploy.
  system.stateVersion = "26.11";

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # DHCP on every uplink (wlan0 for the hotel radio, eth0 for the OOB cable).
  networking.useDHCP = lib.mkDefault true;

  # --- Users: keys-only, no mutable state, no throwaway password on this image ---
  users.mutableUsers = false;
  users.users.root.hashedPassword = "!";
  users.users.${username} = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBJZUOXEhGUUPfHPoXg6imru3+6lPmnVQS437J38QVCW lowcache"
    ];
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
    interfaces."tailscale0".allowedTCPPorts = [ 22 ];
    interfaces."eth0".allowedTCPPorts = [ 22 ];
  };

  # Keep the closure lean for a 1 GB board.
  documentation.enable = lib.mkDefault false;
  environment.systemPackages = [ ];
}
