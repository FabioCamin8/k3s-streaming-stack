#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_VERSION=3
BACKUP_FORMAT_VERSION=2
BACKUP_PATH=''
STAGING_PATH=''
K3S_STOPPED=0
DOWNTIME_START=''

log() {
    printf '[INFO] %s\n' "$*" >&2
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage:
  backup.sh BACKUP_DIRECTORY
  backup.sh --verify BACKUP_DIRECTORY

Capture or verify a K3s recovery baseline. Capture requires root and stops
K3s briefly so SQLite and its companion files are copied consistently.

The destination must be a new absolute directory whose parent already exists.
Backups contain the K3s server token, certificates, encryption key material,
and kubeconfigs. Keep them private and out of Git.
USAGE
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_absolute_new_destination() {
    [[ $BACKUP_PATH == /* ]] || die "backup destination must be an absolute path"
    [[ $BACKUP_PATH != / && $BACKUP_PATH != /root && $BACKUP_PATH != /var &&
        $BACKUP_PATH != /etc && $BACKUP_PATH != /var/lib/rancher &&
        $BACKUP_PATH != /etc/rancher ]] || die "refusing an unsafe backup destination: $BACKUP_PATH"
    case $BACKUP_PATH in
        /var/lib/rancher/k3s|/var/lib/rancher/k3s/*|/etc/rancher/k3s|/etc/rancher/k3s/*)
            die "backup destination must not be inside live K3s state: $BACKUP_PATH"
            ;;
    esac
    [[ ! -e $BACKUP_PATH && ! -L $BACKUP_PATH ]] ||
        die "backup destination already exists; refusing to overwrite: $BACKUP_PATH"

    local parent canonical_parent
    parent=$(dirname -- "$BACKUP_PATH")
    [[ -d $parent ]] || die "backup destination parent does not exist: $parent"
    [[ -w $parent ]] || die "backup destination parent is not writable: $parent"

    canonical_parent=$(readlink -f -- "$parent") ||
        die "could not resolve backup destination parent: $parent"
    [[ -d $canonical_parent && ! -L $canonical_parent ]] ||
        die "backup destination parent is not a real directory: $canonical_parent"
    [[ $(stat -c '%u:%g' "$canonical_parent") == 0:0 ]] ||
        die "backup destination parent must be root-owned: $canonical_parent"
    local parent_permissions
    parent_permissions=$(stat -c '%A' "$canonical_parent")
    [[ ${parent_permissions:5:1} != w && ${parent_permissions:8:1} != w ]] ||
        die "backup destination parent must not be group/world-writable: $canonical_parent"
    case "$canonical_parent/" in
        /var/lib/rancher/k3s/*|/etc/rancher/k3s/*)
            die "backup destination parent resolves inside live K3s state: $canonical_parent"
            ;;
    esac
}

require_backup_directory() {
    [[ $BACKUP_PATH == /* ]] || die "backup path must be an absolute path"
    [[ -d $BACKUP_PATH && ! -L $BACKUP_PATH ]] ||
        die "backup path is not a real directory: $BACKUP_PATH"
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

cluster_is_ready() {
    local nodes node_count

    systemctl is-active --quiet k3s || return 1
    nodes=$(kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get nodes --no-headers 2>/dev/null) ||
        return 1
    node_count=$(awk 'NF { count++ } END { print count + 0 }' <<<"$nodes")
    (( node_count == 1 )) || return 1
    awk '$2 == "Ready" { found = 1 } END { exit found ? 0 : 1 }' <<<"$nodes"
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

cleanup() {
    local status=$?

    if [[ -n $STAGING_PATH && -e $STAGING_PATH ]]; then
        if ! rm -rf -- "$STAGING_PATH"; then
            printf '[ERROR] failed to remove incomplete staging directory: %s\n' \
                "$STAGING_PATH" >&2
            status=1
        fi
    fi

    if (( K3S_STOPPED )); then
        printf '[INFO] restarting K3s after interrupted backup\n' >&2
        if ! systemctl start k3s; then
            printf '[ERROR] K3s failed to start after backup failure\n' >&2
            status=1
        elif ! wait_for_recovery; then
            printf '[ERROR] K3s did not recover after backup failure\n' >&2
            status=1
        else
            K3S_STOPPED=0
        fi
    fi

    exit "$status"
}

sqlite_integrity_check() {
    local database=$1 validation_dir result

    validation_dir=$(mktemp -d -t k3s-sqlite-check.XXXXXX)
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

require_sqlite_validator() {
    if ! command -v sqlite3 >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
        die 'SQLite integrity validation requires sqlite3 or python3'
    fi
}

validate_capture_sources() {
    [[ -d /var/lib/rancher/k3s ]] || die "K3s state directory is missing"
    [[ -d /var/lib/rancher/k3s/server/db ]] || die "K3s SQLite directory is missing"
    [[ -f /var/lib/rancher/k3s/server/db/state.db ]] || die "K3s SQLite state.db is missing"
    [[ -f /var/lib/rancher/k3s/server/token ]] || die "K3s server token is missing"
    [[ -f /var/lib/rancher/k3s/server/cred/encryption-config.json ]] ||
        die "K3s secrets-encryption configuration is missing"
    [[ -f /var/lib/rancher/k3s/server/cred/encryption-state.json ]] ||
        die "K3s secrets-encryption state is missing"
    [[ -d /etc/rancher/k3s ]] || die "K3s configuration directory is missing"
    [[ -f /etc/rancher/k3s/k3s.yaml ]] || die "K3s kubeconfig is missing"
    [[ -f /etc/systemd/system/k3s.service ]] || die "K3s systemd unit is missing"
}

capture_path() {
    local source=$1 destination=$2
    local destination_parent

    destination_parent=$(dirname -- "$destination")
    mkdir -p -- "$destination_parent"
    if [[ -e $source || -L $source ]]; then
        cp -a -- "$source" "$destination"
        printf 'present\n'
    else
        printf 'absent\n'
    fi
}

write_hash_manifest() {
    local state_root=$1 manifest=$2 relative file hash

    : >"$manifest"
    while IFS= read -r -d '' relative; do
        file=$state_root/$relative
        hash=$(sha256sum -- "$file" | awk '{ print $1 }')
        printf '%s\t%s\n' "$hash" "$relative" >>"$manifest"
    done < <(cd "$state_root" && find . -type f -printf '%P\0' | sort -z)
}

write_symlink_manifest() {
    local state_root=$1 manifest=$2 relative target

    : >"$manifest"
    while IFS= read -r -d '' relative; do
        target=$(readlink -- "$state_root/$relative")
        printf '%s\t%s\n' "$relative" "$target" >>"$manifest"
    done < <(cd "$state_root" && find . -type l -printf '%P\0' | sort -z)
}

write_metadata_manifest() {
    local metadata_root=$1 relative hash

    : >"$metadata_root/metadata.sha256"
    for relative in backup-info.tsv files.sha256 symlinks.tsv; do
        hash=$(sha256sum -- "$metadata_root/$relative" | awk '{ print $1 }')
        printf '%s\t%s\n' "$hash" "$relative" >>"$metadata_root/metadata.sha256"
    done
}

verify_secure_permissions() {
    local path mode owner

    for path in "$BACKUP_PATH" "$BACKUP_PATH/metadata" "$BACKUP_PATH/server-state"; do
        mode=$(stat -c '%a' "$path")
        [[ $mode == 700 ]] || die "backup directory is not mode 700: $path (mode $mode)"
        owner=$(stat -c '%u:%g' "$path")
        [[ $owner == 0:0 ]] || die "backup directory is not root-owned: $path (owner $owner)"
    done
    for path in "$BACKUP_PATH/metadata/backup-info.tsv" \
        "$BACKUP_PATH/metadata/files.sha256" "$BACKUP_PATH/metadata/symlinks.tsv" \
        "$BACKUP_PATH/metadata/metadata.sha256"; do
        mode=$(stat -c '%a' "$path")
        [[ $mode == 600 ]] || die "backup metadata is not mode 600: $path (mode $mode)"
        owner=$(stat -c '%u:%g' "$path")
        [[ $owner == 0:0 ]] || die "backup metadata is not root-owned: $path (owner $owner)"
    done
}

verify_metadata_manifest() {
    local manifest=$BACKUP_PATH/metadata/metadata.sha256
    local relative expected actual

    for relative in backup-info.tsv files.sha256 symlinks.tsv; do
        expected=$(awk -F$'\t' -v wanted="$relative" \
            '$2 == wanted { print $1; exit }' "$manifest")
        [[ $expected =~ ^[0-9a-f]{64}$ ]] ||
            die "metadata manifest entry is missing or invalid: $relative"
        actual=$(sha256sum -- "$BACKUP_PATH/metadata/$relative" | awk '{ print $1 }')
        [[ $actual == "$expected" ]] || die "metadata hash mismatch: $relative"
    done

    [[ $(wc -l <"$manifest") == 3 ]] ||
        die 'metadata manifest contains unexpected entries'
}

verify_required_paths() {
    local state_root=$BACKUP_PATH/server-state relative

    for relative in \
        var \
        var/lib \
        var/lib/rancher \
        var/lib/rancher/k3s \
        etc \
        etc/rancher \
        etc/rancher/k3s \
        etc/systemd \
        etc/systemd/system; do
        [[ -d $state_root/$relative && ! -L $state_root/$relative ]] ||
            die "required backed-up directory is missing or symlinked: $relative"
    done

    for relative in \
        var/lib/rancher/k3s/server/db/state.db \
        var/lib/rancher/k3s/server/token \
        var/lib/rancher/k3s/server/cred/encryption-config.json \
        var/lib/rancher/k3s/server/cred/encryption-state.json \
        etc/rancher/k3s/k3s.yaml \
        etc/systemd/system/k3s.service; do
        [[ -f $state_root/$relative && ! -L $state_root/$relative ]] ||
            die "required backed-up file is missing: $relative"
    done
}

verify_optional_path() {
    local info=$1 key=$2 relative=$3 expected

    expected=$(awk -F= -v wanted="$key" \
        '$1 == wanted { print substr($0, index($0, "=") + 1); exit }' "$info")
    case "$expected" in
        present)
            [[ -e $BACKUP_PATH/server-state/$relative || -L $BACKUP_PATH/server-state/$relative ]] ||
                die "metadata says optional path is present but it is missing: $relative"
            ;;
        absent)
            [[ ! -e $BACKUP_PATH/server-state/$relative && ! -L $BACKUP_PATH/server-state/$relative ]] ||
                die "metadata says optional path is absent but it is present: $relative"
            ;;
        *)
            die "invalid optional-path metadata: $key=$expected"
            ;;
    esac
}

verify_manifest() {
    local state_root=$BACKUP_PATH/server-state
    local manifest=$BACKUP_PATH/metadata/files.sha256
    local symlink_manifest=$BACKUP_PATH/metadata/symlinks.tsv
    local expected relative actual file file_count=0 symlink_count=0

    while IFS=$'\t' read -r expected relative; do
        [[ $expected =~ ^[0-9a-f]{64}$ && -n $relative ]] ||
            die "invalid file manifest entry"
        case $relative in
            /*|..|../*|*/../*|*/..)
                die "unsafe file manifest path: $relative"
                ;;
        esac
        file=$state_root/$relative
        [[ -f $file && ! -L $file ]] || die "missing backed-up file: $relative"
        actual=$(sha256sum -- "$file" | awk '{ print $1 }')
        [[ $actual == "$expected" ]] || die "hash mismatch in backed-up file: $relative"
        file_count=$((file_count + 1))
    done <"$manifest"

    actual=$(find "$state_root" -type f | wc -l)
    [[ $actual == "$file_count" ]] ||
        die "file manifest count mismatch (manifest $file_count, backup $actual)"

    while IFS=$'\t' read -r relative expected; do
        [[ -n $relative ]] || die "invalid symlink manifest entry"
        case $relative in
            /*|..|../*|*/../*|*/..)
                die "unsafe symlink manifest path: $relative"
                ;;
        esac
        [[ -L $state_root/$relative ]] || die "missing backed-up symlink: $relative"
        [[ $(readlink -- "$state_root/$relative") == "$expected" ]] ||
            die "symlink target mismatch: $relative"
        symlink_count=$((symlink_count + 1))
    done <"$symlink_manifest"

    actual=$(find "$state_root" -type l | wc -l)
    [[ $actual == "$symlink_count" ]] ||
        die "symlink manifest count mismatch (manifest $symlink_count, backup $actual)"
}

verify_backup() {
    local info=$BACKUP_PATH/metadata/backup-info.tsv value

    require_command awk
    require_command find
    require_command grep
    require_command readlink
    require_command sha256sum
    require_command stat
    require_command wc

    for path in "$BACKUP_PATH/metadata" "$BACKUP_PATH/server-state"; do
        [[ -d $path && ! -L $path ]] ||
            die "required backup directory is missing or symlinked: $path"
    done
    for path in "$BACKUP_PATH/metadata/backup-info.tsv" \
        "$BACKUP_PATH/metadata/files.sha256" "$BACKUP_PATH/metadata/symlinks.tsv" \
        "$BACKUP_PATH/metadata/metadata.sha256"; do
        [[ -f $path && ! -L $path ]] ||
            die "required backup metadata file is missing or symlinked: $path"
    done

    grep -Fxq 'format_version=2' "$info" || die 'unsupported backup format'
    grep -Fxq 'datastore=embedded-sqlite' "$info" || die 'backup is not embedded SQLite state'
    grep -Fxq 'consistency_model=stopped-service' "$info" ||
        die 'backup does not use the stopped-service consistency model'
    grep -Fxq 'secrets_encryption=enabled' "$info" ||
        die 'backup does not record enabled secrets encryption'
    grep -Fxq 'encryption_hashes=match' "$info" ||
        die 'backup does not record matching encryption hashes'
    grep -Fxq 'sqlite_shared_memory=excluded-regenerable' "$info" ||
        die 'backup does not record the SQLite shared-memory policy'
    value=$(awk -F= '$1 == "k3s_version" { print substr($0, index($0, "=") + 1); exit }' "$info")
    [[ $value =~ ^v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+$ ]] ||
        die 'backup K3s version metadata is missing or invalid'

    verify_secure_permissions
    verify_metadata_manifest
    verify_required_paths
    verify_optional_path "$info" service_env_present etc/systemd/system/k3s.service.env
    verify_optional_path "$info" service_dropin_present etc/systemd/system/k3s.service.d
    verify_optional_path "$info" default_env_present etc/default/k3s
    verify_optional_path "$info" sysconfig_env_present etc/sysconfig/k3s
    verify_manifest
    require_sqlite_validator
    sqlite_integrity_check "$BACKUP_PATH/server-state/var/lib/rancher/k3s/server/db/state.db" ||
        die 'backed-up SQLite state.db failed read-only integrity_check'
    log "backup integrity verified: K3s $value"
}

capture_backup() {
    local parent capture_started capture_finished capture_epoch_start capture_epoch_end
    local k3s_version node_name nodes node_count encryption_status encryption_provider
    local encryption_name state_root metadata_root service_env_present dropin_present
    local default_env_present sysconfig_env_present
    local file_count symlink_count sqlite_status downtime_end

    require_command awk
    require_command cp
    require_command date
    require_command find
    require_command grep
    require_command kubectl
    require_command k3s
    require_command mkdir
    require_command mktemp
    require_command mv
    require_command readlink
    require_command sha256sum
    require_command sleep
    require_command stat
    require_command systemctl
    require_command wc
    require_sqlite_validator

    validate_capture_sources
    systemctl is-active --quiet k3s || die 'K3s must be active before backup'
    nodes=$(kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get nodes --no-headers 2>/dev/null) ||
        die 'Kubernetes API is not reachable'
    node_count=$(awk 'NF { count++ } END { print count + 0 }' <<<"$nodes")
    (( node_count == 1 )) || die "expected one node before backup, found $node_count"
    awk '$2 == "Ready" { found = 1 } END { exit found ? 0 : 1 }' <<<"$nodes" ||
        die 'the sole K3s node is not Ready before backup'
    node_name=$(awk 'NF { print $1; exit }' <<<"$nodes")

    if ! encryption_status=$(k3s secrets-encrypt status 2>/dev/null); then
        die 'unable to read K3s secrets-encryption status'
    fi
    grep -Fxq 'Encryption Status: Enabled' <<<"$encryption_status" ||
        die 'K3s secrets encryption is not enabled'
    grep -Fxq 'Server Encryption Hashes: All hashes match' <<<"$encryption_status" ||
        die 'K3s server encryption hashes do not match'
    encryption_provider=$(awk '$1 == "*" { print $2; exit }' <<<"$encryption_status")
    encryption_name=$(awk '$1 == "*" { print $3; exit }' <<<"$encryption_status")
    [[ -n $encryption_provider && -n $encryption_name ]] ||
        die 'active secrets-encryption key metadata is missing'

    k3s_version=$(k3s --version | awk 'NR == 1 { print $3; exit }')
    [[ $k3s_version =~ ^v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+$ ]] ||
        die "unable to determine K3s version: $k3s_version"

    parent=$(dirname -- "$BACKUP_PATH")
    STAGING_PATH=$(mktemp -d -- "$parent/.k3s-backup.XXXXXX")
    chmod 700 "$STAGING_PATH"
    mkdir -m 700 "$STAGING_PATH/metadata" "$STAGING_PATH/server-state"
    state_root=$STAGING_PATH/server-state
    metadata_root=$STAGING_PATH/metadata

    capture_started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    capture_epoch_start=$(date +%s)
    K3S_STOPPED=1
    DOWNTIME_START=$(date +%s)
    systemctl stop k3s
    wait_for_stopped || die 'K3s did not stop within 30 seconds'

    mkdir -p "$state_root/var/lib/rancher" "$state_root/etc/rancher" \
        "$state_root/etc/systemd/system" "$state_root/etc/default" "$state_root/etc/sysconfig"
    cp -a -- /var/lib/rancher/k3s "$state_root/var/lib/rancher/"
    cp -a -- /etc/rancher/k3s "$state_root/etc/rancher/"
    cp -a -- /etc/systemd/system/k3s.service "$state_root/etc/systemd/system/"
    service_env_present=$(capture_path /etc/systemd/system/k3s.service.env \
        "$state_root/etc/systemd/system/k3s.service.env")
    dropin_present=$(capture_path /etc/systemd/system/k3s.service.d \
        "$state_root/etc/systemd/system/k3s.service.d")
    default_env_present=$(capture_path /etc/default/k3s "$state_root/etc/default/k3s")
    sysconfig_env_present=$(capture_path /etc/sysconfig/k3s "$state_root/etc/sysconfig/k3s")

    rm -f -- "$state_root/var/lib/rancher/k3s/server/db/state.db-shm"

    if ! sqlite_integrity_check /var/lib/rancher/k3s/server/db/state.db; then
        die 'SQLite integrity check failed before backup'
    fi
    sqlite_status=passed

    write_hash_manifest "$state_root" "$metadata_root/files.sha256"
    write_symlink_manifest "$state_root" "$metadata_root/symlinks.tsv"
    file_count=$(wc -l <"$metadata_root/files.sha256")
    symlink_count=$(wc -l <"$metadata_root/symlinks.tsv")
    capture_finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    capture_epoch_end=$(date +%s)

    printf '%s\n' \
        "format_version=$BACKUP_FORMAT_VERSION" \
        "backup_script_version=$SCRIPT_VERSION" \
        "created_at_utc=$capture_finished" \
        "capture_started_at_utc=$capture_started" \
        "capture_finished_at_utc=$capture_finished" \
        "k3s_version=$k3s_version" \
        "node_name=$node_name" \
        'datastore=embedded-sqlite' \
        'consistency_model=stopped-service' \
        'secrets_encryption=enabled' \
        "encryption_provider=$encryption_provider" \
        "active_encryption_key_name=$encryption_name" \
        'encryption_hashes=match' \
        'sqlite_shared_memory=excluded-regenerable' \
        "sqlite_integrity_check=$sqlite_status" \
        "regular_file_count=$file_count" \
        "symlink_count=$symlink_count" \
        "service_env_present=$service_env_present" \
        "service_dropin_present=$dropin_present" \
        "default_env_present=$default_env_present" \
        "sysconfig_env_present=$sysconfig_env_present" \
        "capture_duration_seconds=$((capture_epoch_end - capture_epoch_start))" \
        >"$metadata_root/backup-info.tsv"
    write_metadata_manifest "$metadata_root"
    chmod 600 "$metadata_root/backup-info.tsv" "$metadata_root/files.sha256" \
        "$metadata_root/symlinks.tsv" "$metadata_root/metadata.sha256"

    [[ ! -e $BACKUP_PATH && ! -L $BACKUP_PATH ]] ||
        die "backup destination appeared during capture; refusing to overwrite: $BACKUP_PATH"
    mv -T -- "$STAGING_PATH" "$BACKUP_PATH" ||
        die "could not publish backup without overwriting destination: $BACKUP_PATH"
    STAGING_PATH=''
    verify_backup

    log "captured K3s $k3s_version backup with $file_count files and $symlink_count symlinks"
    log "backup capture duration: $((capture_epoch_end - capture_epoch_start)) seconds"

    if ! systemctl start k3s; then
        die 'K3s failed to start after backup'
    fi
    if ! wait_for_recovery; then
        die 'K3s did not recover after backup'
    fi
    K3S_STOPPED=0
    downtime_end=$(date +%s)
    log "K3s recovered after $(( downtime_end - DOWNTIME_START )) seconds of service downtime"
}

(( EUID == 0 )) || die 'run this command as root'

VERIFY_ONLY=0
if (($# > 0)) && [[ $1 == --verify ]]; then
    VERIFY_ONLY=1
    shift
fi
if (($# == 1)); then
    BACKUP_PATH=$1
else
    usage >&2
    exit 2
fi

if (( VERIFY_ONLY )); then
    require_backup_directory
    verify_backup
else
    require_absolute_new_destination
    trap cleanup EXIT
    capture_backup
fi
