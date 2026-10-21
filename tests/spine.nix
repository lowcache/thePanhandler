# Unlock + tamper logic on x86_64 (fast, native). vlan 1 plays the eth0 cable, vlan 2 the tailnet.
# The SD layout (tmpfs root, /sd binds) is Pi-only and checked on the device.
{ pkgs, unlockModule }:
let
  keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;
  uuid = "0b9f6a52-4a1e-4a39-9a2c-3c4c1f0d7e11";
in
pkgs.testers.runNixOSTest {
  name = "panhandler-spine";
  node.specialArgs.username = "lowcache";

  nodes.pi = _: {
    imports = [ unlockModule ];
    virtualisation.vlans = [
      1
      2
    ];
    virtualisation.emptyDiskImages = [ 64 ];
    boot.initrd.systemd.enable = true;

    users.users.lowcache = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
    };
    security.sudo.wheelNeedsPassword = false;
    services.openssh.enable = true;
    services.tailscale.enable = true;
    environment.systemPackages = [ pkgs.cryptsetup ];

    panhandler.spine = {
      persistUuid = uuid;
      initrdBase = {
        path = "/sysroot/base";
        mount = "sysroot.mount";
      };
      cableInterface = "eth1";
      tailnetInterface = "eth2";
      mainAuthKeyFile = "/nonexistent";
      unlockKeys = [ keys.snakeOilEd25519PublicKey ];
      shortBoot.stableMinutes = 1;
    };
  };

  nodes.laptop = _: {
    virtualisation.vlans = [
      1
      2
    ];
  };

  testScript = ''
    import shlex

    def ph(net, cmd, stdin=None, tty=False):
        ip = {"cable": "192.168.1.2", "tailnet": "192.168.2.2"}[net]
        t = "-tt " if tty else ""
        pre = f"printf %s {shlex.quote(stdin)} | " if stdin is not None else ""
        return f"{pre}ssh {t}-i /root/k -o StrictHostKeyChecking=no lowcache@{ip} {cmd}"

    start_all()
    laptop.succeed("install -m600 ${keys.snakeOilEd25519PrivateKey} /root/k")
    pi.wait_for_unit("sshd.service")

    with subtest("first boot counts one short boot"):
        pi.succeed("test $(cat /base/ph/short-boots) = 1")

    with subtest("provision a three-slot-style LUKS volume"):
        pi.succeed(
            "head -c 64 /dev/urandom > /tmp/k0",
            "cryptsetup luksFormat -q --type luks2 --uuid ${uuid} --pbkdf pbkdf2"
            " --pbkdf-force-iterations 1000 --key-file /tmp/k0 /dev/vdb",
            "head -c 64 /dev/urandom > /tmp/kbw",
            "cryptsetup luksAddKey -q --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file /tmp/k0 /dev/vdb /tmp/kbw",
            "printf hunter2 > /tmp/pp",
            "cryptsetup luksAddKey -q --pbkdf argon2id --pbkdf-memory 65536 --key-file /tmp/k0 /dev/vdb /tmp/pp",
            "cryptsetup open --key-file /tmp/k0 /dev/vdb persist && mkfs.ext4 -q /dev/mapper/persist && cryptsetup close persist",
        )
        k0 = pi.succeed("base64 -w0 /tmp/k0").strip()
        kbw = pi.succeed("base64 -w0 /tmp/kbw").strip()
        pi.succeed("rm /tmp/k0 /tmp/kbw /tmp/pp")

    with subtest("status over the cable"):
        out = laptop.succeed(ph("cable", "status"))
        assert "origin=cable persist=locked" in out, out

    with subtest("unlock key cannot get a shell"):
        laptop.fail(ph("cable", "'id; cat /etc/shadow'"))

    with subtest("garbage key fails and is counted"):
        laptop.fail(ph("tailnet", "key", stdin="Z2FyYmFnZQo="))
        pi.succeed("test $(cat /base/ph/failed-unlocks) = 1")
        pi.fail("mountpoint -q /persist")

    with subtest("quorum key over the tailnet unlocks"):
        rc, out = laptop.execute(ph("tailnet", "key", stdin=k0) + " 2>&1")
        assert rc == 0 and "unlocked" in out, out
        pi.succeed("mountpoint -q /persist", "systemctl is-active ph-persist.target")
        pi.succeed("test $(cat /base/ph/failed-unlocks) = 0")
        pi.wait_until_succeeds("findmnt -no SOURCE /var/lib/tailscale | grep -q mapper/persist")

    with subtest("a boot that lives past the threshold resets the run"):
        pi.wait_until_succeeds("test $(cut -d. -f1 /proc/uptime) -ge 60", timeout=120)
        pi.succeed("systemctl start ph-uptime.service")
        pi.succeed("test $(cat /base/ph/short-boots) = 0")

    with subtest("reboot comes up locked"):
        pi.shutdown()
        pi.start()
        pi.wait_for_unit("sshd.service")
        pi.succeed("systemctl stop ph-uptime.timer")
        pi.fail("mountpoint -q /persist")
        pi.succeed("test $(cat /base/ph/short-boots) = 1")

    with subtest("three short boots trigger lockdown"):
        for _ in range(2):
            pi.shutdown()
            pi.start()
            pi.wait_for_unit("sshd.service")
            pi.succeed("systemctl stop ph-uptime.timer")
        pi.succeed("test $(cat /base/ph/short-boots) = 3", "test -e /base/ph/lockdown", "test -e /base/ph/theft")

    with subtest("lockdown refuses the tailnet, even with the right key"):
        laptop.fail(ph("tailnet", "key", stdin=k0))
        pi.fail("mountpoint -q /persist")

    with subtest("lockdown accepts the passphrase over the cable"):
        out = laptop.succeed(ph("cable", "passphrase", stdin="hunter2\n", tty=True))
        assert "LOCKDOWN" in out and "unlocked" in out, out
        pi.succeed("mountpoint -q /persist")

    with subtest("clear-lockdown only over the cable"):
        laptop.fail(ph("tailnet", "clear-lockdown"))
        laptop.succeed(ph("cable", "clear-lockdown"))
        pi.succeed("test ! -e /base/ph/lockdown", "test $(cat /base/ph/short-boots) = 0")

    with subtest("rekey refused over the tailnet"):
        laptop.fail(ph("tailnet", "rekey", stdin=f"{kbw}\n{k0}\n"))

    with subtest("rekey over the cable swaps only the quorum slot"):
        k1 = pi.succeed("head -c 64 /dev/urandom | base64 -w0").strip()
        out = laptop.succeed(ph("cable", "rekey", stdin=f"{kbw}\n{k1}\n"))
        assert "old quorum slot 0 removed" in out, out
        def opens(b64):
            return pi.execute(f"echo {b64} | base64 -d | cryptsetup open --test-passphrase --key-file=- /dev/vdb")[0] == 0
        assert opens(k1) and opens(kbw) and not opens(k0)
        pi.succeed("printf hunter2 | cryptsetup open --test-passphrase --key-file=- /dev/vdb")

    with subtest("check-ins queue while the phone is unreachable"):
        pi.succeed("ls /base/ph/pending/*.json")
  '';
}
