{
  pkgs,
  gatewayModule,
  egressModule ? null,
  portalModule ? null,
}:
let
  udpServer = pkgs.writeText "udp-echo.py" ''
    import socket, sys
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.bind(("0.0.0.0", int(sys.argv[1])))
        while True:
            data, peer = s.recvfrom(1024)
            s.sendto(data, peer)
  '';
  udpProbe = pkgs.writeText "udp-probe.py" ''
    import socket, sys
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.settimeout(2)
        if len(sys.argv) > 3 and int(sys.argv[3], 0):
            s.setsockopt(socket.SOL_SOCKET, socket.SO_MARK, int(sys.argv[3], 0))
        if len(sys.argv) > 4:
            s.bind(("0.0.0.0", int(sys.argv[4])))
        s.sendto(b"probe", (sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 9000))
        assert s.recv(1024) == b"probe"
  '';
  echoServer = pkgs.writeText "portal-echo.py" ''
    import socket, threading
    def handle(c):
        with c:
            while data := c.recv(1024):
                c.sendall(data)
    with socket.create_server(("0.0.0.0", 443)) as server:
        while True:
            c, _ = server.accept()
            threading.Thread(target=handle, args=(c,), daemon=True).start()
  '';
  heldClient = pkgs.writeText "portal-held-client.py" ''
    import pathlib, socket, time
    with socket.create_connection(("192.0.2.2", 443), timeout=3) as s:
        s.sendall(b"first")
        assert s.recv(1024) == b"first"
        pathlib.Path("/run/portal-ready").touch()
        while not pathlib.Path("/run/portal-next").exists():
            time.sleep(0.05)
        s.settimeout(2)
        s.sendall(b"second")
        try:
            data = s.recv(1024)
            pathlib.Path("/run/portal-leaked" if data else "/run/portal-blocked").touch()
        except (TimeoutError, ConnectionError):
            pathlib.Path("/run/portal-blocked").touch()
  '';
  dnsServer = pkgs.writeText "test-dns.py" ''
    import socket, struct, sys
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.bind((sys.argv[1], int(sys.argv[2])))
        while True:
            data, peer = s.recvfrom(4096)
            header = data[:2] + struct.pack("!5H", 0x8180, 1, 1, 0, 0)
            answer = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 30, 4) + bytes([198,18,0,int(sys.argv[3]) if len(sys.argv) > 3 else 1])
            end = 12
            while data[end]:
                end += data[end] + 1
            end += 5
            s.sendto(header + data[12:end] + answer, peer)
  '';
