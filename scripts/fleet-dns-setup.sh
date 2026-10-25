#!/usr/bin/env bash
# fleet-dns-setup.sh — uniform encrypted-DNS layout for systemd fleet hosts.
#
# Why this shape (and how it differs from the Guix System image):
#
#   systemd hosts already have a resolver that understands per-link DNS: the
#   SD-WAN clients (NetBird/ZeroTier/EasyTier) hand their zone resolvers to
#   resolved, which routes each overlay zone to its own resolver.  Throwing that
#   away to run dnsmasq would mean re-implementing overlay zone routing.
#
#   What resolved cannot do is DoH (verified: the shipped binary contains no DoH
#   code; only DNSOverTLS).  So we keep resolved as the per-link authority and
#   make its DEFAULT path a local DoH forwarder:
#
#     apps → resolved :53 → ┬─ <overlay zone> → overlay resolver
#                           └─ everything else → 127.0.0.1:5353 dnsproxy → DoH/H3
#
#   Two settings make that stick, and both are required:
#     * DNS=127.0.0.1:5353 + Domains=~.  → the default route goes to dnsproxy
#     * ipv4/ipv6.ignore-auto-dns yes    → DHCP/RA servers never enter the picture
#       (without it, a link that got a router or ISP address still answers)
#
#   mihomo stays DNS-less: proxied names are resolved by the exit node, DIRECT
#   names by resolved→dnsproxy.  Never point resolved at mihomo (that is a loop).
#
# Usage:
#   fleet-dns-setup.sh --check                 # read-only report
#   fleet-dns-setup.sh --apply --binary PATH   # install + configure
#   fleet-dns-setup.sh --rollback              # restore previous files
#
# --apply is idempotent and backs up every file it touches as <file>.bak-<ts>.

set -uo pipefail

PROXY_PORT=5300   # 5353 is avahi/mDNS; never take it
UPSTREAM_H3_1="h3://dns.alidns.com/dns-query"
UPSTREAM_HT_1="https://dns.alidns.com/dns-query"
UPSTREAM_H3_2="h3://doh.pub/dns-query"
UPSTREAM_HT_2="https://doh.pub/dns-query"
UNIT=/etc/systemd/system/dnsproxy.service
DROPIN_DIR=/etc/systemd/resolved.conf.d
DROPIN="$DROPIN_DIR/50-doh-forwarding.conf"
BIN=/usr/local/bin/dnsproxy
TS=$(date +%Y%m%d%H%M%S)

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" = 0 ] || die "--apply/--rollback need root"; }

check() {
  say "== host =="
  say "host: $(hostname)   os: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
  say "resolved: $(systemctl is-active systemd-resolved 2>/dev/null)   NM: $(systemctl is-active NetworkManager 2>/dev/null)   dnsproxy unit: $(systemctl is-active dnsproxy 2>/dev/null)"
  say
  say "== resolv.conf =="
  grep -vE '^#|^$' /etc/resolv.conf 2>/dev/null | sed 's/^/  /'
  say
  say "== resolved global =="
  grep -hE '^(DNS|FallbackDNS|Domains|DNSOverTLS)=' /etc/systemd/resolved.conf "$DROPIN" 2>/dev/null | sed 's/^/  /' || say "  (none)"
  say
  say "== per-link DNS (overlay zones must appear here) =="
  resolvectl dns 2>/dev/null | sed 's/^/  /'
  say
  say "== DHCP DNS acceptance (should be 'yes' everywhere) =="
  flag() { nmcli -g "$1" connection show "$2" 2>/dev/null | head -1; }
  while IFS= read -r c; do
    printf '  %-32s ipv4=%-4s ipv6=%s\n' "$c" \
      "$(flag ipv4.ignore-auto-dns "$c")" "$(flag ipv6.ignore-auto-dns "$c")"
  done < <(nmcli -t -f NAME connection show 2>/dev/null | sort -u)
  say
  say "== forwarder =="
  if [ -x "$BIN" ]; then say "  binary: $BIN ($("$BIN" --version 2>&1 | head -1))"; else say "  binary: MISSING"; fi
  if ss -lun 2>/dev/null | grep -q ":$PROXY_PORT "; then say "  port $PROXY_PORT: listening"; else say "  port $PROXY_PORT: closed"; fi
  if [ -x "$BIN" ] && ss -lun 2>/dev/null | grep -q ":$PROXY_PORT "; then
    if command -v dig >/dev/null; then
      printf '  query via forwarder: '
      dig +short +time=3 +tries=1 @127.0.0.1 -p "$PROXY_PORT" www.alidns.com A | head -2 | tr '\n' ' '; printf '\n'
    fi
  fi
  say
  say "== end-to-end =="
  say "  resolvectl query www.alidns.com → $(resolvectl query www.alidns.com 2>&1 | head -2 | tr '\n' ' ')"
}

