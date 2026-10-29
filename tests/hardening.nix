# Runtime hardening on x86_64. vlan 1 plays the hostile uplink (wlan0), vlan 2 the cable.
# The wlan0 identity (MAC, DHCP options) needs the real radio and is checked on the device.
{ pkgs, hardeningModule }:
pkgs.testers.runNixOSTest {
  name = "panhandler-hardening";

  nodes.pi = _: {
    imports = [ hardeningModule ];
    panhandler.wanInterfaces = [ "eth1" ];
    virtualisation.vlans = [
      1
      2
    ];
    networking.nftables.enable = true;
    networking.firewall.interfaces.eth2.allowedUDPPorts = [ 67 ];
    services.tailscale.enable = true;
    services.dnsmasq = {
      enable = true;
      resolveLocalQueries = false;
      settings = {
        port = 0;
        interface = "eth2";
        bind-interfaces = true;
        dhcp-range = [ "192.168.2.100,192.168.2.150,1h" ];
      };
    };
  };

  nodes.hostile = _: {
    virtualisation.vlans = [ 1 ];
  };

  nodes.laptop = _: {
    virtualisation.vlans = [ 2 ];
    environment.systemPackages = [ pkgs.busybox ];
  };

  testScript = ''
    start_all()
    pi.wait_for_unit("multi-user.target")
    pi.wait_for_unit("dnsmasq.service")
    pi.wait_for_unit("tailscaled.service")

    def addr(fam, iface):
        return pi.succeed(f"ip -{fam} -o addr show {iface} scope global | awk '{{print $4}}' | cut -d/ -f1").strip()

    with subtest("sysctls and kernel image"):
        for k in ["net.ipv4.conf.all.send_redirects", "net.ipv4.conf.default.send_redirects",
                  "net.ipv4.conf.all.accept_redirects", "net.ipv4.conf.all.secure_redirects",
                  "net.ipv6.conf.all.accept_redirects", "net.ipv6.conf.default.accept_redirects"]:
            assert pi.succeed(f"sysctl -n {k}").strip() == "0", k
        assert pi.succeed("sysctl -n kernel.kexec_load_disabled").strip() == "1"

    with subtest("no ZFS"):
        pi.fail("systemctl cat zfs-zed.service")
        pi.fail("lsmod | grep -w zfs")

    with subtest("uplink ignores ping, v4 and v6"):
        hostile.wait_for_unit("multi-user.target")
        # Control: the link itself works (pi's own echo out, reply in via conntrack).
        pi.wait_until_succeeds("ping -c1 -W2 192.168.1.1")
        pi.wait_until_succeeds("ip -6 -o addr show eth1 scope global | grep -v tentative | grep -q inet6")
        hostile.fail(f"ping -c2 -W2 {addr(4, 'eth1')}")
        hostile.fail(f"ping -6 -c2 -W2 {addr(6, 'eth1')}")

    with subtest("cable still answers ping, v4 and v6"):
        laptop.wait_for_unit("multi-user.target")
        pi.wait_until_succeeds("ip -6 -o addr show eth2 scope global | grep -v tentative | grep -q inet6")
        laptop.succeed(f"ping -c2 -W2 {addr(4, 'eth2')}")
        laptop.succeed(f"ping -6 -c2 -W2 {addr(6, 'eth2')}")

    with subtest("sandboxed dnsmasq hands out a lease"):
        laptop.succeed("busybox udhcpc -i eth1 -n -q -t 5 -s ${pkgs.coreutils}/bin/true")
        pi.succeed("grep -qE '192\\.168\\.2\\.1[0-9]{2}' /var/lib/dnsmasq/dnsmasq.leases")

    with subtest("exposure scores"):
        def score(unit):
            out = pi.succeed(f"systemd-analyze security --no-pager {unit} | tail -1")
            print(unit, out)
            return float(out.split()[-3])
        assert score("dnsmasq.service") < 5.0
        assert score("tailscaled.service") < 9.6
  '';
}
