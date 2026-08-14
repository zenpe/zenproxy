#!/usr/bin/env bash

set -Eeuo pipefail

readonly ZP_VERSION="0.4.2"
readonly ZP_MAIN_URL="https://raw.githubusercontent.com/zenpe/zenproxy/v${ZP_VERSION}/zenproxy"

tmp=$(mktemp)
cleanup() {
  rm -f -- "$tmp"
}
trap cleanup EXIT

curl -fsSL --retry 3 --connect-timeout 10 "$ZP_MAIN_URL" -o "$tmp"
chmod 0755 "$tmp"
exec bash "$tmp" "$@"
