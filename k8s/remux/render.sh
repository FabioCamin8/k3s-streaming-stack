#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE=${REMUX_CONFIG_FILE:-$SCRIPT_DIR/operator.env}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage: render.sh OUTPUT_DIRECTORY

Render the Remux Kustomize bundle from operator-only configuration.
The output contains the selected hostname and must stay outside Git.

Environment:
  REMUX_CONFIG_FILE  path to operator.env (default: ./operator.env)
USAGE
}

if (($# != 1)); then
    usage >&2
    exit 2
fi

OUTPUT_DIR=$1
[[ -r $CONFIG_FILE ]] || die "operator config is not readable: $CONFIG_FILE"
[[ $OUTPUT_DIR = /* ]] || die 'render output must be an absolute path'
command -v awk >/dev/null 2>&1 || die 'required command is missing: awk'
command -v realpath >/dev/null 2>&1 || die 'required command is missing: realpath'
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

REMUX_HOST=$(read_config REMUX_HOST)

hostname_re='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$'
[[ $REMUX_HOST =~ $hostname_re ]] ||
    die 'REMUX_HOST must be a lowercase hostname'
[[ $REMUX_HOST != *'__'* ]] || die 'operator config still contains a placeholder'

mkdir -m 700 "$OUTPUT_DIR"
for resource in pvc.yaml service.yaml deployment.yaml ingress.yaml kustomization.yaml; do
    cp "$SCRIPT_DIR/$resource" "$OUTPUT_DIR/$resource"
done

export _REMUX_HOST=$REMUX_HOST
awk '{ gsub(/__REMUX_HOST__/, ENVIRON["_REMUX_HOST"]); print }' \
    "$OUTPUT_DIR/ingress.yaml" > "$OUTPUT_DIR/ingress.yaml.tmp"
mv -- "$OUTPUT_DIR/ingress.yaml.tmp" "$OUTPUT_DIR/ingress.yaml"

printf 'PASS: rendered Remux bundle (operator values withheld)\n'
