#!/usr/bin/env bash

set -Eeuo pipefail

EXPECTED_K3S_VERSION=${EXPECTED_K3S_VERSION:-}
EXPECTED_NODE_NAME=${EXPECTED_NODE_NAME:-k3s01}
K3S_WAIT_SECONDS=${K3S_WAIT_SECONDS:-180}
FAILURES=0

pass() { printf 'PASS: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is missing: $1"
}

deployment_ready() {
    local namespace=$1 name=$2 desired ready
    desired=$(kubectl -n "$namespace" get deployment "$name" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
    ready=$(kubectl -n "$namespace" get deployment "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
    [[ $desired =~ ^[1-9][0-9]*$ && $ready == "$desired" ]]
}

daemonset_ready() {
    local namespace=$1 name=$2 desired ready
    desired=$(kubectl -n "$namespace" get daemonset "$name" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || true)
    ready=$(kubectl -n "$namespace" get daemonset "$name" -o jsonpath='{.status.numberReady}' 2>/dev/null || true)
    [[ $desired =~ ^[1-9][0-9]*$ && $ready == "$desired" ]]
}

wait_for_deployment() {
    local namespace=$1 name=$2 attempts=$((K3S_WAIT_SECONDS / 5))
    (( attempts > 0 )) || attempts=1
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        deployment_ready "$namespace" "$name" && return 0
        sleep 5
    done
    return 1
}

wait_for_metrics() {
    local attempts=$((K3S_WAIT_SECONDS / 5)) output
    (( attempts > 0 )) || attempts=1
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        if output=$(kubectl top node --no-headers 2>/dev/null) && [[ -n $output ]]; then
            printf '%s\n' "$output"
            return 0
        fi
        sleep 5
    done
    return 1
}

interface_mtu() {
    local interface=$1
    ip -o link show dev "$interface" 2>/dev/null |
        awk -F ' mtu ' 'NF > 1 { split($2, fields, " "); print fields[1]; exit }'
}

(( EUID == 0 )) || fail "run this verifier as root (for example with sudo)"
[[ -n $EXPECTED_K3S_VERSION ]] || fail "EXPECTED_K3S_VERSION is required"
[[ $EXPECTED_NODE_NAME =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail "invalid EXPECTED_NODE_NAME"
[[ $K3S_WAIT_SECONDS =~ ^[1-9][0-9]*$ ]] || fail "K3S_WAIT_SECONDS must be positive"

for command_name in awk curl dpkg-query grep ip k3s kubectl sed sleep systemctl; do
    require_command "$command_name"
done

if systemctl is-enabled --quiet k3s; then
    pass "k3s service is enabled"
else
    fail "k3s service is not enabled"
fi
if systemctl is-active --quiet k3s; then
    pass "k3s service is active"
else
    fail "k3s service is not active"
fi

k3s_version_output=$(k3s --version 2>&1 || true)
if grep -F -- "$EXPECTED_K3S_VERSION" <<<"$k3s_version_output" >/dev/null; then
    pass "K3s version is $EXPECTED_K3S_VERSION"
else
    fail "K3s version mismatch: expected $EXPECTED_K3S_VERSION; got $k3s_version_output"
fi

if kubectl cluster-info >/dev/null 2>&1; then
    pass "Kubernetes API is reachable"
else
    fail "Kubernetes API is not reachable"
fi

nodes=$(kubectl get nodes --no-headers 2>/dev/null || true)
node_count=$(awk 'NF { count++ } END { print count + 0 }' <<<"$nodes")
if [[ $node_count == 1 ]]; then
    pass "exactly one cluster node exists"
else
    fail "expected one cluster node, found $node_count"
fi
if awk -v expected="$EXPECTED_NODE_NAME" '$1 == expected && $2 == "Ready" { found = 1 } END { exit found ? 0 : 1 }' <<<"$nodes"; then
    pass "node $EXPECTED_NODE_NAME is Ready"
else
    fail "node $EXPECTED_NODE_NAME is not Ready"
fi

for component in coredns traefik local-path-provisioner metrics-server; do
    if wait_for_deployment kube-system "$component"; then
        pass "deployment kube-system/$component is ready"
    else
        fail "deployment kube-system/$component is not ready within ${K3S_WAIT_SECONDS}s"
    fi
done

if daemonset_ready kube-system svclb-traefik; then
    pass "ServiceLB daemonset kube-system/svclb-traefik is ready"
else
    fail "ServiceLB daemonset kube-system/svclb-traefik is not ready"
fi
if kubectl -n kube-system get service traefik >/dev/null 2>&1; then
    pass "Traefik Service exists"
else
    fail "Traefik Service is missing"
fi

storageclasses=$(kubectl get storageclass -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' 2>/dev/null || true)
if awk '$2 == "true" { found = 1 } END { exit found ? 0 : 1 }' <<<"$storageclasses"; then
    pass "a default StorageClass is available"
else
    fail "no default StorageClass is available"
fi
if kubectl get ingressclass traefik >/dev/null 2>&1; then
    pass "Traefik IngressClass exists"
else
    fail "Traefik IngressClass is missing"
fi

primary_interface=$(ip -o route show default 2>/dev/null | awk 'NR == 1 { print $5; exit }')
primary_mtu=''
if [[ -n $primary_interface ]]; then
    primary_mtu=$(interface_mtu "$primary_interface")
    if [[ $primary_mtu == 9000 ]]; then
        pass "primary interface $primary_interface MTU is 9000"
    else
        fail "primary interface $primary_interface MTU is ${primary_mtu:-unknown}, expected 9000"
    fi
else
    fail "no default route exists"
fi

if ip link show dev cni0 >/dev/null 2>&1; then
    cni_mtu=$(interface_mtu cni0)
    pass "CNI bridge cni0 exists with observed MTU ${cni_mtu:-unknown}"
    if [[ $primary_mtu =~ ^[0-9]+$ && $cni_mtu =~ ^[0-9]+$ ]] && (( cni_mtu <= primary_mtu )); then
        pass "cni0 MTU does not exceed the underlay MTU"
    else
        fail "cni0 MTU is inconsistent with the underlay"
    fi
else
    fail "CNI bridge cni0 is missing"
fi

overlay_interface=$(ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^(flannel|vxlan|geneve|cilium)/ { split($2, fields, "@"); print fields[1]; exit }')
if [[ -n $overlay_interface ]]; then
    overlay_mtu=$(interface_mtu "$overlay_interface")
    pass "overlay interface $overlay_interface exists with observed MTU ${overlay_mtu:-unknown}"
    if [[ $primary_mtu =~ ^[0-9]+$ && $overlay_mtu =~ ^[0-9]+$ ]] && (( overlay_mtu <= primary_mtu )); then
        pass "overlay MTU does not exceed the underlay MTU"
    else
        fail "overlay MTU is inconsistent with the underlay"
    fi
else
    warn "no conventional overlay interface was discovered"
fi

if output=$(wait_for_metrics 2>&1); then
    pass "metrics-server is functional: $output"
else
    fail "kubectl top node did not become functional within ${K3S_WAIT_SECONDS}s"
fi

runtime_failure=0
for package_name in docker.io docker-ce docker-ce-cli podman podman-docker; do
    if dpkg-query -W -f='${Status}' "$package_name" 2>/dev/null | grep -Fxq 'install ok installed'; then
        fail "unexpected Docker/Podman package is installed: $package_name"
        runtime_failure=1
    fi
done
if (( runtime_failure == 0 )); then
    pass "no Docker or Podman package is installed"
fi

failed_units=$(systemctl --failed --no-legend --no-pager 2>/dev/null || true)
if grep -Eiq 'k3s|containerd|flannel|coredns|traefik|metrics' <<<"$failed_units"; then
    fail "K3s-related systemd units are failed: $failed_units"
elif [[ -n $failed_units ]]; then
    warn "unrelated failed systemd units exist: $failed_units"
else
    pass "no failed systemd units"
fi

for port in 80 443; do
    scheme=http
    curl_options=()
    if [[ $port == 443 ]]; then
        scheme=https
        curl_options=(-k)
    fi
    http_status=$(curl "${curl_options[@]}" --connect-timeout 5 --max-time 10 --silent --output /dev/null --write-out '%{http_code}' "${scheme}://127.0.0.1:${port}" 2>/dev/null || true)
    if [[ $http_status =~ ^(400|404|421)$ ]]; then
        pass "Traefik edge ${scheme}://127.0.0.1:${port} returned expected no-route status $http_status"
    else
        fail "Traefik edge ${scheme}://127.0.0.1:${port} returned unexpected status ${http_status:-unreachable}"
    fi
done

if (( FAILURES > 0 )); then
    printf 'K3s node verification failed with %d failure(s).\n' "$FAILURES"
    exit 1
fi

printf 'K3s node verification passed.\n'