in
pkgs.testers.runNixOSTest {
  name = "panhandler-egress";
  nodes.pi = { config, lib, ... }: {
    imports = [
      gatewayModule
    ]
    ++ lib.optional (egressModule != null) egressModule
    ++ lib.optional (portalModule != null) portalModule;
    config = lib.mkMerge [
      {
        users.users.egress-clock = {
          isSystemUser = true;
          uid = config.ids.uids.systemd-timesync;
          group = "nogroup";
        };
        virtualisation.vlans = [
          1
          2
        ];
        networking.interfaces.eth0.ipv4.addresses = lib.mkForce [ ];
        networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
          {
            address = "192.0.2.1";
            prefixLength = 24;
          }
        ];
        networking.interfaces.eth2.ipv4.addresses = lib.mkForce [
          {
            address = "10.73.0.1";
            prefixLength = 24;
          }
        ];
        networking.interfaces.eth1.ipv6.addresses = lib.mkForce [
          {
            address = "fd73:1::1";
            prefixLength = 64;
          }
        ];
        networking.interfaces.eth2.ipv6.addresses = lib.mkForce [
          {
            address = "fd73:2::1";
            prefixLength = 64;
          }
        ];
        networking.nat.internalInterfaces = lib.mkForce [ "eth2" ];
        networking.nat.externalInterface = lib.mkForce "eth1";
        networking.firewall.interfaces.eth2 = {
          allowedTCPPorts = [ 53 ];
          allowedUDPPorts = [ 53 ];
        };
        boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;
        services.blocky.enable = lib.mkForce false;
        services.dnsmasq.enable = lib.mkForce false;
        environment.systemPackages = [
          pkgs.curl
          pkgs.python3
          pkgs.bind
          pkgs.conntrack-tools
          pkgs.tcpdump
        ];
        systemd.mounts = [
          {
            what = "tmpfs";
            where = "/persist";
            type = "tmpfs";
            wantedBy = [ "multi-user.target" ];
          }
        ];
        systemd.targets.ph-persist = {
          wantedBy = [ "multi-user.target" ];
          requires = [ "persist.mount" ];
          after = [ "persist.mount" ];
        };
      }
      (lib.optionalAttrs (egressModule != null) {
        panhandler.egress = {
          lanInterface = "eth2";
          wanInterface = "eth1";
        };
        services.tor.settings.DisableNetwork = true;
      })
      (lib.optionalAttrs (portalModule != null) {
        systemd.services.ph-portal-bypass.path = lib.mkForce (
          with pkgs;
          [
            (writeShellScriptBin "nmcli" "echo 192.0.2.2")
            nftables
            conntrack-tools
            gnused
            coreutils
          ]
        );
      })
    ];
  };
  nodes.hostile = { lib, ... }: {
    virtualisation.vlans = [ 1 ];
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
      {
        address = "192.0.2.2";
        prefixLength = 24;
      }
    ];
    networking.interfaces.eth1.ipv6.addresses = lib.mkForce [
      {
        address = "fd73:1::2";
        prefixLength = 64;
      }
    ];
    networking.firewall.allowedTCPPorts = [
      80
      443
      8000
    ];
    networking.firewall.allowedUDPPorts = [
      53
      67
      123
      443
      9000
    ];
    environment.systemPackages = [
      pkgs.curl
      pkgs.python3
    ];
  };
  nodes.client = { lib, ... }: {
    virtualisation.vlans = [ 2 ];
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
      {
        address = "10.73.0.50";
        prefixLength = 24;
      }
    ];
    networking.interfaces.eth1.ipv6.addresses = lib.mkForce [
      {
        address = "fd73:2::50";
        prefixLength = 64;
      }
    ];
    environment.systemPackages = [
      pkgs.curl
      pkgs.bind
      pkgs.python3
    ];
  };
  testScript = ''
    # Without allow_reboot QEMU runs -no-reboot and exits on pi.reboot().
    pi.start(allow_reboot=True)
    start_all()
    for machine in [pi, hostile, client]:
        machine.wait_for_unit("multi-user.target")
    hostile.succeed("ip route add 10.73.0.0/24 via 192.0.2.1", "ip -6 route add fd73:2::/64 via fd73:1::1")
    client.succeed("ip route add 192.0.2.0/24 via 10.73.0.1", "ip -6 route add fd73:1::/64 via fd73:2::1")
    hostile.succeed("systemd-run --unit=clearnet -- python3 -m http.server 8000 --bind :: --directory ${pkgs.writeTextDir "index.html" "CLEARNET"}")
    hostile.wait_for_open_port(8000)
    for port in [67, 123, 443, 9000]:
        hostile.succeed(f"systemd-run --unit=udp-{port} -- python3 ${udpServer} {port}")
    hostile.wait_until_succeeds("python3 ${udpProbe} 127.0.0.1")
    hostile.succeed("systemd-run --unit=uplink-dns -- python3 ${dnsServer} 0.0.0.0 53 2")
    hostile.succeed("systemd-run --unit=portal -- python3 -m http.server 80 --bind :: --directory ${pkgs.writeTextDir "index.html" "PORTAL"}")
    hostile.wait_for_open_port(80)
    with subtest("fresh mode is direct and usable while locked"):
        pi.succeed("systemctl stop ph-persist.target tor.service", "umount /persist", "grep -qx direct /run/ph-egress/mode")
        client.succeed("curl -fsS --max-time 3 http://192.0.2.2:8000/ | grep -qx CLEARNET")
        client.succeed("python3 ${udpProbe} 192.0.2.2")
        client.succeed("python3 ${udpProbe} 192.0.2.2 443")
        pi.succeed("install -d -m700 /run/panhandler-webd", "echo 10.73.0.50 > /run/panhandler-webd/portal-client", "systemctl start ph-portal-bypass.service")
        assert client.succeed("dig +short +time=1 +tries=1 @10.73.0.1 example.com").strip() == "198.18.0.2"
        pi.succeed("systemctl stop ph-portal-bypass.service")
    with subtest("switch to Tor cuts existing direct flows"):
        hostile.succeed("systemd-run --unit=portal-stream-server -- python3 ${echoServer}")
        hostile.wait_for_open_port(443)
        client.succeed("systemd-run --unit=direct-stream-client -- python3 ${heldClient}")
        client.wait_until_succeeds("test -e /run/portal-ready")
        pi.succeed("conntrack -L -p tcp --dport 443 | grep -q ESTABLISHED", "ph-egress tor", "ph-egress status | grep -qx tor")
        pi.succeed("test $(stat -c %a /base/ph) = 700")
        client.succeed("touch /run/portal-next")
        client.wait_until_succeeds("test -e /run/portal-blocked")
        client.fail("test -e /run/portal-leaked")
        client.succeed("rm /run/portal-ready /run/portal-next /run/portal-blocked")
    with subtest("no direct fallback before Tor is usable"):
        client.fail("curl -fsS --max-time 3 http://192.0.2.2:8000/")
    pi.succeed("systemctl start persist.mount ph-persist.target")
    pi.wait_for_unit("tor.service")
    with subtest("real Tor configuration starts with persistent state"):
        pi.succeed("test -d /persist/tor", "systemctl stop tor.service")
    # A deterministic local proxy tests packet redirection without public Tor circuits.
    pi.succeed("systemd-run --unit=test-proxy --uid=tor -- python3 -m http.server 9040 --bind 0.0.0.0 --directory ${pkgs.writeTextDir "index.html" "PROXY"}")
    pi.wait_for_open_port(9040)
    with subtest("TCP reaches only the selected proxy"):
        out = client.succeed("curl -fsS --max-time 3 http://192.0.2.2:8000/")
        assert out.strip() == "PROXY", out
        pi.succeed("systemd-run --unit=trace -- tcpdump -U -ni any 'port 9040 or port 8000' -w /tmp/egress.pcap")
        rc, out = pi.execute("systemd-run --wait --pipe --uid=nobody -- curl -fsS --max-time 3 http://192.0.2.2:8000/")
        pi.succeed("systemctl stop trace.service")
        if rc != 0:
            print(pi.succeed("tcpdump -nnr /tmp/egress.pcap"))
            print(pi.succeed("nft list table inet ph-egress"))
        assert rc == 0, out
        assert "PROXY" in out and "CLEARNET" not in out, out
    with subtest("client DNS is forced local and host DNS uses the Tor DNS port"):
        pi.succeed("systemd-run --unit=client-dns -- python3 ${dnsServer} 10.73.0.1 53")
        pi.succeed("systemd-run --unit=tor-dns -- python3 ${dnsServer} 127.0.0.1 9053")
        client.wait_until_succeeds("dig +short +time=1 +tries=1 @192.0.2.2 example.com | grep -qx 198.18.0.1", timeout=15)
        pi.succeed("systemd-run --wait --pipe --uid=nobody -- dig +short +time=1 +tries=1 @192.0.2.2 example.com | grep -qx 198.18.0.1")
    with subtest("IPv6 and UDP have no clear fallback"):
        client.fail("curl -gfsS --max-time 3 'http://[fd73:1::2]:8000/'")
        client.fail("python3 ${udpProbe} 192.0.2.2")
        client.fail("python3 ${udpProbe} 192.0.2.2 443")
        pi.fail("systemd-run --wait --pipe --uid=nobody -- python3 ${udpProbe} 192.0.2.2")
    with subtest("Tor-mode control-plane exceptions leave the uplink"):
        pi.succeed("python3 ${udpProbe} 192.0.2.2 9000 0x80000")
        pi.fail("python3 ${udpProbe} 192.0.2.2 9000 0x40000")
        pi.succeed("systemd-run --wait --pipe --uid=egress-clock -- python3 ${udpProbe} 192.0.2.2 123")
        pi.fail("systemd-run --wait --pipe --uid=nobody -- python3 ${udpProbe} 192.0.2.2 123")
        pi.succeed("curl -fsS --max-time 3 http://192.0.2.2/ | grep -qx PORTAL")
        pi.succeed("dig +short +time=1 +tries=1 @192.0.2.2 example.com | grep -qx 198.18.0.2")
        pi.succeed("systemd-run --wait --pipe --uid=egress-clock -- dig +short +time=1 +tries=1 @192.0.2.2 example.com | grep -qx 198.18.0.2")
        pi.succeed("python3 ${udpProbe} 192.0.2.2 67 0 68")
        pi.fail("python3 ${udpProbe} 192.0.2.2 67")
    with subtest("proxy loss stays closed"):
        pi.succeed("systemctl stop test-proxy.service")
        client.fail("curl -fsS --max-time 3 http://192.0.2.2:8000/")
    with subtest("portal exception is per client and only web ports"):
        pi.succeed("install -d -m700 /run/panhandler-webd", "echo 10.73.0.50 > /run/panhandler-webd/portal-client", "systemctl start ph-portal-bypass.service")
        assert client.succeed("curl -fsS --max-time 3 http://192.0.2.2/").strip() == "PORTAL"
        # Production limits; the expiry subtest shortens the element to observe the clamp.
        pi.succeed(
            "systemctl show -p RuntimeMaxUSec ph-portal-bypass | grep -qx RuntimeMaxUSec=10min",
            "nft list set inet ph-egress portal_clients | grep -q 'timeout 10m'",
            "nft list set inet ph-egress portal_dns | grep -q 'timeout 10m'",
        )
        client.fail("curl -fsS --max-time 3 http://192.0.2.2:8000/")
        client.succeed("ip addr add 10.73.0.51/24 dev eth1")
        client.fail("curl --interface 10.73.0.51 -fsS --max-time 3 http://192.0.2.2/")
    with subtest("portal expiry clamps traffic even with conntrack state"):
        client.succeed("systemd-run --unit=portal-stream-client -- python3 ${heldClient}")
        client.wait_until_succeeds("test -e /run/portal-ready")
        pi.succeed("conntrack -L -p tcp --dport 443 | grep -q ESTABLISHED")
        pi.succeed("nft 'delete element inet ph-egress portal_clients { 10.73.0.50 }; add element inet ph-egress portal_clients { 10.73.0.50 timeout 1s }'")
        pi.wait_until_succeeds("! nft get element inet ph-egress portal_clients '{ 10.73.0.50 }'")
        client.succeed("touch /run/portal-next")
        client.wait_until_succeeds("test -e /run/portal-blocked")
        client.fail("test -e /run/portal-leaked")
        client.fail("curl -fsS --max-time 3 http://192.0.2.2/")
        pi.succeed("systemctl stop ph-portal-bypass.service")
        pi.fail("nft list table ip ph-portal-bypass")
    with subtest("selected Tor survives reload and reboot without fallback"):
        pi.succeed("systemctl reload nftables.service", "grep -qx tor /run/ph-egress/mode")
        client.fail("curl -fsS --max-time 3 http://192.0.2.2:8000/")
        pi.reboot()
        pi.wait_for_unit("multi-user.target")
        pi.succeed("grep -qx tor /run/ph-egress/mode")
        client.fail("curl -fsS --max-time 3 http://192.0.2.2:8000/")
    with subtest("explicit return to Direct restores streaming and persists"):
        pi.succeed("ph-egress direct", "ph-egress status | grep -qx direct")
        assert client.succeed("curl -fsS --max-time 3 http://192.0.2.2:8000/").strip() == "CLEARNET"
        client.succeed("python3 ${udpProbe} 192.0.2.2 443")
        pi.reboot()
        pi.wait_for_unit("multi-user.target")
        pi.succeed("grep -qx direct /run/ph-egress/mode")
        assert client.succeed("curl -fsS --max-time 3 http://192.0.2.2:8000/").strip() == "CLEARNET"
  '';
}
