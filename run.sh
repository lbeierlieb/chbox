CPUS=${CHBOX_CPUS:-4}
MEMORY=${CHBOX_MEMORY:-4G}

rundir=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/chbox.XXXXXX")
cleanup() {
  # shellcheck disable=SC2046
  kill $(jobs -p) 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$rundir"
}
trap cleanup EXIT

virtiofsd \
  --socket-path="$rundir/store.sock" \
  --shared-dir=/nix/store \
  --readonly \
  --sandbox=none \
  --log-level=error &

for _ in $(seq 100); do
  [ -S "$rundir/store.sock" ] && break
  sleep 0.05
done

# Tell the guest's getty on hvc0 which terminal the host is rendering with.
# (Size and resizes reach the guest through the virtio console itself.)
cmdline="init=$TOPLEVEL/init $(cat "$TOPLEVEL/kernel-params")"
cmdline+=" systemd.tty.term.hvc0=${TERM:-xterm-256color}"

echo "chbox: booting VM ($CPUS CPUs, $MEMORY), shut down with: sudo poweroff"
cloud-hypervisor \
  --kernel "$KERNEL" \
  --initramfs "$INITRD" \
  --cmdline "$cmdline" \
  --cpus boot="$CPUS" \
  --memory size="$MEMORY",shared=on \
  --fs tag=nixstore,socket="$rundir/store.sock" \
  --console tty \
  --serial off
