#!/bin/bash
# provision-mihomo.sh — install a subscription config on a host built from
# systems/nas.scm, with the shared DNS/geodata fragment merged in.
#
# The image deliberately ships WITHOUT a subscription: node credentials must
# never be baked into a store path.  This script is the other half — it runs on
# the installed host (or against it) and puts a config in place atomically.
#
# Usage:
#   provision-mihomo.sh --config FILE          # check only, shows the diff
#   provision-mihomo.sh --config FILE --apply  # write, validate, restart
#   provision-mihomo.sh --rollback             # restore the newest backup
#
# Options:
#   --dir DIR         mihomo working directory (default /var/lib/mihomo)
#   --fragment FILE   DNS fragment to merge (default: alongside this script,
#                     ../templates/services/mihomo-dns.fragment.yaml)
#   --config FILE     subscription YAML, or "-" to read stdin
#   --apply           actually write and restart (default is a dry run)
#   --rollback        restore the newest config.yaml.bak-* and restart
#   --no-restart      write and validate, but do not touch the running service
#
# Merge policy: the fragment OWNS these top-level keys — dns, geodata-mode,
# geo-auto-update, geox-url, geodata-loader.  Whatever the subscription says
# about them is removed (a duplicate key in YAML is a silent "last one wins",
# which is exactly how a subscription quietly re-enables fake-ip).  Everything
# else in the subscription is copied verbatim.

set -euo pipefail

DIR=/var/lib/mihomo
FRAGMENT=""
CONFIG=""
APPLY=0
ROLLBACK=0
RESTART=1

FRAGMENT_KEYS="dns geodata-mode geo-auto-update geox-url geodata-loader"

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "[provision-mihomo] $*"; }

# Non-interactive SSH may give us a bare PATH; the Guix System profile carries curl,
# awk and herd.  Do NOT source /etc/profile: on Guix System it ends the shell early
# (measured — the script silently stopped right after sourcing it).
PATH=/run/current-system/profile/bin:/run/current-system/profile/sbin:$PATH
export PATH

# mihomo is a service dependency, NOT part of the system profile, so it is
# usually absent from PATH.  Resolve it from the running process first (that is
# authoritative), then the store, and only then PATH.
find_mihomo() {
  if [ -n "${MIHOMO_BIN:-}" ]; then echo "$MIHOMO_BIN"; return; fi
  if command -v mihomo >/dev/null 2>&1; then command -v mihomo; return; fi
  pid=$(pgrep -x mihomo 2>/dev/null | head -1) || pid=""
  if [ -n "$pid" ] && [ -e "/proc/$pid/exe" ]; then readlink -f "/proc/$pid/exe"; return; fi
  ls -1 /gnu/store/*-mihomo-*/bin/mihomo 2>/dev/null | sort | tail -1
}
MIHOMO=$(find_mihomo)
[ -n "$MIHOMO" ] && [ -x "$MIHOMO" ] || die "cannot locate the mihomo binary (set MIHOMO_BIN)"

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)       DIR=$2; shift 2 ;;
    --fragment)  FRAGMENT=$2; shift 2 ;;
    --config)    CONFIG=$2; shift 2 ;;
    --apply)     APPLY=1; shift ;;
    --rollback)  ROLLBACK=1; shift ;;
    --no-restart) RESTART=0; shift ;;
    -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
    *)           die "unknown argument: $1" ;;
  esac
done

[ -d "$DIR" ] || die "mihomo directory missing: $DIR"

TARGET="$DIR/config.yaml"

restart_mihomo() {
  [ "$RESTART" -eq 1 ] || { say "restart skipped (--no-restart)"; return 0; }
  if command -v herd >/dev/null 2>&1; then
    herd restart mihomo >/dev/null 2>&1 || die "herd restart mihomo failed (see /var/log/mihomo.log)"
  else
    die "no 'herd' on PATH: this script expects a Guix System host"
  fi
  # A restart that returns 0 is not proof the core came up: wait for the API.
  for _ in $(seq 1 20); do
    if curl -fsS -m 2 http://127.0.0.1:9090/version >/dev/null 2>&1; then
      say "mihomo is up (controller answered)"
      return 0
    fi
    sleep 1
  done
  die "mihomo did not answer on the controller after restart; check /var/log/mihomo.log"
}

