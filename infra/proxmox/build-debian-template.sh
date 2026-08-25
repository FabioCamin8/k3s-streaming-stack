#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"

TEMPLATE_VMID=${TEMPLATE_VMID:-9000}
TEMPLATE_NAME=${TEMPLATE_NAME:-debian13-cloud}
STORAGE=${STORAGE:-}
SNIPPET_STORAGE=${SNIPPET_STORAGE:-}
BRIDGE=${BRIDGE:-vmbr0}
MTU=${MTU:-9000}
VENDOR_FILE=${VENDOR_FILE:-$SCRIPT_DIR/debian13-base.vendor.yaml}

usage() {
    cat <<'USAGE'
Usage: build-debian-template.sh [options]

Build the pinned Debian 13 Cloud-Init template on the current Proxmox host.
The image storage must be supplied explicitly; local-lvm is not assumed.

Options:
  --template-vmid ID       Template VMID (default: 9000)
  --storage ID             Storage for VM disks (required)
  --snippet-storage ID     Storage for Cloud-Init snippets (default: storage)
  --bridge NAME            Proxmox bridge (default: vmbr0)
  --mtu BYTES              Explicit VM NIC MTU (default: 9000)
  --dry-run                Validate read-only prerequisites and print mutations
  -h, --help               Show this help

The same values may be supplied through TEMPLATE_VMID, STORAGE,
SNIPPET_STORAGE, BRIDGE, and MTU environment variables.
USAGE
}

