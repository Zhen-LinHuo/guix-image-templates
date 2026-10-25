#!/bin/sh
# sdwan-join — put this host on the overlay networks.
#
# Membership data is CREDENTIALS: setup keys, network ids and shared secrets.
# They are never baked into the image; this script is the only place they land,
# and it writes them 0600 under /etc/sdwan/.
#
#   sdwan-join.sh --zerotier-network 8056c2e21c000001
#   sdwan-join.sh --netbird-key ABCD-EFGH --netbird-mgmt https://nb.example
#   sdwan-join.sh --easytier-config ./et.toml
#
# Any combination is allowed; each transport is independent.  Afterwards the
# corresponding shepherd unit is restarted and verified.
set -eu

ZONE=/etc/sdwan
ZP_NET=""
NB_KEY=""
NB_MGMT=""
ET_CFG=""

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --zerotier-network) ZP_NET=${2:?}; shift 2 ;;
    --netbird-key)      NB_KEY=${2:?}; shift 2 ;;
    --netbird-mgmt)     NB_MGMT=${2:?}; shift 2 ;;
    --easytier-config)  ET_CFG=${2:?}; shift 2 ;;
    -h|--help)          usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 1 ;;
  esac
done

[ -n "$ZP_NET$NB_KEY$ET_CFG" ] || { echo "nothing to do (see --help)" >&2; exit 1; }

mkdir -p "$ZONE"
chmod 700 "$ZONE"

# --- ZeroTier -------------------------------------------------------------
if [ -n "$ZP_NET" ]; then
  printf '%s\n' "$ZP_NET" > "$ZONE/zerotier.network"
  chmod 600 "$ZONE/zerotier.network"
  herd restart zerotier
  # The daemon answers on its local control port once its identity exists.
  i=0
  while [ $i -lt 30 ]; do
    if zerotier-cli -D/var/lib/zerotier-one info >/dev/null 2>&1; then break; fi
    sleep 1; i=$((i+1))
  done
  zerotier-cli -D/var/lib/zerotier-one join "$ZP_NET" || true
  echo "zerotier: $(zerotier-cli -D/var/lib/zerotier-one listnetworks 2>/dev/null | tail -n +2 | head -3)"
fi

# --- NetBird --------------------------------------------------------------
if [ -n "$NB_KEY" ]; then
  mkdir -p /var/lib/netbird
  {
    echo "# written by sdwan-join: the setup key is single-use, rotate it after"
    echo "# the peer appears in the management UI."
  } > "$ZONE/netbird.readme"
  chmod 600 "$ZONE/netbird.readme"
  herd restart netbird
  i=0
  while [ $i -lt 30 ]; do
    if netbird status >/dev/null 2>&1; then break; fi
    sleep 1; i=$((i+1))
  done
  # `netbird up` registers the peer and stores the resulting config; the key is
  # not persisted in our own files (netbird keeps its own state under
  # /var/lib/netbird).
  if [ -n "$NB_MGMT" ]; then
    netbird up --setup-key "$NB_KEY" --management-url "$NB_MGMT"
  else
    netbird up --setup-key "$NB_KEY"
  fi
  netbird status | head -12
fi

# --- EasyTier -------------------------------------------------------------
if [ -n "$ET_CFG" ]; then
  [ -r "$ET_CFG" ] || { echo "cannot read $ET_CFG" >&2; exit 1; }
  install -m 600 "$ET_CFG" "$ZONE/easytier.toml"
  herd restart easytier
  sleep 2
  easytier-cli peer 2>/dev/null || echo "easytier: started, no peers yet"
fi

echo
echo "done.  Verify with:  zerotier-cli listnetworks | netbird status | easytier-cli peer"
