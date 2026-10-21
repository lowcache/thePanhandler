# High-priority security fixes implementation plan

**Goal:** Address audit items 1–5 with separately explained changes and evidence.
**Architecture:** Keep the existing NixOS modules, Go/NM backend and Svelte UI. Direct defaults on a fresh card; explicitly selected Tor never falls back. Preserve cable recovery and explicitly bounded portal access. Build locally; activation and administrative-policy publication require a later review.
**Spec:** The five high-priority findings plus the user's subsequent selectable-mode requirements and downgrade authorization boundary.

## Constraints and review focus

- Preserve pre-existing changes to wifi.nix, the runtime-hardening spec and untracked tooling.
- No tether changes or invocation while Claude is updating it.
- No Pi activation, reboot, key rotation or administrative ACL changes in this pass.
- Test hostile-to-client forwarding, established replies, IPv6, stale connections, spoofed web origins, changed AP security, failed replacement and captive-portal expiry.
- All tests must exercise behavior; a successful build alone is not a network-isolation test.

## Tasks

1. Forwarding boundary: add a production-module VM test that fails on unsolicited upstream-to-client TCP. Enable forwarding filtering in gateway.nix; prove outbound traffic and replies still work, and IPv4/IPv6 unsolicited connections fail.
2. Web origins: add HTTP tests for attacker-controlled panhandler.* names and cross-origin mutations. Replace the prefix check with exact configured names; enforce same-origin browser mutations while retaining the existing trusted-interface model. Verify normal UI/CLI requests.
3. Wi-Fi joins: bind new/replacement joins to selected BSSID and expected security, reject missing/stale/mismatched selections, retain old profiles until replacement activation succeeds, serialize mutations. Test through a private D-Bus fake, plus UI type/build checks.
4. Tor egress: implement transparent TCP routing with explicit DNS handling and a fail-closed firewall, including boot/daemon-loss/IPv6/portal-transition tests. Keep bootstrap exceptions explicit and narrow. Review the exact design before activation.
5. Tailnet policy: inspect available local node metadata and effective filtering; prepare minimal policy requirements and validation tests. Do not claim administrative ACL verification without the actual policy.

## Progress

- Baseline: Go builds; no Go tests existed. Existing Nix VM tests passed in prior audit; forwarding and web-origin failures were reproduced there.
- Work is on security/audit-high-priority. Existing uncommitted changes remain in place.
- Direct file changes and local tests are authorized; deployment is not part of this pass.
- User required branch separation until all items are finished and assessed. At the user's request, fast-forwarded only the security branch to existing main commit a4199b9, after saving four byte-identical main files in a recovery stash. No security edits entered main.
- Item 1: production-module VM test reproduced upstream-to-client access, then passed after filterForward=true (IPv4/IPv6 TCP isolation plus outbound replies).
- Items 3/4: HTTP and private-D-Bus tests reproduced the defects, then passed after exact hosts/origins and selected-AP/profile-retention changes. Go race detector passes; UI type/build checks pass.
- Item 5: user supplied the administrative policy; the unrestricted wildcard grant is confirmed. Replacement policy and tests are prepared but unpublished. Console validation and expiry confirmation remain external acceptance steps.
- Item 2: original Tor-only VM passed TCP, Pi-local TCP/DNS, forced client DNS, daemon loss, IPv6, per-client portal access and established-flow expiry. The initial complete Pi build passed. Requirements subsequently changed to selectable Direct/Tor. The revised Pi system build passed; Go race tests and UI checks pass. Expanded VM verification is NOT COMPLETE: latest run passed direct/locked access, live-flow cutoff, proxy/DNS, actual UDP/IPv6 denial and marked transport, then failed because the VM framework omits the timesync account. The fixture now creates egress-clock with the production timesync UID, but that edit has NOT been rerun at shutdown checkpoint.
- Test harness fixes: explicit VM addresses avoid framework defaults; Nix imports must remain outside mkMerge; private D-Bus uses its own config rather than /etc; synthetic DNS replies strip EDNS additions from the echoed question.

## Decisions settled with the user

- Direct works while locked; Tor remains clamped until unlock. Mode persists at /base/ph/egress-mode; no automatic fallback.
- Only verified management peers arriving on the real tailscale0 listener can choose Direct through HTTP. Cable clients may choose Tor/open a portal window. sudo ph-egress direct is cable SSH recovery through the same root operation.
- panhandler.managementPeers supplies webd and generated policy hosts. The stale-output check proves repository consistency only. Console equality and server-side tests remain publication acceptance steps.
- Exact extra management names use a Nix option. No permanent Wi-Fi BSSID pin; retain selection-time validation and WPA protocol constraints.
- Tag migration for laptop/phone explicitly deferred: it changes user ownership and autogroup:self/SSH semantics. Cost: re-registration needs a source IP update and regenerated JSON.
- Keep five commits on the security branch. No merge, deployment, policy publication, tether use, machine-id branch edits or snapshot edits.

## Shutdown checkpoint / resume

1. Run nixfmt on tests/egress.nix, then rebuild checks.x86_64-linux.egress, webd and tailscale-policy with cache.nixos.org. Capture logs under ~/Storage/tmp/ph-security-audit. Fix genuine failures before calling item 2 ready.
2. Ensure the complete mode tests reach portal expiry, reload, both reboot-persistence cases, explicit Direct recovery, and all control-plane exceptions. The timesync fixture fix is currently unverified.
3. Re-run nixops.py gate, make checks, full flake evaluation and the final Pi build as appropriate; read closure diff. Do not activate. System build passed before the test-fixture-only last edit.
4. Inspect the final five-commit diff against a4199b9. Claude's first assessment is ~/Storage/tmp/ph-codex-findings.md; its snapshot is read-only. A second review agent hit a usage limit and supplied no review.
5. Hardware acceptance includes throughput/CPU, phone-on-bubble tailnet UI downgrade, expired-portal recovery of Tailscale, cable SSH command, real Tor circuits and console/generated-policy equality. None has been claimed complete.
