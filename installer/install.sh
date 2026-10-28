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
#   install.sh /dev/sda                 # GPT + ESP + the medium's filesystem
#   install.sh --erase /dev/nvme0n1     # same, for a disk with existing data
#
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

PATH=/run/current-system/profile/bin:/run/current-system/profile/sbin:$PATH

TARGET_SCM=${TARGET_SCM:-/etc/install/target.scm}
MODULES=${MODULES:-/etc/install/modules}
MOUNT=${MOUNT:-/mnt}
# The medium is built for one filesystem, and the target config next to it was
# built for the same one: the value is baked into the image rather than taken
# from the command line, so a medium cannot be pointed at a layout its target
# does not expect.
ROOT_FS=$(cat /etc/install/root-fs 2>/dev/null | tr -d '[:space:]')
ROOT_FS=${ROOT_FS:-ext4}
# The target config is evaluated *here*, at install time, and it reads this same
# variable to decide the root filesystem and whether the initrd needs the btrfs
# module.  Without exporting it the medium formats btrfs while the system it
# writes still describes an ext4 root — the machine then installs cleanly and
# never mounts its own root.
export GUIX_TEMPLATES_ROOT_FS="$ROOT_FS"

die() { printf 'install: %s\n' "$*" >&2; exit 1; }
say() { printf 'install: %s\n' "$*" >&2; }

[ $# -ge 1 ] || die "usage: install.sh [--erase] [--allow-removable] <disk>"

ERASE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --erase) ERASE=1; shift ;;
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *) break ;;
  esac
done
DISK=${1:-}
[ -n "$DISK" ] || die "usage: install.sh [--erase] [--allow-removable] <disk>"

[ -b "$DISK" ] || die "$DISK is not a block device"
[ -r "$TARGET_SCM" ] || die "missing target config: $TARGET_SCM"
[ -d "$MODULES" ] || die "missing module tree: $MODULES"

# --- never install onto the medium we booted from -------------------------
# The one invariant is "the target must not be the disk we are running from".
# It is deliberately NOT "refuse removable/USB disks": installing the OS on an
# onboard USB DOM while the SATA bays hold the data disks is a normal NAS layout
# (and the reason this check exists at all — a USB stick is usually enumerated
# before the internal disk, so the medium is often /dev/sda).
DISK_NAME=$(basename "$(readlink -f "$DISK")")

# Encode a blkid UUID the way Guix writes root= on its installation image: the
# UUID's ASCII bytes in hex, e.g. "1970010122113383" ->
# "31393730303130313232313133333833".  Guix keeps a few of the original dashes
# in that string, so both sides are compared with dashes removed rather than
# trying to reproduce its exact placement.
encode_uuid() {
  printf '%s' "${1//-/}" | od -An -tx1 | tr -d ' \n'
}

