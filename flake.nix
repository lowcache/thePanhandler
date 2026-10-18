{
  description = "The Panhandler — roaming privacy gateway on a Raspberry Pi 3B (aarch64 NixOS)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-hardware,
      sops-nix,
      ...
    }@inputs:
    let
      username = "lowcache";
    in
    {
      nixosConfigurations.panhandler = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs username; };
        modules = [
          # Reported by `nixos-version --configuration-revision`.
          { system.configurationRevision = self.rev or self.dirtyRev or "unknown"; }
          nixos-hardware.nixosModules.raspberry-pi-3
          "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
          sops-nix.nixosModules.sops
          ./modules/base.nix
          ./modules/secrets.nix
          ./modules/wifi.nix
          ./modules/tailscale.nix
          ./modules/storage.nix
          ./modules/unlock.nix
        ];
      };

      # The flashable image (binfmt on volnix): `nix build .#packages.aarch64-linux.sdImage`.
      packages.aarch64-linux.sdImage = self.nixosConfigurations.panhandler.config.system.build.sdImage;

      # Laptop-side tools (run on volnix).
      packages.x86_64-linux =
        let
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
        in
        {
          ph-provision = pkgs.writeShellApplication {
            name = "ph-provision";
            runtimeInputs = with pkgs; [
              age
              coreutils
              cryptsetup
              e2fsprogs
              gnugrep
              gnused
              openssh
              parted
              python3
              sops
              util-linux
              zstd
            ];
            text = builtins.readFile ./tools/ph-provision.sh;
          };
          ph-unlock = pkgs.writers.writePython3Bin "ph-unlock" {
            flakeIgnore = [
              "E401"
              "E501"
              "E701"
            ];
          } (builtins.readFile ./tools/ph-unlock.py);
        };

      checks.x86_64-linux.spine = import ./tests/spine.nix {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        unlockModule = ./modules/unlock.nix;
      };

      # Built on the x86_64 laptop; nixfmt = RFC 166 (matches volnix).
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt;
    };
}
