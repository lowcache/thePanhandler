# The one login account. Options rather than a specialArg, so the modules work in any flake.
{ lib, ... }:
{
  options.panhandler = {
    adminUser = lib.mkOption {
      type = lib.types.str;
      description = "Login account: SSH keys only, passwordless wheel (the box holds nothing).";
    };
    adminKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "SSH public keys for adminUser.";
    };
  };
}
