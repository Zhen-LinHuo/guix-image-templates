#!/bin/bash
# gate.sh — evaluate every entry point before building anything.
#
# `guix system image -n media/installer-iso.scm' does NOT load
# appliances/*/target.scm: the target is a local-file copied into the medium, not
# a module the ISO imports.  So a target config with a broken form — an unclosed
# paren, a symbol that never gets defined — evaluates to a perfectly good ISO and
# then fails on the machine being installed, which is the worst place to find out.
# Evaluate both.
#
# Usage: gate.sh            (uses GUIX_TEMPLATES_EXTRA_MODULES for extra -L dirs)
set -u

dir=$(cd "$(dirname "$0")/.." && pwd)
load=(-L "$dir/modules")
IFS=: read -r -a extra <<< "${GUIX_TEMPLATES_EXTRA_MODULES:-}"
for d in "${extra[@]}"; do [ -n "$d" ] && load+=(-L "$d"); done

fail=0
check() {  # check <what> <command...>
  local what=$1; shift
  local log; log=$(mktemp)
  if "$@" >"$log" 2>&1; then
    printf 'ok   %s\n' "$what"
  else
    printf 'FAIL %s\n' "$what"
    tail -15 "$log"
    fail=1
  fi
  rm -f "$log"
}

check "target system" guix system build -n "${load[@]}" "$dir/appliances/nas/target.scm"

# Every medium must at least describe a valid system...
for media in "$dir"/media/*.scm; do
  check "medium $(basename "$media")" guix system build -n "${load[@]}" "$media"
done

# ...and the one image type we build here must actually get to a derivation.
check "installer image (iso9660)" \
  guix system image -n -t iso9660 "${load[@]}" "$dir/media/installer-iso.scm"

[ "$fail" -eq 0 ] && { echo "all entry points evaluate"; exit 0; }
echo "some entry points do not evaluate"; exit 1
