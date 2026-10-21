# NM's v2 secret_key is hashed with /etc/machine-id, and a tmpfs root mints a new one every boot,
# so stable-ssid MACs changed per boot. Root here is tmpfs and /base a persistent disk, as on the Pi.
{ pkgs, machineIdModule }:
pkgs.testers.runNixOSTest {
  name = "panhandler-machine-id";

  nodes.pi = _: {
    imports = [ machineIdModule ];
    boot.initrd.systemd.enable = true;
    virtualisation.diskImage = null;
    virtualisation.emptyDiskImages = [
      {
        size = 16;
        driveConfig.deviceExtraOpts.serial = "base";
      }
    ];
    # The VM harness replaces fileSystems wholesale; its own option is the one that mounts.
    virtualisation.fileSystems."/base" = {
      device = "/dev/disk/by-id/virtio-base";
      fsType = "ext4";
      autoFormat = true;
      neededForBoot = true;
    };
  };

  testScript = ''
    pi.wait_for_unit("multi-user.target")
    first = pi.succeed("cat /etc/machine-id").strip()

    with subtest("machine-id lives in /base and is readable by everyone"):
        pi.succeed("test -L /etc/machine-id")
        assert pi.succeed("cat /base/machine-id").strip() == first
        pi.succeed("test $(stat -c %a /base/machine-id) = 444")
        pi.succeed("su nobody -s /bin/sh -c 'cat /etc/machine-id'")

    with subtest("machine-id survives a reboot of the tmpfs root"):
        pi.shutdown()
        pi.start()
        pi.wait_for_unit("multi-user.target")
        assert pi.succeed("cat /etc/machine-id").strip() == first
        # systemd bind-mounts a transient id over /etc/machine-id when it finds none it can use.
        pi.fail("findmnt /etc/machine-id")

    with subtest("first switch adopts the running per-boot id, so MACs do not move"):
        # The Pi before this module: /etc/machine-id a plain file minted at boot, nothing in /base.
        pi.succeed("rm /base/machine-id /etc/machine-id")
        pi.succeed("echo 0123456789abcdef0123456789abcdef > /etc/machine-id")
        pi.succeed("/run/current-system/activate")
        assert pi.succeed("cat /base/machine-id").strip() == "0123456789abcdef0123456789abcdef"
        pi.succeed("test -L /etc/machine-id")
        assert pi.succeed("cat /etc/machine-id").strip() == "0123456789abcdef0123456789abcdef"
  '';
}
