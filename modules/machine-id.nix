# Persistent machine-id on a tmpfs root. NM hashes its v2 secret_key with /etc/machine-id, so a
# per-boot id gave every network a new stable-ssid MAC on each boot (portal login again).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  file = config.panhandler.machineIdFile;
  coreutils = "${pkgs.coreutils}/bin";
  grep = "${pkgs.gnugrep}/bin/grep";
in
{
  options.panhandler.machineIdFile = lib.mkOption {
    type = lib.types.str;
    default = "/base/machine-id";
    description = "World-readable file holding the machine-id; must sit on a filesystem neededForBoot.";
  };

  config = {
    environment.etc."machine-id".source = file;

    # Runs before /etc is linked, in the initrd on a cold boot. A missing id is seeded from the
    # running one, so deploying this keeps today's MACs; a fresh card gets a random id.
    system.activationScripts.ph-machine-id = ''
      if ! ${grep} -qxE '[0-9a-f]{32}' ${file} 2>/dev/null; then
        # Without its filesystem this lands on the tmpfs root: per-boot id, but never a dangling link.
        ${coreutils}/mkdir -p "$(${coreutils}/dirname ${file})"
        if [ ! -L /etc/machine-id ] && ${grep} -qxE '[0-9a-f]{32}' /etc/machine-id 2>/dev/null; then
          ${coreutils}/cp /etc/machine-id ${file}.tmp
        else
          ${coreutils}/tr -d - < /proc/sys/kernel/random/uuid > ${file}.tmp
        fi
        ${coreutils}/chmod 444 ${file}.tmp
        ${coreutils}/mv ${file}.tmp ${file}
      fi
    '';
    system.activationScripts.etc.deps = [ "ph-machine-id" ];
  };
}
