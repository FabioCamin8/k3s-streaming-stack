#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT

failures=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; failures=$((failures + 1)); }

if ! command -v awk >/dev/null 2>&1; then fail 'required command is missing: awk'; fi
if ! command -v realpath >/dev/null 2>&1; then fail 'required command is missing: realpath'; fi

config="$TMP_DIR/remux.env"
cat > "$config" <<'EOF'
REMUX_HOST=remux.example.com
EOF

if REMUX_CONFIG_FILE="$config" "$REPO_ROOT/k8s/remux/render.sh" "$TMP_DIR/rendered" >/dev/null; then
    pass 'render script accepts a valid operator hostname'
else
    fail 'render script rejected a valid operator hostname'
fi

if grep -F 'remux.example.com' "$TMP_DIR/rendered/ingress.yaml" >/dev/null 2>&1 &&
    ! grep -F '__REMUX_HOST__' "$TMP_DIR/rendered/ingress.yaml" >/dev/null 2>&1; then
    pass 'rendered Ingress contains no hostname placeholder'
else
    fail 'rendered Ingress substitution is invalid'
fi

if grep -F 'streaming-authelia-forwardauth@kubernetescrd' \
    "$TMP_DIR/rendered/admin-ingress.yaml" >/dev/null 2>&1 &&
    grep -F 'remux.example.com' "$TMP_DIR/rendered/admin-ingress.yaml" >/dev/null 2>&1 &&
    ! grep -F '__REMUX_HOST__' "$TMP_DIR/rendered/admin-ingress.yaml" >/dev/null 2>&1; then
    pass 'admin Ingress is separately rendered with the Authelia middleware'
else
    fail 'admin Ingress rendering or middleware reference is invalid'
fi

invalid="$TMP_DIR/invalid.env"
cat > "$invalid" <<'EOF'
REMUX_HOST=__REMUX_HOST__
EOF
if REMUX_CONFIG_FILE="$invalid" "$REPO_ROOT/k8s/remux/render.sh" "$TMP_DIR/invalid-rendered" >/dev/null 2>&1; then
    fail 'render script accepted a placeholder hostname'
else
    pass 'render script rejects placeholder hostnames'
fi

if (( failures > 0 )); then
    printf 'Remux render verification failed with %d failure(s).\n' "$failures"
    exit 1
fi
printf 'Remux render verification passed.\n'
