# One source of truth for the trusted downlink and the hostile uplinks.
{ lib, ... }:
{
  options.panhandler = {
    lanInterface = lib.mkOption {
      type = lib.types.str;
      default = "eth0";
      description = "Trusted downlink (the cable to the laptop).";
    };
    wanInterfaces = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.str;
      # wlan0 = hotel/hotspot radio; usb0 = phone USB tether. NM's route metric picks the live one.
      default = [
        "wlan0"
        "usb0"
      ];
      description = "Hostile uplinks: NAT, Tor clamp, portal and echo-drop rules cover all of them.";
    };
    clockUid = lib.mkOption {
      type = lib.types.int;
      # Static: the nftables ruleset names it numerically and is checked at build time.
      default = 920;
      description = "uid of ph-clock, the one non-root user allowed direct DNS + HTTPS in Tor mode (clock bootstrap).";
    };
  };
}
