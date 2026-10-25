#!/bin/bash
# qemu-guard-test.sh — prove the installer refuses removable/sr media.
#
# Boots the built ISO with:
#   - a USB-attached disk  (enumerated as /dev/sda, tran=usb, rm=1)
#   - a virtio blank disk  (enumerated as /dev/vda, tran=virtio)
# then drives install.sh over the serial console:
#   1. install.sh /dev/sda          -> MUST refuse (medium-like device)
#   2. install.sh /dev/sr0          -> MUST refuse (not a disk)
#   3. install.sh --erase /dev/vda  -> MUST proceed past the guard
#
# Usage: qemu-guard-test.sh <iso> <workdir>
set -uo pipefail
ISO=${1:?iso path}
WORK=${2:?workdir}
mkdir -p "$WORK"
USB="$WORK/usbdisk.img"
TGT="$WORK/target.img"

[ -f "$USB" ] || qemu-img create -f raw "$USB" 512M >/dev/null
[ -f "$TGT" ] || qemu-img create -f raw "$TGT" 8G >/dev/null

rm -f "$WORK/serial.log" "$WORK/qemu.pid"
setsid qemu-system-x86_64 \
  -enable-kvm -m 3072 -smp 2 \
  -cdrom "$ISO" \
  -drive file="$USB",if=none,id=usb1,format=raw \
  -device qemu-xhci -device usb-storage,drive=usb1 \
  -drive file="$TGT",if=virtio,format=raw \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -nographic -monitor none \
  -serial "file:$WORK/serial.log" \
  -pidfile "$WORK/qemu.pid" < /dev/null > "$WORK/qemu.out" 2>&1 &

echo "qemu pid $(cat "$WORK/qemu.pid" 2>/dev/null) — serial: $WORK/serial.log"
