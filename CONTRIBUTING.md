# Contributing

The Panhandler is a personal project, but issues and pull requests are welcome.

## Before you start

- Read [`THREAT-MODEL.md`](docs/THREAT-MODEL.md) and [`RISKS.md`](docs/RISKS.md). A feature that
  doesn't map to a threat-model line or a real daily need is scope creep and won't be merged.
- The spine (gateway, hardening, unlock, re-flash) comes before any sensor. See RISKS §2.
- For a security bug, follow [`SECURITY.md`](SECURITY.md). Don't open a public issue.

## Development

```sh
make fmt                       # nixfmt (RFC 166)
make checks                    # NixOS VM tests: spine, hardening
nix build .#checks.x86_64-linux.{gateway,egress,machine-id,webd,tailscale-policy} -L
make build                     # aarch64 system via binfmt
```

For `pkgs/panhandler-webd`, run `go test ./...` there, and run `npm run build` in `web/`. If
dependencies change, update `vendorHash` or `npmDepsHash` in `default.nix`.

## Rules

- **Never commit secrets.** Only sops-encrypted `secrets/*.yaml` belongs in the repo. Age keys stay
  out (see `.gitignore`).
- **Nothing listens on `wlan0`.** Every new service binds to `eth0` or `tailscale0`, with a
  systemd sandbox like the one in [`webd.nix`](modules/webd.nix).
- **Passive only.** No code that scans, probes or touches systems on networks the box is a guest on.
- Keep changes small and focused, with one concern per commit. Write commit messages as
  `area: what changed` (e.g. `egress: keep /base/ph at 0700`).
- A behaviour change to the firewall, egress or unlock path needs a VM test in [`tests/`](tests/).
- Update the matching doc in `docs/` when a decision changes, and date it.

By contributing you agree that your work is licensed under the [MIT License](LICENSE) and that you
follow the [Code of Conduct](CODE_OF_CONDUCT.md).
