# High-priority audit changes

These changes are prepared on `security/audit-high-priority`. They are not activated on the Pi or merged into main. The Tailscale policy is a separate, unpublished administrative change.

Shutdown checkpoint: the revised system builds, but item 2's expanded mode VM test is unfinished. See the implementation plan for the last fixture failure and exact resume steps. This branch is not ready for integration or activation.

## 1. Forwarding isolation

Reason: the old firewall denied unsolicited connections to the Pi, but permitted unsolicited forwarding through it. NAT did not provide the intended downstream boundary.

Change: enable NixOS forwarding filtering. Its NAT module permits downstream-initiated flows, and conntrack permits replies. A VM test uses the production gateway module with isolated upstream/downstream networks.

Expected result: downstream requests and replies work; unsolicited upstream IPv4/IPv6 TCP cannot reach a downstream server even when its own firewall permits that server.

## 2. Selectable Direct/Tor egress

Reason: ordinary client traffic previously left directly over Wi-Fi, and Tailscale was only providing mesh management.

Change: add explicit Direct and Tor modes, defaulting to Direct on a fresh card as subsequently requested by the user for streaming. Both modes force client DNS to Blocky. Direct retains ordinary gateway forwarding and direct Blocky DoH. Tor redirects IPv4 client TCP and ordinary Pi TCP/DNS through Tor; its independent forwarding chain blocks every packet except explicitly authorized portal traffic, including already-established connections. Unsupported client UDP and IPv6 are blocked in Tor mode. There is no automatic fallback. Changing to Tor cuts existing direct client flows.

The applied mode is visible in the UI and persists at `/base/ph/egress-mode`. Direct works while locked; selected Tor stays clamped until unlock. Firewall start/reload begins clamped before restoring the saved selection. Invalid state keeps the clamp. The UI can select Direct only from configured laptop/phone IPs over the actual `tailscale0` listener, enforced by the Pi without trusting forwarded headers or the laptop MAC filter. Cable clients may enable Tor and request portal access. Mode requests, denials and outcomes enter the volatile journal. Keys-only cable SSH recovery is `sudo ph-egress direct`; it invokes the same root operation as the UI. `ph-egress status` reports the applied mode.

Tor starts after unlock. Its guard state is encrypted at `/persist/tor`, preserving guard continuity across reboots. Its memory limit is 192 MiB. Locked boots retain management/bootstrap access and enforce the selected mode.

The explicit control-plane exceptions are Tor's TCP transport, Tailscale's `0x80000/0xff0000` transport mark, DHCP, NDP, time-sync NTP, root/time-sync DNS bootstrap, and root HTTP connectivity probes. Root is trusted to administer this firewall; these exceptions do not constitute blanket anonymity for all root activity. Normal unprivileged processes and client applications do not inherit those exceptions.

Portal recovery is an explicit privacy exception: the requesting IPv4 cable client may use direct TCP 80/443 and the uplink DNS resolver for up to 600 seconds. It covers web destinations needed by portal redirects/assets, not just one guessed portal IP. The UI discloses this. Other clients and other ports remain clamped. Both the kernel set timeout and systemd runtime cap enforce expiry. End portal access before ordinary browsing; all tabs on that client share its temporary permission. Open the UI using the cable address to authorize this client; tailnet-originated requests cannot authorize an unrelated cable client.

Expected result: Direct supports streaming with direct uplink exposure; selected Tor has no direct fallback on daemon failure, locked startup, unsupported protocols or expired portal permissions. Deterministic proxy/DNS fixtures establish packet enforcement; they do not prove public Tor circuit health.

Hardware acceptance remains required after separately approved activation:

- Run `tools/ph-bench.sh`/`make bench` in each mode and record throughput and Pi 3B CPU/memory.
- In Tor mode with the phone on the bubble, open the UI over its tailnet address and switch to Direct. Marked-packet VM tests do not establish the live WireGuard/DERP path.
- With the uplink portal login expired, open the portal window from the cable UI and confirm Tailscale returns.
- Verify real Tor bootstrap, captive-portal compatibility, cable SSH recovery and radio reconnects. Preserve rollback access.

## 3. Management origins

Reason: the old `panhandler.*` Host check accepted attacker-owned domains, and mutations did not validate browser origins.

Change: accept literal IPs, the two exact short device names and exact additional names supplied through `panhandler.webd.allowedHostnames`. The host configuration supplies the current MagicDNS names. Reject cross-origin mutation requests, including incompatible Fetch Metadata. Preserve JSON CLI requests from the trusted interfaces.

Expected result: normal local/tailnet UI requests work; DNS-rebinding lookalikes and browser requests from other origins fail before reaching NetworkManager. This retains the existing trusted-interface authorization model; it does not add a user login. Every client permitted through the network boundary still has management authority. The administrative policy narrows that boundary over Tailscale.

## 4. Wi-Fi selection and replacement

Reason: the backend could replace the UI's selected AP/security with the strongest matching SSID, and deleted the working profile before a replacement succeeded.

Change: send the selected BSSID/security, recheck both against NM, and set the corresponding WPA protocol. Bind the initial activation to that AP while keeping the saved profile free to roam within its security constraints. Refuse missing/stale/changed selections and a password supplied for an open network. Serialize connect/forget operations. Delete the prior profile only after successful replacement activation; delete only the candidate after activation failure.

Expected result: a stronger open AP cannot silently replace a selected protected AP, and a failed password replacement retains the previous profile. Saved-profile reconnects work without a new scan, and roaming remains available. A spoofed BSSID alone is not cryptographic AP authentication.
