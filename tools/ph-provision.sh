# ph-provision keys                 — once, before building the image: unlock SSH key → keys/unlock-keys.pub
# ph-provision card IMAGE DEVICE    — flash + partition + LUKS + populate /base and /persist + split K
# Run from the repo root. Destructive on DEVICE; asks before touching it.
repo=$PWD
[ -f "$repo/flake.nix" ] && [ -f "$repo/.sops.yaml" ] || { echo "run from the Panhandler repo root" >&2; exit 64; }
state=${XDG_DATA_HOME:-$HOME/.local/share}/panhandler
unlock_key=$HOME/.ssh/panhandler_unlock
# Runs as you (rbw, sops, age key); only device and mounted-filesystem steps use sudo.
S=sudo
[ "$(id -u)" = 0 ] && S=

keys() {
  [ -f "$unlock_key" ] || ssh-keygen -q -t ed25519 -N "" -C panhandler-unlock -f "$unlock_key"
  mkdir -p "$repo/keys"
  grep -qxF "$(cat "$unlock_key.pub")" "$repo/keys/unlock-keys.pub" 2>/dev/null ||
    cat "$unlock_key.pub" >>"$repo/keys/unlock-keys.pub"
  echo "keys/unlock-keys.pub updated; add the phone's Termux key there too if you want phone break-glass, then rebuild."
}

# rbw add reads the secret from $EDITOR; feed it a file instead of opening one.
bw_add() {
  local name=$1 file=$2
  EDITOR="cp $file" rbw add "$name"
}

