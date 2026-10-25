#!/bin/bash
# install.sh — unattended install of the target appliance onto a disk.
#
# Runs from the installer medium (media/installer-iso.scm), where these are
# pre-placed by the image:
#   /etc/install/target.scm   the operating-system to install
#   /etc/install/modules/     the channel modules that config imports
#
# Refuses to touch anything unless a target is named explicitly.  Destroying the
# wrong disk is the one mistake an unattended installer must not be able to make,
# so a disk is selected by serial or by path, never "the first one we found".
#
#   install.sh /dev/sda                 # BIOS-free: GPT + ESP + ext4 root
#   install.sh --erase /dev/nvme0n1     # same, for a disk with existing data
#
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

PATH=/run/current-system/profile/bin:/run/current-system/profile/sbin:$PATH

TARGET_SCM=${TARGET_SCM:-/etc/install/target.scm}
MODULES=${MODULES:-/etc/install/modules}
MOUNT=${MOUNT:-/mnt}

die() { printf 'install: %s\n' "$*" >&2; exit 1; }
say() { printf 'install: %s\n' "$*" >&2; }

[ $# -ge 1 ] || die "usage: install.sh [--erase] <disk>   e.g. install.sh /dev/sda"

ERASE=0
if [ "$1" = "--erase" ]; then ERASE=1; shift; fi
DISK=$1

[ -b "$DISK" ] || die "$DISK is not a block device"
[ -r "$TARGET_SCM" ] || die "missing target config: $TARGET_SCM"
[ -d "$MODULES" ] || die "missing module tree: $MODULES"

# Refuse a disk that clearly holds something, unless --erase says otherwise.
if [ "$ERASE" -eq 0 ]; then
  if blkid "$DISK" >/dev/null 2>&1 || lsblk -no NAME "$DISK" | tail -n +2 | grep -q .; then
    die "$DISK already has partitions or a filesystem; re-run with --erase to wipe it"
  fi
fi

say "partitioning $DISK (GPT, 512M ESP, ext4 root)"
wipefs -a "$DISK"
parted -s "$DISK" mklabel gpt \
  mkpart ESP fat32 1MiB 513MiB set 1 esp on \
  mkpart root ext4 513MiB 100%

# Device names for the partitions we just made (sda1 / nvme0n1p1 / vda1).
case "$DISK" in
  *[0-9]) P1="${DISK}p1"; P2="${DISK}p2" ;;
  *)      P1="${DISK}1";  P2="${DISK}2"  ;;
esac
partprobe "$DISK" 2>/dev/null || true
sleep 2
[ -b "$P1" ] || die "partition $P1 did not appear"
[ -b "$P2" ] || die "partition $P2 did not appear"

say "formatting: $P1 -> vfat (nas-esp), $P2 -> ext4 (nas-root)"
mkfs.fat -F32 -n nas-esp "$P1"
mkfs.ext4 -q -F -L nas-root "$P2"

mkdir -p "$MOUNT"
mount "$P2" "$MOUNT"
mkdir -p "$MOUNT/boot/efi"
mount "$P1" "$MOUNT/boot/efi"

say "installing the system (this copies the store and installs the bootloader)"
# -L makes (templates …) importable from the medium's copy of the channel; the
# config is absolute because -L resolves modules, not the config path.
guix system init -L "$MODULES" "$TARGET_SCM" "$MOUNT"

say "installation complete on $DISK; syncing"
sync
umount -R "$MOUNT"
say "done — remove the medium and boot the disk"
