#!/bin/bash
# auto-install.sh — decide from the kernel command line whether to install.
#
# Runs once at boot on the installation medium.  Doing the parsing here rather
# than inside a Shepherd gexp keeps the service definition free of host-side
# procedures that would not exist on the target.
#
#   install.disk=/dev/sda     install to this disk
#   install.erase=1           wipe a disk that already holds data
#   install.allow_removable=1 install onto a removable/USB disk on purpose
#
# With no install.disk=, the medium stays interactive (the console is yours).
#
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail

PATH=/run/current-system/profile/bin:/run/current-system/profile/sbin:$PATH

die() { printf 'auto-install: %s\n' "$*" >&2; exit 1; }

cmdline=$(cat /proc/cmdline)

arg() {
  # arg KEY -> value of KEY=… (first match), empty if absent
  printf '%s\n' "$cmdline" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1
}

disk=$(arg install.disk)
if [ -z "$disk" ]; then
  printf 'auto-install: no install.disk= on the kernel command line; staying interactive\n' >&2
  exit 0
fi

erase=$(arg install.erase)
allow_removable=$(arg install.allow_removable)
set -- "$disk"
[ "$erase" = "1" ] && set -- --erase "$disk"
[ "$allow_removable" = "1" ] && set -- --allow-removable "$@"

printf 'auto-install: installing to %s (erase=%s)\n' "$disk" "${erase:-0}" >&2
exec /etc/install/install.sh "$@"
