#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BACKUP_PATH=''
EXPECTED_K3S_VERSION=''
FORCE_RESTORE=0
PRESERVE_STAMP=$(date -u +%Y%m%dT%H%M%SZ)
PRESERVED_PATHS=()
K3S_STOPPED_BY_SCRIPT=0
RESTORE_PHASE='PRE_MUTATION'

log() {
    printf '[INFO] %s\n' "$*" >&2
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage: restore.sh --force-restore [--expected-k3s-version VERSION] BACKUP_DIRECTORY

Destructively restore the K3s state/configuration boundary from a verified
backup. The exact K3s release must already be installed on the target.

The explicit --force-restore flag is mandatory. Existing K3s state is moved
to adjacent .pre-restore paths and is never silently deleted.
USAGE
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

preserve_if_present() {
    local source=$1 preserved

    if [[ -e $source || -L $source ]]; then
        preserved="${source}.pre-restore.${PRESERVE_STAMP}"
        [[ ! -e $preserved && ! -L $preserved ]] ||
            die "pre-restore path already exists: $preserved"
        RESTORE_PHASE='LIVE_STATE_PRESERVED_OR_RESTORE_IN_PROGRESS'
        PRESERVED_PATHS+=("$preserved")
        mv -- "$source" "$preserved"
    fi
}

copy_if_present() {
    local relative=$1 target source

    source=$BACKUP_PATH/server-state/$relative
    target=/$relative
    if [[ -e $source || -L $source ]]; then
        mkdir -p -- "$(dirname -- "$target")"
        cp -a -- "$source" "$target"
    fi
}

cluster_is_ready() {
    local nodes node_count

    systemctl is-active --quiet k3s || return 1
    nodes=$(kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get nodes --no-headers 2>/dev/null) ||
        return 1
    node_count=$(awk 'NF { count++ } END { print count + 0 }' <<<"$nodes")
    (( node_count == 1 )) || return 1
    awk '$2 == "Ready" { found = 1 } END { exit found ? 0 : 1 }' <<<"$nodes"
}

wait_for_stopped() {
    local attempt

    for ((attempt = 1; attempt <= 30; attempt++)); do
        if ! systemctl is-active --quiet k3s; then
            return 0
        fi
        sleep 1
    done
    return 1
}

wait_for_recovery() {
    local attempt

    for ((attempt = 1; attempt <= 180; attempt++)); do
        if cluster_is_ready; then
            return 0
        fi
        sleep 1
    done
    return 1
}

secrets_encryption_is_healthy() {
    local encryption_status

    encryption_status=$(k3s secrets-encrypt status 2>/dev/null) || return 1
    grep -Fxq 'Encryption Status: Enabled' <<<"$encryption_status" || return 1
    grep -Fxq 'Server Encryption Hashes: All hashes match' <<<"$encryption_status"
}

wait_for_encryption_status() {
    local attempt

    for ((attempt = 1; attempt <= 180; attempt++)); do
        if secrets_encryption_is_healthy; then
            return 0
        fi
        sleep 1
    done
    return 1
}

sqlite_integrity_check() {
    local database=$1 validation_dir result

    validation_dir=$(mktemp -d -t k3s-sqlite-restore-check.XXXXXX)
    if ! cp -- "$database" "$validation_dir/state.db"; then
        rm -rf -- "$validation_dir"
        return 1
    fi
    if [[ -e ${database}-wal || -L ${database}-wal ]]; then
        if ! cp -a -- "${database}-wal" "$validation_dir/state.db-wal"; then
            rm -rf -- "$validation_dir"
            return 1
        fi
    fi

    if command -v sqlite3 >/dev/null 2>&1; then
        result=$(sqlite3 -readonly "$validation_dir/state.db" 'PRAGMA integrity_check;' 2>/dev/null) || {
            rm -rf -- "$validation_dir"
            return 1
        }
    elif command -v python3 >/dev/null 2>&1; then
        result=$(python3 - "$validation_dir/state.db" <<'PY'
import sqlite3
import sys

database = sys.argv[1]
connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
try:
    result = connection.execute("PRAGMA integrity_check;").fetchall()
finally:
    connection.close()

if len(result) != 1 or result[0][0] != "ok":
    raise SystemExit("; ".join(str(row[0]) for row in result))
print("ok")
PY
        ) || {
            rm -rf -- "$validation_dir"
            return 1
        }
    else
        rm -rf -- "$validation_dir"
        return 2
    fi

    rm -rf -- "$validation_dir" || return 1
    [[ $result == ok ]]
}

read_metadata() {
    local info=$BACKUP_PATH/metadata/backup-info.tsv

    K3S_VERSION=$(awk -F= '$1 == "k3s_version" { print substr($0, index($0, "=") + 1); exit }' "$info")
    NODE_NAME=$(awk -F= '$1 == "node_name" { print substr($0, index($0, "=") + 1); exit }' "$info")
    [[ $K3S_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+$ ]] ||
        die 'backup K3s version metadata is missing or invalid'
    [[ $NODE_NAME =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
        die 'backup node name metadata is missing or invalid'
}

require_safe_backup_directory() {
    local canonical_path parent canonical_parent parent_permissions

    [[ $BACKUP_PATH == /* ]] || die 'backup path must be an absolute path'
    [[ -d $BACKUP_PATH && ! -L $BACKUP_PATH ]] || die 'backup path is not a real directory'
    canonical_path=$(readlink -f -- "$BACKUP_PATH") || die 'could not resolve backup path'
    [[ $(stat -c '%u:%g' "$canonical_path") == 0:0 ]] ||
        die 'backup path must be root-owned'
    [[ $(stat -c '%a' "$canonical_path") == 700 ]] ||
        die 'backup path must be mode 700'
    parent=$(dirname -- "$canonical_path")
    canonical_parent=$(readlink -f -- "$parent") ||
        die 'could not resolve backup parent'
    [[ -d $canonical_parent && ! -L $canonical_parent ]] ||
        die 'backup parent is not a real directory'
    [[ $(stat -c '%u:%g' "$canonical_parent") == 0:0 ]] ||
        die 'backup parent must be root-owned'
    parent_permissions=$(stat -c '%A' "$canonical_parent")
    [[ ${parent_permissions:5:1} != w && ${parent_permissions:8:1} != w ]] ||
        die 'backup parent must not be group/world-writable'
    BACKUP_PATH=$canonical_path
    case "$canonical_path/" in
        /var/lib/rancher/k3s|/var/lib/rancher/k3s/*|/etc/rancher/k3s|/etc/rancher/k3s/*)
            die 'backup path must not be inside live K3s state'
            ;;
    esac
}

restore_backup() {
    local current_version database nodes

    require_command awk
    require_command cp
    require_command grep
    require_command kubectl
    require_command k3s
    require_command mkdir
    require_command mktemp
    require_command mv
    require_command rm
    require_command readlink
    require_command sleep
    require_command stat
    require_command systemctl
    require_safe_backup_directory

    [[ -x $SCRIPT_DIR/backup.sh ]] || die "verification helper is missing: $SCRIPT_DIR/backup.sh"
    bash "$SCRIPT_DIR/backup.sh" --verify "$BACKUP_PATH"
    read_metadata

    current_version=$(k3s --version | awk 'NR == 1 { print $3; exit }')
    [[ $current_version == "$K3S_VERSION" ]] ||
        die "K3s version mismatch: backup $K3S_VERSION, installed $current_version"
    if [[ -n $EXPECTED_K3S_VERSION && $EXPECTED_K3S_VERSION != "$K3S_VERSION" ]]; then
        die "backup version $K3S_VERSION does not match requested version $EXPECTED_K3S_VERSION"
    fi

    database=$BACKUP_PATH/server-state/var/lib/rancher/k3s/server/db/state.db
    sqlite_integrity_check "$database" || die 'backup SQLite state.db failed read-only integrity_check'
    log 'backup SQLite integrity_check passed in read-only mode'

    if systemctl is-active --quiet k3s; then
        log 'stopping K3s for destructive restore'
        K3S_STOPPED_BY_SCRIPT=1
    else
        log 'K3s is already inactive; proceeding with destructive restore'
    fi
    systemctl stop k3s
    wait_for_stopped || die 'K3s did not stop within 30 seconds for restore'

    preserve_if_present /var/lib/rancher/k3s
    preserve_if_present /etc/rancher/k3s
    preserve_if_present /etc/systemd/system/k3s.service
    preserve_if_present /etc/systemd/system/k3s.service.env
    preserve_if_present /etc/systemd/system/k3s.service.d
    preserve_if_present /etc/default/k3s
    preserve_if_present /etc/sysconfig/k3s

    RESTORE_PHASE='LIVE_STATE_PRESERVED_OR_RESTORE_IN_PROGRESS'
    copy_if_present var/lib/rancher/k3s
    copy_if_present etc/rancher/k3s
    copy_if_present etc/systemd/system/k3s.service
    copy_if_present etc/systemd/system/k3s.service.env
    copy_if_present etc/systemd/system/k3s.service.d
    copy_if_present etc/default/k3s
    copy_if_present etc/sysconfig/k3s

    database=/var/lib/rancher/k3s/server/db/state.db
    sqlite_integrity_check "$database" ||
        die 'restored SQLite state.db failed read-only integrity_check'
    log 'restored SQLite state.db passed read-only integrity_check'

    RESTORE_PHASE='RESTORE_INSTALLED_AND_STARTING'
    systemctl daemon-reload
    systemctl start k3s
    wait_for_recovery || die 'K3s did not recover after restore; pre-restore state was preserved'
    wait_for_encryption_status ||
        die 'K3s secrets encryption did not become healthy after restore'

    nodes=$(kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get nodes --no-headers)
    RESTORE_PHASE='RESTORE_SUCCEEDED'
    log "restored K3s $K3S_VERSION with one Ready node"
    log "restored node identity: $(awk 'NF { print $1; exit }' <<<"$nodes")"
    log 'secrets encryption remains enabled with matching server hashes'
    log 'pre-restore state preserved at:'
    print_preserved_paths
}

print_preserved_paths() {
    local path listed=0

    for path in "${PRESERVED_PATHS[@]}"; do
        if [[ -e $path || -L $path ]]; then
            printf '  %s\n' "$path" >&2
            listed=1
        fi
    done
    if (( ! listed )); then
        printf '  (no completed pre-restore path was confirmed; inspect before repair)\n' >&2
    fi
}

restore_cleanup() {
    local status=$?

    case $RESTORE_PHASE in
        PRE_MUTATION)
            if (( K3S_STOPPED_BY_SCRIPT )); then
                printf '[INFO] restore failed before destructive mutation; restarting original K3s\n' >&2
                if ! systemctl start k3s; then
                    printf '[ERROR] original K3s failed to start after pre-mutation restore failure\n' >&2
                    status=1
                elif ! wait_for_recovery; then
                    printf '[ERROR] original K3s did not recover after pre-mutation restore failure\n' >&2
                    status=1
                else
                    printf '[INFO] original K3s recovered after pre-mutation restore failure\n' >&2
                fi
            fi
            ;;
        LIVE_STATE_PRESERVED_OR_RESTORE_IN_PROGRESS|RESTORE_INSTALLED_AND_STARTING)
            if ! systemctl stop k3s || ! wait_for_stopped; then
                printf '[ERROR] could not confirm K3s is stopped after restore failure\n' >&2
                status=1
            else
                printf '[ERROR] restore failed after destructive mutation began; K3s has intentionally been left stopped\n' >&2
                printf '[ERROR] no automatic restart or rollback was attempted; operator-directed rollback or repair is required\n' >&2
            fi
            ;;
        RESTORE_SUCCEEDED)
            ;;
        *)
            printf '[ERROR] unknown restore phase %s; leaving K3s stopped\n' "$RESTORE_PHASE" >&2
            if ! systemctl stop k3s || ! wait_for_stopped; then
                printf '[ERROR] could not confirm K3s is stopped after unknown restore phase\n' >&2
                status=1
            fi
            ;;
    esac

    if ((${#PRESERVED_PATHS[@]} > 0)) && [[ $RESTORE_PHASE != PRE_MUTATION ]]; then
        printf '[INFO] preserved .pre-restore paths (never deleted):\n' >&2
        print_preserved_paths
    fi

    exit "$status"
}

(( EUID == 0 )) || die 'run restore as root'

while (($# > 0)); do
    case $1 in
        --force-restore)
            FORCE_RESTORE=1
            shift
            ;;
        --expected-k3s-version)
            (($# >= 2)) || die '--expected-k3s-version requires a value'
            EXPECTED_K3S_VERSION=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            ;;
        -* )
            die "unknown option: $1"
            ;;
        *)
            [[ -z $BACKUP_PATH ]] || die 'exactly one backup directory is required'
            BACKUP_PATH=$1
            shift
            ;;
    esac
done

[[ -n $BACKUP_PATH ]] || {
    usage >&2
    exit 2
}
(( FORCE_RESTORE )) || die 'destructive restore requires the explicit --force-restore flag'

trap restore_cleanup EXIT
restore_backup
