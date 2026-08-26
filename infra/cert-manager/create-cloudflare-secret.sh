#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

KUBECTL=${KUBECTL:-kubectl}
NAMESPACE=cert-manager
SECRET_NAME=cloudflare-api-token-secret
TOKEN_FILE=${CLOUDFLARE_API_TOKEN_FILE:-}
TOKEN_TEMP=''

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

kube() {
    "$KUBECTL" "$@"
}

cleanup() {
    if [[ -n $TOKEN_TEMP && -e $TOKEN_TEMP ]]; then
        rm -f -- "$TOKEN_TEMP"
    fi
    unset token key_value
}

trap cleanup EXIT

usage() {
    cat <<'USAGE'
Usage: create-cloudflare-secret.sh [--token-file FILE]

Create or replace cert-manager's Cloudflare API-token Secret from a protected
operator-local file. The token is never accepted as a command-line argument,
printed, or included in a manifest stored by this repository.

The file may also be supplied with CLOUDFLARE_API_TOKEN_FILE. It must be
readable only by its owner (for example mode 600 or stricter).
USAGE
}

while (($# > 0)); do
    case $1 in
        --token-file)
            (($# >= 2)) || die '--token-file requires a path'
            TOKEN_FILE=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

[[ -n $TOKEN_FILE ]] || die 'provide CLOUDFLARE_API_TOKEN_FILE or --token-file'
[[ -f $TOKEN_FILE ]] || die 'Cloudflare token file does not exist'
[[ -r $TOKEN_FILE ]] || die 'Cloudflare token file is not readable'
command -v stat >/dev/null 2>&1 || die 'required command not found: stat'
command -v mktemp >/dev/null 2>&1 || die 'required command not found: mktemp'
command -v "$KUBECTL" >/dev/null 2>&1 || die "required command not found: $KUBECTL"

mode=$(stat -c '%a' "$TOKEN_FILE")
[[ $mode =~ ^[0-7]+$ ]] || die 'could not inspect Cloudflare token file permissions'
(( (8#$mode & 077) == 0 )) || die 'Cloudflare token file must not be group- or world-readable'

# Bash command substitution removes trailing newlines. Reject any remaining
# line breaks so an editor-added newline cannot become part of the API token.
token=$(<"$TOKEN_FILE")
[[ -n $token ]] || die 'Cloudflare token file is empty'
[[ $token != *$'\n'* && $token != *$'\r'* ]] || die 'Cloudflare token file must contain one line'

TOKEN_TEMP=$(mktemp -t cloudflare-api-token.XXXXXX)
chmod 600 "$TOKEN_TEMP"
printf '%s' "$token" >"$TOKEN_TEMP"

kube -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
    --from-file="api-token=$TOKEN_TEMP" \
    --dry-run=client --output=yaml |
    kube apply --filename=- >/dev/null

key_value=$(kube -n "$NAMESPACE" get secret "$SECRET_NAME" \
    -o "jsonpath={.data['api-token']}" 2>/dev/null || true)
[[ -n $key_value ]] || die "Secret $NAMESPACE/$SECRET_NAME has no api-token key"

printf 'PASS: Secret %s/%s exists with the expected key (value withheld)\n' \
    "$NAMESPACE" "$SECRET_NAME"
