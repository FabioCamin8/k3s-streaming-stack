#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RENDER_SH=$SCRIPT_DIR/../../k8s/aiostreams/render.sh
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
FAILURES=0

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

write_config() {
    local config=$1 port=$2
    {
        printf 'AIOSTREAMS_HOST=stream.example.com\n'
        printf 'AIOSTREAMS_PUBLIC_HTTPS_PORT=%s\n' "$port"
        printf 'AIOSTREAMS_SECRET_KEY=%s\n' '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
        printf 'AIOSTREAMS_AUTH=admin:render-test-password\n'
        printf 'AIOSTREAMS_TRUSTED_IPS=192.0.2.0/24\n'
        printf 'AIOSTREAMS_OIDC_ISSUER=https://auth.example.com/\n'
        printf 'AIOSTREAMS_OIDC_CLIENT_SECRET=render-test-client-secret\n'
    } > "$config"
}

check_valid_port() {
    local port=$1 expected=$2 config output actual
    config=$TEST_ROOT/config-$port
    output=$TEST_ROOT/output-$port
    write_config "$config" "$port"
    if ! AIOSTREAMS_CONFIG_FILE=$config "$RENDER_SH" "$output" >/dev/null; then
        fail "render rejected valid port $port"
        return
    fi

    actual=$(awk '$1 == "BASE_URL:" {print $2; exit}' "$output/bootstrap.yaml" |
        base64 -d)
    if [[ $actual == "$expected" ]]; then
        pass "port $port renders the expected BASE_URL"
    else
        fail "port $port rendered an unexpected BASE_URL"
    fi

    if grep -Eq 'host: stream\.example\.com:' "$output/ingress.yaml"; then
        fail "port $port inserted a port into the Ingress hostname"
    else
        pass "port $port leaves the Ingress hostname portless"
    fi
}

check_invalid_port() {
    local port=$1 config output
    config=$TEST_ROOT/invalid-config-${port//[^[:alnum:]]/_}
    output=$TEST_ROOT/invalid-output-${port//[^[:alnum:]]/_}
    write_config "$config" "$port"
    if AIOSTREAMS_CONFIG_FILE=$config "$RENDER_SH" "$output" \
        >/dev/null 2>&1; then
        fail "invalid port $port was accepted"
    else
        pass "invalid port $port fails closed"
    fi
}

check_valid_port 443 https://stream.example.com
check_valid_port 8443 https://stream.example.com:8443

for invalid_port in '' 0 65536 abc -1 443/tcp; do
    check_invalid_port "$invalid_port"
done

if (( FAILURES > 0 )); then
    printf 'AIOStreams render verification failed with %d failure(s).\n' "$FAILURES"
    exit 1
fi

printf 'AIOStreams render verification passed.\n'
