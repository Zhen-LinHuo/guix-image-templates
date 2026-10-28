#!/bin/bash
# auto-install.sh — decide from the kernel command line whether to install.
#
# Runs once at boot on the installation medium.  Doing the parsing here rather
# than inside a Shepherd gexp keeps the service definition free of host-side
# procedures that would not exist on the target.
#
#   install.disk=/dev/sda     install to this disk
#   install.erase=1           wipe a disk that already holds data
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
set -- "$disk"
[ "$erase" = "1" ] && set -- --erase "$disk"

printf 'auto-install: installing to %s (erase=%s)\n' "$disk" "${erase:-0}" >&2

# Mirror progress onto the console: the service's output goes to a log file, and
# an unattended install that says nothing on the serial line is indistinguishable
# from one that hung.
[ -w /dev/console ] && exec > >(tee -a /dev/console) 2>&1

# Via bash, not exec: the script arrives from the store as a plain file with no
# execute bit, so executing it directly fails with EACCES at the rack.
#
# A child process rather than `exec`, because the exit status decides whether
# this machine powers off: a failed install must leave the live system up.
# An operator needs the shell and the logs, and a machine that switched itself
# off after failing is indistinguishable from one that succeeded.
bash /etc/install/install.sh "$@"
status=$?

if [ "$status" -ne 0 ]; then
  printf '\nauto-install: install.sh exited %s — the live system stays up for inspection\n' \
         "$status" >&2
  exit "$status"
fi

cat <<'EOM'

  Installation finished.

    1. Remove the installation medium (USB stick or disc).
    2. Fit the storage disks this machine is meant to use.
    3. Power the machine on again — it boots from the installed disk.

  Powering off now.
EOM
# Flush the filesystem above all: the medium can be pulled the moment the
# machine goes dark.
sync
# shepherd's halt is the normal path; the syscall route is the fallback for the
# live profile, which may not carry it.
halt 2>/dev/null || poweroff 2>/dev/null || printf o > /proc/sysrq-trigger
