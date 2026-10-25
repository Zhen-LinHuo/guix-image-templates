#!/bin/bash
# verify-medium-guard.sh — prove the installer cannot erase its own medium.
#
# Three layouts, booted for real, driven over the serial console:
#
#   A  CD medium, virtio internal disk      install proceeds on /dev/vda
#   B  USB medium (kernel names it sda)     install REFUSES /dev/sda
#   C  CD medium, USB disk as the target    install proceeds on /dev/sda
#
# C is the case a blanket "refuse removable devices" rule would break: an
# onboard USB DOM holding the system while the SATA bays hold the data disks.
#
# Usage: verify-medium-guard.sh <iso> [workdir]
# Needs: qemu-system-x86_64 with KVM, qemu-img, python3.
set -uo pipefail

ISO=${1:?usage: verify-medium-guard.sh <iso> [workdir]}
W=${2:-/tmp/medium-guard}
mkdir -p "$W"

fail=0
note() { printf '\n=== %s ===\n' "$*"; }
ok()   { printf 'PASS: %s\n' "$*"; }
bad()  { printf 'FAIL: %s\n' "$*"; fail=1; }

# Drive the serial console: wait for the root shell, run each command, print.
drive() {  # drive <socket> <command file>
  python3 - "$1" "$2" <<'PY'
import socket, sys, time, select
sock, cmds = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
for _ in range(90):
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
            if not d: return
            buf += d.decode("utf-8", "replace")
# the prompt is printed before we attach: nudge with empty lines
for _ in range(60):
    s.sendall(b"\n")
    pump(3)
    if "# " in buf: break
for line in open(cmds).read().splitlines():
    if line.strip() and not line.startswith("#"):
        s.sendall((line + "\n").encode())
        pump(8)
pump(6)
sys.stdout.write(buf)
PY
}

boot() {  # boot <name> <extra qemu args...>
  local name=$1; shift
  kill "$(cat "$W/$name.pid" 2>/dev/null)" 2>/dev/null
  sleep 1
  rm -f "$W/$name.sock"
  setsid qemu-system-x86_64 -enable-kvm -cpu host -m 3072 -smp 2 \
    "$@" -display none -monitor none \
    -serial unix:"$W/$name.sock",server=on,wait=off \
    -pidfile "$W/$name.pid" < /dev/null > "$W/$name.out" 2>&1 &
  sleep 70
}

stop() { kill "$(cat "$W/$1.pid" 2>/dev/null)" 2>/dev/null; }

[ -f "$W/target.img" ] || qemu-img create -f raw "$W/target.img" 12G >/dev/null
[ -f "$W/dom.img" ]    || qemu-img create -f raw "$W/dom.img" 8G >/dev/null

# ---------------------------------------------------------------- A: CD + disk
note "A: CD medium, internal disk"
boot a -cdrom "$ISO" -drive file="$W/target.img",if=virtio,format=raw -device virtio-rng-pci
cat > "$W/a.cmds" <<'EOF'
bash /etc/install/install.sh --erase /dev/vda
EOF
out_a=$(drive "$W/a.sock" "$W/a.cmds"); stop a
case "$out_a" in
  *"partitioning /dev/vda"*) ok "install proceeds on the internal disk" ;;
  *) bad "install did not proceed on /dev/vda"; printf '%s\n' "$out_a" | tail -5 ;;
esac

# ------------------------------------------------- B: the medium IS /dev/sda
note "B: USB medium, kernel names it /dev/sda"
[ -f "$W/usb.img" ] || { qemu-img create -f raw "$W/usb.img" 2G >/dev/null; dd if="$ISO" of="$W/usb.img" bs=8M conv=notrunc status=none; }
boot b \
  -drive file="$W/usb.img",if=none,id=u1,format=raw \
  -device qemu-xhci,id=xhci -device usb-storage,drive=u1,bus=xhci.0,bootindex=1 \
  -drive file="$W/target.img",if=none,id=t1,format=raw \
  -device virtio-blk-pci,drive=t1,bootindex=2 -device virtio-rng-pci
cat > "$W/b.cmds" <<'EOF'
lsblk -o NAME,TRAN,SIZE,TYPE
bash /etc/install/install.sh /dev/sda
EOF
out_b=$(drive "$W/b.sock" "$W/b.cmds"); stop b
case "$out_b" in
  *"carries the running installation medium"*) ok "the medium is refused by name" ;;
  *) bad "the installer did not refuse the USB medium"; printf '%s\n' "$out_b" | tail -6 ;;
esac
case "$out_b" in
  *"partitioning /dev/sda"*) bad "the installer started partitioning the medium" ;;
esac

# ------------------------------------------ C: USB disk as the TARGET (DOM)
note "C: CD medium, USB disk as the target"
boot c \
  -drive file="$ISO",media=cdrom,if=none,id=cd0,readonly=on \
  -device ide-cd,drive=cd0,bootindex=1 \
  -drive file="$W/dom.img",if=none,id=u2,format=raw \
  -device qemu-xhci,id=id2 -device usb-storage,drive=u2,bus=id2.0,bootindex=2 \
  -device virtio-rng-pci
cat > "$W/c.cmds" <<'EOF'
bash /etc/install/install.sh --erase /dev/sda
EOF
out_c=$(drive "$W/c.sock" "$W/c.cmds"); stop c
case "$out_c" in
  *"partitioning /dev/sda"*) ok "a USB target is allowed (onboard-DOM layout)" ;;
  *) bad "a USB target was refused although it is not the medium"; printf '%s\n' "$out_c" | tail -5 ;;
esac

printf '\n'
[ "$fail" -eq 0 ] && { echo "ALL THREE LAYOUTS BEHAVE AS INTENDED"; exit 0; }
echo "SOME LAYOUTS FAILED"; exit 1
