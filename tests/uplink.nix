{
  pkgs,
  probeModule,
  clockModule,
}:
let
  # A test CA and one cert for both clock hosts, valid from 2020: the test sets the Pi clock back.
  certs = pkgs.runCommand "uplink-test-certs" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out && cd $out
    openssl req -x509 -newkey rsa:2048 -nodes -not_before 20200101000000Z -days 7300 -subj /CN=test-ca -keyout ca.key -out ca.crt
    openssl req -newkey rsa:2048 -nodes -subj /CN=clock-a.test -keyout srv.key -out srv.csr
    printf 'subjectAltName=DNS:clock-a.test,DNS:clock-b.test\n' > ext
    openssl x509 -req -in srv.csr -CA ca.crt -CAkey ca.key -CAcreateserial -not_before 20200101000000Z -days 7300 -extfile ext -out srv.crt
  '';
  # Every A query → the hostile node, like a portal's DNS.
  dns = pkgs.writeText "dns.py" ''
    import socket, struct
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("0.0.0.0", 53))
    while True:
        q, peer = s.recvfrom(512)
        end = 12
        while q[end]:
            end += q[end] + 1
        end += 5
        a = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 30, 4) + bytes([192, 0, 2, 2])
        s.sendto(q[:2] + struct.pack("!5H", 0x8180, 1, 1, 0, 0) + q[12:end] + a, peer)
  '';
  https = pkgs.writeText "https.py" ''
    import http.server, ssl
    srv = http.server.HTTPServer(("0.0.0.0", 443), http.server.SimpleHTTPRequestHandler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain("${certs}/srv.crt", "${certs}/srv.key")
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    srv.serve_forever()
  '';
  # The phone listener's /uplink, reduced to "append the body".
  receiver = pkgs.writeText "receiver.py" ''
    import http.server
    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            with open("/tmp/notices", "ab") as f:
                f.write(body + b"\n")
            self.send_response(200); self.end_headers()
    http.server.HTTPServer(("0.0.0.0", 8463), H).serve_forever()
  '';
  page = body: pkgs.writeText "page.html" body;
in
pkgs.testers.runNixOSTest {
  name = "panhandler-uplink";
  nodes.pi = { lib, ... }: {
    imports = [
      probeModule
      clockModule
    ];
    virtualisation.vlans = [ 1 ];
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
      {
        address = "192.0.2.1";
        prefixLength = 24;
      }
    ];
    networking.defaultGateway = {
      address = "192.0.2.2";
      interface = "eth1";
    };
    panhandler.wanInterfaces = [ "eth1" ];
    panhandler.probe = {
      targets = [
        {
          url = "http://a.test/";
          marker = "OPEN-A";
        }
        {
          url = "http://b.test/";
          marker = "OPEN-B";
        }
      ];
      noticeUrl = "http://192.0.2.2:8463/uplink";
    };
    panhandler.clock.hosts = [
      "clock-a.test"
      "clock-b.test"
    ];
    security.pki.certificateFiles = [ "${certs}/ca.crt" ];
    # Unsynced, like a hotel that blocks NTP.
    services.timesyncd.enable = lib.mkForce false;
    systemd.tmpfiles.rules = [ "d /base/ph 0700 root root -" ];
    # No NetworkManager here: the uplink's DHCP DNS is the hostile node.
    systemd.services.ph-uplink-probe.path = lib.mkBefore [
      (pkgs.writeShellScriptBin "nmcli" "echo 192.0.2.2")
    ];
    systemd.services.ph-clock-https.path = lib.mkBefore [
      (pkgs.writeShellScriptBin "nmcli" "echo 192.0.2.2")
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
    networking.firewall.allowedTCPPorts = [
      80
      443
      8463
    ];
    networking.firewall.allowedUDPPorts = [ 53 ];
    environment.systemPackages = [ pkgs.python3 ];
  };
  testScript = ''
    import json

    def probe():
        pi.succeed("systemctl start ph-uplink-probe.service")
        return json.loads(pi.succeed("cat /run/ph-uplink/state.json"))

    start_all()
    pi.wait_for_unit("multi-user.target")
    hostile.wait_for_unit("multi-user.target")
    hostile.succeed("systemd-run --unit=dns -- python3 ${dns}")
    hostile.succeed("mkdir -p /srv/web", "cp ${page ''<html><head><meta http-equiv="refresh" content="0; URL=https://portal.test/login?x=1&amp;y=2"></head></html>''} /srv/web/index.html")
    hostile.succeed("systemd-run --unit=web -- python3 -m http.server 80 --directory /srv/web")
    hostile.wait_for_open_port(80)

    with subtest("portal: redirect captured despite no allowlisted check; notice waits for the phone"):
        st = probe()
        assert st["verdict"] == "portal", st
        assert st["portalUrl"] == "https://portal.test/login?x=1&y=2", st
        pi.succeed("grep -q 'unknown -> portal' /run/ph-uplink/history", "ls /run/ph-uplink/outbox/*.json")

    with subtest("open: marker wins; queued notices delivered once the phone answers"):
        hostile.succeed("systemd-run --unit=receiver -- python3 ${receiver}")
        hostile.wait_for_open_port(8463)
        hostile.succeed("echo 'hello OPEN-A' > /srv/web/index.html")
        assert probe()["verdict"] == "open"
        pi.succeed("grep -q 'portal -> open' /run/ph-uplink/history", "! ls /run/ph-uplink/outbox/*.json")
        got = [json.loads(l)["verdict"] for l in hostile.succeed("cat /tmp/notices").split()]
        assert got == ["portal", "open"], got

    with subtest("a hostile redirect target is not handed to the UI"):
        hostile.succeed("cp ${page ''<meta http-equiv="refresh" content="0; url=javascript:alert(1)">''} /srv/web/index.html")
        st = probe()
        assert st["verdict"] == "portal" and st["portalUrl"] == "", st

    with subtest("dead: nothing answers; a portal is held through one silent run"):
        hostile.succeed("systemctl stop web.service")
        st = probe()
        assert st["verdict"] == "portal" and st["held"], st
        assert probe()["verdict"] == "dead"
        pi.succeed("test $(grep -c 'portal -> dead' /run/ph-uplink/history) = 1")

    hostile.succeed("cp ${page "<html>clock</html>"} /srv/web/index.html")
    hostile.succeed("systemd-run --unit=https --working-directory=/srv/web -- python3 ${https}")
    hostile.wait_for_open_port(443)

    def clock():
        rc, _ = pi.execute("systemctl start ph-clock-https.service")
        if rc != 0:
            print(pi.succeed("journalctl -u ph-clock-https -o cat --no-pager"))
        assert rc == 0

    def skew():
        return int(pi.succeed("date +%s")) - int(hostile.succeed("date +%s"))

    with subtest("clock steps forward from two agreeing HTTPS dates"):
        pi.succeed("date -s @$(( $(date +%s) - 600 ))")
        assert skew() < -500
        clock()
        assert abs(skew()) < 30, skew()
        pi.succeed("test -e /run/ph-clock/https", "test -e /base/ph/clock", "! test -e /run/ph-clock/stepped")

    with subtest("clock never steps backward"):
        pi.succeed("date -s @$(( $(date +%s) + 600 ))")
        clock()
        assert skew() > 500, skew()

    with subtest("no agreeing HTTPS dates: no step"):
        pi.succeed("date -s @$(( $(date +%s) - 1200 ))")
        hostile.succeed("systemctl stop dns.service")
        clock()
        assert skew() < -500, skew()
  '';
}
