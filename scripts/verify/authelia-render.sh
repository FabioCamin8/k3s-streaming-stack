#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
RENDERER=$REPO_ROOT/k8s/authelia/render.sh
TEMP_DIR=$(mktemp -d -t authelia-render.XXXXXX)
trap 'rm -rf -- "$TEMP_DIR"' EXIT

mkdir -m 700 "$TEMP_DIR/secrets"
printf '%s\n' 'users:' '  operator:' '    displayname: Operator' \
    '    password: placeholder-hash' '    email: operator@example.invalid' \
    '    groups:' '      - admins' > "$TEMP_DIR/users_database.yml"
for name in SESSION_SECRET STORAGE_ENCRYPTION_KEY \
    IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET OIDC_HMAC_SECRET \
    OIDC_ISSUER_PRIVATE_KEY AIOSTREAMS_OIDC_CLIENT_SECRET_HASH; do
    printf '%s\n' placeholder > "$TEMP_DIR/secrets/$name"
done
cat > "$TEMP_DIR/operator.env" <<EOF
AUTHELIA_HOST=auth.example.com
AUTHELIA_COOKIE_DOMAIN=example.com
AIOSTREAMS_HOST=stream.example.com
AIOSTREAMS_PUBLIC_HTTPS_PORT=443
REMUX_HOST=remux.example.com
AUTHELIA_USERS_DATABASE_FILE=$TEMP_DIR/users_database.yml
AUTHELIA_SECRETS_DIR=$TEMP_DIR/secrets
EOF

AUTHELIA_CONFIG_FILE="$TEMP_DIR/operator.env" "$RENDERER" "$TEMP_DIR/output" >/dev/null
[[ ! -e "$REPO_ROOT/k8s/authelia/users_database.yml" ]]
[[ -e "$TEMP_DIR/output/users_database.yml" ]]
[[ -e "$TEMP_DIR/output/OIDC_ISSUER_PRIVATE_KEY" ]]
! grep -R -n -- '__[A-Z0-9_]*__' "$TEMP_DIR/output"
grep -q -- 'auth.example.com' "$TEMP_DIR/output/ingress.yaml"
grep -q -- 'remux.example.com' "$TEMP_DIR/output/configuration.yml"
grep -q -- 'https://stream.example.com/api/v1/auth/oidc/callback' \
    "$TEMP_DIR/output/configuration.yml"
! grep -q -- 'https://stream.example.com:443/' \
    "$TEMP_DIR/output/configuration.yml"
[[ $(grep -c -- 'defaultMode: 0400' "$TEMP_DIR/output/deployment.yaml") == 2 ]]

sed 's/AIOSTREAMS_PUBLIC_HTTPS_PORT=443/AIOSTREAMS_PUBLIC_HTTPS_PORT=8443/' \
    "$TEMP_DIR/operator.env" > "$TEMP_DIR/operator-8443.env"
AUTHELIA_CONFIG_FILE="$TEMP_DIR/operator-8443.env" "$RENDERER" \
    "$TEMP_DIR/output-8443" >/dev/null
grep -q -- 'https://stream.example.com:8443/api/v1/auth/oidc/callback' \
    "$TEMP_DIR/output-8443/configuration.yml"

sed 's/AUTHELIA_HOST=auth.example.com/AUTHELIA_HOST=auth.other.invalid/' \
    "$TEMP_DIR/operator.env" > "$TEMP_DIR/operator-invalid-domain.env"
if AUTHELIA_CONFIG_FILE="$TEMP_DIR/operator-invalid-domain.env" "$RENDERER" \
    "$TEMP_DIR/output-invalid-domain" >/dev/null 2>&1; then
    printf '%s\n' 'Authelia renderer accepted a cookie-domain mismatch' >&2
    exit 1
fi
printf 'Authelia renderer checks passed.\n'
