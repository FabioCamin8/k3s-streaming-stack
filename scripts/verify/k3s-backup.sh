#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BACKUP_HELPER=$SCRIPT_DIR/../../infra/k3s/backup.sh

usage() {
    cat <<'USAGE'
Usage: k3s-backup.sh BACKUP_DIRECTORY

Verify a K3s recovery baseline without changing the backup or the cluster.
The verification checks the deterministic layout, required recovery artifacts,
metadata, ownership/modes, SHA-256 manifest, symlinks, and SQLite integrity.
Run it as root because the backup contains protected recovery material.
USAGE
}

(( EUID == 0 )) || {
    printf '[ERROR] run this verifier as root\n' >&2
    exit 1
}

if (($# != 1)) || [[ $1 == --help || $1 == -h ]]; then
    usage >&2
    (($# == 1)) && exit 0
    exit 2
fi

[[ -x $BACKUP_HELPER ]] || {
    printf '[ERROR] backup helper is missing or not executable: %s\n' "$BACKUP_HELPER" >&2
    exit 1
}

exec "$BACKUP_HELPER" --verify "$1"
