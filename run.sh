CPUS=${CHBOX_CPUS:-4}
MEMORY=${CHBOX_MEMORY:-8G}
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

  # Dies with pasta, so the VM never outlives the launcher.
  exec setpriv --pdeathsig KILL cloud-hypervisor \
    --kernel "$KERNEL" \
    --initramfs "$INITRD" \
    --cmdline "$CHBOX_CMDLINE" \
    --cpus boot="$CPUS" \
    --memory size="$MEMORY",shared=on \
    --fs tag=nixstore,socket="$CHBOX_RUNDIR/store.sock" tag=repo,socket="$CHBOX_RUNDIR/repo.sock" \
      tag=chbox,socket="$CHBOX_RUNDIR/guest.sock" \
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
trap 'exit 130' INT TERM HUP

# Throwaway, sparse write layer for /nix/store. Not in $XDG_RUNTIME_DIR: that's RAM.
cachedir=${XDG_CACHE_HOME:-$HOME/.cache}/chbox
mkdir -p "$cachedir"
disk=$(mktemp "$cachedir/store.XXXXXX.img")
truncate -s "$DISK_SIZE" "$disk"
mkfs.ext4 -q -m 0 -L chbox-store -E lazy_itable_init=1,lazy_journal_init=1 "$disk"

# virtiofsd stays outside pasta's namespace: as namespace root it would try to
# switch credentials. Its sockets are plain files, reachable from inside.
setpriv --pdeathsig KILL virtiofsd \
  --socket-path="$rundir/store.sock" \
  --shared-dir=/nix/store \
  --readonly \
  --cache=always \
  --sandbox=none \
  --log-level=error &

# Git files that make the host run code later (hooks, config and the files it
# includes) are read-only for the guest, even for root in it: the repo's
# virtiofsd runs in a bubblewrap mount namespace where they are read-only bind
# mounts. Their parent directories (e.g. .git) are bind mounts of themselves,
# so they can't be renamed away and replaced either.
bwrap_args=()
declare -A bound
protect() {
  local path rest dir
  path=$(realpath -m "$1")
  case $path in "$PWD"/*) ;; *) return 0 ;; esac
  [ -e "$path" ] || return 0
  rest=${path#"$PWD"/} dir=$PWD
  while [[ $rest == */* ]]; do
    dir+=/${rest%%/*} rest=${rest#*/}
    if [ -z "${bound[$dir]-}" ]; then
      bwrap_args+=(--bind "$dir" "$dir")
      bound[$dir]=1
    fi
  done
  bwrap_args+=(--ro-bind "$path" "$path")
}
if [ -d .git ]; then
  mkdir -p .git/hooks
  protect .git/hooks
  protect .git/config
  protect .git/config.worktree
  # Relative include paths are relative to the including file, i.e. .git/.
  while read -r _ inc; do
    case $inc in /*) ;; *) inc=.git/$inc ;; esac
    protect "$inc"
  done < <(git config --file .git/config --get-regexp '^include(if\..*)?\.path$' || true)
  # A hooksPath inside the worktree (.githooks/, .husky/...) holds tracked hooks.
  if hooks_path=$(git config --get core.hooksPath); then
    case $hooks_path in /*) ;; *) hooks_path=$PWD/$hooks_path ;; esac
    case $(realpath -m "$hooks_path") in "$PWD"/*) mkdir -p "$hooks_path" ;; esac
    protect "$hooks_path"
  fi
  # Submodules keep their own hooks and config under .git/modules.
  while IFS= read -r -d '' f; do
    protect "$f"
  done < <(find "$PWD/.git/modules" \( -type d -name hooks -prune -print0 \) \
             -o \( -type f -name config -print0 \) 2>/dev/null || true)
fi

# The guest user dev (1000:100) appears as the invoking host user, both ways.
setpriv --pdeathsig KILL bwrap --dev-bind / / "${bwrap_args[@]}" --die-with-parent -- virtiofsd \
  --socket-path="$rundir/repo.sock" \
  --shared-dir="$PWD" \
  --translate-uid="map:1000:$(id -u):1" \
  --translate-gid="map:100:$(id -g):1" \
  --sandbox=none \
  --log-level=error &

# Per-launch data for the guest (Claude token, git identity), read-only at
# /run/chbox. Lives in $rundir, which only the invoking user can read.
mkdir -m 700 "$rundir/guest"
tokenfile=${XDG_CONFIG_HOME:-$HOME/.config}/chbox/claude-token
token=${CLAUDE_CODE_OAUTH_TOKEN:-}
if [ -z "$token" ] && [ -r "$tokenfile" ]; then
  if [ -n "$(find "$tokenfile" -perm /077)" ]; then
    echo "chbox: warning: $tokenfile is accessible by other users, chmod 600 it" >&2
  fi
  token=$(< "$tokenfile")
fi
# First run: create a long-lived token on the host and keep it for next time.
if [ -z "$token" ] && [ -t 0 ]; then
  # Ask first: setup-token's login screen is hard to back out of.
  read -rp "chbox: no Claude token yet. Create one now with 'claude setup-token'? [Y/n] " answer
  if [[ ! $answer =~ ^[Nn] ]] && claude setup-token; then
    read -rsp "chbox: paste the token shown above (empty to skip): " token
    echo >&2
    if [ -n "$token" ]; then
      mkdir -p "$(dirname "$tokenfile")"
      (umask 077; printf '%s\n' "$token" > "$tokenfile")
      echo "chbox: saved to $tokenfile" >&2
    fi
  fi
fi
if [ -n "$token" ]; then
  (umask 077; printf '%s\n' "$token" > "$rundir/guest/claude-token")
else
  echo "chbox: no Claude token, Claude will ask you to log in in the VM. To skip" >&2
  echo "       that, save a 'claude setup-token' token to $tokenfile" >&2
  echo "       (or export CLAUDE_CODE_OAUTH_TOKEN)." >&2
fi
git config --get user.name > "$rundir/guest/git-name" || true
git config --get user.email > "$rundir/guest/git-email" || true

setpriv --pdeathsig KILL virtiofsd \
  --socket-path="$rundir/guest.sock" \
  --shared-dir="$rundir/guest" \
  --readonly \
  --translate-uid="map:1000:$(id -u):1" \
  --translate-gid="map:100:$(id -g):1" \
  --sandbox=none \
  --log-level=error &

for sock in store repo guest; do
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
# Run as a job and wait: bash only handles signals (and so cleans up) between
# commands, and a foreground child would block that. Without job control a
# job's stdin would be /dev/null, so hand it the terminal explicitly.
CHBOX_RUNDIR=$rundir CHBOX_DISK=$disk CHBOX_CMDLINE=$cmdline CHBOX_HOST_ADDRS=$host_addrs \
  setpriv --pdeathsig KILL pasta --quiet --foreground --config-net -4 \
    --map-host-loopback none --dns-forward "$DNS_FWD" \
    -t none -u none -T none -U none \
    -- "$0" --in-netns <&0 &
wait $!
