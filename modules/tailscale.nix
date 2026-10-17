{ config, ... }:
{
  # Mesh / management plane only in phase-1 — NOT an exit or subnet router yet.
  # ephemeral + tag:panhandler are properties of the key you mint in the admin
  # console; keep its ACL minimal (it's the most-exposed node). Revocable from
  # the phone in seconds.
  services.tailscale = {
    enable = true;
    authKeyFile = config.sops.secrets.tailscale_authkey.path;
    extraUpFlags = [ "--hostname=panhandler" ];
  };
}
