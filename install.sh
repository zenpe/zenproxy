#!/usr/bin/env bash

set -Eeuo pipefail

readonly ZP_CHANNEL="main"
readonly ZP_MAIN_URL="https://raw.githubusercontent.com/zenpe/zenproxy/${ZP_CHANNEL}/zenproxy"

tmp=$(mktemp)
cleanup() {
  rm -f -- "$tmp"
}
trap cleanup EXIT

curl -fsSL --retry 3 --connect-timeout 10 "$ZP_MAIN_URL" -o "$tmp"
chmod 0755 "$tmp"
if [[ ! -t 0 ]]; then
  printf '[提示] 检测到管道运行(curl | bash)。若脚本需交互输入，请先下载到本地再执行：\n  curl -fsSL %s -o /tmp/zenproxy && sudo bash /tmp/zenproxy\n' "$ZP_MAIN_URL" >&2
fi
exec bash "$tmp" "$@"
