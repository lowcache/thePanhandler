# The author's Panhandler: who logs in, which tailnet, which phone. Everything generic is
# in ../modules (nixosModules.hobosec).
{ config, lib, ... }:
let
  inherit (config.panhandler.managementPeers) phone;
in
{
  networking.hostName = "panhandler";
  # First deployed on 26.11. Never bump.
  system.stateVersion = "26.11";

  panhandler.adminUser = "lowcache";
  panhandler.adminKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBJZUOXEhGUUPfHPoXg6imru3+6lPmnVQS437J38QVCW lowcache"
  ];

  panhandler.managementPeers = {
    volnix = "100.66.249.117";
    volnix-v6 = "fd7a:115c:a1e0::9b3b:f976";
    phone = "100.65.161.34";
    phone-v6 = "fd7a:115c:a1e0::531:a123";
  };
  panhandler.webd.allowedHostnames = [
    "panhandler.taila5270e.ts.net"
    "panhandler-locked.taila5270e.ts.net"
  ];
  # volnix runs the travel bubble and reports its clients.
  panhandler.webd.bubbleReporters = with config.panhandler.managementPeers; [
    volnix
    volnix-v6
  ];

  # Verdict changes (open / portal / dead) to the phone listener; no SSID in the notice.
  panhandler.probe.noticeUrl = "http://${phone}:8463/uplink";
  panhandler.spine = {
    # Phone boot-log listener (phone/listener.py) on the phone's tailnet address.
    checkinUrl = "http://${phone}:8463/checkin";
    # Fixed so ph-provision can luksFormat --uuid it; not secret.
    persistUuid = "f1dd299a-8515-44ed-9377-8ac71096433b";
    unlockKeys = lib.optionals (builtins.pathExists ../keys/unlock-keys.pub) (
      lib.filter (l: l != "") (lib.splitString "\n" (builtins.readFile ../keys/unlock-keys.pub))
    );
  };

  sops.defaultSopsFile = ../secrets/secrets.yaml;
}