while (($# > 0)); do
    case $1 in
        --template-vmid)
            (($# >= 2)) || die "--template-vmid requires a value"
            TEMPLATE_VMID=$2
            shift 2
            ;;
        --storage)
            (($# >= 2)) || die "--storage requires a value"
            STORAGE=$2
            shift 2
            ;;
        --snippet-storage)
            (($# >= 2)) || die "--snippet-storage requires a value"
            SNIPPET_STORAGE=$2
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

SNIPPET_STORAGE=${SNIPPET_STORAGE:-$STORAGE}
WORK_DIR=

cleanup() {
    if [[ -n $WORK_DIR && -d $WORK_DIR ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}

on_exit() {
    local exit_code=$?

    cleanup
    if (( exit_code != 0 )); then
        warn "template creation stopped; no automatic VM cleanup was attempted"
        warn "inspect VMID $TEMPLATE_VMID before retrying if creation had already started"
    fi
    exit "$exit_code"
}

trap on_exit EXIT

require_proxmox_host
for command_name in qm pvesm ip curl sha512sum awk cmp install mktemp; do
    require_command "$command_name"
done

require_positive_integer TEMPLATE_VMID "$TEMPLATE_VMID"
require_positive_integer MTU "$MTU"
require_nonempty STORAGE "$STORAGE"
require_nonempty VENDOR_FILE "$VENDOR_FILE"
[[ -r $VENDOR_FILE ]] || die "vendor-data file is not readable: $VENDOR_FILE"

[[ $DEBIAN_MAJOR == 13 ]] || die "this builder expects Debian major version 13, got $DEBIAN_MAJOR"
[[ $DEBIAN_IMAGE_VERSION =~ ^[0-9]{8}-[0-9]+$ ]] || die "DEBIAN_IMAGE_VERSION is not an immutable dated build: $DEBIAN_IMAGE_VERSION"
[[ $DEBIAN_IMAGE_URL != */latest/* ]] || die "DEBIAN_IMAGE_URL must not use the moving latest path"
[[ $DEBIAN_IMAGE_URL == */$DEBIAN_IMAGE_VERSION/* ]] || die "DEBIAN_IMAGE_URL is not pinned to DEBIAN_IMAGE_VERSION"
[[ $DEBIAN_IMAGE_CHECKSUM_URL == */$DEBIAN_IMAGE_VERSION/* ]] || die "DEBIAN_IMAGE_CHECKSUM_URL is not pinned to DEBIAN_IMAGE_VERSION"
[[ $DEBIAN_IMAGE_SHA512 =~ ^[[:xdigit:]]{128}$ ]] || die "DEBIAN_IMAGE_SHA512 must be a 128-character SHA-512 digest"

IMAGE_NAME=${DEBIAN_IMAGE_URL##*/}
VENDOR_NAME=${VENDOR_FILE##*/}
SNIPPET_VOLID="${SNIPPET_STORAGE}:snippets/${VENDOR_NAME}"

require_bridge "$BRIDGE"
require_storage_content "$STORAGE" images
require_storage_content "$SNIPPET_STORAGE" snippets
require_vm_free "$TEMPLATE_VMID"
require_vm_name_free "$TEMPLATE_NAME"

WORK_DIR=$(mktemp -d)
IMAGE_FILE="$WORK_DIR/$IMAGE_NAME"
CHECKSUM_FILE="$WORK_DIR/SHA512SUMS"

if (( DRY_RUN )); then
    log "dry-run: skipping image download and checksum verification"
else
    log "downloading pinned Debian image: $DEBIAN_IMAGE_URL"
    curl --fail --location --proto '=https' --tlsv1.2 --output "$IMAGE_FILE" "$DEBIAN_IMAGE_URL"
    curl --fail --location --proto '=https' --tlsv1.2 --output "$CHECKSUM_FILE" "$DEBIAN_IMAGE_CHECKSUM_URL"

    checksum=$(awk -v wanted="$IMAGE_NAME" '$2 == wanted { print $1; exit }' "$CHECKSUM_FILE")
    [[ $checksum == "$DEBIAN_IMAGE_SHA512" ]] || die "checksum file did not contain the pinned SHA-512 for $IMAGE_NAME"
    printf '%s  %s\n' "$checksum" "$IMAGE_FILE" | sha512sum --check --status - || die "SHA-512 verification failed for $IMAGE_NAME"
    log "verified Debian image SHA-512: $checksum"
fi

snippet_path=$(pvesm path "$SNIPPET_VOLID") || die "unable to resolve Cloud-Init snippet path: $SNIPPET_VOLID"
if [[ -e $snippet_path ]]; then
    cmp -s "$VENDOR_FILE" "$snippet_path" || die "existing snippet differs: $snippet_path; refusing to overwrite it"
    log "reusing identical Cloud-Init vendor-data snippet: $SNIPPET_VOLID"
elif (( DRY_RUN )); then
    log "dry-run: would install vendor-data snippet at $snippet_path"
else
    install -D -m 0644 "$VENDOR_FILE" "$snippet_path"
    log "installed Cloud-Init vendor-data snippet: $SNIPPET_VOLID"
fi

log "creating Debian template VMID $TEMPLATE_VMID ($TEMPLATE_NAME)"
run_cmd qm create "$TEMPLATE_VMID" \
    --name "$TEMPLATE_NAME" \
    --ostype l26 \
    --machine q35 \
    --bios ovmf \
    --cpu cputype=host \
    --cores 2 \
    --memory 2048 \
    --balloon 0 \
    --ciupgrade 0 \
    --scsihw virtio-scsi-single \
    --agent enabled=1 \
    --serial0 socket \
    --vga serial0 \
    --net0 "virtio,bridge=${BRIDGE},mtu=${MTU}"

run_cmd qm set "$TEMPLATE_VMID" \
    --efidisk0 "${STORAGE}:0,efitype=4m"

if (( DRY_RUN )); then
    run_cmd qm disk import "$TEMPLATE_VMID" "$IMAGE_FILE" "$STORAGE"
    imported_volume="${STORAGE}:vm-${TEMPLATE_VMID}-disk-1"
    log "dry-run: using illustrative imported disk volume $imported_volume"
else
    log "importing Debian cloud disk into $STORAGE"
    qm disk import "$TEMPLATE_VMID" "$IMAGE_FILE" "$STORAGE" >"$WORK_DIR/importdisk.log" 2>&1 || {
        sed -n '1,120p' "$WORK_DIR/importdisk.log" >&2
        die "qm disk import failed; inspect VMID $TEMPLATE_VMID before retrying"
    }
    imported_volume=$(qm config "$TEMPLATE_VMID" | awk '$1 ~ /^unused[0-9]+:/ { print $2; exit }')
    [[ -n $imported_volume ]] || die "qm disk import completed but no unused disk was found in VM config"
fi

run_cmd qm set "$TEMPLATE_VMID" \
    --scsi0 "${imported_volume},discard=on,ssd=1,iothread=1"
run_cmd qm set "$TEMPLATE_VMID" --ide2 "${STORAGE}:cloudinit"
run_cmd qm set "$TEMPLATE_VMID" --boot order=scsi0
run_cmd qm set "$TEMPLATE_VMID" --cicustom "vendor=${SNIPPET_VOLID}"
run_cmd qm template "$TEMPLATE_VMID"

log "template ready: $TEMPLATE_NAME (VMID $TEMPLATE_VMID)"
