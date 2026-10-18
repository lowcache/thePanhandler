_: {
  # Mesh / management plane only — NOT an exit or subnet router yet. Login and the
  # locked/main identity swap are handled by ph-tailscale-{state,up} in unlock.nix.
  services.tailscale.enable = true;
}
