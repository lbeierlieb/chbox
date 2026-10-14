CPUS=${CHBOX_CPUS:-4}
MEMORY=${CHBOX_MEMORY:-4G}
DISK_SIZE=${CHBOX_DISK_SIZE:-20G}

# Guest network (guest.nix has the matching static config), on a tap device
# inside pasta's namespace. DNS_FWD is a made-up address that pasta forwards
# to the host's resolver.
GUEST_NET=10.200.0
DNS_FWD=192.0.2.53

# Second stage: runs as root of pasta's user+network namespace. Creates the tap
# for the VM, NATs it to pasta's uplink, and firewalls it off from everything
# but the public internet. Then becomes the VM.
if [ "${1-}" = --in-netns ]; then
  ip tuntap add dev tap0 mode tap
  ip addr add "$GUEST_NET.1/24" dev tap0
  ip link set tap0 up
  echo 1 > /proc/sys/net/ipv4/ip_forward
  nft -f - <<NFT
table ip chbox {
  set blocked {
    type ipv4_addr; flags interval
    elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16,
                 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 }
  }
  # Every address the host has, e.g. a public IP on another interface.
  set host {
    type ipv4_addr
    elements = { $CHBOX_HOST_ADDRS }
  }
  chain input {
    type filter hook input priority 0; policy accept
    iifname "tap0" drop
  }
  chain forward {
    type filter hook forward priority 0; policy drop
    ct state established,related accept
    iifname "tap0" ip daddr $DNS_FWD meta l4proto { tcp, udp } th dport 53 accept
    iifname "tap0" ip daddr @blocked drop
    iifname "tap0" ip daddr @host drop
    iifname "tap0" accept
  }
  chain postrouting {
    type nat hook postrouting priority 100
    oifname != "tap0" masquerade
  }
}
NFT

  exec cloud-hypervisor \
    --kernel "$KERNEL" \
    --initramfs "$INITRD" \
    --cmdline "$CHBOX_CMDLINE" \
    --cpus boot="$CPUS" \
    --memory size="$MEMORY",shared=on \
    --fs tag=nixstore,socket="$CHBOX_RUNDIR/store.sock" tag=repo,socket="$CHBOX_RUNDIR/repo.sock" \
    --disk path="$CHBOX_DISK",image_type=raw \
    --net tap=tap0 \
    --console tty \
    --serial off
fi

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

# virtiofsd stays outside pasta's namespace: as namespace root it would try to
# switch credentials. Its sockets are plain files, reachable from inside.
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

host_addrs=$(ip -4 -o addr show | awk '{ sub("/.*", "", $4); print $4 }' | paste -sd,)

echo "chbox: booting VM ($CPUS CPUs, $MEMORY), shut down with: sudo poweroff"
# IPv4 only; no port forwarding in either direction; nothing maps to the host.
CHBOX_RUNDIR=$rundir CHBOX_DISK=$disk CHBOX_CMDLINE=$cmdline CHBOX_HOST_ADDRS=$host_addrs \
  pasta --quiet --foreground --config-net -4 \
    --map-host-loopback none --dns-forward "$DNS_FWD" \
    -t none -u none -T none -U none \
    -- "$0" --in-netns
