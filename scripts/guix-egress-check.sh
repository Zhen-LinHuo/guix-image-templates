#!/usr/bin/env bash
# guix-egress-check.sh — can this host actually fetch substitutes?
#
# The failure this exists to catch: guile's HTTP client honours only
# http_proxy/https_proxy and implements no no_proxy, so a proxy either breaks
# every INTERNAL url or (unset) leaves the overseas build farms unreachable.
# Splitting is therefore the proxy's job, and this script proves the split
# works from the host's own point of view — direct AND proxied, per source
# class — instead of trusting a config file.
#
# A second, sneakier failure: a cache that answers HTTP 200 with a body that is
# not narinfo (S3 <Error> XML from Garage, or an SPA index.html).  guix parses
# it and reports "corrupt input while restoring archive"; the status code looks
# healthy.  Every check below validates the BODY, not just the code.
#
# Usage:  guix-egress-check.sh [proxy-url]
#   default proxy-url: http://127.0.0.1:7890
# Exit:   0 all required cells pass, 1 otherwise (matrix printed either way).

set -uo pipefail

PROXY="${1:-http://127.0.0.1:7890}"
TIMEOUT=12
FAILED=0

# Internal substitute cache (overlay-reachable, site-specific).  Must work
# DIRECT and also THROUGH the proxy: the proxy is expected to route this domain
# DIRECT by rule, so a proxied failure means its DNS or rules are wrong.
# No default: the URL names a private cache, so it comes from the environment.
INTERNAL_URL="${GUIX_EGRESS_INTERNAL:-}"

# Domestic mirror: plain reachability is enough here (usually direct-friendly).
DOMESTIC_URL="${GUIX_EGRESS_DOMESTIC:-https://mirrors.sjtug.sjtu.edu.cn/guix/nix-cache-info}"

# Official build farm: this is the one that NEEDS the proxy from inside CN.
OFFICIAL_URL="${GUIX_EGRESS_OFFICIAL:-https://bordeaux.guix.gnu.org/nix-cache-info}"

# A store path that every cache should know if it carries upstream substitutes.
# Used only for the narinfo body check (a nix-cache-info check cannot detect the
# 200+XML pathology, because that endpoint is a static file).
NARINFO_HASH="${GUIX_EGRESS_NARINFO:-0hxwjx1pj49xw41i5vlqy9zrcx9j527s}"   # curl-8.21.0-doc on bordeaux

probe() {                       # probe <label> <url> <direct|proxy> <body-expect>
  local label="$1" url="$2" via="$3" expect="$4"
  local -a cargs=(-sk -m "$TIMEOUT" -o /tmp/gec.$$ -w '%{http_code}')
  [ "$via" = proxy ] && cargs+=(-x "$PROXY")
  local code; code=$(curl "${cargs[@]}" "$url" 2>/dev/null) || true
  [ -z "$code" ] && code="000"
  local verdict="OK"
  if [ "$code" = "000" ]; then
    verdict="UNREACHABLE"
  elif [ "$code" != "200" ]; then
    verdict="HTTP $code"
  elif [ -n "$expect" ] && ! head -c 200 /tmp/gec.$$ | grep -q "$expect"; then
    verdict="BAD BODY (not $expect)"
  fi
  printf '%-28s %-7s %-6s %-12s %s\n' "$label" "$via" "$code" "$verdict" \
    "$(head -c 60 /tmp/gec.$$ 2>/dev/null | tr -d '\n' | tr -c '[:print:]' '.')"
  rm -f /tmp/gec.$$
  case "$verdict" in OK) return 0;; *) return 1;; esac
}

echo "proxy: $PROXY"
echo
printf '%-28s %-7s %-6s %-12s %s\n' SOURCE VIA CODE VERDICT BODY
echo "-------------------------------------------------------------------------------"

# internal: both paths required, but only if a cache URL was supplied
if [ -n "$INTERNAL_URL" ]; then
  probe internal-cache "$INTERNAL_URL" direct "StoreDir:" || FAILED=1
  probe internal-cache "$INTERNAL_URL" proxy  "StoreDir:" || FAILED=1
else
  printf '%-28s %-7s %-6s %-12s %s\n' internal-cache - - "SKIPPED" \
    "set GUIX_EGRESS_INTERNAL to your own cache URL"
fi

# domestic mirror: proxy path required (direct is informative only)
probe domestic-mirror "$DOMESTIC_URL" proxy "StoreDir:" || FAILED=1

# official farm: proxy path is the required one
probe official-farm "$OFFICIAL_URL" proxy "StoreDir:" || FAILED=1

echo
echo "narinfo body check (catches 200 + non-narinfo bodies):"
for via in direct proxy; do
  probe narinfo "$OFFICIAL_URL/../$NARINFO_HASH.narinfo" "$via" "StorePath:" || true
done

echo
if [ "$FAILED" = 0 ]; then
  echo "RESULT: PASS — internal and overseas substitute paths both usable"
else
  echo "RESULT: FAIL — see the rows above; internal rows are mandatory on BOTH paths"
fi
exit "$FAILED"