card() {
  local image=$1 dev=$2
  [ -b "$dev" ] || { echo "$dev is not a block device" >&2; exit 64; }
  lsblk -o NAME,SIZE,MODEL,MOUNTPOINTS "$dev"
  read -rp "ERASE $dev? type its path to confirm: " ok
  [ "$ok" = "$dev" ] || { echo aborted >&2; exit 1; }
  if lsblk -no MOUNTPOINTS "$dev" | grep -q .; then echo "$dev has mounted partitions; unmount first" >&2; exit 1; fi

  local uuid
  uuid=$(nix eval --raw .#nixosConfigurations.panhandler.config.panhandler.spine.persistUuid)
  # Flakes ignore untracked files: an unstaged keys/unlock-keys.pub builds an image nobody can unlock.
  if [ "$(nix eval --raw .#nixosConfigurations.panhandler.config.panhandler.spine.unlockKeys --apply 'k: toString (builtins.length k)')" = 0 ]; then
    echo "no unlock keys in the config: git add keys/unlock-keys.pub, rebuild the image, rerun" >&2
    exit 1
  fi
  # tmpfs only: K must never touch a disk, where rm does not erase it.
  # Global, not local: the EXIT trap runs after card() returns.
  tmp=$(mktemp -d "${XDG_RUNTIME_DIR:-/dev/shm}/ph-provision.XXXXXX")
  chmod 700 "$tmp"
  trap '$S umount -q "$tmp/sd" "$tmp/persist" 2>/dev/null; $S cryptsetup close ph-provision 2>/dev/null; rm -rf "$tmp"' EXIT

  echo "== flash"
  case $image in *.zst) zstd -dc "$image" ;; *) cat "$image" ;; esac | $S dd of="$dev" bs=4M conv=fsync status=progress
  $S partprobe "$dev"
  local p
  p=$(lsblk -lnpo NAME "$dev" | sed -n 3p)  # second partition (system); row 1 is the disk
  local p3_part=${p%2}3

  echo "== partition: system grows to all but 4 GiB, persist takes the rest"
  # Persist starts on a 4 MiB boundary (SD erase blocks), 4 GiB before the end.
  local sectors start
  sectors=$($S blockdev --getsz "$dev")
  start=$(((sectors - 4 * 1024 * 2048) / 8192 * 8192))
  $S parted -s "$dev" -- resizepart 2 "$((start - 1))s" mkpart primary ext4 "${start}s" 100%
  $S partprobe "$dev"
  $S e2fsck -fy "$p" >/dev/null || true
  $S resize2fs "$p"

  echo "== keys"
  head -c 64 /dev/urandom >"$tmp/K"
  head -c 64 /dev/urandom >"$tmp/S_L"
  head -c 64 /dev/urandom >"$tmp/K_BW"
  python3 -c 'import sys; a,b=(open(f,"rb").read() for f in sys.argv[1:3]); open(sys.argv[3],"w").write(bytes(x^y for x,y in zip(a,b)).hex())' \
    "$tmp/K" "$tmp/S_L" "$tmp/S_P.hex"

  echo "== LUKS (Adiantum: the Pi 3 has no AES instructions)"
  $S cryptsetup luksFormat -q --type luks2 --uuid "$uuid" --cipher xchacha12,aes-adiantum-plain64 \
    --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file "$tmp/K" "$p3_part"
  # Pin slots to the spec map (0 quorum, 1 passphrase, 2 Bitwarden); later steps rely on it.
  $S cryptsetup luksAddKey -q --key-slot 2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file "$tmp/K" "$p3_part" "$tmp/K_BW"
  echo "Slot 1 passphrase: memorize or paper only, NEVER Bitwarden (independent root)."
  # Argon2id sized for the Pi's ~860 MB, not this laptop.
  $S cryptsetup luksAddKey --key-slot 1 --pbkdf argon2id --pbkdf-memory 262144 --iter-time 3000 --key-file "$tmp/K" "$p3_part"

  echo "== /persist"
  $S cryptsetup open --key-file "$tmp/K" "$p3_part" ph-provision
  $S mkfs.ext4 -q -L persist /dev/mapper/ph-provision
  mkdir -p "$tmp/persist" "$tmp/sd"
  $S mount /dev/mapper/ph-provision "$tmp/persist"
  $S install -d -m700 "$tmp/persist/sops-nix" "$tmp/persist/tailscale"
  local pub
  pub=$(sed -n 's/^ *- &panhandler //p' .sops.yaml)
  grep '^AGE-SECRET-KEY-' "$HOME/.config/sops/age/keys.txt" | while read -r k; do
    if [ "$(age-keygen -y <<<"$k")" = "$pub" ]; then printf '%s\n' "$k"; fi
  done >"$tmp/age.txt"
  [ -s "$tmp/age.txt" ] || { echo "Panhandler age key not found in ~/.config/sops/age/keys.txt" >&2; exit 1; }
  $S install -m600 "$tmp/age.txt" "$tmp/persist/sops-nix/key.txt"

  echo "== /base"
  $S mount "$p" "$tmp/sd"
  $S install -d -m700 "$tmp/sd/base/ph"
  printf 'psk_enroll=%s\n' "$(sops -d --extract '["wifi_enroll_psk"]' secrets/secrets.yaml)" >"$tmp/wireless.env"
  $S install -m600 "$tmp/wireless.env" "$tmp/sd/base/ph/wireless.env"
  read -rsp "Single-use tag:panhandler-locked authkey (spent on first boot): " lk
  echo
  printf '%s\n' "$lk" >"$tmp/lk"
  $S install -m600 "$tmp/lk" "$tmp/sd/base/ph/ts-locked-authkey"

  echo "== laptop share + Bitwarden"
  install -d -m700 "$state"
  install -m600 "$tmp/S_L" "$state/unlock-share"
  base64 -w0 "$tmp/K_BW" >"$tmp/K_BW.b64"
  base64 -w0 "$tmp/S_L" >"$tmp/S_L.b64"
  # Slot 2's key exists only here: on failure, kill slot 2 instead of losing the run.
  if bw_add "panhandler luks slot2" "$tmp/K_BW.b64" &&
    bw_add "panhandler laptop share" "$tmp/S_L.b64" &&
    bw_add "panhandler age key" "$tmp/age.txt" &&
    bw_add "panhandler unlock ssh key" "$unlock_key"; then
    rbw lock
  else
    echo "Bitwarden step failed: removing slot 2 (its key would be lost). Re-add it later with the passphrase." >&2
    $S cryptsetup luksKillSlot -q --key-file "$tmp/K" "$p3_part" 2
  fi

  install -m600 "$tmp/S_P.hex" "$state/phone-share.hex"
  sync
  cat <<EOF

Card ready. One step left, the phone share:
  1. Move $state/phone-share.hex to the phone over a channel you trust (Taildrop or USB).
  2. In Termux:  python3 enroll.py < phone-share.hex && rm phone-share.hex
  3. Here:       shred -u $state/phone-share.hex
K itself was never written outside $tmp, which is deleted now.
EOF
}

case ${1:-} in
  keys) keys ;;
  card) [ $# -eq 3 ] || { echo "usage: ph-provision card IMAGE DEVICE" >&2; exit 64; }; card "$2" "$3" ;;
  *) echo "usage: ph-provision keys | card IMAGE DEVICE" >&2; exit 64 ;;
esac
