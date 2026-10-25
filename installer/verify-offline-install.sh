#!/bin/bash
# verify-offline-install.sh — install with no network, then boot what was installed.
#
# The medium claims to be self-contained.  The only honest test is a VM with no
# network device at all: install from it, remove it, boot the disk.
#
# Usage: verify-offline-install.sh <iso> [workdir] [install-timeout-seconds]
set -uo pipefail
ISO=${1:?usage: verify-offline-install.sh <iso> [workdir] [timeout]}
W=${2:-/tmp/offline-install}
LIMIT=${3:-3600}
mkdir -p "$W"
DISK=$W/installed.img
[ -f "$DISK" ] || qemu-img create -f raw "$DISK" 20G >/dev/null

# serial <socket> <commands file|-> <linger> [wait-for-substring]
serial() {
  python3 - "$@" <<'PY'
import socket, sys, time, select
sock, cmds, linger = sys.argv[1], sys.argv[2], int(sys.argv[3])
wait_for = sys.argv[4] if len(sys.argv) > 4 else None
limit = int(sys.argv[5]) if len(sys.argv) > 5 else 300
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
for _ in range(180):
    try:
        s.connect(sock); break
    except OSError:
        time.sleep(2)
else:
    sys.exit("cannot connect to the serial console")
buf = ""
def pump(sec):
    global buf
    end = time.time() + sec
    while time.time() < end:
        r, _, _ = select.select([s], [], [], 0.5)
        if r:
            d = s.recv(65536)
            if not d: return False
            buf += d.decode("utf-8", "replace")
    return True
for _ in range(60):
    s.sendall(b"\n"); pump(3)
    if "# " in buf: break
if cmds != "-":
    for line in open(cmds).read().splitlines():
        if line.strip() and not line.startswith("#"):
            s.sendall((line + "\n").encode()); pump(linger)
if wait_for:
    end = time.time() + limit
    while time.time() < end and wait_for not in buf:
        pump(5)
sys.stdout.write(buf)
PY
}

boot() {  # boot <name> <seconds> <args...>
  local name=$1 secs=$2; shift 2
  kill "$(cat "$W/$name.pid" 2>/dev/null)" 2>/dev/null; sleep 1
  rm -f "$W/$name.sock"
  setsid qemu-system-x86_64 -enable-kvm -cpu host -m 4096 -smp 4 \
    "$@" -display none -monitor none \
    -serial unix:"$W/$name.sock",server=on,wait=off \
    -pidfile "$W/$name.pid" < /dev/null > "$W/$name.out" 2>&1 &
  sleep "$secs"
}
stop() { kill "$(cat "$W/$1.pid" 2>/dev/null)" 2>/dev/null; }

printf '=== install with no network device ===\n'
boot install 80 \
  -cdrom "$ISO" \
  -drive file="$DISK",if=virtio,format=raw \
  -device virtio-rng-pci -net none
printf 'ls /etc/install\nbash /etc/install/install.sh --erase /dev/vda\n' > "$W/install.cmds"
out=$(serial "$W/install.sock" "$W/install.cmds" 20 "done — remove the medium" "$LIMIT")
stop install
printf '%s\n' "$out" | grep -aE "install:|error|substitut|download|Unbound|no code" | tail -25

if printf '%s' "$out" | grep -q "done — remove the medium"; then
  printf '\nPASS: installed through the medium alone\n'
else
  printf '\nFAIL: the install did not finish offline\n'; exit 1
fi
if printf '%s' "$out" | grep -qiE "would be downloaded|substitute: looking|http://|https://" ; then
  printf 'note: output mentions the network — inspect before believing the closure is baked\n'
fi

printf '\n=== boot the installed disk (medium removed, no network) ===\n'
boot installed 80 \
  -drive file="$DISK",if=virtio,format=raw \
  -device virtio-rng-pci -net none
printf 'findmnt -no SOURCE,FSTYPE / ; lsblk -o NAME,SIZE,MOUNTPOINT ; herd status 2>/dev/null | head -8\n' > "$W/installed.cmds"
out2=$(serial "$W/installed.sock" "$W/installed.cmds" 10)
stop installed
printf '%s\n' "$out2" | tail -20

case "$out2" in
  *nas-root*) printf '\nPASS: the installed disk boots into its own root filesystem\n'; exit 0 ;;
  *) printf '\nFAIL: the installed disk did not come up\n'; exit 1 ;;
esac