# Print the device node the kernel was told to use as root, if it names one.
root_device_from_cmdline() {
  local root uuid dev
  root=$(tr ' ' '\n' < /proc/cmdline | sed -n 's/^root=//p' | head -1)
  [ -n "$root" ] || return 1
  case "$root" in
    /dev/*) [ -b "$root" ] && { readlink -f "$root"; return 0; } ;;
    UUID=*|PARTUUID=*) root=${root#*=} ;;
  esac
  # Skip floppy/loop pseudo-disks: probing them logs I/O errors and can never
  # be the medium.
  # "rom" is in the scan on purpose: booting from a CD means the medium is the
  # optical drive, and it must be recognised so it can be compared and refused.
  for dev in $(lsblk -ndo NAME,TYPE | awk '$2 ~ /^(disk|rom)$/ && $1 !~ /^(fd|loop)/ { print "/dev/" $1 }'); do
    uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null) || continue
    [ -n "$uuid" ] || continue
    if [ "$uuid" = "$root" ] || [ "$(encode_uuid "$uuid")" = "${root//-/}" ]; then
      printf '%s\n' "$dev"
      return 0
    fi
  done
  return 1
}

# Print the name of the disk carrying the running system, or nothing.
boot_medium_disk() {
  local probe src parent dev
  for probe in "$(findmnt -no SOURCE / 2>/dev/null)" \
               "$(findmnt -no SOURCE /run/root 2>/dev/null)" \
               "$(findmnt -no SOURCE /run/booted-system 2>/dev/null)" \
               "$(findmnt -no SOURCE /gnu/store 2>/dev/null)"; do
    [ -n "$probe" ] || continue
    src=${probe%%\[*}
    [ -b "$src" ] || continue
    parent=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1 | tr -d ' ')
    if [ -n "$parent" ]; then
      printf '%s\n' "$parent"
    else
      basename "$(readlink -f "$src")"
    fi
    return 0
  done
  src=$(awk '$3 == "iso9660" || $3 == "squashfs" { print $1; exit }' /proc/mounts)
  if [ -n "$src" ] && [ -b "$src" ]; then
    parent=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1 | tr -d ' ')
    printf '%s\n' "${parent:-$(basename "$(readlink -f "$src")")}"
    return 0
  fi
  # A live medium has no block device behind / (it is an overlay), and the
  # squashfs is already gone by the time this runs — but the kernel was told
  # which device to mount, so ask that device instead.
  dev=$(root_device_from_cmdline) || return 1
  parent=$(lsblk -no PKNAME "$dev" 2>/dev/null | head -1 | tr -d ' ')
  printf '%s\n' "${parent:-$(basename "$dev")}"
}

MEDIUM_DISK=$(boot_medium_disk) || MEDIUM_DISK=""
if [ -z "$MEDIUM_DISK" ]; then
  printf 'install: warning: could not identify the device this system booted from;\n' >&2
  printf 'install:          %s will be written without that cross-check\n' "$DISK" >&2
elif [ "$MEDIUM_DISK" = "$DISK_NAME" ]; then
  die "$DISK carries the running installation medium (/dev/$MEDIUM_DISK).
     Refusing to erase the medium itself.  Name the internal data/system disk."
fi

# Optical media cannot be a target: the kernel reports type 5 for CD-ROM/DVD.
if [ "$(cat "/sys/block/$DISK_NAME/device/type" 2>/dev/null)" = "5" ]; then
  die "$DISK is optical media; pick a writable disk"
fi

# Refuse a disk that clearly holds something, unless --erase says otherwise.
if [ "$ERASE" -eq 0 ]; then
  if blkid "$DISK" >/dev/null 2>&1 || lsblk -no NAME "$DISK" | tail -n +2 | grep -q .; then
    die "$DISK already has partitions or a filesystem; re-run with --erase to wipe it"
  fi
fi

say "partitioning $DISK (GPT, 512M ESP, $ROOT_FS root)"
wipefs -a "$DISK"
parted -s "$DISK" mklabel gpt \
  mkpart ESP fat32 1MiB 513MiB set 1 esp on \
  mkpart root "$ROOT_FS" 513MiB 100%

# Device names for the partitions we just made (sda1 / nvme0n1p1 / vda1).
case "$DISK" in
  *[0-9]) P1="${DISK}p1"; P2="${DISK}p2" ;;
  *)      P1="${DISK}1";  P2="${DISK}2"  ;;
esac
partprobe "$DISK" 2>/dev/null || true
sleep 2
[ -b "$P1" ] || die "partition $P1 did not appear"
[ -b "$P2" ] || die "partition $P2 did not appear"

say "formatting: $P1 -> vfat (nas-esp), $P2 -> $ROOT_FS (nas-root)"
mkfs.fat -F32 -n nas-esp "$P1"

mkdir -p "$MOUNT"

case "$ROOT_FS" in
  ext4)
    mkfs.ext4 -q -F -L nas-root "$P2"
    mount "$P2" "$MOUNT"
    ;;
  btrfs)
    # A plain btrfs filesystem on the device we were given: one subvolume, no
    # RAID profile.  Redundancy, when it exists, was already built underneath —
    # mdadm owns arrays, and btrfs parity RAID is not something this medium
    # creates even on request.
    mkfs.btrfs -q -f -L nas-root "$P2" || die "mkfs.btrfs failed on $P2"
    mount "$P2" "$MOUNT" || die "could not mount $P2"
    btrfs subvolume create "$MOUNT/@" >/dev/null || die "could not create the @ subvolume"
    # GRUB reads the filesystem's *default* subvolume: with @ merely existing,
    # it looks at the top level, finds no /gnu/store, and the machine stops at
    # a bootloader with nothing to load.  Making @ the default is what puts the
    # system where the bootloader expects it, and it also means a plain mount
    # without options lands on the system rather than an empty top level.
    subvol_id=$(btrfs subvolume list "$MOUNT" | awk '$NF == "@" { print $2; exit }')
    [ -n "$subvol_id" ] || die "could not find the @ subvolume in $(btrfs subvolume list "$MOUNT")"
    btrfs subvolume set-default "$subvol_id" "$MOUNT" \
      || die "could not make @ ($subvol_id) the default subvolume"
    umount "$MOUNT"
    mount -o "subvol=@,compress=zstd" "$P2" "$MOUNT" \
      || die "could not mount the @ subvolume"
    ;;
  *)
    die "unsupported root filesystem '$ROOT_FS' (ext4 or btrfs)"
    ;;
esac

mkdir -p "$MOUNT/boot/efi"
mount "$P1" "$MOUNT/boot/efi"

say "installing the system (this copies the store and installs the bootloader)"
# -L makes (templates …) importable from the medium's copy of the channel; the
# config is absolute because -L resolves modules, not the config path.
# The target config imports modules from channels the medium was built with
# (a kernel channel, the panel module).  Their sources are baked next to ours,
# because the installer's own guile does not know those channels: without them
# evaluation fails with "no code for module (nongnu packages linux)".
# The appliance's proxy packages read geodata at evaluation time; the copies on
# the medium are authoritative, so no network fetch is attempted.
if [ -d /etc/install/geodata ]; then
  export GUIX_TEMPLATES_GEODATA=/etc/install/geodata
fi

LOAD_PATH_ARGS=()
for extra in /etc/install/extra/*; do
  [ -d "$extra" ] && LOAD_PATH_ARGS+=(-L "$extra")
done

# Substitutes: the medium carries the list its build was configured with.  The
# nonguix server has to be in it — the target boots the nonguix kernel, and
# without a binary for it the install turns into a source build of Linux.
SUBSTITUTE_ARGS=()
if [ -r /etc/install/substitute-urls ]; then
  SUBSTITUTE_ARGS=(--substitute-urls="$(tr -d '\n' < /etc/install/substitute-urls)")
fi

# A baked medium carries the target's closure.  Say plainly whether the system
# this machine derives is the one that was baked — if it is not, the closure on
# the disc is dead weight and the install will reach for substitutes instead.
BAKED=$(cat /etc/install/baked-system 2>/dev/null || true)
if [ -n "$BAKED" ]; then
  PROBE_ERR=$(mktemp)
  WANT=$(guix system build --no-grafts -d ${LOAD_PATH_ARGS[@]+"${LOAD_PATH_ARGS[@]}"} \
           -L "$MODULES" "$TARGET_SCM" 2>"$PROBE_ERR" | tail -1 || true)
  if [ -z "$WANT" ]; then
    say "warning: cannot derive the target system; the last lines were:"
    tail -5 "$PROBE_ERR" | sed 's/^/         /' >&2
  fi
  rm -f "$PROBE_ERR"
  if [ "$WANT" = "$BAKED" ]; then
    say "using the closure baked into this medium"
  else
    say "note: baked system is $BAKED"
    say "      this machine derives $WANT"
    say "      the baked closure will not be reused"
  fi
fi

# Every derivation this install computes must be computed the same way the
# medium was built, including the boot config that `init' generates here.  The
# flag on the command line is not enough: nested evaluations (bootcfg) can still
# run with grafting on and produce a derivation whose build inputs are not on
# this medium.  GUIX_BUILD_OPTIONS covers all of them.
export GUIX_BUILD_OPTIONS="--no-grafts${GUIX_BUILD_OPTIONS:+ $GUIX_BUILD_OPTIONS}"

# --no-grafts, deliberately: computing a grafted derivation requires building
# the ungrafted packages first, and those build inputs are not part of any
# runtime closure — on a medium with no network that is the difference between
# "reuses the baked closure" and "starts compiling coreutils from source".
# The price is paid once at first `guix pull`/reconfigure, which grafts the
# installed system normally.
guix system init --verbosity=1 --no-grafts \
  ${SUBSTITUTE_ARGS[@]+"${SUBSTITUTE_ARGS[@]}"} \
  ${LOAD_PATH_ARGS[@]+"${LOAD_PATH_ARGS[@]}"} \
  -L "$MODULES" "$TARGET_SCM" "$MOUNT"

say "installation complete on $DISK; syncing"
sync
umount -R "$MOUNT"
say "done — remove the medium and boot the disk"
