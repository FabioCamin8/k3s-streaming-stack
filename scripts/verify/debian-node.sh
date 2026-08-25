#!/usr/bin/env bash

set -Eeuo pipefail

EXPECTED_MTU=${EXPECTED_MTU:-9000}
EXPECTED_DISK_SIZE_GIB=${EXPECTED_DISK_SIZE_GIB:-40}
FAILURES=0

pass() {
    printf 'PASS: %s\n' "$*"
}

warn() {
    printf 'WARN: %s\n' "$*"
}

fail() {
    printf 'FAIL: %s\n' "$*"
    FAILURES=$((FAILURES + 1))
}

check_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required verification command is missing: $1"
}

check_command awk
check_command cloud-init
check_command dpkg-query
check_command find
check_command findmnt
check_command getent
check_command ip
check_command lsblk
check_command sshd
check_command systemctl
check_command timedatectl

warn "K3s and the CNI overlay are intentionally outside this pre-K3s baseline"

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ ${ID:-} == debian && ${VERSION_ID:-} == 13* && ${VERSION_CODENAME:-} == trixie ]]; then
        pass "guest is Debian 13 (trixie)"
    else
        fail "guest is not Debian 13 trixie (ID=${ID:-unknown}, VERSION_ID=${VERSION_ID:-unknown}, CODENAME=${VERSION_CODENAME:-unknown})"
    fi
else
    fail "/etc/os-release is missing"
fi

cloud_init_status=''
cloud_init_rc=0
cloud_init_status=$(cloud-init status --wait 2>&1) || cloud_init_rc=$?
cloud_init_details=$(cloud-init status --long 2>&1 || true)
if awk '
    /^status: done$/ { done = 1 }
    /^errors: \[\]$/ { no_errors = 1 }
    END { exit (done && no_errors) ? 0 : 1 }
' <<<"$cloud_init_details"; then
    if (( cloud_init_rc != 0 )); then
        warn "Cloud-Init completed with recoverable warnings (status exit $cloud_init_rc)"
    fi
    pass "Cloud-Init completed"
else
    fail "Cloud-Init did not complete successfully: ${cloud_init_details:-$cloud_init_status}"
fi

if systemctl is-enabled --quiet qemu-guest-agent; then
    pass "qemu-guest-agent is enabled"
else
    fail "qemu-guest-agent is not enabled"
fi
if systemctl is-active --quiet qemu-guest-agent; then
    pass "qemu-guest-agent is active"
else
    fail "qemu-guest-agent is not active"
fi

ssh_effective_config=''
if ssh_effective_config=$(sshd -T 2>&1); then
    for setting in 'permitrootlogin no' 'passwordauthentication no' 'kbdinteractiveauthentication no'; do
        if awk -v expected="$setting" '$0 == expected { found = 1 } END { exit found ? 0 : 1 }' <<<"$ssh_effective_config"; then
            pass "effective SSH setting: $setting"
        else
            fail "effective SSH setting is not enforced: $setting"
        fi
    done
else
    fail "sshd -T could not read the effective SSH configuration: $ssh_effective_config"
fi

if find /home -xdev -type f -name authorized_keys -size +0c -print -quit 2>/dev/null | awk 'NF { found = 1 } END { exit found ? 0 : 1 }'; then
    pass "a non-root SSH authorized_keys file is present"
else
    fail "no non-root SSH authorized_keys file with a key was found"
fi

root_source=$(findmnt -n -o SOURCE / 2>/dev/null || true)
if [[ -n $root_source ]]; then
    root_parent=$(lsblk -no PKNAME "$root_source" 2>/dev/null || true)
    if [[ -n $root_parent ]]; then
        root_disk="/dev/$root_parent"
    else
        root_disk=$root_source
    fi
    disk_bytes=$(lsblk -bndo SIZE "$root_disk" 2>/dev/null || true)
    minimum_bytes=$((EXPECTED_DISK_SIZE_GIB * 1024 * 1024 * 1024))
    if [[ $disk_bytes =~ ^[0-9]+$ ]] && (( disk_bytes >= minimum_bytes )); then
        pass "root disk is at least ${EXPECTED_DISK_SIZE_GIB} GiB ($root_disk)"
    else
        fail "root disk is smaller than ${EXPECTED_DISK_SIZE_GIB} GiB or could not be measured ($root_disk)"
    fi
else
    fail "could not determine the root block device"
fi

primary_interface=$(ip -o route show default 2>/dev/null | awk 'NR == 1 { print $5; exit }')
if [[ -n $primary_interface ]]; then
    pass "default route exists through $primary_interface"
    interface_mtu=$(ip -o link show dev "$primary_interface" 2>/dev/null | awk -F ' mtu ' 'NF > 1 { split($2, fields, " "); print fields[1]; exit }')
    if [[ $interface_mtu == "$EXPECTED_MTU" ]]; then
        pass "primary interface MTU is $EXPECTED_MTU"
    else
        fail "primary interface MTU is ${interface_mtu:-unknown}, expected $EXPECTED_MTU"
    fi
else
    fail "no default route exists"
fi

if getent ahostsv4 deb.debian.org >/dev/null 2>&1; then
    pass "DNS resolution works"
else
    fail "DNS resolution failed for deb.debian.org"
fi

unexpected_runtime=0
for package_name in docker.io docker-ce docker-ce-cli podman containerd containerd.io cri-o; do
    if dpkg-query -W -f='${Status}' "$package_name" 2>/dev/null | awk '$0 == "install ok installed" { found = 1 } END { exit found ? 0 : 1 }'; then
        fail "unexpected container runtime package is installed: $package_name"
        unexpected_runtime=1
    fi
done
if (( unexpected_runtime == 0 )); then
    pass "no Docker, Podman, containerd, or CRI-O package is installed"
fi

if command -v k3s >/dev/null 2>&1; then
    fail "K3s is installed even though this baseline is pre-K3s"
else
    pass "K3s is not installed"
fi

if [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null || true) == yes ]]; then
    pass "system time is synchronized"
else
    fail "system time is not synchronized"
fi

time_sync_active=0
for service in systemd-timesyncd chrony ntp; do
    if systemctl is-active --quiet "$service"; then
        pass "time synchronization service is active: $service"
        time_sync_active=1
        break
    fi
done
if (( time_sync_active == 0 )); then
    fail "no supported time synchronization service is active"
fi

if (( FAILURES > 0 )); then
    printf 'Baseline verification failed with %d failure(s).\n' "$FAILURES"
    exit 1
fi

printf 'Baseline verification passed.\n'
