{ config, ... }:
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
    secretsFile = config.sops.templates."wireless.env".path;
    networks.${enrollSSID}.pskRaw = "ext:psk_enroll";
  };
}
