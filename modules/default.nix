# hoboSEC: a roaming privacy gateway for a Raspberry Pi 3. Generic; a host sets who and where
# (hosts/panhandler.nix). Needs nixos-hardware's raspberry-pi-3, the aarch64 sd-image module and
# sops-nix, which the flake's nixosModules.hobosec brings along.
{
  imports = [
    ./admin.nix
    ./base.nix
    ./secrets.nix
    ./wifi.nix
    ./tailscale.nix
    ./storage.nix
    ./unlock.nix
    ./gateway.nix
    ./egress.nix
    ./webd.nix
    ./portal.nix
    ./probe.nix
    ./clock.nix
    ./hardening.nix
    ./machine-id.nix
  ];
}
