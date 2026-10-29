# verify-card DEVICE — offline integrity check of a Panhandler card in this laptop's reader.
# Trust anchor: this laptop's Nix store (the deploy source) and this flake's firmware build.
# Checks every extlinux entry (cmdline, kernel, initrd, dtbs, full system closure) and the
# firmware partition. Not covered: /base (mutable state), the LUKS volume. Opt-in, never a gate.
repo=$PWD
[ -f "$repo/flake.nix" ] || { echo "run from the Panhandler repo root" >&2; exit 64; }
dev=${1:-}
[ -b "$dev" ] || { echo "usage: verify-card DEVICE (the whole card, e.g. /dev/sdb)" >&2; exit 64; }
S=sudo
[ "$(id -u)" = 0 ] && S=

fails=0
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }
warn() { echo "WARN  $*"; }

lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$dev"
if lsblk -no MOUNTPOINTS "$dev" | grep -q .; then echo "$dev has mounted partitions; unmount first" >&2; exit 1; fi
mnt=$(mktemp -d "${XDG_RUNTIME_DIR:-/dev/shm}/verify-card.XXXXXX")
trap '$S umount -q "$mnt/fw" "$mnt/sys" 2>/dev/null || true; rm -rf --one-file-system "$mnt"' EXIT
mkdir "$mnt/fw" "$mnt/sys"
# Rows 2 and 3 = partitions 1 (firmware, vfat) and 2 (system, ext4). noload: no journal replay.
$S mount -o ro,nodev,nosuid,noexec "$(lsblk -lnpo NAME "$dev" | sed -n 2p)" "$mnt/fw"
$S mount -o ro,noload,nodev,nosuid,noexec "$(lsblk -lnpo NAME "$dev" | sed -n 3p)" "$mnt/sys"
sys=$mnt/sys

echo "== firmware partition vs this flake's image"
ref=$(nix build --no-link --print-out-paths .#packages.aarch64-linux.firmware)
diff -r "$ref" "$mnt/fw" >/dev/null || {
  fail "firmware partition differs:"
  diff -rq "$ref" "$mnt/fw" | sed 's/^/        /'
}

echo "== boot entries"
conf=$sys/boot/extlinux/extlinux.conf
[ -f "$conf" ] || { fail "no extlinux.conf"; exit 1; }
# Boot-store name of a file inside a store path: <hash>-<name>-<file>, as generic-extlinux copies it.
bootname() { local r; r=$(readlink -f "$1"); echo "$(basename "$(dirname "$r")")-$(basename "$r")"; }
declare -A tops
check_entry() {
  local label=$1 linux=$2 initrd=$3 fdtdir=$4 append=$5 t
  t=$(grep -o 'init=/nix/store/[^ ]*/init' <<<"$append" | head -1)
  t=${t#init=}
  t=${t%/init}
  if [ -z "$t" ] || [ ! -e "$t" ]; then
    # An entry nothing here can vouch for is a failure, not a pass with a footnote.
    fail "$label: system ${t:-?} is not in this store (nix copy it here, or GC old generations on the Pi)"
    return
  fi
  [ "$append" = "init=$t/init $(cat "$t/kernel-params")" ] || fail "$label: cmdline differs: $append"
  local want got f
  for f in kernel:"$linux" initrd:"$initrd" dtbs:"$fdtdir"; do
    want=../nixos/$(bootname "$t/${f%%:*}")
    got=${f#*:}
    if [ "$got" != "$want" ]; then
      fail "$label: ${f%%:*} is $got, system expects $want"
    elif ! diff -r "$(readlink -f "$t/${f%%:*}")" "$sys/boot/nixos/${want#../nixos/}" >/dev/null; then
      fail "$label: ${f%%:*} contents differ ($want)"
    fi
  done
  tops[$t]=1
  echo "ok    $label"
}

label="" linux="" initrd="" fdtdir="" append="" default=""
while read -r key val; do
  case $key in
    "" | "#"* | TIMEOUT | MENU) ;;
    DEFAULT) default=$val ;;
    LABEL)
      [ -z "$label" ] || check_entry "$label" "$linux" "$initrd" "$fdtdir" "$append"
      label=$val linux="" initrd="" fdtdir="" append=""
      ;;
    LINUX) linux=$val ;;
    INITRD) initrd=$val ;;
    FDTDIR) fdtdir=$val ;;
    APPEND) append=$val ;;
    *) fail "unexpected extlinux directive: $key $val" ;;
  esac
done <"$conf"
[ -z "$label" ] || check_entry "$label" "$linux" "$initrd" "$fdtdir" "$append"
grep -qx "LABEL $default" "$conf" || fail "DEFAULT $default has no entry"
echo "default entry: $default"
for f in "$sys"/boot/nixos/*; do
  grep -qF "../nixos/$(basename "$f")" "$conf" || warn "unreferenced boot file: $(basename "$f")"
done

echo "== system closures (${#tops[@]} systems) vs this store's NAR hashes"
n=0
if [ "${#tops[@]}" -gt 0 ]; then
  # Enumerate first: a failure inside process substitution would pass silently as "0 paths".
  if ! closure=$(nix path-info -r --json "${!tops[@]}" |
    jq -r 'if type == "array" then .[] else to_entries[] | .value + {path: .key} end | "\(.path) \(.narHash)"'); then
    fail "could not enumerate the system closures"
  fi
  while read -r p h; do
    [ -n "$p" ] || continue
    n=$((n + 1))
    if [ ! -e "$sys$p" ]; then
      fail "missing $p"
    elif [ "$(nix hash path "$sys$p")" != "$h" ]; then
      fail "modified $p"
    fi
  done <<<"${closure:-}"
  [ "$n" -gt 0 ] || fail "closure enumeration returned no paths"
fi
echo "hashed $n store paths"

echo "== not checked"
for f in "$sys"/*; do
  case ${f##*/} in nix | boot | lost+found) ;; *) echo "      /${f##*/} (state, not verifiable)" ;; esac
done

if [ "$fails" -gt 0 ]; then
  echo "verify-card: $fails FAILURE(S)"
  exit 1
fi
echo "verify-card: card matches this laptop's store and flake"
