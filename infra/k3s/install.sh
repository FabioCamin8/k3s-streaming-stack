#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/versions.env"

DRY_RUN=0
TEMP_DIR=''

log() {
    printf '[INFO] %s\n' "$*" >&2
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n $TEMP_DIR && -d $TEMP_DIR ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}

trap cleanup EXIT

usage() {
    cat <<'USAGE'
Usage: install.sh [--dry-run]

Install the pinned K3s single-server release using the official installer for
service lifecycle management. The K3s binary and installer are downloaded and
verified against the hashes in versions.env before installation.

Options:
  --dry-run    Validate local prerequisites and print the exact plan.
  -h, --help   Show this help.

The release, node name, checksum URLs, and secrets-encryption policy are
defined in versions.env and must be changed there explicitly.
USAGE
}

while (($# > 0)); do
    case $1 in
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

(( EUID == 0 )) || die "K3s installation must run as root"

for command_name in curl sha256sum install mktemp systemctl uname grep awk; do
    command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done

[[ -r /etc/os-release ]] || die "/etc/os-release is missing"
# shellcheck disable=SC1091
source /etc/os-release
[[ ${ID:-} == debian && ${VERSION_ID:-} == 13* ]] || die "this installer requires Debian 13"
[[ $(uname -m) == x86_64 ]] || die "this release contract is for amd64 only"
[[ $K3S_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+$ ]] || die "invalid K3S_VERSION: $K3S_VERSION"
[[ $K3S_ARCH == amd64 ]] || die "unsupported K3S_ARCH: $K3S_ARCH"
[[ $K3S_BINARY_SHA256 =~ ^[0-9a-f]{64}$ ]] || die "invalid K3S_BINARY_SHA256"
[[ $K3S_INSTALLER_SHA256 =~ ^[0-9a-f]{64}$ ]] || die "invalid K3S_INSTALLER_SHA256"
[[ $K3S_NODE_NAME =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "invalid K3S_NODE_NAME: $K3S_NODE_NAME"
[[ $K3S_SECRETS_ENCRYPTION == 1 ]] || die "secrets encryption must remain enabled for this bootstrap"

if [[ -e /etc/systemd/system/k3s.service || -e /usr/local/bin/k3s || \
    -e /usr/local/bin/k3s-uninstall.sh || -e /var/lib/rancher/k3s ]]; then
    die "an existing K3s installation was detected; refusing reinstall or overwrite"
fi

log "K3s release: $K3S_VERSION"
log "K3s node name: $K3S_NODE_NAME"
log "Secrets encryption: enabled (K3s default aescbc provider)"
log "Binary: $K3S_BINARY_URL"
log "Checksum manifest: $K3S_CHECKSUM_URL"
log "Official installer: $K3S_INSTALLER_URL"

if (( DRY_RUN )); then
    log "dry-run: no download, file installation, service creation, or start performed"
    exit 0
fi

TEMP_DIR=$(mktemp -d -t k3s-bootstrap.XXXXXX)
chmod 700 "$TEMP_DIR"

binary_path="$TEMP_DIR/k3s"
checksum_path="$TEMP_DIR/sha256sum-amd64.txt"
installer_path="$TEMP_DIR/install.sh"

curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --silent --show-error \
    "$K3S_BINARY_URL" --output "$binary_path"
curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --silent --show-error \
    "$K3S_CHECKSUM_URL" --output "$checksum_path"
curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --silent --show-error \
    "$K3S_INSTALLER_URL" --output "$installer_path"

upstream_checksum=$(awk '$2 == "k3s" { print $1; exit }' "$checksum_path")
[[ $upstream_checksum == "$K3S_BINARY_SHA256" ]] || die "upstream checksum manifest does not match pinned K3S_BINARY_SHA256"
printf '%s  %s\n' "$K3S_BINARY_SHA256" "$binary_path" | sha256sum --check --status - \
    || die "K3s binary checksum verification failed"
printf '%s  %s\n' "$K3S_INSTALLER_SHA256" "$installer_path" | sha256sum --check --status - \
    || die "official K3s installer checksum verification failed"

binary_version=$("$binary_path" --version 2>&1)
grep -F -- "$K3S_VERSION" <<<"$binary_version" >/dev/null \
    || die "downloaded K3s binary reports an unexpected version: $binary_version"

install -m 0755 "$binary_path" /usr/local/bin/k3s

log "running the verified official installer with download disabled"
INSTALL_K3S_SKIP_DOWNLOAD=true \
INSTALL_K3S_BIN_DIR=/usr/local/bin \
INSTALL_K3S_EXEC="server --node-name $K3S_NODE_NAME --secrets-encryption" \
    sh "$installer_path"

systemctl daemon-reload
systemctl enable --now k3s
systemctl is-enabled --quiet k3s || die "k3s service is not enabled"
systemctl is-active --quiet k3s || die "k3s service is not active"

installed_version=$(/usr/local/bin/k3s --version 2>&1)
grep -F -- "$K3S_VERSION" <<<"$installed_version" >/dev/null \
    || die "installed K3s reports an unexpected version: $installed_version"

log "K3s $K3S_VERSION installed and active"
log "server datastore: default embedded SQLite unless overridden by operator configuration"
log "encryption key material is in /var/lib/rancher/k3s/server/cred/encryption-config.json; back it up with the datastore and server token"
