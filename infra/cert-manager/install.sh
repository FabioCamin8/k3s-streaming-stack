#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/versions.env"

KUBECTL=${KUBECTL:-kubectl}
CERT_MANAGER_WAIT_SECONDS=${CERT_MANAGER_WAIT_SECONDS:-180}
TEMP_DIR=''

log() {
    printf '[INFO] %s\n' "$*" >&2
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

kube() {
    "$KUBECTL" "$@"
}

cleanup() {
    if [[ -n $TEMP_DIR && -d $TEMP_DIR ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}

trap cleanup EXIT

usage() {
    cat <<'USAGE'
Usage: install.sh

Download and install the exact cert-manager release recorded in versions.env
using the official static manifest. The temporary manifest is verified against
its pinned SHA-256 digest and is never kept in the repository.

Environment:
  KUBECTL                       kubectl command or absolute path
  KUBECONFIG                    operator-selected kubeconfig, when needed
  CERT_MANAGER_WAIT_SECONDS     readiness timeout per check (default: 180)
USAGE
}

while (($# > 0)); do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

[[ $CERT_MANAGER_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "invalid CERT_MANAGER_VERSION: $CERT_MANAGER_VERSION"
[[ $CERT_MANAGER_MANIFEST_SHA256 =~ ^[0-9a-f]{64}$ ]] ||
    die "invalid CERT_MANAGER_MANIFEST_SHA256"
[[ $CERT_MANAGER_WAIT_SECONDS =~ ^[1-9][0-9]*$ ]] ||
    die "CERT_MANAGER_WAIT_SECONDS must be positive"
command -v curl >/dev/null 2>&1 || die 'required command not found: curl'
command -v sha256sum >/dev/null 2>&1 || die 'required command not found: sha256sum'
command -v "$KUBECTL" >/dev/null 2>&1 || die "required command not found: $KUBECTL"

log "cert-manager release: $CERT_MANAGER_VERSION"
log "release URL: $CERT_MANAGER_RELEASE_URL"
log "static manifest: $CERT_MANAGER_MANIFEST_URL"
log "manifest digest verification: enabled"

TEMP_DIR=$(mktemp -d -t cert-manager-bootstrap.XXXXXX)
chmod 700 "$TEMP_DIR"
manifest_path="$TEMP_DIR/cert-manager.yaml"

curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --silent --show-error \
    "$CERT_MANAGER_MANIFEST_URL" --output "$manifest_path"
printf '%s  %s\n' "$CERT_MANAGER_MANIFEST_SHA256" "$manifest_path" |
    sha256sum --check --status - || die 'cert-manager manifest checksum verification failed'

log 'applying verified upstream static manifest'
kube apply --filename "$manifest_path"

for crd in \
    certificates.cert-manager.io \
    certificaterequests.cert-manager.io \
    challenges.acme.cert-manager.io \
    clusterissuers.cert-manager.io \
    issuers.cert-manager.io \
    orders.acme.cert-manager.io; do
    kube wait --for=condition=Established --timeout="${CERT_MANAGER_WAIT_SECONDS}s" "crd/$crd" >/dev/null
done

for deployment in cert-manager cert-manager-cainjector cert-manager-webhook; do
    kube -n "$CERT_MANAGER_NAMESPACE" rollout status \
        "deployment/$deployment" --timeout="${CERT_MANAGER_WAIT_SECONDS}s" >/dev/null
done

declare -A expected_images=(
    [cert-manager]="$CERT_MANAGER_CONTROLLER_IMAGE"
    [cert-manager-cainjector]="$CERT_MANAGER_CAINJECTOR_IMAGE"
    [cert-manager-webhook]="$CERT_MANAGER_WEBHOOK_IMAGE"
)
for deployment in "${!expected_images[@]}"; do
    image=$(kube -n "$CERT_MANAGER_NAMESPACE" get deployment "$deployment" \
        -o jsonpath='{.spec.template.spec.containers[0].image}')
    [[ $image == "${expected_images[$deployment]}" ]] ||
        die "$deployment image does not match $CERT_MANAGER_VERSION"
done

# A server-side dry run exercises the cert-manager validating webhook without
# creating a probe object or requiring the Cloudflare Secret to exist yet.
kube apply --server-side --dry-run=server --filename=- >/dev/null <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: cert-manager-install-webhook-probe
spec:
  selfSigned: {}
EOF

log "cert-manager $CERT_MANAGER_VERSION is installed, ready, and webhook-functional"
