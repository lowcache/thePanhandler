{ pkgs, ... }:
let
  # UI-added profiles: inside LUKS, so they exist only after unlock (hotel SSIDs are a location trail).
  persistProfiles = "/persist/nm/system-connections";
  nmKey = "/var/lib/NetworkManager/secret_key";
  nmKeyBase = "/base/ph/nm-secret_key";
in
{
  # NetworkManager owns wlan0 at runtime (scan/join/forget from panhandler-webd, no rebuilds).
  # The module keeps wpa_supplicant as its D-Bus-controlled backend and sets useDHCP = false.
  networking.networkmanager = {
    enable = true;
    # eth0 = static downlink (gateway.nix), tailscale0 = mesh: never NM's.
    unmanaged = [
      "interface-name:eth0"
      "interface-name:tailscale0"
    ];
    # brcmfmac flaps under power save (4-way handshake timeout, reason=15) → 2 (off).
    wifi.powersave = false;
    # Per-SSID random MAC, never the b8:27:eb Raspberry Pi OUI; stable via the key below.
    wifi.macAddress = "stable-ssid";
    settings = {
      # No hostname over DHCP; DHCPv6 DUID per profile instead of from machine-id.
      connection = {
        "ipv4.dhcp-send-hostname" = false;
        "ipv6.dhcp-send-hostname" = false;
        "ipv6.dhcp-duid" = "stable-uuid";
      };
      keyfile.path = persistProfiles;
      # Captive-portal detection (Connectivity = portal). Resolved via the uplink's own DNS,
      # so it works pre-auth; blocky/DoH is for downstream clients only.
      connectivity = {
        uri = "http://nmcheck.gnome.org/check_network_status.txt";
        interval = 300;
      };
    };
    # Lifeline uplink while locked: the phone hotspot, rendered into /run from /base at boot.
    # SSID and PSK are both env-substituted, so neither lands in the store or the repo.
    ensureProfiles = {
      environmentFiles = [ "/base/ph/wireless.env" ];
      profiles.ph-enroll = {
        connection = {
          id = "ph-enroll";
          type = "wifi";
          # Burns cellular: lowest priority, any UI-added network wins.
          autoconnect-priority = -10;
        };
        wifi = {
          mode = "infrastructure";
          ssid = "$ssid_enroll";
        };
        wifi-security = {
          key-mgmt = "wpa-psk";
          psk = "$psk_enroll";
        };
        ipv4.method = "auto";
      };
    };
  };
  # No modem on this board; the NM module defaults it on.
  networking.modemmanager.enable = false;

  # Regdomain is a kernel setting NM never touches. Unset = world (00) and brcmfmac
  # active scan fails (error -512 / escan_timeout). US = travel region; change abroad.
  boot.extraModprobeConfig = ''options cfg80211 ieee80211_regdom="US"'';

  # Saved profiles live in /persist; tell NM to re-read once it is mounted.
  systemd.services.ph-nm-persist = {
    description = "Load persisted NetworkManager profiles after unlock";
    wantedBy = [ "ph-persist.target" ];
    after = [
      "persist.mount"
      "NetworkManager.service"
    ];
    requires = [ "persist.mount" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      install -d -m700 ${persistProfiles}
      ${pkgs.networkmanager}/bin/nmcli connection reload
    '';
  };

  # stable-ssid MACs derive from NM's secret_key. Keep only that key in /base so a portal's MAC
  # survives reboots; the rest of /var/lib/NetworkManager (seen BSSIDs, leases) stays ephemeral.
  systemd.services.ph-nm-key-load = {
    description = "Restore NetworkManager's MAC-derivation key from /base";
    wantedBy = [ "NetworkManager.service" ];
    before = [ "NetworkManager.service" ];
    unitConfig = {
      RequiresMountsFor = [ "/base" ];
      ConditionPathExists = nmKeyBase;
    };
    serviceConfig.Type = "oneshot";
    script = "install -D -m600 ${nmKeyBase} ${nmKey}";
  };
  # First boot only: adopt the key NM generated, so its format stays NM's business.
  systemd.paths.ph-nm-key-save = {
    wantedBy = [ "multi-user.target" ];
    pathConfig.PathExists = nmKey;
  };
  systemd.services.ph-nm-key-save = {
    description = "Save NetworkManager's MAC-derivation key to /base";
    unitConfig.RequiresMountsFor = [ "/base" ];
    serviceConfig = {
      Type = "oneshot";
      # Stays active, or PathExists re-triggers it in a loop.
      RemainAfterExit = true;
    };
    script = "[ -e ${nmKeyBase} ] || install -m600 ${nmKey} ${nmKeyBase}";
  };

  # Backstop for wifi.powersave, run when brcmfmac creates the netdev (it appears late at boot).
  systemd.services.wlan0-powersave-off = {
    description = "Disable wlan0 Wi-Fi power save (brcmfmac flap workaround)";
    wantedBy = [ "sys-subsystem-net-devices-wlan0.device" ];
    bindsTo = [ "sys-subsystem-net-devices-wlan0.device" ];
    after = [ "sys-subsystem-net-devices-wlan0.device" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.iw}/bin/iw dev wlan0 set power_save off";
    };
  };
}
