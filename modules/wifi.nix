{ pkgs, ... }:
let
  # First-enrollment network. CHANGE THIS to your non-captive enroll SSID
  # (home / phone hotspot). NOTE: this attr name is the SSID and lands in the
  # world-readable store + the public repo — use a non-identifying one, or we
  # move it into sops (rendered wpa_supplicant conf) in a later pass.
  enrollSSID = "VolatileDevice";
in
{
  # On-board brcmfmac radio (wlan0). wpa_supplicant, not NetworkManager: headless.
  networking.wireless = {
    enable = true;
    # Outside LUKS: Wi-Fi must work while locked. Written by ph-provision (psk_enroll=...).
    secretsFile = "/base/ph/wireless.env";
    networks.${enrollSSID}.pskRaw = "ext:psk_enroll";
    # Without a regdomain cfg80211 stays at world (00) and brcmfmac active scan
    # fails (scan error -512 / escan_timeout). Set a country so the regulatory
    # database loads. US = the travel region; change when roaming abroad.
    extraConfig = "country=US";
  };

  # brcmfmac on the Pi 3B flaps the link under power-save (4-way handshake
  # timeout, reason=15) so DHCP never completes. Disable it once the radio
  # exists; the setting lives on the netdev and persists across re-associations.
  systemd.services.wlan0-powersave-off = {
    description = "Disable wlan0 Wi-Fi power save (brcmfmac flap workaround)";
    wantedBy = [ "multi-user.target" ];
    after = [ "wpa_supplicant.service" ];
    wants = [ "wpa_supplicant.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.iw}/bin/iw dev wlan0 set power_save off";
    };
  };
}
