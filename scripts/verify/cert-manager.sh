#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../infra/cert-manager/versions.env"

KUBECTL=${KUBECTL:-kubectl}
CERT_MANAGER_WAIT_SECONDS=${CERT_MANAGER_WAIT_SECONDS:-180}
STAGING_ISSUER_NAME=${STAGING_ISSUER_NAME:-letsencrypt-staging}
PRODUCTION_ISSUER_NAME=${PRODUCTION_ISSUER_NAME:-letsencrypt-production}
STAGING_CERTIFICATE_NAME=${STAGING_CERTIFICATE_NAME:-platform-staging-certificate}
PRODUCTION_CERTIFICATE_NAME=${PRODUCTION_CERTIFICATE_NAME:-platform-production-certificate}
STAGING_TLS_SECRET_NAME=${STAGING_TLS_SECRET_NAME:-platform-staging-tls}
PRODUCTION_TLS_SECRET_NAME=${PRODUCTION_TLS_SECRET_NAME:-platform-production-tls}
FAILURES=0

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

kube() {
    "$KUBECTL" "$@"
}

check_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is missing: $1"
}

ready_condition() {
    local kind=$1 name=$2 condition
    condition=$(kube get "$kind" "$name" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    [[ $condition == True ]]
}

secret_key_exists() {
    local namespace=$1 name=$2 key=$3 value
    value=$(kube -n "$namespace" get secret "$name" \
        -o "jsonpath={.data['$key']}" 2>/dev/null || true)
    [[ -n $value ]]
    unset value
}

[[ $CERT_MANAGER_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'invalid pinned cert-manager version'
[[ $CERT_MANAGER_WAIT_SECONDS =~ ^[1-9][0-9]*$ ]] || fail 'invalid wait timeout'
check_command awk
check_command grep
check_command "$KUBECTL"

if kube get namespace "$CERT_MANAGER_NAMESPACE" >/dev/null 2>&1; then
    pass "namespace $CERT_MANAGER_NAMESPACE exists"
else
    fail "namespace $CERT_MANAGER_NAMESPACE is missing"
fi

declare -A expected_images=(
    [cert-manager]="$CERT_MANAGER_CONTROLLER_IMAGE"
    [cert-manager-cainjector]="$CERT_MANAGER_CAINJECTOR_IMAGE"
    [cert-manager-webhook]="$CERT_MANAGER_WEBHOOK_IMAGE"
)
for deployment in cert-manager cert-manager-cainjector cert-manager-webhook; do
    if kube -n "$CERT_MANAGER_NAMESPACE" rollout status \
        "deployment/$deployment" --timeout="${CERT_MANAGER_WAIT_SECONDS}s" >/dev/null 2>&1; then
        pass "deployment $CERT_MANAGER_NAMESPACE/$deployment is Ready"
    else
        fail "deployment $CERT_MANAGER_NAMESPACE/$deployment is not Ready"
    fi
    image=$(kube -n "$CERT_MANAGER_NAMESPACE" get deployment "$deployment" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
    if [[ $image == "${expected_images[$deployment]}" ]]; then
        pass "$deployment image matches $CERT_MANAGER_VERSION"
    else
        fail "$deployment image does not match $CERT_MANAGER_VERSION"
    fi
done

for crd in \
    certificates.cert-manager.io \
    certificaterequests.cert-manager.io \
    challenges.acme.cert-manager.io \
    clusterissuers.cert-manager.io \
    issuers.cert-manager.io \
    orders.acme.cert-manager.io; do
    if kube wait --for=condition=Established --timeout="${CERT_MANAGER_WAIT_SECONDS}s" \
        "crd/$crd" >/dev/null 2>&1; then
        pass "CRD $crd is Established"
    else
        fail "CRD $crd is not Established"
    fi
done

if kube apply --server-side --dry-run=server --filename=- >/dev/null 2>&1 <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: cert-manager-verifier-webhook-probe
spec:
  selfSigned: {}
EOF
then
    pass 'cert-manager webhook accepts a server-side dry-run'
else
    fail 'cert-manager webhook server-side dry-run failed'
fi

for issuer in "$STAGING_ISSUER_NAME" "$PRODUCTION_ISSUER_NAME"; do
    if ready_condition clusterissuer "$issuer"; then
        pass "ClusterIssuer $issuer is Ready"
    else
        fail "ClusterIssuer $issuer is not Ready"
    fi
done

for certificate in "$STAGING_CERTIFICATE_NAME" "$PRODUCTION_CERTIFICATE_NAME"; do
    if ready_condition certificate "$certificate"; then
        pass "Certificate $certificate is Ready"
    else
        fail "Certificate $certificate is not Ready"
    fi
done

if secret_key_exists "$CERT_MANAGER_NAMESPACE" cloudflare-api-token-secret api-token; then
    pass "Cloudflare Secret $CERT_MANAGER_NAMESPACE/cloudflare-api-token-secret has api-token key (value withheld)"
else
    fail "Cloudflare Secret $CERT_MANAGER_NAMESPACE/cloudflare-api-token-secret is missing api-token key"
fi

for secret in "$STAGING_TLS_SECRET_NAME" "$PRODUCTION_TLS_SECRET_NAME"; do
    if secret_key_exists default "$secret" tls.crt && secret_key_exists default "$secret" tls.key; then
        pass "TLS Secret default/$secret exists with certificate and key (values withheld)"
    else
        fail "TLS Secret default/$secret is missing certificate or key"
    fi
done

failed_pod_phases=$(kube -n "$CERT_MANAGER_NAMESPACE" get pods \
    -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null || true)
if awk '$1 == "Failed" { found = 1 } END { exit found ? 0 : 1 }' <<<"$failed_pod_phases"; then
    fail 'a cert-manager Pod is in Failed phase'
else
    pass 'no cert-manager Pod is in Failed phase'
fi

if (( FAILURES > 0 )); then
    printf 'cert-manager verification failed with %d failure(s).\n' "$FAILURES"
    exit 1
fi

printf 'cert-manager verification passed.\n'
