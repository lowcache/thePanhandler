# High-priority audit changes

These changes are prepared on `security/audit-high-priority`. They are not activated on the Pi or merged into main. The Tailscale policy is a separate, unpublished administrative change.

## 1. Forwarding isolation

Reason: the old firewall denied unsolicited connections to the Pi, but permitted unsolicited forwarding through it. NAT did not provide the intended downstream boundary.

Change: enable NixOS forwarding filtering. Its NAT module permits downstream-initiated flows, and conntrack permits replies. A VM test uses the production gateway module with isolated upstream/downstream networks.

Expected result: downstream requests and replies work; unsolicited upstream IPv4/IPv6 TCP cannot reach a downstream server even when its own firewall permits that server.
