#!/usr/bin/env bash

set -Eeuo pipefail

: "${DRY_RUN:=0}"

log() {
    printf '[INFO] %s\n' "$*" >&2
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

require_command() {
    local command_name=$1

    command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
}

require_root() {
    (( EUID == 0 )) || die "this operation must run as root on a Proxmox VE host"
}

require_proxmox_host() {
    require_root
    require_command pveversion
    pveversion >/dev/null || die "pveversion did not identify a working Proxmox VE host"
}

require_positive_integer() {
    local name=$1
    local value=$2

    [[ $value =~ ^[1-9][0-9]*$ ]] || die "$name must be a positive integer: $value"
}

require_nonempty() {
    local name=$1
    local value=$2

    [[ -n $value ]] || die "$name must be set"
}

require_vm_free() {
    local vmid=$1

    if qm status "$vmid" >/dev/null 2>&1; then
        die "VMID $vmid already exists; refusing to overwrite it"
    fi
}

require_vm_name_free() {
    local name=$1
    local vm_list

    vm_list=$(qm list) || die "unable to list existing VMs while checking name collision"
    if awk -v wanted="$name" 'NR > 1 && $2 == wanted { found = 1 } END { exit found ? 0 : 1 }' <<<"$vm_list"; then
        die "VM name $name already exists; refusing to create a duplicate"
    fi
}

require_bridge() {
    local bridge=$1

    ip link show dev "$bridge" >/dev/null 2>&1 || die "Proxmox bridge does not exist on this host: $bridge"
}

require_storage_content() {
    local storage=$1
    local content=$2

    if ! pvesm status --content "$content" | awk -v wanted="$storage" 'NR > 1 && $1 == wanted { found = 1 } END { exit found ? 0 : 1 }'; then
        die "storage $storage is not available for content type $content"
    fi
}

require_template() {
    local vmid=$1
    local config

    config=$(qm config "$vmid") || die "unable to read template VMID $vmid"
    if ! awk '$1 == "template:" && $2 == "1" { found = 1 } END { exit found ? 0 : 1 }' <<<"$config"; then
        die "VMID $vmid exists but is not a Proxmox template"
    fi
}

run_cmd() {
    if (( DRY_RUN )); then
        printf '[DRY-RUN]'
        printf ' %q' "$@"
        printf '\n'
        return 0
    fi

    "$@"
}
