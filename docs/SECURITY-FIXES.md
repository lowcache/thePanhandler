# High-priority audit changes

These changes are prepared on `security/audit-high-priority`. They are not activated on the Pi or merged into main. The Tailscale policy is a separate, unpublished administrative change.

## 1. Forwarding isolation

Reason: the old firewall denied unsolicited connections to the Pi, but permitted unsolicited forwarding through it. NAT did not provide the intended downstream boundary.

Change: enable NixOS forwarding filtering. Its NAT module permits downstream-initiated flows, and conntrack permits replies. A VM test uses the production gateway module with isolated upstream/downstream networks.

Expected result: downstream requests and replies work; unsolicited upstream IPv4/IPv6 TCP cannot reach a downstream server even when its own firewall permits that server.

## 3. Management origins

Reason: the old `panhandler.*` Host check accepted attacker-owned domains, and mutations did not validate browser origins.

Change: accept literal IPs, the two exact short device names and exact additional names supplied through `panhandler.webd.allowedHostnames`. The host configuration supplies the current MagicDNS names. Reject cross-origin mutation requests, including incompatible Fetch Metadata. Preserve JSON CLI requests from the trusted interfaces.

Expected result: normal local/tailnet UI requests work; DNS-rebinding lookalikes and browser requests from other origins fail before reaching NetworkManager. This retains the existing trusted-interface authorization model; it does not add a user login. Every client permitted through the network boundary still has management authority. The administrative policy narrows that boundary over Tailscale.
