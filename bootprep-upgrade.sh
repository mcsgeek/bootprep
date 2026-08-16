#!/usr/bin/env bash
#
# BootPrep Upgrade
#
# Migrates a legacy BootPrep installation to version 2.0.0, removes the old
# GRUB patch/runtime architecture, and runs the version 2 installer.
#
# Version: 2.0.0
# License: GPL-3.0-or-later
#
# Copyright (C) 2026 Scott McClain
# SPDX-License-Identifier: GPL-3.0-or-later

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

readonly INSTALLER_SOURCE="${SCRIPT_DIR}/bootprep-install.sh"
readonly BOOTPREP_SOURCE="${SCRIPT_DIR}/bootprep"
readonly BTRFS_SOURCE="${SCRIPT_DIR}/bootprep-btrfs"
readonly SNAPPER_SOURCE="${SCRIPT_DIR}/99_bootprep"
readonly BOOTPREP_DEST="/usr/sbin/bootprep"
readonly BTRFS_DEST="/usr/sbin/bootprep-btrfs"
readonly SNAPPER_DEST="/usr/lib/snapper/plugins/99_bootprep"

readonly GRUB_SCRIPT="/etc/grub.d/10_linux"
readonly GRUB_DEFAULT="/etc/default/grub"
readonly GRUB_DIVERSION="/var/lib/bootprep/backups/10_linux.dist"
readonly GRUB_BACKUP="/var/lib/bootprep/backups/10_linux.original"
readonly LEGACY_VARIABLE="BOOTPREP_BTRFS_SNAPSHOT_BOOTING"

readonly LEGACY_RUNTIME="/usr/lib/bootprep/bootprep-runtime.sh"
readonly LEGACY_STATE="/var/lib/bootprep/next-boot"
readonly MIGRATION_ROOT="/var/lib/bootprep/backups"

MIGRATION_DIR=""

section() {
    printf '\n============================================================\n%s\n============================================================\n' "$1"
}

info() { printf '[INFO] %s\n' "$1"; }
ok() { printf '[ OK ] %s\n' "$1"; }
die() { printf '[FAIL] %s\n' "$1" >&2; exit 1; }

