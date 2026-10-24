# Security Policy

The Panhandler sees all of its owner's traffic before tunnelling it, so a compromise inverts the
whole project ([THREAT-MODEL A5](docs/THREAT-MODEL.md)). Reports are taken seriously.

## Reporting

Report privately through GitHub:
**[Security → Report a vulnerability](https://github.com/lowcache/thePanhandler/security/advisories/new)**.
Don't open a public issue or PR for an unfixed vulnerability.

Include the affected module or file, the commit, the steps to reproduce, and the impact. You'll get
an acknowledgement when the report is read. There is no bounty and no guaranteed response time.

## Scope

**In scope:** anything reachable from the hostile uplink (`wlan0`); bypasses of the egress
kill-switch or Tor clamp; flaws in the web UI's origin or host checks; weaknesses in the unlock
quorum, LUKS setup or lockdown; secrets leaking into the Nix store; and over-broad tailnet policy.

**Out of scope** ([THREAT-MODEL §3](docs/THREAT-MODEL.md)): targeted or nation-state attackers,
attacks that need a powered-on, unlocked device, evil-maid attacks on the unencrypted `/base`, and
bugs in upstream packages (report those upstream).

## Supported versions

Only the latest commit on `main` is supported.
