#!/usr/bin/env bash

set -Eeuo pipefail

KUBECTL=${KUBECTL:-kubectl}
NAMESPACE=${NAMESPACE:-streaming}
WAIT_SECONDS=${WAIT_SECONDS:-180}
AUTHELIA_URL=${AUTHELIA_URL:-}
AIOSTREAMS_URL=${AIOSTREAMS_URL:-}
REMUX_URL=${REMUX_URL:-}
FAILURES=0

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is missing: $1"
}

json_value() {
    local kind=$1 name=$2 path=$3
    "$KUBECTL" -n "$NAMESPACE" get "$kind" "$name" -o "jsonpath=$path" 2>/dev/null || true
}

wait_for_namespace() {
    local deadline=$((SECONDS + WAIT_SECONDS))
    while (( SECONDS < deadline )); do
        if "$KUBECTL" get namespace "$NAMESPACE" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

[[ $WAIT_SECONDS =~ ^[1-9][0-9]*$ ]] || fail 'WAIT_SECONDS must be positive'
require_command awk
require_command curl
require_command grep
require_command sleep
require_command "$KUBECTL"

if wait_for_namespace; then
    pass "namespace $NAMESPACE exists"
else
    fail "namespace $NAMESPACE is missing"
fi

if "$KUBECTL" -n "$NAMESPACE" wait --for=condition=available deployment/authelia \
    --timeout="${WAIT_SECONDS}s" >/dev/null 2>&1; then
    pass 'Authelia Deployment is Available'
else
    fail 'Authelia Deployment is not Available'
fi

replicas=$(json_value deployment authelia '{.spec.replicas}')
ready_replicas=$(json_value deployment authelia '{.status.readyReplicas}')
strategy=$(json_value deployment authelia '{.spec.strategy.type}')
if [[ $replicas == 1 && $ready_replicas == 1 && $strategy == Recreate ]]; then
    pass 'Deployment has one ready replica and Recreate strategy'
else
    fail "Deployment safety shape is invalid (replicas=$replicas ready=$ready_replicas strategy=$strategy)"
fi

image=$(json_value deployment authelia '{.spec.template.spec.containers[0].image}')
if [[ $image == ghcr.io/authelia/authelia:4.39.20 ]]; then
    pass 'Deployment uses the reviewed Authelia release tag'
else
    fail "unexpected Authelia image: $image"
fi

image_id=$("$KUBECTL" -n "$NAMESPACE" get pod \
    -l app.kubernetes.io/name=authelia \
    -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' 2>/dev/null || true)
if [[ $image_id == *@sha256:* ]]; then
    pass "running image digest ${image_id##*@}"
else
    fail 'running Authelia image has no immutable digest'
fi

service_type=$(json_value service authelia '{.spec.type}')
service_port=$(json_value service authelia '{.spec.ports[0].port}')
service_target=$(json_value service authelia '{.spec.ports[0].targetPort}')
if [[ $service_type == ClusterIP && $service_port == 80 && $service_target == http ]]; then
    pass 'ClusterIP Service exposes HTTP 80 to the named container port'
else
    fail 'Authelia Service shape is invalid'
fi

ready_endpoints=$("$KUBECTL" -n "$NAMESPACE" get endpointslice \
    -l kubernetes.io/service-name=authelia \
    -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{"\n"}{end}' 2>/dev/null || true)
if awk '$1 == "true" { found = 1 } END { exit found ? 0 : 1 }' <<<"$ready_endpoints"; then
    pass 'Service has a ready endpoint'
else
    fail 'Service has no ready endpoint'
fi

pvc_phase=$(json_value persistentvolumeclaim authelia-data '{.status.phase}')
pvc_storage_class=$(json_value persistentvolumeclaim authelia-data '{.spec.storageClassName}')
if [[ $pvc_phase == Bound && $pvc_storage_class == local-path ]]; then
    pass 'PVC is Bound on local-path'
else
    fail "PVC is not ready (phase=$pvc_phase storageClass=$pvc_storage_class)"
fi

configmap=$(json_value configmap authelia-config '{.metadata.name}')
users_secret=$(json_value secret authelia-users '{.metadata.name}')
secrets_secret=$(json_value secret authelia-secrets '{.metadata.name}')
if [[ $configmap == authelia-config && $users_secret == authelia-users &&
    $secrets_secret == authelia-secrets ]]; then
    pass 'configuration and private generated resources exist (values withheld)'
else
    fail 'Authelia generated configuration resources are incomplete'
fi

middleware=$(json_value middleware authelia-forwardauth '{.metadata.name}')
if [[ $middleware == authelia-forwardauth ]]; then
    pass 'Authelia ForwardAuth middleware exists'
else
    fail 'Authelia ForwardAuth middleware is missing'
fi

admin_ingress_class=$(json_value ingress remux-admin '{.spec.ingressClassName}')
admin_path=$(json_value ingress remux-admin '{.spec.rules[0].http.paths[0].path}')
admin_middleware=$(json_value ingress remux-admin \
    '{.metadata.annotations.traefik\.ingress\.kubernetes\.io/router\.middlewares}')
main_middleware=$(json_value ingress remux \
    '{.metadata.annotations.traefik\.ingress\.kubernetes\.io/router\.middlewares}')
if [[ $admin_ingress_class == traefik && $admin_path == /admin &&
    $admin_middleware == streaming-authelia-forwardauth@kubernetescrd &&
    -z $main_middleware ]]; then
    pass 'Remux /admin alone has Authelia ForwardAuth'
else
    fail 'Remux selective-authentication Ingress boundary is invalid'
fi

ingress_class=$(json_value ingress authelia '{.spec.ingressClassName}')
tls_secret=$(json_value ingress authelia '{.spec.tls[0].secretName}')
if [[ $ingress_class == traefik && $tls_secret == authelia-tls ]]; then
    pass 'Ingress uses Traefik and the Authelia TLS Secret'
else
    fail 'Authelia Ingress TLS/class shape is invalid'
fi

if "$KUBECTL" -n "$NAMESPACE" wait --for=condition=Ready certificate/authelia-tls \
    --timeout="${WAIT_SECONDS}s" >/dev/null 2>&1; then
    pass 'Authelia Certificate is Ready'
else
    fail 'Authelia Certificate is not Ready'
fi

if [[ -n $AUTHELIA_URL ]]; then
    require_command mktemp
    headers_file=$(mktemp)
    body_file=$(mktemp)
    trap 'rm -f -- "$headers_file" "$body_file"' EXIT
    health_code=$(curl --silent --show-error --output "$body_file" \
        --dump-header "$headers_file" --write-out '%{http_code}' --max-time 30 \
        "$AUTHELIA_URL/api/health" || true)
    if [[ $health_code == 200 ]]; then
        pass 'HTTPS Authelia health endpoint returns HTTP 200'
    else
        fail "Authelia health endpoint returned HTTP $health_code"
    fi
    discovery_code=$(curl --silent --show-error --output "$body_file" \
        --write-out '%{http_code}' --max-time 30 \
        "$AUTHELIA_URL/.well-known/openid-configuration" || true)
    if [[ $discovery_code == 200 ]] && grep -q '"issuer"' "$body_file"; then
        pass 'OIDC discovery returns an issuer'
    else
        fail "OIDC discovery returned HTTP $discovery_code or no issuer"
    fi
fi

check_machine_url() {
    local label=$1 url=$2
    [[ -n $url ]] || return 0
    require_command mktemp
    local headers_file code
    headers_file=$(mktemp)
    code=$(curl --silent --show-error --output /dev/null --dump-header "$headers_file" \
        --write-out '%{http_code}' --max-time 30 "$url" || true)
    if [[ $code == 200 ]]; then
        pass "$label returns HTTP 200"
    else
        fail "$label returned HTTP $code"
    fi
    if grep -Eiq '^location:.*(authelia|/login)' "$headers_file"; then
        fail "$label unexpectedly redirects to an authentication flow"
    else
        pass "$label has no unexpected Authelia redirect"
    fi
    rm -f -- "$headers_file"
}

check_machine_url 'AIOStreams public manifest' "${AIOSTREAMS_URL:+$AIOSTREAMS_URL/stremio/manifest.json}"
check_machine_url 'Remux health endpoint' "${REMUX_URL:+$REMUX_URL/health}"

if (( FAILURES > 0 )); then
    printf 'Authelia verification failed with %d failure(s).\n' "$FAILURES"
    exit 1
fi

printf 'Authelia structural verification passed.\n'
