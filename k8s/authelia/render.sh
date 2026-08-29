#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE=${AUTHELIA_CONFIG_FILE:-$SCRIPT_DIR/operator.env}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage: render.sh OUTPUT_DIRECTORY

Render the Authelia Kustomize bundle from operator-only configuration.
The output contains Kubernetes Secrets and must stay outside Git.

Environment:
  AUTHELIA_CONFIG_FILE  path to operator.env (default: ./operator.env)
USAGE
}

if (($# != 1)); then
    usage >&2
    exit 2
fi

OUTPUT_DIR=$1
[[ -r $CONFIG_FILE ]] || die "operator config is not readable: $CONFIG_FILE"
[[ $OUTPUT_DIR = /* ]] || die 'render output must be an absolute path'
for command_name in awk chmod cp realpath; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "required command is missing: $command_name"
done

repo_real=$(realpath "$SCRIPT_DIR")
output_real=$(realpath -m "$OUTPUT_DIR")
[[ $output_real != "$repo_real" && $output_real != "$repo_real"/* ]] ||
    die 'render output must be outside the repository tree'
[[ ! -e $OUTPUT_DIR ]] || die "render output already exists: $OUTPUT_DIR"

read_config() {
    local key=$1 value
    value=$(awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$CONFIG_FILE")
    printf '%s' "$value"
}

AUTHELIA_HOST=$(read_config AUTHELIA_HOST)
AUTHELIA_COOKIE_DOMAIN=$(read_config AUTHELIA_COOKIE_DOMAIN)
AIOSTREAMS_HOST=$(read_config AIOSTREAMS_HOST)
AIOSTREAMS_PUBLIC_HTTPS_PORT=$(read_config AIOSTREAMS_PUBLIC_HTTPS_PORT)
REMUX_HOST=$(read_config REMUX_HOST)
AUTHELIA_USERS_DATABASE_FILE=$(read_config AUTHELIA_USERS_DATABASE_FILE)
AUTHELIA_SECRETS_DIR=$(read_config AUTHELIA_SECRETS_DIR)

hostname_re='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$'
[[ $AUTHELIA_HOST =~ $hostname_re ]] || die 'AUTHELIA_HOST must be a lowercase hostname'
[[ $AUTHELIA_COOKIE_DOMAIN =~ $hostname_re ]] ||
    die 'AUTHELIA_COOKIE_DOMAIN must be a lowercase hostname'
[[ $AIOSTREAMS_HOST =~ $hostname_re ]] || die 'AIOSTREAMS_HOST must be a lowercase hostname'
[[ $REMUX_HOST =~ $hostname_re ]] || die 'REMUX_HOST must be a lowercase hostname'
[[ $AIOSTREAMS_PUBLIC_HTTPS_PORT =~ ^[0-9]+$ ]] ||
    die 'AIOSTREAMS_PUBLIC_HTTPS_PORT must be a decimal TCP port'
public_port=$AIOSTREAMS_PUBLIC_HTTPS_PORT
while [[ ${public_port:0:1} == 0 && $public_port != 0 ]]; do
    public_port=${public_port:1}
done
(( ${#public_port} <= 5 )) ||
    die 'AIOSTREAMS_PUBLIC_HTTPS_PORT must be between 1 and 65535'
(( 10#$public_port >= 1 && 10#$public_port <= 65535 )) ||
    die 'AIOSTREAMS_PUBLIC_HTTPS_PORT must be between 1 and 65535'
[[ $AUTHELIA_HOST != *'__'* && $AUTHELIA_COOKIE_DOMAIN != *'__'* &&
    $AIOSTREAMS_HOST != *'__'* && $AIOSTREAMS_PUBLIC_HTTPS_PORT != *'__'* &&
    $REMUX_HOST != *'__'* ]] ||
    die 'operator config still contains a placeholder'
[[ $AUTHELIA_HOST == "$AUTHELIA_COOKIE_DOMAIN" ||
    $AUTHELIA_HOST == *."$AUTHELIA_COOKIE_DOMAIN" ]] ||
    die 'AUTHELIA_HOST must be equal to or beneath AUTHELIA_COOKIE_DOMAIN'
[[ $AIOSTREAMS_HOST == *."$AUTHELIA_COOKIE_DOMAIN" ]] ||
    die 'AIOSTREAMS_HOST must be beneath AUTHELIA_COOKIE_DOMAIN'
[[ $REMUX_HOST == *."$AUTHELIA_COOKIE_DOMAIN" ]] ||
    die 'REMUX_HOST must be beneath AUTHELIA_COOKIE_DOMAIN'
[[ -f $AUTHELIA_USERS_DATABASE_FILE && -r $AUTHELIA_USERS_DATABASE_FILE ]] ||
    die 'AUTHELIA_USERS_DATABASE_FILE must be a readable file'
[[ -d $AUTHELIA_SECRETS_DIR && -r $AUTHELIA_SECRETS_DIR ]] ||
    die 'AUTHELIA_SECRETS_DIR must be a readable directory'

secret_files=(
    SESSION_SECRET
    STORAGE_ENCRYPTION_KEY
    IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET
    OIDC_HMAC_SECRET
    OIDC_ISSUER_PRIVATE_KEY
    AIOSTREAMS_OIDC_CLIENT_SECRET_HASH
)
for secret_name in "${secret_files[@]}"; do
    secret_path=$AUTHELIA_SECRETS_DIR/$secret_name
    [[ -f $secret_path && -r $secret_path && -s $secret_path ]] ||
        die "missing or empty Authelia secret file: $secret_name"
done

mkdir -m 700 "$OUTPUT_DIR"
for resource in configuration.yml pvc.yaml service.yaml deployment.yaml ingress.yaml middleware.yaml kustomization.yaml; do
    cp -- "$SCRIPT_DIR/$resource" "$OUTPUT_DIR/$resource"
done
cp -- "$AUTHELIA_USERS_DATABASE_FILE" "$OUTPUT_DIR/users_database.yml"
chmod 600 "$OUTPUT_DIR/users_database.yml"
for secret_name in "${secret_files[@]}"; do
    cp -- "$AUTHELIA_SECRETS_DIR/$secret_name" "$OUTPUT_DIR/$secret_name"
    chmod 600 "$OUTPUT_DIR/$secret_name"
done

export _AUTHELIA_HOST=$AUTHELIA_HOST
export _AUTHELIA_COOKIE_DOMAIN=$AUTHELIA_COOKIE_DOMAIN
export _REMUX_HOST=$REMUX_HOST
if [[ $public_port == 443 ]]; then
    AIOSTREAMS_BASE_URL=https://$AIOSTREAMS_HOST
else
    AIOSTREAMS_BASE_URL=https://$AIOSTREAMS_HOST:$public_port
fi
export _AIOSTREAMS_BASE_URL=$AIOSTREAMS_BASE_URL
awk '
  {
    gsub(/__AUTHELIA_HOST__/, ENVIRON["_AUTHELIA_HOST"])
    gsub(/__AUTHELIA_COOKIE_DOMAIN__/, ENVIRON["_AUTHELIA_COOKIE_DOMAIN"])
    gsub(/__AIOSTREAMS_BASE_URL__/, ENVIRON["_AIOSTREAMS_BASE_URL"])
    gsub(/__REMUX_HOST__/, ENVIRON["_REMUX_HOST"])
    print
  }
' "$OUTPUT_DIR/configuration.yml" > "$OUTPUT_DIR/configuration.yml.tmp"
mv -- "$OUTPUT_DIR/configuration.yml.tmp" "$OUTPUT_DIR/configuration.yml"
awk '
  {
    gsub(/__AUTHELIA_HOST__/, ENVIRON["_AUTHELIA_HOST"])
    print
  }
' "$OUTPUT_DIR/ingress.yaml" > "$OUTPUT_DIR/ingress.yaml.tmp"
mv -- "$OUTPUT_DIR/ingress.yaml.tmp" "$OUTPUT_DIR/ingress.yaml"

if awk '/__[A-Z0-9_]+__/ { found = 1 } END { exit found ? 0 : 1 }' \
    "$OUTPUT_DIR/configuration.yml" "$OUTPUT_DIR/ingress.yaml"; then
    die 'rendered bundle still contains placeholders'
fi

printf 'PASS: rendered Authelia bundle (secret values withheld)\n'