apply() {
  need_root
  local src="$1"
  [ -n "$src" ] || die "--apply needs --binary <path to static dnsproxy>"
  [ -x "$src" ] || die "$src is not executable"
  file "$src" | grep -q "statically linked" || say "WARNING: $src is not statically linked; it may need libraries on this host"

  say "== installing binary =="
  install -Dm0755 "$src" "$BIN"
  sha256sum "$BIN" | sed 's/^/  /'

  say "== systemd unit =="
  [ -f "$UNIT" ] && cp -a "$UNIT" "$UNIT.bak-$TS"
  cat > "$UNIT" <<EOF
[Unit]
Description=DoH/DoH3 forwarding resolver
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN -l 127.0.0.1 -p $PROXY_PORT \\
  -u $UPSTREAM_H3_1 -u $UPSTREAM_HT_1 \\
  -u $UPSTREAM_H3_2 -u $UPSTREAM_HT_2 \\
  --cache
Restart=always
RestartSec=3
# No capabilities needed: $PROXY_PORT is above 1024 and the listener is loopback.
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now dnsproxy.service || die "dnsproxy failed to start: journalctl -u dnsproxy -n 30"

  say "== resolved: default path → dnsproxy =="
  mkdir -p "$DROPIN_DIR"
  [ -f "$DROPIN" ] && cp -a "$DROPIN" "$DROPIN.bak-$TS"
  cat > "$DROPIN" <<EOF
# Managed by fleet-dns-setup.sh.  DoH lives in dnsproxy; resolved keeps the
# per-link overlay zones and only needs to stop using plaintext upstreams.
[Resolve]
DNS=127.0.0.1:$PROXY_PORT
FallbackDNS=
Domains=~.
# The hop to dnsproxy is loopback; TLS here would be a handshake against a
# plaintext listener and would fail.
DNSOverTLS=no
EOF
  # A global DNS= plus ~. only wins if no link claims the default route; links
  # that still carry DHCP/RA servers must stop accepting them.
  say "== stopping DHCP/RA DNS from entering =="
  while IFS= read -r c; do
    nmcli connection mod "$c" ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes 2>/dev/null \
      && say "  $c: ignore-auto-dns=yes"
  done < <(nmcli -t -f NAME connection show 2>/dev/null | sort -u)

  systemctl restart systemd-resolved || die "resolved restart failed"
  resolvectl flush-caches 2>/dev/null
  sleep 1

  say "== verify =="
  say "  global: $(resolvectl dns 2>/dev/null | head -1)"
  say "  domestic: $(resolvectl query www.alidns.com 2>&1 | head -2 | tr '\n' ' ')"
  say "  overlay : $(resolvectl query "${OVERLAY_PROBE:-localhost}" 2>&1 | head -2 | tr '\n' ' ')"
  say "Done.  Roll back with: $0 --rollback"
}

rollback() {
  need_root
  say "== rollback =="
  [ -f "$DROPIN" ] && rm -f "$DROPIN" && say "  removed $DROPIN"
  local b; b=$(ls -1t "$DROPIN".bak-* 2>/dev/null | head -1)
  [ -n "${b:-}" ] && cp -a "$b" "$DROPIN" && say "  restored $DROPIN from $b"
  systemctl disable --now dnsproxy.service 2>/dev/null && say "  dnsproxy stopped"
  rm -f "$UNIT"; systemctl daemon-reload
  while IFS= read -r c; do
    nmcli connection mod "$c" ipv4.ignore-auto-dns no ipv6.ignore-auto-dns no 2>/dev/null \
      && say "  $c: ignore-auto-dns=no"
  done < <(nmcli -t -f NAME connection show 2>/dev/null)
  systemctl restart systemd-resolved
  resolvectl flush-caches 2>/dev/null
  say "  resolved: $(grep -hE '^DNS=' /etc/systemd/resolved.conf 2>/dev/null || echo '(unset)')"
}

case "${1:-}" in
  --check) check ;;
  --apply) shift; bin=""; while [ $# -gt 0 ]; do case "$1" in --binary) bin="$2"; shift 2;; *) die "unknown arg $1";; esac; done; apply "$bin" ;;
  --rollback) rollback ;;
  *) say "usage: $0 --check | --apply --binary PATH | --rollback"; exit 2 ;;
esac
