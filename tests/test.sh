#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/zenproxy-test.XXXXXX)

export ZENPROXY_CONFIG_DIR="$TEST_ROOT/etc/zenproxy"
export ZENPROXY_STATE_DIR="$TEST_ROOT/var/lib/zenproxy"
export ZENPROXY_INSTALL_DIR="$TEST_ROOT/usr/local/lib/zenproxy"
export ZENPROXY_SYSTEMD_DIR="$TEST_ROOT/etc/systemd/system"
export ZENPROXY_LOCK_FILE="$TEST_ROOT/run/zenproxy.lock"

# shellcheck disable=SC1091
source "$PROJECT_DIR/zenproxy"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

assert() {
  local message=$1
  shift
  "$@" || { printf 'FAIL: %s\n' "$message" >&2; exit 1; }
  printf 'PASS: %s\n' "$message"
}

assert_not_contains() {
  local message=$1 haystack=$2 needle=$3
  [[ "$haystack" != *"$needle"* ]] || { printf 'FAIL: %s\n' "$message" >&2; exit 1; }
  printf 'PASS: %s\n' "$message"
}

assert "accepts a normal domain" validate_domain direct.example.com
assert "accepts a valid node name" validate_node_name us-la-01
assert "accepts a Chinese node name" validate_node_name '美国-洛杉矶-01'
if validate_node_name 'US Los Angeles'; then
  printf 'FAIL: rejects an invalid node name\n' >&2
  exit 1
else
  printf 'PASS: rejects an invalid node name\n'
fi
if validate_domain https://example.com; then
  printf 'FAIL: rejects a URL as domain\n' >&2
  exit 1
else
  printf 'PASS: rejects a URL as domain\n'
fi
assert "accepts TCP port 8443" validate_port 8443
if validate_port 08443; then
  printf 'FAIL: rejects a port with a leading zero\n' >&2
  exit 1
else
  printf 'PASS: rejects a port with a leading zero\n'
fi
assert "accepts a valid IPv4 address" valid_ipv4_address 203.0.113.10
if valid_ipv4_address 999.0.0.1; then
  printf 'FAIL: rejects an invalid IPv4 address\n' >&2
  exit 1
else
  printf 'PASS: rejects an invalid IPv4 address\n'
fi
assert "accepts a valid IPv6 address" valid_ipv6_address 2001:db8::10
if valid_ipv6_address '2001:db8::invalid'; then
  printf 'FAIL: rejects an invalid IPv6 address\n' >&2
  exit 1
else
  printf 'PASS: rejects an invalid IPv6 address\n'
fi
assert "accepts Debian 12" validate_platform_version debian 12
assert "accepts Ubuntu 22.04" validate_platform_version ubuntu 22.04
if validate_platform_version ubuntu 20.04; then
  printf 'FAIL: rejects Ubuntu 20.04\n' >&2
  exit 1
else
  printf 'PASS: rejects Ubuntu 20.04\n'
fi

getent() { return 2; }
assert "accepts missing dedicated users during preflight" check_install_users
unset -f getent

ss() {
  case "${2:-}" in
    -lnt) printf '%s\n' 'LISTEN 0 4096 [::]:8443 [::]:*' ;;
    -lnu) printf '%s\n' 'UNCONN 0 0 [::]:443 [::]:*' ;;
  esac
}
assert "detects a listening TCP port" port_in_use tcp 8443
assert "detects a listening UDP port" port_in_use udp 443
if port_in_use udp 8443; then
  printf 'FAIL: rejects a different UDP port\n' >&2
  exit 1
else
  printf 'PASS: rejects a different UDP port\n'
fi
unset -f ss

dry_run_output=$(
  "$PROJECT_DIR/zenproxy" install \
    --tunnel-domain cf.example.com \
    --node-name test-node \
    --dry-run
)
assert_not_contains "dry-run reserves web TCP 443" "$dry_run_output" "VLESS监听：       TCP 443"
[[ "$dry_run_output" == *"VLESS监听：       TCP 8443"* ]]
[[ "$dry_run_output" == *"Hysteria2监听：   UDP 443"* ]]

mkdir -p "$ZP_CONFIG_DIR" "$ZP_CREDENTIAL_DIR" "$ZP_STATE_DIR" "$ZP_BIN_DIR"
test_private_key='private-test-key'
test_public_key='public-test-key'
test_xray_source=""
for candidate in /usr/local/lib/zenproxy/bin/xray /root/agsbx/xray; do
  if [[ -x "$candidate" ]]; then test_xray_source=$candidate; break; fi