if [ "$ROLLBACK" -eq 1 ]; then
  BAK=$(ls -1t "$DIR"/config.yaml.bak-* 2>/dev/null | head -1) || true
  [ -n "$BAK" ] || die "no backup to roll back to in $DIR"
  say "rolling back to $BAK"
  install -m 0600 "$BAK" "$TARGET"
  "$MIHOMO" -t -d "$DIR" -f "$TARGET" >/dev/null 2>&1 || die "restored config fails validation"
  restart_mihomo
  say "rollback complete"
  exit 0
fi

# Rollback does not merge anything, so the fragment is resolved only past that
# branch — otherwise "provision-mihomo.sh --rollback" run from /tmp dies on a
# missing fragment path it never needed.
[ -n "$FRAGMENT" ] || FRAGMENT="$(cd "$(dirname "$0")/.." && pwd)/modules/templates/services/mihomo-dns.fragment.yaml"
[ -r "$FRAGMENT" ] || die "fragment not readable: $FRAGMENT"

[ -n "$CONFIG" ] || die "--config is required (or use --rollback)"
if [ "$CONFIG" = "-" ]; then
  TMP_SRC=$(mktemp)
  cat > "$TMP_SRC"
  CONFIG=$TMP_SRC
fi
[ -r "$CONFIG" ] || die "config not readable: $CONFIG"

# --- merge -------------------------------------------------------------------
# Strip the fragment-owned top-level keys from the subscription, keep the rest
# byte-for-byte, then append the fragment.
MERGED=$(mktemp)
trap 'rm -f "$MERGED"' EXIT

awk -v keys="$FRAGMENT_KEYS" '
  BEGIN { n = split(keys, k, " "); for (i = 1; i <= n; i++) owned[k[i]] = 1 }
  {
    if (match($0, /^[A-Za-z0-9_-]+:/)) {
      key = substr($0, 1, RLENGTH - 1)
      skip = (key in owned)
    }
    if (!skip) print
  }
' "$CONFIG" > "$MERGED"

# Drop trailing blank lines from the subscription part so the fragment does not
# end up separated by a run of empties (cosmetic, but the diff is reviewed).
sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$MERGED" 2>/dev/null || true
{ cat "$MERGED"; echo; cat "$FRAGMENT"; } > "$MERGED.final"
MERGED=$MERGED.final
trap 'rm -f "$MERGED" "$MERGED.final"' EXIT

# Validate before touching the live file: a config that fails "mihomo -t" would
# otherwise take the resolver down and leave the host without DNS.
VALID=$(mktemp -d)
cp "$MERGED" "$VALID/config.yaml"
# Geo files must be visible to the tester, or every geosite: rule looks broken.
for f in GeoSite.dat GeoIP.dat; do
  [ -f "$DIR/$f" ] && cp "$DIR/$f" "$VALID/$f"
done
if ! "$MIHOMO" -t -d "$VALID" -f "$VALID/config.yaml" >/tmp/provision-mihomo-test.log 2>&1; then
  tail -5 /tmp/provision-mihomo-test.log >&2
  die "merged config fails validation; nothing was written"
fi
say "merged config validates (mihomo -t)"
rm -rf "$VALID"

if [ -f "$TARGET" ]; then
  say "current config: $(wc -l < "$TARGET") lines; merged: $(wc -l < "$MERGED") lines"
  if cmp -s "$MERGED" "$TARGET"; then
    say "no change; leaving the running config alone"
    exit 0
  fi
fi

if [ "$APPLY" -eq 0 ]; then
  say "dry run — diff against the live config:"
  diff -u "$TARGET" "$MERGED" 2>/dev/null | head -60 || true
  say "re-run with --apply to install"
  exit 0
fi

if [ -f "$TARGET" ]; then
  BAK="$TARGET.bak-$(date +%Y%m%d%H%M%S)"
  cp -p "$TARGET" "$BAK"
  chmod 600 "$BAK"
  say "backup: $BAK"
fi
install -m 0600 -o root -g root "$MERGED" "$TARGET"
say "installed $TARGET (0600 root:root)"
restart_mihomo
say "done — resolve something: getent hosts example.com"
