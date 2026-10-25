#!/bin/bash
# Test B: the medium lives on a USB disk, which the kernel names /dev/sda.
# The installer must refuse it — that is the case this check exists for.
#
# bootindex puts explicit ordering on the devices: QEMU otherwise enumerates the
# virtio disk first and "boot the USB stick" silently boots the empty target.
set -uo pipefail
ISO=$(readlink -f /tmp/nas-installer.iso)
W=/tmp/guardtest
mkdir -p "$W"
[ -f "$W/usb.img" ] || { qemu-img create -f raw "$W/usb.img" 2G >/dev/null; dd if="$ISO" of="$W/usb.img" bs=8M conv=notrunc status=none; }
[ -f "$W/tgt.img" ] || qemu-img create -f raw "$W/tgt.img" 12G >/dev/null
rm -f "$W/ser.sock" "$W/serial.txt"

setsid qemu-system-x86_64 \
  -enable-kvm -m 3072 -smp 2 \
  -drive file="$W/usb.img",if=none,id=u1,format=raw \
  -device qemu-xhci,id=xhci \
  -device usb-storage,drive=u1,bus=xhci.0,bootindex=1 \
  -drive file="$W/tgt.img",if=none,id=t1,format=raw \
  -device virtio-blk-pci,drive=t1,bootindex=2 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -display none -monitor none \
  -serial unix:"$W/ser.sock",server=on,wait=off \
  -pidfile "$W/qemu.pid" < /dev/null > "$W/qemu.out" 2>&1 &

sleep 3
echo "qemu $(cat "$W/qemu.pid" 2>/dev/null)"