done
if [[ -n "$test_xray_source" ]]; then
  install -m 0755 "$test_xray_source" "$XRAY_BIN"
  if [[ -x "$(dirname "$test_xray_source")/cloudflared" ]]; then
    install -m 0755 "$(dirname "$test_xray_source")/cloudflared" "$CLOUDFLARED_BIN"
  fi
  key_pair=$($XRAY_BIN x25519)
  test_private_key=$(awk -F: '/PrivateKey/ {gsub(/[[:space:]]/, "", $2); print $2}' <<<"$key_pair")
  test_public_key=$(awk -F: '/PublicKey|Password/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' <<<"$key_pair")
fi
printf '%s\n' '11111111-1111-4111-8111-111111111111' >"$ZP_CREDENTIAL_DIR/vless.uuid"
printf '%s\n' "$test_private_key" >"$ZP_CREDENTIAL_DIR/reality.private-key"
printf '%s\n' "$test_public_key" >"$ZP_CREDENTIAL_DIR/reality.public-key"
printf '%s\n' '0123456789abcdef' >"$ZP_CREDENTIAL_DIR/reality.short-id"
printf '%s\n' 'hy2-test-password' >"$ZP_CREDENTIAL_DIR/hysteria.password"
printf '%s\n' '/test-ws-path' >"$ZP_CREDENTIAL_DIR/ws.path"

chown() { :; }
cat >"$ZP_BIN_DIR/cloudflared" <<'EOF'
#!/bin/sh
case "$*" in
  'tunnel login') mkdir -p "$HOME/.cloudflared"; : >"$HOME/.cloudflared/cert.pem" ;;
  'tunnel create zenproxy-test') printf '{}\n' >"$HOME/.cloudflared/11111111-1111-4111-8111-111111111111.json" ;;
  'tunnel list --output json') printf '[{"name":"zenproxy-test","id":"11111111-1111-4111-8111-111111111111"}]\n' ;;
  tunnel\ route\ dns*) printf '%s\n' "$*" >"$HOME/route.args" ;;
  *) exit 1 ;;
esac
EOF
chmod 0755 "$ZP_BIN_DIR/cloudflared"
tunnel_result=""
setup_cloudflare_tunnel cf.example.com zenproxy-test tunnel_result
[[ "$tunnel_result" == 11111111-1111-4111-8111-111111111111 ]]
[[ $(<"$ZP_STATE_DIR/cloudflare-home/route.args") != *--overwrite-dns* ]]
printf 'PASS: tunnel setup does not overwrite an existing domain by default\n'
printf 'PASS: tunnel setup returns the created ID to the installer\n'

mkdir -p "$ZP_TLS_DIR"
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -subj '/CN=www.bing.com' \
  -keyout "$ZP_TLS_DIR/privkey.pem" -out "$ZP_TLS_DIR/fullchain.pem" >/dev/null 2>&1
openssl x509 -in "$ZP_TLS_DIR/fullchain.pem" -outform DER | sha256sum | awk '{print $1}' \
  >"$ZP_CREDENTIAL_DIR/tls.fingerprint"

write_state 203.0.113.10 203.0.113.10 2001:db8::10 cf.example.com apple.com \
  11111111-1111-4111-8111-111111111111 zenproxy-test 8443 443 test-node
[[ $(jq -r '.managed_users | length' "$ZP_STATE_FILE") == 2 ]]
manager_hash=$(sha256sum "$PROJECT_DIR/zenproxy" | awk '{print $1}')
manager_update_plan=$(cmd_update --manager-file "$PROJECT_DIR/zenproxy" \
  --manager-sha256 "$manager_hash" --dry-run)
[[ "$manager_update_plan" == *"Xray ${XRAY_VERSION#v}"* ]]
[[ "$manager_update_plan" == *"cloudflared ${CLOUDFLARED_VERSION#v}"* ]]
printf 'PASS: combined update uses the new manager core versions\n'
mkdir -p "$ZP_SYSTEMD_DIR"
systemctl() { :; }
write_systemd_units
unset -f systemctl
grep -Fq 'tunnel run 11111111-1111-4111-8111-111111111111' \
  "$ZP_SYSTEMD_DIR/$CLOUDFLARED_SERVICE"
