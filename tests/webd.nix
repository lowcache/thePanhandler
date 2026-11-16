# The web UI service as deployed (sandbox, journal group, per-device listeners), not just the Go
# handlers. vlan 1 plays the cable, vlan 2 the tailnet.
{ pkgs, webdModule }:
let
  pi = {
    cable = "10.73.0.1";
    tailnet = "100.81.123.86";
  };
  volnix = "100.66.249.117";
  stranger = "100.64.0.99";
  client =
    vlan: address: prefixLength:
    { lib, ... }:
    {
      virtualisation.vlans = [ vlan ];
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [ { inherit address prefixLength; } ];
      environment.systemPackages = [ pkgs.curl ];
    };
in
pkgs.testers.runNixOSTest {
  name = "panhandler-webd";
  nodes.pi =
    { lib, ... }:
    {
      imports = [ webdModule ];
      virtualisation.vlans = [
        1
        2
      ];
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
        {
          address = pi.cable;
          prefixLength = 24;
        }
      ];
      networking.interfaces.eth2.ipv4.addresses = lib.mkForce [
        {
          address = pi.tailnet;
          prefixLength = 10;
        }
      ];
      panhandler.lanInterface = "eth1";
      services.tailscale.interfaceName = "eth2";
      panhandler.managementPeers.volnix = volnix;
      panhandler.webd.bubbleReporters = [ volnix ];
      # webd requires NetworkManager; keep it off the test links.
      networking.networkmanager = {
        enable = true;
        unmanaged = [ "*" ];
      };
    };
  nodes.cable = client 1 "10.73.0.133" 24;
  nodes.volnix = client 2 volnix 10;
  nodes.stranger = client 2 stranger 10;

  testScript = ''
    import json

    def code(node, args):
        # Streams never end on their own: -m cuts them, so read the status, not curl's exit.
        return node.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' -m 3 {args} || true").strip()

    report = json.dumps({"devices": [
        {"mac": "96:94:0b:00:00:01", "ip": "10.74.0.154", "hostname": "VolatileDevice", "leaseExpires": 1794796079, "online": True},
    ]})
    post = f"-H 'Content-Type: application/json' --data '{report}'"

    start_all()
    pi.wait_for_unit("panhandler-webd.service")
    cable.wait_until_succeeds("curl -sf -m 3 http://${pi.cable}:8080/ >/dev/null")
    volnix.wait_until_succeeds("curl -sf -m 3 http://${pi.tailnet}:8080/ >/dev/null")

    with subtest("logs stream from the journal over the cable (sandbox can read it)"):
        out = cable.succeed("curl -sN -m 4 http://${pi.cable}:8080/api/logs || true")
        assert "event: log" in out and '"unit":"panhandler-webd"' in out, out

    with subtest("logs: management peer yes, other tailnet peers no"):
        assert code(volnix, "http://${pi.tailnet}:8080/api/logs") == "200"
        assert code(stranger, "http://${pi.tailnet}:8080/api/logs") == "403"

    with subtest("bubble reports only from volnix over the tailnet"):
        assert code(cable, f"{post} http://${pi.cable}:8080/api/bubble") == "403"
        assert code(stranger, f"{post} http://${pi.tailnet}:8080/api/bubble") == "403"
        assert code(volnix, f"{post} http://${pi.tailnet}:8080/api/bubble") == "204"

    with subtest("device list: readable on the cable, not by a stranger"):
        devs = json.loads(cable.succeed("curl -sf -m 3 http://${pi.cable}:8080/api/devices"))
        assert devs["reportedAt"] and [d["hostname"] for d in devs["devices"]] == ["VolatileDevice"], devs
        assert devs["devices"][0]["vendor"] == "randomized", devs
        assert code(stranger, "http://${pi.tailnet}:8080/api/devices") == "403"
  '';
}
