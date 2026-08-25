#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

TEMPLATE_VMID=${TEMPLATE_VMID:-9000}
VMID=${VMID:-9001}
VM_NAME=${VM_NAME:-k3s01}
STORAGE=${STORAGE:-}
BRIDGE=${BRIDGE:-vmbr0}
MTU=${MTU:-9000}
CORES=${CORES:-4}
MEMORY=${MEMORY:-6144}
DISK_SIZE=${DISK_SIZE:-40G}
CI_USER=${CI_USER:-debian}
SSH_PUBLIC_KEY_FILE=${SSH_PUBLIC_KEY_FILE:-}
START_VM=${START_VM:-1}

usage() {
    cat <<'USAGE'
Usage: spawn-k3s-node.sh [options]

Clone the Debian Cloud-Init template into a full, disposable k3s01 VM.
The image storage and an operator public-key file must be supplied explicitly.

Options:
  --template-vmid ID       Source template VMID (default: 9000)
  --vmid ID                New VMID (default: 9001)
  --name NAME              New VM name (default: k3s01)
  --storage ID             Target VM disk storage (required)
  --bridge NAME            Proxmox bridge (default: vmbr0)
  --mtu BYTES              Explicit guest NIC MTU (default: 9000)
  --cores COUNT            vCPU count (default: 4)
  --memory MIB             fixed RAM in MiB (default: 6144)
  --disk-size SIZE         root disk size (default: 40G)
  --ci-user USER            Cloud-Init user (default: debian)
  --ssh-public-key-file F  public SSH key file (required)
  --no-start               leave the clone powered off
  --dry-run                validate read-only prerequisites and print mutations
  -h, --help               Show this help

The same values may be supplied through TEMPLATE_VMID, VMID, VM_NAME, STORAGE,
BRIDGE, MTU, CORES, MEMORY, DISK_SIZE, CI_USER, SSH_PUBLIC_KEY_FILE, and
START_VM environment variables.
USAGE
}

while (($# > 0)); do
    case $1 in
        --template-vmid)
            (($# >= 2)) || die "--template-vmid requires a value"
            TEMPLATE_VMID=$2
            shift 2
            ;;
        --vmid)
            (($# >= 2)) || die "--vmid requires a value"
            VMID=$2
            shift 2
            ;;
        --name)
            (($# >= 2)) || die "--name requires a value"
            VM_NAME=$2
            shift 2
            ;;
        --storage)
            (($# >= 2)) || die "--storage requires a value"
            STORAGE=$2
            shift 2
            ;;
        --bridge)
            (($# >= 2)) || die "--bridge requires a value"
            BRIDGE=$2
            shift 2
            ;;
        --mtu)
            (($# >= 2)) || die "--mtu requires a value"
            MTU=$2
            shift 2
            ;;
        --cores)
            (($# >= 2)) || die "--cores requires a value"
            CORES=$2
            shift 2
            ;;
        --memory)
            (($# >= 2)) || die "--memory requires a value"
            MEMORY=$2
            shift 2
            ;;
        --disk-size)
            (($# >= 2)) || die "--disk-size requires a value"
            DISK_SIZE=$2
            shift 2
            ;;
        --ci-user)
            (($# >= 2)) || die "--ci-user requires a value"
            CI_USER=$2
            shift 2
            ;;
        --ssh-public-key-file)
            (($# >= 2)) || die "--ssh-public-key-file requires a value"
            SSH_PUBLIC_KEY_FILE=$2
            shift 2
            ;;
        --no-start)
            START_VM=0
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
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

require_proxmox_host
for command_name in qm pvesm ip awk ssh-keygen; do
    require_command "$command_name"
done

require_positive_integer TEMPLATE_VMID "$TEMPLATE_VMID"
require_positive_integer VMID "$VMID"
require_positive_integer MTU "$MTU"
require_positive_integer CORES "$CORES"
require_positive_integer MEMORY "$MEMORY"
require_nonempty STORAGE "$STORAGE"
require_nonempty SSH_PUBLIC_KEY_FILE "$SSH_PUBLIC_KEY_FILE"
[[ -r $SSH_PUBLIC_KEY_FILE ]] || die "SSH public key file is not readable: $SSH_PUBLIC_KEY_FILE"
[[ $CI_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || die "CI_USER is not a valid Linux account name: $CI_USER"
[[ $DISK_SIZE =~ ^[1-9][0-9]*G$ ]] || die "DISK_SIZE must be a whole GiB value such as 40G: $DISK_SIZE"
[[ $START_VM == 0 || $START_VM == 1 ]] || die "START_VM must be 0 or 1"

if ! ssh-keygen -lf "$SSH_PUBLIC_KEY_FILE" >/dev/null 2>&1; then
    die "SSH public key file could not be parsed: $SSH_PUBLIC_KEY_FILE"
fi

require_bridge "$BRIDGE"
require_storage_content "$STORAGE" images
require_template "$TEMPLATE_VMID"
require_vm_free "$VMID"
require_vm_name_free "$VM_NAME"
[[ $VMID != "$TEMPLATE_VMID" ]] || die "VMID and TEMPLATE_VMID must be different"

log "creating full clone $VM_NAME (VMID $VMID) from template VMID $TEMPLATE_VMID"
run_cmd qm clone "$TEMPLATE_VMID" "$VMID" \
    --full 1 \
    --name "$VM_NAME" \
    --storage "$STORAGE"

run_cmd qm resize "$VMID" scsi0 "$DISK_SIZE"
run_cmd qm set "$VMID" \
    --cpu cputype=host \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --balloon 0 \
    --agent enabled=1 \
    --net0 "virtio,bridge=${BRIDGE},mtu=${MTU}" \
    --ciuser "$CI_USER" \
    --sshkeys "$SSH_PUBLIC_KEY_FILE" \
    --ipconfig0 ip=dhcp \
    --onboot 1

if (( START_VM )); then
    run_cmd qm start "$VMID"
    log "started VMID $VMID; wait for Cloud-Init before verification: cloud-init status --wait"
else
    log "clone is powered off by request (--no-start)"
fi

log "k3s01 profile ready: $VM_NAME (VMID $VMID)"
