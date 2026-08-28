#!/usr/bin/env bash

set -Eeuo pipefail

KUBECTL=${KUBECTL:-kubectl}
NAMESPACE=${NAMESPACE:-streaming}
WAIT_SECONDS=${WAIT_SECONDS:-180}
REMUX_URL=${REMUX_URL:-}
REMUX_API_TOKEN_FILE=${REMUX_API_TOKEN_FILE:-}
REMUX_LOCATION_CHECK_URL=${REMUX_LOCATION_CHECK_URL:-}
TEMP_FILES=()
FAILURES=0

cleanup() {
    local path
    for path in "${TEMP_FILES[@]}"; do
        rm -f -- "$path"
    done
}
trap cleanup EXIT

pass() { printf 'PASS: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is missing: $1"
}

wait_for_deployment() {
    local deadline=$((SECONDS + WAIT_SECONDS))
    while (( SECONDS < deadline )); do
        if "$KUBECTL" -n "$NAMESPACE" wait \
            --for=condition=available deployment/remux \
            --timeout=5s >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

json_value() {
    local kind=$1 name=$2 path=$3
    "$KUBECTL" -n "$NAMESPACE" get "$kind" "$name" -o "jsonpath=$path" 2>/dev/null || true
}

[[ $WAIT_SECONDS =~ ^[1-9][0-9]*$ ]] || fail 'WAIT_SECONDS must be positive'
require_command awk
require_command curl
require_command "$KUBECTL"

if "$KUBECTL" get namespace "$NAMESPACE" >/dev/null 2>&1; then
    pass "namespace $NAMESPACE exists"
else
    fail "namespace $NAMESPACE is missing"
fi

if wait_for_deployment; then
    pass 'Remux Deployment is Available'
else
    fail "Remux Deployment is not Available within ${WAIT_SECONDS}s"
fi

replicas=$(json_value deployment remux '{.spec.replicas}')
ready_replicas=$(json_value deployment remux '{.status.readyReplicas}')
strategy=$(json_value deployment remux '{.spec.strategy.type}')
if [[ $replicas == 1 && $ready_replicas == 1 && $strategy == Recreate ]]; then
    pass 'Deployment has one ready replica and Recreate strategy'
else
    fail "Deployment safety shape is invalid (replicas=$replicas ready=$ready_replicas strategy=$strategy)"
fi

image=$(json_value deployment remux '{.spec.template.spec.containers[0].image}')
pull_policy=$(json_value deployment remux '{.spec.template.spec.containers[0].imagePullPolicy}')
if [[ $image == ghcr.io/lostb1t/remux:0.27.0 && $pull_policy == IfNotPresent ]]; then
    pass 'Deployment uses the reviewed Remux v0.27.0 image policy'
else
    fail "unexpected image policy (image=$image pullPolicy=$pull_policy)"
fi

image_id=$("$KUBECTL" -n "$NAMESPACE" get pod \
    -l app.kubernetes.io/name=remux \
    -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' 2>/dev/null || true)
if [[ $image_id == *@sha256:* ]]; then
    pass "running image digest ${image_id##*@}"
else
    fail 'running image has no immutable digest'
fi

service_type=$(json_value service remux '{.spec.type}')
service_port=$(json_value service remux '{.spec.ports[0].port}')
service_target=$(json_value service remux '{.spec.ports[0].targetPort}')
if [[ $service_type == ClusterIP && $service_port == 80 && $service_target == http ]]; then
    pass 'ClusterIP Service exposes HTTP 80 to the named container port'
else
    fail 'Service shape is invalid'
fi

ready_endpoints=$("$KUBECTL" -n "$NAMESPACE" get endpointslice \
    -l kubernetes.io/service-name=remux \
    -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{"\n"}{end}' 2>/dev/null || true)
if awk '$1 == "true" { found = 1 } END { exit found ? 0 : 1 }' <<<"$ready_endpoints"; then
    pass 'Service has a ready endpoint'
else
    fail 'Service has no ready endpoint'
fi

pvc_phase=$(json_value persistentvolumeclaim remux-data '{.status.phase}')
pvc_storage_class=$(json_value persistentvolumeclaim remux-data '{.spec.storageClassName}')
if [[ $pvc_phase == Bound && $pvc_storage_class == local-path ]]; then
    pass 'PVC is Bound on local-path'
else
    fail "PVC is not ready (phase=$pvc_phase storageClass=$pvc_storage_class)"
fi

ingress_class=$(json_value ingress remux '{.spec.ingressClassName}')
tls_secret=$(json_value ingress remux '{.spec.tls[0].secretName}')
ingress_host=$(json_value ingress remux '{.spec.rules[0].host}')
if [[ $ingress_class == traefik && $tls_secret == remux-tls &&
    -n $ingress_host && $ingress_host != *:* ]]; then
    pass 'Ingress uses Traefik, remux-tls, and a portless hostname'
else
    fail 'Ingress class, TLS Secret, or hostname is invalid'
fi

if usage=$("$KUBECTL" -n "$NAMESPACE" top pod \
    -l app.kubernetes.io/name=remux --no-headers 2>/dev/null) && [[ -n $usage ]]; then
    pass "Remux pod usage: $usage"
else
    fail 'kubectl top pod did not return Remux usage'
fi
if usage=$("$KUBECTL" top node --no-headers 2>/dev/null) && [[ -n $usage ]]; then
    pass "node usage: $usage"
else
    fail 'kubectl top node did not return usage'
fi

api_headers=()
if [[ -n $REMUX_API_TOKEN_FILE ]]; then
    [[ -r $REMUX_API_TOKEN_FILE ]] || fail 'REMUX_API_TOKEN_FILE is not readable'
    require_command jq
    api_token=$(<"$REMUX_API_TOKEN_FILE")
    [[ -n $api_token && $api_token != *$'\n'* && $api_token != *$'\r'* ]] ||
        fail 'Remux API token file must contain one non-empty token line'
    api_headers=(-H "X-Emby-Token: $api_token" -H 'Accept: application/json')
fi

if [[ -n $REMUX_URL ]]; then
    health_code=$(curl --silent --show-error --output /dev/null \
        --write-out '%{http_code}' --max-time 30 "$REMUX_URL/health" || true)
    if [[ $health_code == 200 ]]; then
        pass 'Remux liveness endpoint returns HTTP 200'
    else
        fail "Remux liveness endpoint returned HTTP $health_code"
    fi

    for path in /system/info/public /users/public; do
        code=$(curl --silent --show-error --output /dev/null \
            --write-out '%{http_code}' --max-time 30 "$REMUX_URL$path" || true)
        if [[ $code == 200 ]]; then
            pass "public Jellyfin bootstrap $path returns HTTP 200"
        else
            fail "public Jellyfin bootstrap $path returned HTTP $code"
        fi
    done

    if ((${#api_headers[@]} > 0)); then
        addons_file=$(mktemp)
        TEMP_FILES+=("$addons_file")
        code=$(curl --silent --show-error --output "$addons_file" \
            --write-out '%{http_code}' --max-time 30 "${api_headers[@]}" \
            "$REMUX_URL/addons" || true)
        if [[ $code == 200 ]] && jq -e \
            '.[] | select(.name == "AIOStreams" and .kind == "stremio") |
             .httpRedirectStream == false and .serviceFilter == [] and .enabled == true and
             (.config.manifest_url | startswith("http://aiostreams.streaming.svc.cluster.local/"))' \
            "$addons_file" >/dev/null; then
            pass 'AIOStreams addon is internal, enabled, unfiltered, and non-redirecting'
        else
            fail "AIOStreams addon contract check failed (HTTP $code)"
        fi
    else
        warn 'REMUX_API_TOKEN_FILE not supplied; addon contract was not queried'
    fi
else
    warn 'REMUX_URL not supplied; HTTP, Jellyfin, and redirect checks were not run'
fi

if [[ -n $REMUX_LOCATION_CHECK_URL ]]; then
    location_headers=$(mktemp)
    TEMP_FILES+=("$location_headers")
    code=$(curl --silent --show-error --output /dev/null --dump-header "$location_headers" \
        --max-time 30 --max-redirs 0 "${api_headers[@]}" \
        "$REMUX_LOCATION_CHECK_URL" || true)
    location=$(awk 'BEGIN {IGNORECASE=1} /^Location:/ {sub(/^[^:]*:[[:space:]]*/, ""); sub(/[[:space:]]*\r?$/, ""); print; exit}' "$location_headers")
    if [[ $location == *'.svc.cluster.local'* ]]; then
        fail 'stream response leaked a cluster-local redirect Location'
    elif [[ $code =~ ^3[0-9][0-9]$ && -n $location ]]; then
        pass "stream redirect target is not cluster-local (HTTP $code)"
    else
        warn "redirect check did not observe a redirect (HTTP $code)"
    fi
fi

if (( FAILURES > 0 )); then
    printf 'Remux verification failed with %d failure(s).\n' "$FAILURES"
    exit 1
fi

printf 'Remux verification passed.\n'
