{ pkgs, gatewayModule }:
pkgs.testers.runNixOSTest {
  name = "panhandler-gateway";
  nodes.pi = { lib, ... }: {
    imports = [ gatewayModule ];
    # vlan 1 = Wi-Fi uplink, 2 = cable, 3 = USB-tether uplink, 4 = a non-uplink (tailscale0's role).
    virtualisation.vlans = [
      1
      2
      3
      4
    ];
    networking.interfaces.eth0.ipv4.addresses = lib.mkForce [ ];
    networking.interfaces.eth3.ipv4.addresses = lib.mkForce [
      {
        address = "198.51.100.1";
        prefixLength = 24;
      }
    ];
    networking.interfaces.eth4.ipv4.addresses = lib.mkForce [
      {
        address = "203.0.113.1";
        prefixLength = 24;
      }
    ];
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
    panhandler.lanInterface = "eth2";
    # gateway.nix kept eth0 static when it was the hardcoded LAN; keep dhcpcd off port 68.
    networking.interfaces.eth0.useDHCP = false;
    panhandler.wanInterfaces = [
      "eth1"
      "eth3"
    ];
    boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;
    services.blocky.enable = lib.mkForce false;
    services.dnsmasq.enable = lib.mkForce false;
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
    networking.firewall.allowedTCPPorts = [ 8000 ];
    environment.systemPackages = [
      pkgs.curl
      pkgs.python3
    ];
  };
  nodes.tether = { lib, ... }: {
    virtualisation.vlans = [ 3 ];
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
      {
        address = "198.51.100.2";
        prefixLength = 24;
      }
    ];
    networking.firewall.allowedTCPPorts = [ 8000 ];
    environment.systemPackages = [
      pkgs.curl
      pkgs.python3
    ];
  };
  nodes.tailnet = { lib, ... }: {
    virtualisation.vlans = [ 4 ];
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
      {
        address = "203.0.113.2";
        prefixLength = 24;
      }
    ];
    networking.firewall.allowedTCPPorts = [ 8000 ];
    environment.systemPackages = [ pkgs.python3 ];
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
    networking.firewall.allowedTCPPorts = [ 8000 ];
    environment.systemPackages = [
      pkgs.curl
      pkgs.python3
    ];
  };
  testScript = ''
    start_all()
    for machine in [pi, hostile, tether, tailnet, client]:
        machine.wait_for_unit("multi-user.target")
    hostile.succeed("ip route add 10.73.0.0/24 via 192.0.2.1")
    hostile.succeed("ip -6 route add fd73:2::/64 via fd73:1::1")
    client.succeed("ip route add 192.0.2.0/24 via 10.73.0.1")
    client.succeed("ip -6 route add fd73:1::/64 via fd73:2::1")
    client.succeed("ip route add 198.51.100.0/24 via 10.73.0.1")
    client.succeed("ip route add 203.0.113.0/24 via 10.73.0.1")
    tether.succeed("ip route add 10.73.0.0/24 via 198.51.100.1")
    tailnet.succeed("ip route add 10.73.0.0/24 via 203.0.113.1")
    for machine in [hostile, tether, tailnet, client]:
        machine.succeed("systemd-run --unit=web -- python3 -m http.server 8000 --bind ::")
        machine.wait_for_open_port(8000)
    with subtest("outbound TCP and replies work"):
        client.succeed("curl -fsS --max-time 5 http://192.0.2.2:8000/ >/dev/null")
    with subtest("every uplink masquerades the cable"):
        client.succeed("curl -fsS --max-time 5 http://198.51.100.2:8000/ >/dev/null")
        hostile.wait_until_succeeds("journalctl -u web | grep -q '192.0.2.1 '")
        tether.wait_until_succeeds("journalctl -u web | grep -q '198.51.100.1 '")
    with subtest("the cable reaches no non-uplink interface"):
        client.fail("curl -fsS --max-time 3 http://203.0.113.2:8000/")
    with subtest("unsolicited upstream TCP cannot reach downstream"):
        tether.fail("curl -fsS --max-time 3 http://10.73.0.50:8000/")
        hostile.fail("curl -fsS --max-time 3 http://10.73.0.50:8000/")
        hostile.fail("curl -gfsS --max-time 3 'http://[fd73:2::50]:8000/'")
    with subtest("clients still reach each service on their own interface"):
        client.succeed("curl -fsS --max-time 5 http://10.73.0.50:8000/ >/dev/null")
        hostile.succeed("curl -fsS --max-time 5 http://192.0.2.2:8000/ >/dev/null")
  '';
}
