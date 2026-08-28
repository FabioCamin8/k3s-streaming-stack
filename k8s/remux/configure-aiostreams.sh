#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE=${REMUX_CONFIG_FILE:-$SCRIPT_DIR/operator.env}
TOKEN_FILE=${REMUX_API_TOKEN_FILE:-}
TMP_DIR=''

cleanup() {
    if [[ -n $TMP_DIR && -d $TMP_DIR ]]; then
        rm -rf -- "$TMP_DIR"
    fi
}
trap cleanup EXIT

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

read_config() {
    local key=$1 value
    value=$(awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$CONFIG_FILE")
    printf '%s' "$value"
}

[[ -r $CONFIG_FILE ]] || die "operator config is not readable: $CONFIG_FILE"
[[ -n $TOKEN_FILE && -r $TOKEN_FILE ]] ||
    die 'REMUX_API_TOKEN_FILE must point to a protected readable token file'
command -v awk >/dev/null 2>&1 || die 'required command is missing: awk'
command -v curl >/dev/null 2>&1 || die 'required command is missing: curl'
command -v jq >/dev/null 2>&1 || die 'required command is missing: jq'
command -v mktemp >/dev/null 2>&1 || die 'required command is missing: mktemp'

REMUX_HOST=$(read_config REMUX_HOST)
REMUX_PUBLIC_HTTPS_PORT=$(read_config REMUX_PUBLIC_HTTPS_PORT)
AIOSTREAMS_MANIFEST_URL=$(read_config REMUX_AIOSTREAMS_MANIFEST_URL)
[[ $REMUX_HOST =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]] ||
    die 'REMUX_HOST must be a lowercase hostname'
[[ $REMUX_PUBLIC_HTTPS_PORT =~ ^[0-9]+$ ]] ||
    die 'REMUX_PUBLIC_HTTPS_PORT must be a decimal TCP port'
internal_manifest_re='^http://aiostreams\.streaming\.svc\.cluster\.local(:80)?/stremio/[^[:space:]?#]+/manifest\.json$'
[[ $AIOSTREAMS_MANIFEST_URL =~ $internal_manifest_re ]] ||
    die 'REMUX_AIOSTREAMS_MANIFEST_URL must be an HTTP AIOStreams Service URL'
[[ $AIOSTREAMS_MANIFEST_URL == */manifest.json ]] ||
    die 'REMUX_AIOSTREAMS_MANIFEST_URL must end in manifest.json'
[[ $AIOSTREAMS_MANIFEST_URL != *'<'* && $AIOSTREAMS_MANIFEST_URL != *'__'* &&
    $AIOSTREAMS_MANIFEST_URL != *REPLACE_WITH* ]] ||
    die 'AIOStreams manifest URL still contains a placeholder'

public_port=$REMUX_PUBLIC_HTTPS_PORT
while [[ ${public_port:0:1} == 0 && $public_port != 0 ]]; do
    public_port=${public_port:1}
done
(( ${#public_port} <= 5 && 10#$public_port >= 1 && 10#$public_port <= 65535 )) ||
    die 'REMUX_PUBLIC_HTTPS_PORT must be between 1 and 65535'

if [[ $public_port == 443 ]]; then
    REMUX_URL=https://$REMUX_HOST
else
    REMUX_URL=https://$REMUX_HOST:$public_port
fi

API_TOKEN=$(<"$TOKEN_FILE")
[[ -n $API_TOKEN && $API_TOKEN != *$'\n'* && $API_TOKEN != *$'\r'* ]] ||
    die 'Remux API token file must contain one non-empty token line'

TMP_DIR=$(mktemp -d)
response=$TMP_DIR/addon.json
headers=( -H "X-Emby-Token: $API_TOKEN" -H 'Accept: application/json' )

status=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' \
    --max-time 30 "${headers[@]}" "$REMUX_URL/addons") ||
    die 'Remux addon list request failed'
[[ $status == 200 ]] || die "Remux addon list returned HTTP $status"

addon_id=$(jq -r '.[] | select(.name == "AIOStreams" and .kind == "stremio") | .id' \
    "$response" | head -n 1)
payload=$(mktemp "$TMP_DIR/payload.XXXXXX")
jq -n --arg url "$AIOSTREAMS_MANIFEST_URL" \
    '{preset:{kind:"stremio",config:{manifest_url:$url}},name:"AIOStreams",resources:[],types:[],priority:0,isDefault:true}' \
    > "$payload"

if [[ -z $addon_id ]]; then
    status=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' \
        --max-time 60 "${headers[@]}" -H 'Content-Type: application/json' \
        --data-binary "@$payload" "$REMUX_URL/addons") ||
        die 'Remux addon create request failed'
    [[ $status == 201 ]] || die "Remux addon create returned HTTP $status"
    addon_id=$(jq -r '.id // empty' "$response")
else
    update=$(mktemp "$TMP_DIR/update.XXXXXX")
    jq -n --arg url "$AIOSTREAMS_MANIFEST_URL" \
        '{config:{manifest_url:$url},enabled:true,isDefault:true,httpRedirectStream:false,serviceFilter:[]}' \
        > "$update"
    status=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' \
        --max-time 60 "${headers[@]}" -H 'Content-Type: application/json' \
        --data-binary "@$update" "$REMUX_URL/addons/$addon_id") ||
        die 'Remux addon update request failed'
    [[ $status == 200 ]] || die "Remux addon update returned HTTP $status"
fi

[[ $addon_id =~ ^[0-9a-fA-F-]{36}$ ]] || die 'Remux did not return an addon ID'
status=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' \
    --max-time 30 "${headers[@]}" "$REMUX_URL/addons/$addon_id") ||
    die 'Remux addon verification request failed'
[[ $status == 200 ]] || die "Remux addon verification returned HTTP $status"
jq -e --arg url "$AIOSTREAMS_MANIFEST_URL" \
    '.kind == "stremio" and .config.manifest_url == $url and .httpRedirectStream == false and .serviceFilter == [] and .enabled == true' \
    "$response" >/dev/null || die 'AIOStreams addon contract is not safely configured'

printf 'PASS: AIOStreams addon configured through Remux internal Service (redirects disabled)\n'
