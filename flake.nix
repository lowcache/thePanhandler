{
  description = "The Panhandler — roaming privacy gateway on a Raspberry Pi 3B (aarch64 NixOS)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixos-hardware = {
      url = "github:NixOS/nixos-hardware/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
      tailnetPolicy = (builtins.fromJSON (builtins.readFile ./security/tailscale-policy.json)) // {
        hosts = self.nixosConfigurations.panhandler.config.panhandler.managementPeers;
      };
    in
    {
      nixosConfigurations.panhandler = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs username; };
        modules = [
          # Reported by `nixos-version --configuration-revision`.
          {
            system.configurationRevision = self.rev or self.dirtyRev or "unknown";
            panhandler.webd.allowedHostnames = [
              "panhandler.taila5270e.ts.net"
              "panhandler-locked.taila5270e.ts.net"
            ];
            panhandler.managementPeers = {
              volnix = "100.66.249.117";
              volnix-v6 = "fd7a:115c:a1e0::9b3b:f976";
              phone = "100.101.229.9";
              phone-v6 = "fd7a:115c:a1e0::3801:e5aa";
            };
          }
          nixos-hardware.nixosModules.raspberry-pi-3
          "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
          sops-nix.nixosModules.sops
          ./modules/base.nix
          ./modules/secrets.nix
          ./modules/wifi.nix
          ./modules/tailscale.nix
          ./modules/storage.nix
          ./modules/unlock.nix
          ./modules/gateway.nix
          ./modules/egress.nix
          ./modules/webd.nix
          ./modules/portal.nix
          ./modules/hardening.nix
        ];
      };

      # The flashable image (binfmt on volnix): `nix build .#packages.aarch64-linux.sdImage`.
      packages.aarch64-linux = {
        sdImage = self.nixosConfigurations.panhandler.config.system.build.sdImage;
        panhandler-webd = nixpkgs.legacyPackages.aarch64-linux.callPackage ./pkgs/panhandler-webd { };
        # The image's firmware partition, rebuilt standalone as verify-card's reference.
        firmware =
          let
            inherit (self.nixosConfigurations.panhandler) config pkgs;
          in
          pkgs.runCommand "panhandler-firmware" { } ''
            mkdir firmware
            ${config.sdImage.populateFirmwareCommands}
            mv firmware $out
          '';
      };

      # Laptop-side tools (run on volnix).
      packages.x86_64-linux =
        let
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
        in
        {
          tailscale-policy = pkgs.writeText "tailscale-policy.json" (builtins.toJSON tailnetPolicy);
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
          verify-card = pkgs.writeShellApplication {
            name = "verify-card";
            runtimeInputs = with pkgs; [
              coreutils
              diffutils
              gnugrep
              gnused
              jq
              util-linux
            ];
            text = builtins.readFile ./tools/verify-card.sh;
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

      checks.x86_64-linux.hardening = import ./tests/hardening.nix {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        hardeningModule = ./modules/hardening.nix;
      };

      checks.x86_64-linux.gateway = import ./tests/gateway.nix {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        gatewayModule = ./modules/gateway.nix;
      };

      checks.x86_64-linux.egress = import ./tests/egress.nix {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        gatewayModule = ./modules/gateway.nix;
        egressModule = ./modules/egress.nix;
        portalModule = ./modules/portal.nix;
      };

      checks.x86_64-linux.webd =
        nixpkgs.legacyPackages.x86_64-linux.callPackage ./pkgs/panhandler-webd
          { };

      checks.x86_64-linux.tailscale-policy =
        assert builtins.fromJSON (builtins.readFile ./security/tailscale-policy.json) == tailnetPolicy;
        nixpkgs.legacyPackages.x86_64-linux.runCommand "tailscale-policy-current" { } "mkdir $out";

      # Built on the x86_64 laptop; nixfmt = RFC 166 (matches volnix).
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt;
    };
}
