CPUS=${CHBOX_CPUS:-4}
MEMORY=${CHBOX_MEMORY:-4G}
DISK_SIZE=${CHBOX_DISK_SIZE:-20G}

rundir=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/chbox.XXXXXX")
disk=
cleanup() {
  # shellcheck disable=SC2046
  kill $(jobs -p) 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$rundir"
  [ -z "$disk" ] || rm -f "$disk"
}
trap cleanup EXIT

# Throwaway, sparse write layer for /nix/store. Not in $XDG_RUNTIME_DIR: that's RAM.
cachedir=${XDG_CACHE_HOME:-$HOME/.cache}/chbox
mkdir -p "$cachedir"
disk=$(mktemp "$cachedir/store.XXXXXX.img")
truncate -s "$DISK_SIZE" "$disk"
mkfs.ext4 -q -m 0 -L chbox-store -E lazy_itable_init=1,lazy_journal_init=1 "$disk"

virtiofsd \
  --socket-path="$rundir/store.sock" \
  --shared-dir=/nix/store \
  --readonly \
  --cache=always \
  --sandbox=none \
  --log-level=error &

# The guest user dev (1000:100) appears as the invoking host user, both ways.
virtiofsd \
  --socket-path="$rundir/repo.sock" \
  --shared-dir="$PWD" \
  --translate-uid="map:1000:$(id -u):1" \
  --translate-gid="map:100:$(id -g):1" \
  --sandbox=none \
  --log-level=error &

for sock in store repo; do
  for _ in $(seq 100); do
    [ -S "$rundir/$sock.sock" ] && break
    sleep 0.05
  done
done

# Tell the guest's getty on hvc0 which terminal the host is rendering with.
# (Size and resizes reach the guest through the virtio console itself.)
cmdline="init=$TOPLEVEL/init $(cat "$TOPLEVEL/kernel-params")"
cmdline+=" systemd.tty.term.hvc0=${TERM:-xterm-256color}"
cmdline+=" chbox.registration=$REGISTRATION"

echo "chbox: booting VM ($CPUS CPUs, $MEMORY), shut down with: sudo poweroff"
cloud-hypervisor \
  --kernel "$KERNEL" \
  --initramfs "$INITRD" \
  --cmdline "$cmdline" \
  --cpus boot="$CPUS" \
  --memory size="$MEMORY",shared=on \
  --fs tag=nixstore,socket="$rundir/store.sock" tag=repo,socket="$rundir/repo.sock" \
  --disk path="$disk",image_type=raw \
  --console tty \
  --serial off
