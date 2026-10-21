# Panhandler tailnet policy

`security/tailscale-policy.json` is a proposed replacement for the supplied allow-all policy. It is not published by Nix or by this security pass.

The supplied `src: ["*"], dst: ["*"], ip: ["*"]` grant gives both Pi identities unrestricted tailnet access. Tags do not narrow that grant. The replacement removes it; adding narrower grants while retaining it would have no restrictive effect.

| Source | Destination | New connections |
| --- | --- | --- |
| Current laptop and phone | Each other | Existing general access |
| Current laptop and phone | Either Pi identity | TCP 22 and 8080 |
| Either Pi identity | Phone | TCP 8463 check-ins only |
| Either Pi identity | Other tailnet services | Denied |
| Other devices | Pi | Denied |

Replies to permitted connections remain allowed. The locked node has a narrow check-in exception, not literally zero outbound reach. The existing Tailscale SSH check rule is retained; the Pi still uses its configured OpenSSH keys and does not enable Tailscale SSH.

Host aliases use the laptop and phone addresses verified from the live Pi's node map on 2026-10-21, including IPv6. `panhandler.managementPeers` in the host configuration is their editable source, shared with webd's Direct-mode authorization. After changing it, regenerate the reviewable artifact with `nix build .#tailscale-policy --out-link ~/Storage/tmp/ph-policy` and `python3 -m json.tool ~/Storage/tmp/ph-policy > security/tailscale-policy.json`. The `tailscale-policy` flake check rejects stale host output. The JSON keeps the small grant/test template; Nix substitutes only its host aliases.

IP identity is explicitly retained for this pass. Device tags would replace user ownership and change `autogroup:self`/Tailscale SSH semantics; retagging the phone/laptop is a separate reviewed migration. See [Tailscale tags](https://tailscale.com/docs/features/tags). Re-enrollment/IP changes or additional devices require updating the Nix source and regenerating the JSON. Pi Taildrop/peer-API connections are not allowed; move new phone shares directly between the laptop and phone.

Before publishing, save the old policy, review the complete tailnet device list, and paste the generated replacement into the admin editor. Its built-in tests must pass there; local consistency checks do not validate Tailscale semantics or establish the console's current policy. After publishing, compare the saved console policy with the generated file and verify its tests pass. Then verify laptop/phone SSH and UI access, locked-identity phone check-in, and denial of Pi-originated SSH to the laptop. Test the locked identity during a scheduled reboot, not by swapping identities on a running router.

Node tags are verified locally. Administrative key-expiry settings must also be checked in the console; a node-status snapshot does not establish that setting. Tag ownership is limited to tailnet administrators.