require_file() {
    [[ -f "$1" ]] || die "Missing file: $1"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

path_exists() {
    [[ -e "$1" || -L "$1" ]]
}

installation_is_present() {
    local path

    for path in \
        "$BOOTPREP_DEST" \
        "$BTRFS_DEST" \
        "$SNAPPER_DEST" \
        "$LEGACY_RUNTIME" \
        "$LEGACY_STATE"; do
        path_exists "$path" && return 0
    done

    legacy_architecture_is_present && return 0

    return 1
}

validate() {
    section "Upgrade Validation"

    [[ $EUID -eq 0 ]] || die "Please run with sudo."
    require_file "$INSTALLER_SOURCE"
    require_file "$BOOTPREP_SOURCE"
    require_file "$BTRFS_SOURCE"
    require_file "$SNAPPER_SOURCE"

    local command
    for command in awk bash btrfs cat cmp cp date findmnt grep \
        grub-install grub-mkconfig install mktemp mountpoint mv paste rmdir rm sed; do
        require_command "$command"
    done

    installation_is_present \
        || die "BootPrep is not installed. Use bootprep-install.sh instead."

    bash -n "$INSTALLER_SOURCE" || die "Installer contains shell syntax errors."
    bash -n "$BOOTPREP_SOURCE" || die "BootPrep contains shell syntax errors."
    bash -n "$BTRFS_SOURCE" || die "BootPrep Btrfs contains shell syntax errors."
    bash -n "$SNAPPER_SOURCE" || die "BootPrep Snapper plugin contains shell syntax errors."

    [[ "$(findmnt -n -o FSTYPE /)" == "btrfs" ]] \
        || die "The root filesystem is not Btrfs."
    [[ -d /sys/firmware/efi ]] \
        || die "The system is not booted in UEFI mode."
    mountpoint -q /boot/efi \
        || die "/boot/efi is not mounted."

    ok "Upgrade prerequisites verified."
}

create_migration_archive() {
    MIGRATION_DIR="${MIGRATION_ROOT}/v1-migration.$(date +%Y%m%d-%H%M%S)"
    [[ ! -e "$MIGRATION_DIR" ]] \
        || die "Migration archive already exists: $MIGRATION_DIR"
    install -d -m 0700 "$MIGRATION_DIR"
    ok "Migration archive created."
    printf 'Archive : %s\n' "$MIGRATION_DIR"
}

grub_script_is_legacy() {
    grep -qE 'BOOTPREP_BTRFS_SNAPSHOT_BOOTING|bootprep_resolve_subvolume' "$1"
}

legacy_architecture_is_present() {
    local diverted_path

    if command -v dpkg-divert >/dev/null 2>&1; then
        diverted_path="$(dpkg-divert --truename "$GRUB_SCRIPT" 2>/dev/null || true)"
        [[ -n "$diverted_path" && "$diverted_path" != "$GRUB_SCRIPT" ]] && return 0
    fi

    grub_script_is_legacy "$GRUB_SCRIPT" 2>/dev/null && return 0
    grep -qE "^[[:space:]]*${LEGACY_VARIABLE}=" "$GRUB_DEFAULT" 2>/dev/null && return 0
    [[ -e "$LEGACY_RUNTIME" || -e "$LEGACY_STATE" ]] \
        && return 0
    return 1
}

validate_legacy_migration() {
    command -v dpkg-divert >/dev/null 2>&1 \
        || die "Legacy BootPrep integration was detected, but this system does not support the Version 1 dpkg-divert migration. Upgrade stopped without changes."

    require_file "$GRUB_SCRIPT"
    require_file "$GRUB_DEFAULT"
}

validate_upstream_grub_script() {
    local file="$1"

    [[ -f "$file" ]] || die "Upstream GRUB script is missing: $file"
    [[ -x "$file" ]] || die "Upstream GRUB script is not executable: $file"
    bash -n "$file" || die "Upstream GRUB script contains syntax errors: $file"
    ! grub_script_is_legacy "$file" \
        || die "Expected upstream GRUB script still contains BootPrep integration: $file"
}

restore_diverted_grub_script() {
    local diverted_path
    local diverting_package
    local patched_archive="${MIGRATION_DIR}/10_linux.bootprep-v1"
    local upstream_archive="${MIGRATION_DIR}/10_linux.upstream"

    diverted_path="$(dpkg-divert --truename "$GRUB_SCRIPT")"

    if [[ "$diverted_path" == "$GRUB_SCRIPT" ]]; then
        return 1
    fi

    [[ "$diverted_path" == "$GRUB_DIVERSION" ]] \
        || die "Unexpected diversion target for $GRUB_SCRIPT: $diverted_path"

    diverting_package="$(dpkg-divert --listpackage "$GRUB_SCRIPT")"
    [[ "$diverting_package" == "local" ]] \
        || die "Unexpected package owns the GRUB diversion: ${diverting_package:-unknown}"

    require_file "$GRUB_BACKUP"
    validate_upstream_grub_script "$GRUB_BACKUP"
    validate_upstream_grub_script "$GRUB_DIVERSION"
    grub_script_is_legacy "$GRUB_SCRIPT" \
        || die "Diverted $GRUB_SCRIPT is not the expected BootPrep v1 script."

    cp -a "$GRUB_DIVERSION" "$upstream_archive"
    mv "$GRUB_SCRIPT" "$patched_archive"

    if ! dpkg-divert \
        --package local \
        --divert "$GRUB_DIVERSION" \
        --rename \
        --remove \
        "$GRUB_SCRIPT"; then
        if [[ ! -e "$GRUB_SCRIPT" && -f "$patched_archive" ]]; then
            mv "$patched_archive" "$GRUB_SCRIPT"
        fi
        die "Unable to remove the BootPrep GRUB diversion."
    fi

    [[ "$(dpkg-divert --truename "$GRUB_SCRIPT")" == "$GRUB_SCRIPT" ]] \
        || die "GRUB diversion still exists after removal."
    [[ ! -e "$GRUB_DIVERSION" ]] \
        || die "Diverted GRUB script remains after diversion removal."
    validate_upstream_grub_script "$GRUB_SCRIPT"
    cmp -s "$GRUB_SCRIPT" "$upstream_archive" \
        || die "Restored GRUB script does not match the diverted upstream copy."

    ok "Stock GRUB script restored and verified."
    return 0
}

restore_undiverted_grub_script() {
    local patched_archive="${MIGRATION_DIR}/10_linux.bootprep-v1"
    local restored_tmp

    grub_script_is_legacy "$GRUB_SCRIPT" || return 0

    require_file "$GRUB_BACKUP"
    validate_upstream_grub_script "$GRUB_BACKUP"
    cp -a "$GRUB_SCRIPT" "$patched_archive"

    restored_tmp="$(mktemp /etc/grub.d/10_linux.bootprep.XXXXXX)"
    cp -a "$GRUB_BACKUP" "$restored_tmp"
    mv "$restored_tmp" "$GRUB_SCRIPT"

    validate_upstream_grub_script "$GRUB_SCRIPT"
    cmp -s "$GRUB_SCRIPT" "$GRUB_BACKUP" \
        || die "Restored GRUB script does not match the BootPrep backup."

    ok "Stock GRUB script restored from the BootPrep backup."
}

restore_grub_script() {
    section "Restore Stock GRUB Script"

    if restore_diverted_grub_script; then
        return 0
    fi

    restore_undiverted_grub_script
    validate_upstream_grub_script "$GRUB_SCRIPT"
    ok "Stock GRUB script verified."
}

remove_legacy_grub_setting() {
    section "Remove Legacy GRUB Setting"

    local grub_default_archive="${MIGRATION_DIR}/grub.default"
    local replacement

    if ! grep -qE "^[[:space:]]*${LEGACY_VARIABLE}=" "$GRUB_DEFAULT"; then
        ok "Legacy GRUB setting is not present."
        return 0
    fi

    cp -a "$GRUB_DEFAULT" "$grub_default_archive"
    replacement="$(mktemp /etc/default/grub.bootprep.XXXXXX)"
    cp -a "$GRUB_DEFAULT" "$replacement"

    awk -v variable="$LEGACY_VARIABLE" '
        $0 ~ "^[[:space:]]*" variable "=" { next }
        { print }
    ' "$GRUB_DEFAULT" > "${replacement}.content"

    cat "${replacement}.content" > "$replacement"
    rm -f "${replacement}.content"
    mv "$replacement" "$GRUB_DEFAULT"

    ! grep -qE "^[[:space:]]*${LEGACY_VARIABLE}=" "$GRUB_DEFAULT" \
        || die "Unable to remove the legacy GRUB setting."

    ok "Legacy GRUB setting removed."
}

archive_legacy_file() {
    local source="$1"
    local name="$2"

    [[ -e "$source" ]] || return 0
    [[ ! -L "$source" ]] || die "Refusing to archive symbolic link: $source"
    [[ -f "$source" ]] || die "Legacy artifact is not a regular file: $source"

    mv "$source" "${MIGRATION_DIR}/${name}"
    [[ ! -e "$source" ]] || die "Unable to remove legacy artifact: $source"
    [[ -f "${MIGRATION_DIR}/${name}" ]] || die "Unable to archive legacy artifact: $source"
    info "Archived $source"
}

remove_legacy_artifacts() {
    section "Remove Legacy Runtime Artifacts"

    archive_legacy_file "$LEGACY_RUNTIME" "bootprep-runtime.sh"
    archive_legacy_file "$LEGACY_STATE" "next-boot"

    rmdir /usr/lib/bootprep 2>/dev/null || true

    [[ ! -e "$LEGACY_RUNTIME" ]] || die "Legacy runtime remains installed."
    [[ ! -e "$LEGACY_STATE" ]] || die "Legacy state remains installed."

    ok "Legacy runtime architecture removed."
}

verify_legacy_cleanup() {
    section "Verify Legacy Cleanup"

    [[ "$(dpkg-divert --truename "$GRUB_SCRIPT")" == "$GRUB_SCRIPT" ]] \
        || die "GRUB diversion remains installed."
    ! grub_script_is_legacy "$GRUB_SCRIPT" \
        || die "BootPrep integration remains in $GRUB_SCRIPT."
    ! grep -qE "^[[:space:]]*${LEGACY_VARIABLE}=" "$GRUB_DEFAULT" \
        || die "Legacy GRUB setting remains installed."
    [[ ! -e "$LEGACY_RUNTIME" && ! -e "$LEGACY_STATE" ]] \
        || die "Legacy runtime artifacts remain installed."

    ok "Legacy BootPrep integration completely removed."
}

run_v2_installer() {
    section "Install BootPrep 2.0.0"
    BOOTPREP_INTERNAL_UPGRADE=true /bin/bash "$INSTALLER_SOURCE"
}

main() {
    section "BootPrep 2.0.0 Upgrade"

    validate

    if legacy_architecture_is_present; then
        validate_legacy_migration
        create_migration_archive
        restore_grub_script
        remove_legacy_grub_setting
        remove_legacy_artifacts
        verify_legacy_cleanup
    else
        ok "No legacy integration detected; migration is not required."
    fi

    run_v2_installer

    section "Upgrade Complete"
    ok "BootPrep was upgraded to version 2.0.0."
    if [[ -n "$MIGRATION_DIR" ]]; then
        printf 'Legacy archive : %s\n' "$MIGRATION_DIR"
    fi
}

main "$@"
