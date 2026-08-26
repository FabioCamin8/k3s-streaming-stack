#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE=${CERT_MANAGER_CONFIG_FILE:-$SCRIPT_DIR/operator.env}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage: render.sh OUTPUT_DIRECTORY

Render the staging or production cert-manager resources from the operator-only
configuration file. The output directory is suitable for `kubectl apply -k`
and should be temporary or otherwise kept outside Git.

Environment:
  CERT_MANAGER_CONFIG_FILE  path to operator.env (default: ./operator.env)
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

ACME_EMAIL=$(read_config ACME_EMAIL)
TLS_STAGING_HOST=$(read_config TLS_STAGING_HOST)
TLS_PRODUCTION_HOST=$(read_config TLS_PRODUCTION_HOST)
hostname_re='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$'

[[ $ACME_EMAIL =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]] || die 'ACME_EMAIL is invalid'
[[ $TLS_STAGING_HOST =~ $hostname_re ]] || die 'TLS_STAGING_HOST must be a lowercase hostname'
[[ $TLS_PRODUCTION_HOST =~ $hostname_re ]] || die 'TLS_PRODUCTION_HOST must be a lowercase hostname'
[[ $TLS_STAGING_HOST != "$TLS_PRODUCTION_HOST" ]] ||
    die 'staging and production hostnames must be different'
[[ $ACME_EMAIL != *'__'* && $TLS_STAGING_HOST != *'__'* && $TLS_PRODUCTION_HOST != *'__'* ]] ||
    die 'operator config still contains a placeholder'

mkdir -p "$OUTPUT_DIR/staging" "$OUTPUT_DIR/production" "$OUTPUT_DIR/tls-validation"
for stage in staging production; do
    cp "$SCRIPT_DIR/$stage/kustomization.yaml" "$OUTPUT_DIR/$stage/kustomization.yaml"
done
cp "$SCRIPT_DIR/tls-validation/kustomization.yaml" "$OUTPUT_DIR/tls-validation/kustomization.yaml"

sed -e "s|__ACME_EMAIL__|$ACME_EMAIL|g" \
    "$SCRIPT_DIR/staging/cluster-issuer.yaml" >"$OUTPUT_DIR/staging/cluster-issuer.yaml"
sed -e "s|__TLS_STAGING_HOST__|$TLS_STAGING_HOST|g" \
    "$SCRIPT_DIR/staging/certificate.yaml" >"$OUTPUT_DIR/staging/certificate.yaml"
sed -e "s|__ACME_EMAIL__|$ACME_EMAIL|g" \
    "$SCRIPT_DIR/production/cluster-issuer.yaml" >"$OUTPUT_DIR/production/cluster-issuer.yaml"
sed -e "s|__TLS_PRODUCTION_HOST__|$TLS_PRODUCTION_HOST|g" \
    "$SCRIPT_DIR/production/certificate.yaml" >"$OUTPUT_DIR/production/certificate.yaml"
cp "$SCRIPT_DIR/tls-validation/deployment.yaml" "$OUTPUT_DIR/tls-validation/deployment.yaml"
cp "$SCRIPT_DIR/tls-validation/service.yaml" "$OUTPUT_DIR/tls-validation/service.yaml"
sed -e "s|__TLS_STAGING_HOST__|$TLS_STAGING_HOST|g" \
    "$SCRIPT_DIR/tls-validation/ingress.yaml" >"$OUTPUT_DIR/tls-validation/ingress.yaml"

printf 'PASS: rendered staging and production bundles (values withheld)\n'
