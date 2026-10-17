{ config, ... }:
{
  sops = {
    defaultSopsFile = ../secrets/secrets.yaml;

    # Decrypt with the dedicated Panhandler age key, NOT a host-ssh-derived one
    # (the host key doesn't exist until first boot — chicken/egg at enrollment).
    # Placed out-of-band after flashing (phase-1); moves to /persist with LUKS.
    age.sshKeyPaths = [ ];
    age.keyFile = "/var/lib/sops-nix/key.txt";

    secrets = {
      tailscale_authkey = { };
      wifi_enroll_psk = { };
    };

    # wpa_supplicant reads ext:psk_enroll from this rendered file (never the store).
    templates."wireless.env".content = ''
      psk_enroll=${config.sops.placeholder.wifi_enroll_psk}
    '';
  };
}
