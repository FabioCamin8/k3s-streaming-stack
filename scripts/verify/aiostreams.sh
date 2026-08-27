#!/usr/bin/env bash

set -Eeuo pipefail

KUBECTL=${KUBECTL:-kubectl}
NAMESPACE=${NAMESPACE:-streaming}
WAIT_SECONDS=${WAIT_SECONDS:-180}
AIOSTREAMS_URL=${AIOSTREAMS_URL:-}
FAILURES=0

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is missing: $1"
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

json_value() {
    local kind=$1 name=$2 path=$3
    "$KUBECTL" -n "$NAMESPACE" get "$kind" "$name" -o "jsonpath=$path" 2>/dev/null || true
}

[[ $WAIT_SECONDS =~ ^[1-9][0-9]*$ ]] || fail 'WAIT_SECONDS must be positive'
require_command awk
require_command grep
require_command sleep
require_command "$KUBECTL"

if wait_for_namespace; then
    pass "namespace $NAMESPACE exists"
else
    fail "namespace $NAMESPACE is missing"
fi

if "$KUBECTL" -n "$NAMESPACE" rollout status deployment/aiostreams \
    --timeout="${WAIT_SECONDS}s" >/dev/null 2>&1; then
    pass 'AIOStreams Deployment is Available'
else
    fail 'AIOStreams Deployment is not Available'
fi

replicas=$(json_value deployment aiostreams '{.spec.replicas}')
ready_replicas=$(json_value deployment aiostreams '{.status.readyReplicas}')
strategy=$(json_value deployment aiostreams '{.spec.strategy.type}')
if [[ $replicas == 1 && $ready_replicas == 1 && $strategy == Recreate ]]; then
    pass 'Deployment has one ready replica and Recreate strategy'
else
    fail "Deployment safety shape is invalid (replicas=$replicas ready=$ready_replicas strategy=$strategy)"
fi

image=$(json_value deployment aiostreams '{.spec.template.spec.containers[0].image}')
pull_policy=$(json_value deployment aiostreams '{.spec.template.spec.containers[0].imagePullPolicy}')
if [[ $image == ghcr.io/viren070/aiostreams:latest && $pull_policy == Always ]]; then
    pass 'Deployment uses the deliberate latest/Always image policy'
else
    fail "unexpected image policy (image=$image pullPolicy=$pull_policy)"
fi

image_id=$("$KUBECTL" -n "$NAMESPACE" get pod \
    -l app.kubernetes.io/name=aiostreams \
    -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' 2>/dev/null || true)
if [[ $image_id == *@sha256:* ]]; then
    pass "running image digest ${image_id##*@}"
else
    fail 'running image has no immutable digest'
fi

service_type=$(json_value service aiostreams '{.spec.type}')
service_port=$(json_value service aiostreams '{.spec.ports[0].port}')
service_target=$(json_value service aiostreams '{.spec.ports[0].targetPort}')
if [[ $service_type == ClusterIP && $service_port == 80 && $service_target == http ]]; then
    pass 'ClusterIP Service exposes HTTP 80 to the named container port'
else
    fail 'Service shape is invalid'
fi

ready_endpoints=$("$KUBECTL" -n "$NAMESPACE" get endpointslice \
    -l kubernetes.io/service-name=aiostreams \
    -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{"\n"}{end}' 2>/dev/null || true)
if awk '$1 == "true" { found = 1 } END { exit found ? 0 : 1 }' <<<"$ready_endpoints"; then
    pass 'Service has a ready endpoint'
else
    fail 'Service has no ready endpoint'
fi

pvc_phase=$(json_value persistentvolumeclaim aiostreams-data '{.status.phase}')
pvc_storage_class=$(json_value persistentvolumeclaim aiostreams-data '{.spec.storageClassName}')
if [[ $pvc_phase == Bound && $pvc_storage_class == local-path ]]; then
    pass 'PVC is Bound on local-path'
else
    fail "PVC is not ready (phase=$pvc_phase storageClass=$pvc_storage_class)"
fi

for key in BASE_URL SECRET_KEY DATABASE_URI AIOSTREAMS_AUTH AIOSTREAMS_AUTH_REQUIRED TRUSTED_IPS; do
    value=$("$KUBECTL" -n "$NAMESPACE" get secret aiostreams-bootstrap \
        -o "jsonpath={.data.$key}" 2>/dev/null || true)
    if [[ -n $value ]]; then
        pass "bootstrap Secret contains $key (value withheld)"
    else
        fail "bootstrap Secret is missing $key"
    fi
    unset value
done

ingress_class=$(json_value ingress aiostreams '{.spec.ingressClassName}')
tls_secret=$(json_value ingress aiostreams '{.spec.tls[0].secretName}')
if [[ $ingress_class == traefik && $tls_secret == aiostreams-tls ]]; then
    pass 'Ingress uses Traefik and the AIOStreams TLS Secret'
else
    fail 'Ingress TLS/class shape is invalid'
fi

if "$KUBECTL" -n "$NAMESPACE" wait \
    --for=condition=Ready certificate/aiostreams-tls \
    --timeout="${WAIT_SECONDS}s" >/dev/null 2>&1; then
    pass 'AIOStreams Certificate is Ready'
else
    fail 'AIOStreams Certificate is not Ready'
fi

if [[ -n $AIOSTREAMS_URL ]]; then
    require_command curl
    health_code=$(curl --silent --show-error --output /dev/null \
        --write-out '%{http_code}' --max-time 30 "$AIOSTREAMS_URL/api/v1/health" || true)
    if [[ $health_code == 200 ]]; then
        pass 'external DB-backed health endpoint returns HTTP 200'
    else
        fail "external health endpoint returned HTTP $health_code"
    fi

    manifest_code=$(curl --silent --show-error --output /dev/null \
        --write-out '%{http_code}' --max-time 30 "$AIOSTREAMS_URL/stremio/manifest.json" || true)
    if [[ $manifest_code == 200 ]]; then
        pass 'public Stremio manifest returns HTTP 200'
    else
        fail "public Stremio manifest returned HTTP $manifest_code"
    fi

    configure_code=$(curl --silent --show-error --output /dev/null \
        --write-out '%{http_code}' --max-time 30 "$AIOSTREAMS_URL/stremio/configure" || true)
    if [[ $configure_code == 302 ]]; then
        pass 'unauthenticated configure request redirects to login'
    else
        fail "unauthenticated configure request returned HTTP $configure_code"
    fi
fi

if (( FAILURES > 0 )); then
    printf 'AIOStreams verification failed with %d failure(s).\n' "$FAILURES"
    exit 1
fi

printf 'AIOStreams verification passed.\n'
