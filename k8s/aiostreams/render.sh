#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE=${AIOSTREAMS_CONFIG_FILE:-$SCRIPT_DIR/operator.env}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage: render.sh OUTPUT_DIRECTORY

Render the AIOStreams Kustomize bundle from the operator-only configuration.
The output contains a Secret and must stay outside Git.

Environment:
  AIOSTREAMS_CONFIG_FILE  path to operator.env (default: ./operator.env)
USAGE
}

if (($# != 1)); then
    usage >&2
    exit 2
fi

OUTPUT_DIR=$1
[[ -r $CONFIG_FILE ]] || die "operator config is not readable: $CONFIG_FILE"
[[ $OUTPUT_DIR = /* ]] || die 'render output must be an absolute path'
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

base64_value() {
    printf '%s' "$1" | base64 | tr -d '\n'
}

AIOSTREAMS_HOST=$(read_config AIOSTREAMS_HOST)
AIOSTREAMS_PUBLIC_HTTPS_PORT=$(read_config AIOSTREAMS_PUBLIC_HTTPS_PORT)
AIOSTREAMS_SECRET_KEY=$(read_config AIOSTREAMS_SECRET_KEY)
AIOSTREAMS_AUTH=$(read_config AIOSTREAMS_AUTH)
AIOSTREAMS_TRUSTED_IPS=$(read_config AIOSTREAMS_TRUSTED_IPS)

hostname_re='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$'
[[ $AIOSTREAMS_HOST =~ $hostname_re ]] ||
    die 'AIOSTREAMS_HOST must be a lowercase hostname'
[[ $AIOSTREAMS_PUBLIC_HTTPS_PORT =~ ^[0-9]+$ ]] ||
    die 'AIOSTREAMS_PUBLIC_HTTPS_PORT must be a decimal TCP port'

public_port=$AIOSTREAMS_PUBLIC_HTTPS_PORT
while [[ ${public_port:0:1} == 0 && $public_port != 0 ]]; do
    public_port=${public_port:1}
done
(( ${#public_port} <= 5 )) || die 'AIOSTREAMS_PUBLIC_HTTPS_PORT must be between 1 and 65535'
(( 10#$public_port >= 1 && 10#$public_port <= 65535 )) ||
    die 'AIOSTREAMS_PUBLIC_HTTPS_PORT must be between 1 and 65535'
[[ $AIOSTREAMS_SECRET_KEY =~ ^[A-Fa-f0-9]{64}$ ]] ||
    die 'AIOSTREAMS_SECRET_KEY must be a 64-character hex string'
[[ $AIOSTREAMS_AUTH =~ ^[^,:]+:[^,]+(,[^,:]+:[^,]+)*$ ]] ||
    die 'AIOSTREAMS_AUTH must be comma-separated username:password pairs'
[[ $AIOSTREAMS_TRUSTED_IPS =~ ^[0-9./,]+$ ]] ||
    die 'AIOSTREAMS_TRUSTED_IPS must contain only IPv4 addresses or CIDRs'
[[ $AIOSTREAMS_HOST != *'__'* && $AIOSTREAMS_SECRET_KEY != *'__'* &&
    $AIOSTREAMS_PUBLIC_HTTPS_PORT != *'__'* &&
    $AIOSTREAMS_AUTH != *'__'* && $AIOSTREAMS_TRUSTED_IPS != *'__'* ]] ||
    die 'operator config still contains a placeholder'

command -v awk >/dev/null 2>&1 || die 'required command is missing: awk'
command -v base64 >/dev/null 2>&1 || die 'required command is missing: base64'
command -v tr >/dev/null 2>&1 || die 'required command is missing: tr'

mkdir -m 700 "$OUTPUT_DIR"
for resource in namespace.yaml bootstrap.yaml pvc.yaml service.yaml deployment.yaml ingress.yaml kustomization.yaml; do
    cp "$SCRIPT_DIR/$resource" "$OUTPUT_DIR/$resource"
done

if [[ $public_port == 443 ]]; then
    AIOSTREAMS_BASE_URL=https://$AIOSTREAMS_HOST
else
    AIOSTREAMS_BASE_URL=https://$AIOSTREAMS_HOST:$public_port
fi

export _AIOSTREAMS_BASE_URL_B64=$(base64_value "$AIOSTREAMS_BASE_URL")
export _AIOSTREAMS_SECRET_KEY_B64=$(base64_value "$AIOSTREAMS_SECRET_KEY")
export _AIOSTREAMS_AUTH_B64=$(base64_value "$AIOSTREAMS_AUTH")
export _AIOSTREAMS_TRUSTED_IPS_B64=$(base64_value "$AIOSTREAMS_TRUSTED_IPS")
export _AIOSTREAMS_HOST=$AIOSTREAMS_HOST

awk '
  {
    gsub(/__AIOSTREAMS_BASE_URL_B64__/, ENVIRON["_AIOSTREAMS_BASE_URL_B64"])
    gsub(/__AIOSTREAMS_SECRET_KEY_B64__/, ENVIRON["_AIOSTREAMS_SECRET_KEY_B64"])
    gsub(/__AIOSTREAMS_AUTH_B64__/, ENVIRON["_AIOSTREAMS_AUTH_B64"])
    gsub(/__AIOSTREAMS_TRUSTED_IPS_B64__/, ENVIRON["_AIOSTREAMS_TRUSTED_IPS_B64"])
    print
  }
' "$OUTPUT_DIR/bootstrap.yaml" > "$OUTPUT_DIR/bootstrap.yaml.tmp"
mv -- "$OUTPUT_DIR/bootstrap.yaml.tmp" "$OUTPUT_DIR/bootstrap.yaml"

awk '{ gsub(/__AIOSTREAMS_HOST__/, ENVIRON["_AIOSTREAMS_HOST"]); print }' \
    "$OUTPUT_DIR/ingress.yaml" > "$OUTPUT_DIR/ingress.yaml.tmp"
mv -- "$OUTPUT_DIR/ingress.yaml.tmp" "$OUTPUT_DIR/ingress.yaml"

printf 'PASS: rendered AIOStreams bundle (secret values withheld)\n'
