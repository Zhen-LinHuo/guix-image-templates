#!/usr/bin/env bash
# fetch-geodata.sh — provision the geodata files mihomo's packages build from.
#
# Why this exists: guix's built-in downloader cannot fetch these from GitHub on
# a CN build host (no CONNECT through a proxy, and a sandboxed build has its own
# loopback so a proxy on 127.0.0.1 is unreachable anyway).  The packages in
# templates/packages/proxy.scm therefore take (local-file ...) from a vendored directory,
# with the sha256 pinning content exactly as url-fetch would.
#
# Run once per build host, and again whenever mihomo-geodata / mihomo-geoip
# versions change (the hash table below is the authority for both sides).
#
# Usage: fetch-geodata.sh [--dest DIR] [--proxy URL] [--tag TAG] [--check]
#   default dest: <repo>/geodata      (override with GUIX_TEMPLATES_GEODATA)
#   --check     verify what is already there, download nothing

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${GUIX_TEMPLATES_GEODATA:-$REPO/geodata}"
PROXY="${HTTP_PROXY:-}"
TAG="202610232206"
CHECK_ONLY=0

# tag → "file:sha256" pairs.  Bump BOTH this table and the package version/hash
# in templates/packages/proxy.scm; they must agree or the build fails honestly.
declare -A HASHES=(
  ["202610232206/geosite.dat"]="9cb5ab39ce601ad17d4077909b4d4e943c212af7baa658a612adc64e1c201ca4"
  ["202610232206/geoip.dat"]="a6271d3c96361d96156e6d3f7cf1550ef21b00d2f951deb772f464db91e89ac5"
)

while [ $# -gt 0 ]; do
  case "$1" in
    --dest)  DEST="$2"; shift 2;;
    --proxy) PROXY="$2"; shift 2;;
    --tag)   TAG="$2"; shift 2;;
    --check) CHECK_ONLY=1; shift;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done

fail=0
for key in "${!HASHES[@]}"; do
  [ "${key%%/*}" = "$TAG" ] || continue
  file="${key##*/}"
  want="${HASHES[$key]}"
  target="$DEST/$file"

  if [ -f "$target" ]; then
    got=$(sha256sum "$target" | cut -d' ' -f1)
    if [ "$got" = "$want" ]; then
      echo "ok       $file  ($(du -h "$target" | cut -f1))"
      continue
    fi
    echo "MISMATCH $file  have=${got:0:12} want=${want:0:12}" >&2
    [ "$CHECK_ONLY" = 1 ] && { fail=1; continue; }
  elif [ "$CHECK_ONLY" = 1 ]; then
    echo "MISSING  $file" >&2; fail=1; continue
  fi

  url="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/$TAG/$file"
  tmp="$target.part"
  echo "fetch    $file  <- $url"
  curl_args=(-fsSL --max-time 600 -o "$tmp")
  [ -n "$PROXY" ] && curl_args+=(-x "$PROXY")
  if ! curl "${curl_args[@]}" "$url"; then
    echo "download failed: $file" >&2; rm -f "$tmp"; fail=1; continue
  fi
  got=$(sha256sum "$tmp" | cut -d' ' -f1)
  if [ "$got" != "$want" ]; then
    echo "hash mismatch after download: $file (have ${got:0:12}, want ${want:0:12})" >&2
    rm -f "$tmp"; fail=1; continue
  fi
  install -Dm0444 "$tmp" "$target" && rm -f "$tmp"
  echo "installed $file"
done

[ "$fail" = 0 ] && echo "geodata ready in $DEST" || { echo "geodata NOT ready" >&2; exit 1; }
