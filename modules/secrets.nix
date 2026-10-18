{ config, lib, ... }:
{
  sops = {
    defaultSopsFile = ../secrets/secrets.yaml;

    # Dedicated Panhandler age key, inside LUKS: secrets exist only after unlock.
    age.sshKeyPaths = [ ];
    age.keyFile = "/persist/sops-nix/key.txt";
    # A systemd unit, so installation can wait for ph-persist.target (see unlock.nix).
    useSystemdActivation = true;

    # wifi_enroll_psk stays in secrets.yaml as the source of truth; ph-provision copies it
    # to /base because Wi-Fi must work while locked.
    secrets.tailscale_authkey = { };
  };

  panhandler.spine.mainAuthKeyFile = config.sops.secrets.tailscale_authkey.path;
  # Upstream wants this at sysinit, where RequiresMountsFor on the key would stall every
  # locked boot waiting for /dev/mapper/persist. Install secrets on unlock instead.
  systemd.services.sops-install-secrets.wantedBy = lib.mkForce [ "ph-persist.target" ];
}