printf 'PASS: cloudflared service receives the tunnel ID explicitly\n'
build_node_links
[[ "$HY2_V4_LINK" == *'203.0.113.10:443/'* ]]
[[ "$HY2_V4_LINK" == *'pinSHA256='* ]]
[[ "$VLESS_V4_LINK" == *'203.0.113.10:8443?'* ]]
[[ "$HY2_V6_LINK" == *'@[2001:db8::10]:443/'* ]]
[[ "$VLESS_V6_LINK" == *'@[2001:db8::10]:8443?'* ]]
[[ "$CF_LINK" == vless://*test-node-cf ]]
[[ "$CF_LINK" == *'#test-node-cf' ]]
printf 'PASS: generated links honor configured ports\n'
[[ $(uri_host '2001:db8::1') == '[2001:db8::1]' ]]
write_state 203.0.113.10 203.0.113.10 2001:db8::10 cf.example.com apple.com \
  11111111-1111-4111-8111-111111111111 zenproxy-test 8443 443 '美国-洛杉矶-01'
build_node_links
[[ "$CF_LINK" == *'%E7%BE%8E%E5%9B%BD-%E6%B4%9B%E6%9D%89%E7%9F%B6-01-cf' ]]
printf 'PASS: Chinese node names are URI encoded\n'
write_state 203.0.113.10 203.0.113.10 2001:db8::10 cf.example.com apple.com \
  11111111-1111-4111-8111-111111111111 zenproxy-test 8443 443 test-node
printf 'PASS: IPv6 node addresses use URI brackets\n'

clash_nodes=$(cmd_info --clash)
[[ "$clash_nodes" == proxies:* ]]
[[ $(awk '/^  - name:/ {count++} END {print count+0}' <<<"$clash_nodes") == 5 ]]
assert_not_contains "info clash output omits proxy groups" "$clash_nodes" "proxy-groups:"
assert_not_contains "Mihomo HY2 keeps certificate verification" "$clash_nodes" "skip-cert-verify: true"
[[ "$clash_nodes" == *"fingerprint:"* ]]
[[ "$clash_nodes" == *"test-node-cf"* ]]
printf 'PASS: info emits separate IPv4 and IPv6 Clash.Meta nodes\n'

existing_export="$TEST_ROOT/existing-export"
mkdir -m 0755 "$existing_export"
printf 'keep\n' >"$existing_export/existing.txt"
chmod 0644 "$existing_export/existing.txt"
if (cmd_export --output "$existing_export" >/dev/null 2>&1); then
  printf 'FAIL: export rejects an existing directory\n' >&2
  exit 1
else
  printf 'PASS: export rejects an existing directory\n'
fi
[[ $(stat -c %a "$existing_export") == 755 ]]
[[ $(stat -c %a "$existing_export/existing.txt") == 644 ]]

safe_export="$TEST_ROOT/safe-export"
cmd_export --output "$safe_export" >/dev/null
[[ $(stat -c %a "$safe_export") == 700 ]]
[[ $(stat -c %a "$safe_export/nodes.txt") == 600 ]]
[[ $(find "$safe_export" -mindepth 1 -maxdepth 1 -type f | wc -l) == 3 ]]
jq -e '.outbounds | length == 5' "$safe_export/sing-box-outbounds.json" >/dev/null
jq -e '[.outbounds[] | select(.type == "hysteria2") |
  (.tls.insecure // false) == false and (.tls.certificate | length > 0)] | all' \
  "$safe_export/sing-box-outbounds.json" >/dev/null
for tag in test-node-cf test-node-hy2-v4 test-node-reality-v4 test-node-hy2-v6 test-node-reality-v6; do
  jq -e --arg tag "$tag" '[.outbounds[].tag] | index($tag) != null' \
    "$safe_export/sing-box-outbounds.json" >/dev/null
done
assert_not_contains "sing-box HY2 never disables TLS verification" \
  "$(<"$safe_export/sing-box-outbounds.json")" '"insecure":true'
[[ $(awk '/^proxy-groups:/ {exit} /^  - name:/ {count++} END {print count+0}' "$safe_export/mihomo.yaml") == 5 ]]
grep -Fq 'name: ZenProxy' "$safe_export/mihomo.yaml"
grep -Fq 'GEOSITE,category-ads-all,REJECT' "$safe_export/mihomo.yaml"
grep -Fq 'GEOSITE,cn,DIRECT' "$safe_export/mihomo.yaml"
grep -Fq 'GEOIP,cn,DIRECT' "$safe_export/mihomo.yaml"
grep -Fq 'MATCH,ZenProxy' "$safe_export/mihomo.yaml"
grep -Fq 'https://dns.alidns.com/dns-query' "$safe_export/mihomo.yaml"
[[ $(jq '.outbounds | length' "$safe_export/sing-box-outbounds.json") == 5 ]]
printf 'PASS: export creates a dedicated private directory\n'

curl() { printf '101'; }
assert "accepts a successful Cloudflare WebSocket handshake" \
  cloudflare_route_reachable cf.example.com /test-ws-path
curl() { printf '530'; }
if cloudflare_route_reachable cf.example.com /test-ws-path; then
  printf 'FAIL: rejects a failed Cloudflare route\n' >&2
  exit 1
else
  printf 'PASS: rejects a failed Cloudflare route\n'
fi
unset -f curl

if [[ "${ZENPROXY_NETWORK_TEST:-0}" == 1 ]]; then
  install_core_binaries "$ZP_BIN_DIR"
fi

if [[ -x "$XRAY_BIN" ]]; then
  write_xray_config apple.com 8443 443
  "$XRAY_BIN" run -test -config "$ZP_CONFIG_DIR/xray.json"
  [[ $(jq '[.inbounds[] | select(.tag=="hysteria2-direct" and .port==443)] | length' "$ZP_CONFIG_DIR/xray.json") == 1 ]]
  printf 'PASS: generated Xray config contains valid VLESS and HY2 inbounds\n'

  printf '%s\n' \
    '{"AccountTag":"test-account","TunnelSecret":"test-secret","TunnelID":"11111111-1111-4111-8111-111111111111"}' \
    >"$ZP_CREDENTIAL_DIR/cloudflared.json"
  write_cloudflared_config 11111111-1111-4111-8111-111111111111 cf.example.com
  mkdir -p "$ZP_SYSTEMD_DIR"
  for unit in "$XRAY_SERVICE" "$CLOUDFLARED_SERVICE"; do
    printf '%s\n' '[Unit]' >"$ZP_SYSTEMD_DIR/$unit"
  done
  printf '#!/bin/sh\nprintf "Xray old\\n"\n' >"$XRAY_BIN"
  printf '#!/bin/sh\nprintf "cloudflared version old\\n"\n' >"$CLOUDFLARED_BIN"
  chmod 0755 "$XRAY_BIN" "$CLOUDFLARED_BIN"
  old_xray_hash=$(sha256sum "$XRAY_BIN" | awk '{print $1}')
  old_cloudflared_hash=$(sha256sum "$CLOUDFLARED_BIN" | awk '{print $1}')
  if (
    install_core_binaries() {
      local target=$1 component
      mkdir -p "$target"
      for component in xray cloudflared; do
        printf '#!/bin/sh\nexit 0\n# new-%s\n' "$component" >"$target/$component"
        chmod 0755 "$target/$component"
      done
    }
    systemctl() { return 1; }
    service_active() { return 0; }
    cmd_update >/dev/null 2>&1
  ); then
    printf 'FAIL: update reports a restart failure\n' >&2
    exit 1
  else
    printf 'PASS: update reports a restart failure\n'
  fi
  [[ $(sha256sum "$XRAY_BIN" | awk '{print $1}') == "$old_xray_hash" ]]
  [[ $(sha256sum "$CLOUDFLARED_BIN" | awk '{print $1}') == "$old_cloudflared_hash" ]]
  printf 'PASS: failed update restores all core binaries\n'
else
  printf 'SKIP: no local Xray binary available for config validation\n'
fi

if [[ "${ZENPROXY_NETWORK_TEST:-0}" == 1 ]]; then
  [[ -x "$XRAY_BIN" && -x "$CLOUDFLARED_BIN" ]]
  generate_credentials
  write_xray_config apple.com 35444 35443
  jq '(.inbounds[] | select(.tag=="vless-ws-cloudflare").port) = 35445' \
    "$ZP_CONFIG_DIR/xray.json" >"$ZP_CONFIG_DIR/xray-runtime-test.json"
  if timeout 3 "$XRAY_BIN" run -config "$ZP_CONFIG_DIR/xray-runtime-test.json" >"$TEST_ROOT/xray.log" 2>&1; then
    xray_result=0
  else
    xray_result=$?
  fi
  if [[ "$xray_result" == 124 ]]; then
    printf 'PASS: Xray started VLESS WS, VLESS REALITY, and HY2 together\n'
  else
    cat "$TEST_ROOT/xray.log" >&2
    printf 'FAIL: Xray exited with %s\n' "$xray_result" >&2
    exit 1
  fi

  write_cloudflared_config 11111111-1111-4111-8111-111111111111 cf.example.com
  "$CLOUDFLARED_BIN" --config "$ZP_CONFIG_DIR/cloudflared.yml" tunnel ingress validate
  printf 'PASS: cloudflared accepted the generated ingress config\n'
fi

printf 'All tests passed.\n'
