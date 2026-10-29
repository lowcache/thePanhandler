# thePanhandler front door. `make` lists targets. VIA=cable|tailnet picks the path to the Pi.
.DEFAULT_GOAL := help
SHELL := bash
.SHELLFLAGS := -euo pipefail -c
# Quiet recipes; `make V=1 <target>` shows the commands again.
ifndef V
.SILENT:
endif

VIA     ?= cable
PI_cable   := lowcache@10.73.0.1
PI_tailnet := lowcache@100.81.123.86
PI      := $(PI_$(VIA))
MODE    ?= switch
CHECK   ?= hardening
export TMPDIR ?= $(HOME)/Storage/tmp
OUT     := $(TMPDIR)/ph-build
# Pinned host key: one key, two addresses.
SSHOPTS := -o HostKeyAlias=100.81.123.86 -o ConnectTimeout=6 -o BatchMode=yes
SSH     := ssh $(SSHOPTS) $(PI)
# Another configured substituter has been failing (curl errors); go straight to the main cache.
NIXOPTS := --option substituters https://cache.nixos.org
TOPLEVEL_ATTR := .\#nixosConfigurations.panhandler.config.system.build.toplevel

## help: this list
help:
	@awk '/^## / { sub(/^## /, ""); i = index($$0, ":"); \
	  printf "  \033[33m%-15s\033[0m %s\n", substr($$0, 1, i - 1), substr($$0, i + 2) }' $(MAKEFILE_LIST)

# ---- build & test -------------------------------------------------------------
## build: build the Pi system (aarch64 via binfmt) → $(OUT)/toplevel
build:
	@mkdir -p $(OUT)
	nix build $(NIXOPTS) $(TOPLEVEL_ATTR) --out-link $(OUT)/toplevel
	@readlink -f $(OUT)/toplevel

## image: build the flashable sd image → $(OUT)/sd-image
image:
	@mkdir -p $(OUT)
	nix build $(NIXOPTS) .#packages.aarch64-linux.sdImage --out-link $(OUT)/sd-image

## check: run a VM test (CHECK=hardening|spine)
check:
	nix build $(NIXOPTS) .#checks.x86_64-linux.$(CHECK) -L --no-link

## checks: run every VM test
checks:
	$(MAKE) check CHECK=spine
	$(MAKE) check CHECK=hardening

## fmt: format the nix files
fmt:
	nix fmt

# ---- deploy ---------------------------------------------------------------------
## diff: package changes, running Pi system → fresh build
diff: build
	@cur=$$($(SSH) readlink -f /run/current-system); \
	  echo "pi: $$cur"; nix store diff-closures $$cur $$(readlink -f $(OUT)/toplevel)

## deploy: build, copy, activate (MODE=switch|boot, VIA=cable|tailnet)
deploy: build
	@T=$$(readlink -f $(OUT)/toplevel); \
	  echo ">> copy $$T"; \
	  NIX_SSHOPTS="$(SSHOPTS)" nix copy --no-check-sigs \
	    --to "ssh-ng://$(PI)?remote-program=sudo%20nix-daemon" $$T; \
	  echo ">> $(MODE)"; \
	  $(SSH) "sudo nix-env -p /nix/var/nix/profiles/system --set $$T && \
	    sudo systemd-run --wait --collect --unit=ph-switch $$T/bin/switch-to-configuration $(MODE)" \
	    || { $(SSH) 'journalctl -u ph-switch -o cat -n 200 | grep -A1 "units failed"'; exit 4; }; \
	  $(SSH) 'readlink /nix/var/nix/profiles/system; systemctl is-system-running || true'
# systemd-run: activation outlives the ssh session if a restart (tailscaled, NM) drops it.

## rollback: activate the previous Pi generation
rollback:
	$(SSH) 'sudo nix-env -p /nix/var/nix/profiles/system --rollback && \
	  sudo systemd-run --wait --collect --unit=ph-switch /nix/var/nix/profiles/system/bin/switch-to-configuration switch; \
	  readlink /nix/var/nix/profiles/system'

## generations: list Pi system generations
generations:
	$(SSH) 'ls -l /nix/var/nix/profiles/ | grep system-'

# ---- the box --------------------------------------------------------------------
## ssh: shell on the Pi
ssh:
	ssh $(subst BatchMode=yes,BatchMode=no,$(SSHOPTS)) $(PI)

## health: uplink, route, connectivity, egress, DNS, failed units, uptime
health:
	$(SSH) 'nmcli -t -f DEVICE,STATE,CONNECTION device | grep -v unmanaged; \
	  echo "route: $$(ip -4 route show default | head -1)"; \
	  echo "connectivity: $$(nmcli -g CONNECTIVITY general)"; \
	  echo "egress: $$(ph-egress status) (tor $$(systemctl is-active tor))"; \
	  echo "dns: blocky $$(systemctl is-active blocky)"; \
	  systemctl --failed --no-legend; awk '\''{printf "up %.1f h\n", $$1/3600}'\'' /proc/uptime'

# Laptop side. pi-diag: fixed address on the cable, no default route, so the Pi is reachable at
# 10.73.0.1 while the laptop's internet comes from elsewhere (pi-share going down stops the bubble).
LAPTOP_ETH := enp3s0
## cable-debug: laptop keeps its own internet; Pi stays reachable on the cable (bubble off)
cable-debug:
	nmcli -t -f NAME con show | grep -qx pi-diag || nmcli con add type ethernet \
	  ifname $(LAPTOP_ETH) con-name pi-diag autoconnect no ipv4.method manual \
	  ipv4.addresses 10.73.0.200/24 ipv4.never-default yes ipv6.method link-local
	nmcli con up pi-diag
	@echo ">> bubble off. Join the hotel Wi-Fi on the laptop; the Pi is still at 10.73.0.1."

## cable-share: back to normal: laptop routes through the Pi, bubble back on
cable-share:
	nmcli con down pi-diag 2>/dev/null || true
	nmcli con up pi-share

## bench: throughput laptop → Pi → Cloudflare, plus Pi CPU
bench:
	tools/ph-bench.sh $(SSHOPTS) $(PI)

# ---- unlock & keys (ph-unlock reads ~/.config/panhandler/agent.json) -------------
## status: persist lock state (ph-unlock status)
status:
	nix run .#ph-unlock -- status --via $(VIA)

## up: cold start — cable, wait for Pi, unlock, uplink, bubble (HOW=bitwarden, BUBBLE=yes|no)
up:
	tools/ph-up.sh $(if $(filter command line,$(origin HOW)),$(HOW),bitwarden)

## unlock: unlock /persist (HOW=auto|bitwarden|passphrase)
HOW ?= auto
unlock:
	nix run .#ph-unlock -- $(HOW) --via $(VIA)

## rekey: rotate the quorum key (cable only, persist unlocked)
rekey:
	nix run .#ph-unlock -- rekey

## log: recent check-ins from the phone listener
log:
	nix run .#ph-unlock -- log

# ---- cards ------------------------------------------------------------------------
## provision-keys: once: generate the unlock SSH key
provision-keys:
	nix run .#ph-provision -- keys

## provision-card: flash + set up a card (IMAGE=… DEVICE=/dev/sdX; destructive, asks first)
provision-card:
	nix run .#ph-provision -- card $(IMAGE) $(DEVICE)

## verify-card: offline integrity check of a card (DEVICE=/dev/sdX)
verify-card:
	nix run .#verify-card -- $(DEVICE)

.PHONY: help build image check checks fmt diff deploy rollback generations ssh health bench \
	cable-debug cable-share \
	status unlock rekey log provision-keys provision-card verify-card
