#!/usr/bin/env bash
#
# BootPrep Installer
#
# Installs BootPrep 2.0.1 on a fresh system. Existing and partial installations
# must be handled by bootprep-upgrade.sh.
#
# Version: 2.0.1
# License: GPL-3.0-or-later
#
# Copyright (C) 2026 Scott McClain
# SPDX-License-Identifier: GPL-3.0-or-later

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly FSTAB="/etc/fstab"
readonly BACKUP_DIR="/var/lib/bootprep/backups"
readonly BOOTPREP_SOURCE="${SCRIPT_DIR}/bootprep"
readonly BTRFS_SOURCE="${SCRIPT_DIR}/bootprep-btrfs"
readonly SNAPPER_SOURCE="${SCRIPT_DIR}/99_bootprep"
readonly BOOTPREP_DEST="/usr/sbin/bootprep"
readonly BTRFS_DEST="/usr/sbin/bootprep-btrfs"
readonly SNAPPER_DEST="/usr/lib/snapper/plugins/99_bootprep"
readonly LEGACY_RUNTIME="/usr/lib/bootprep/bootprep-runtime.sh"
readonly LEGACY_STATE="/var/lib/bootprep/next-boot"

readonly UPGRADE_MODE="${BOOTPREP_INTERNAL_UPGRADE:-false}"

ROOT_DEVICE=""
ROOT_UUID=""
ROOT_SUBVOL=""
BASE_SUBVOL=""
HOME_SUBVOL=""

section() { printf '\n============================================================\n%s\n============================================================\n' "$1"; }
info() { printf '[INFO] %s\n' "$1"; }
ok() { printf '[ OK ] %s\n' "$1"; }
die() { printf '[FAIL] %s\n' "$1" >&2; exit 1; }
require_file() { [[ -f "$1" ]] || die "Missing file: $1"; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
require_root() { [[ $EUID -eq 0 ]] || die "Please run with sudo."; }

validate_environment() {
    section "Environment"
    [[ "$(findmnt -n -o FSTYPE /)" == btrfs ]] || die "The root filesystem is not Btrfs."
    mountpoint -q /boot/efi || die "/boot/efi is not mounted."
    [[ -d /sys/firmware/efi ]] || die "The system is not booted in UEFI mode."

    for file in "$FSTAB" "$BOOTPREP_SOURCE" "$BTRFS_SOURCE" "$SNAPPER_SOURCE"; do
        require_file "$file"
    done
    for command in awk bash btrfs findmnt grub-install grub-mkconfig install mountpoint paste sed; do
        require_command "$command"
    done
    for file in "$BOOTPREP_SOURCE" "$BTRFS_SOURCE" "$SNAPPER_SOURCE"; do
        bash -n "$file" || die "Shell syntax validation failed: $file"
    done
    ok "BootPrep prerequisites verified."
}

prepare_grub_layout() {
    section "GRUB Layout"

    if [[ -f /boot/grub/grub.cfg ]]; then
        ok "GRUB layout verified."
        return
    fi

    if path_exists /boot/grub; then
        die "/boot/grub exists but does not provide grub.cfg."
    fi

    [[ -f /boot/efi/grub/grub.cfg ]] \
        || die "/boot/grub/grub.cfg was not found."

    ln -s efi/grub /boot/grub
    if [[ ! -L /boot/grub || ! /boot/grub -ef /boot/efi/grub || ! -f /boot/grub/grub.cfg ]]; then
        rm -f /boot/grub
        die "GRUB layout reconciliation failed."
    fi

    ok "GRUB layout reconciled and verified."
}

path_exists() {
    [[ -e "$1" || -L "$1" ]]
}

require_fresh_installation() {
    section "Installation Eligibility"

    case "$UPGRADE_MODE" in
        true)
            ok "Installer invoked by the BootPrep upgrader."
            return 0
            ;;
        false)
            ;;
        *)
            die "Invalid internal upgrade mode."
            ;;
    esac

    local path
    for path in \
        "$BOOTPREP_DEST" \
        "$BTRFS_DEST" \
        "$SNAPPER_DEST" \
        "$LEGACY_RUNTIME" \
        "$LEGACY_STATE"; do
        if path_exists "$path"; then
            die "An existing or partial BootPrep installation was detected. Use bootprep-upgrade.sh."
        fi
    done

    ok "Fresh installation confirmed."
}

discover_btrfs_layout() {
    section "Btrfs Layout"
    ROOT_DEVICE="$(findmnt -n -o SOURCE /)"; ROOT_DEVICE="${ROOT_DEVICE%%[*}"
    ROOT_UUID="$(findmnt -n -o UUID /)"
    ROOT_SUBVOL="$(findmnt -n -o OPTIONS / | sed -n 's/.*subvol=\/\([^,]*\).*/\1/p')"
    [[ -n "$ROOT_DEVICE" && -n "$ROOT_UUID" && -n "$ROOT_SUBVOL" ]] \
        || die "Unable to determine the active Btrfs root layout."
    BASE_SUBVOL="$ROOT_SUBVOL"
    if [[ "$BASE_SUBVOL" == */.snapshots/*/snapshot ]]; then
        BASE_SUBVOL="${BASE_SUBVOL%%/.snapshots/*}"
    fi
    if [[ "$(findmnt -n -o TARGET -T /home 2>/dev/null || true)" == /home ]]; then
        HOME_SUBVOL="$(findmnt -n -o OPTIONS /home | sed -n 's/.*subvol=\/\([^,]*\).*/\1/p')"
    fi
    printf 'Device         : %s\nUUID           : %s\nRoot Subvolume : %s\nHome Subvolume : %s\n' \
        "$ROOT_DEVICE" "$ROOT_UUID" "$BASE_SUBVOL" "${HOME_SUBVOL:-not separate}"
    ok "Btrfs layout discovered."
}

discover_snapshot_stores() {
    local path root_store="${BASE_SUBVOL}/.snapshots" home_store="${BASE_SUBVOL}/home/.snapshots"
    [[ -n "$HOME_SUBVOL" ]] && home_store="${HOME_SUBVOL}/.snapshots"
    while IFS= read -r path; do
        case "$path" in
            .snapshots|"$root_store") printf '%s\t%s\n' "$root_store" /.snapshots ;;
            "$home_store") printf '%s\t%s\n' "$home_store" /home/.snapshots ;;
        esac
    done < <(btrfs subvolume list / | awk '{ sub(/^.* path /, ""); if ($0 ~ /(^|\/)\.snapshots$/) print }')
}

snapshot_mount_options() {
    local options
    options="$(findmnt -n -o OPTIONS / | tr ',' '\n' | awk '
        $0 == "rw" || $0 == "ro" { next }
        $0 ~ /^subvol=/ || $0 ~ /^subvolid=/ || $0 ~ /^space_cache=/ { next }
        NF { print }
    ' | paste -sd, -)"
    printf '%s\n' "defaults${options:+,$options}"
}

fstab_entry_is_correct() {
    local line="$1" expected="$2" source target fstype options
    read -r source target fstype options _ <<< "$line"
    [[ "$fstype" == btrfs ]] || return 1
    [[ ",$options," == *",subvol=/$expected,"* ]] || return 1
    [[ "$source" == "UUID=$ROOT_UUID" || "$source" == "$ROOT_DEVICE" ]]
}

verify_fstab() {
    local file="$1"; shift
    local subvol target line
    local -a found
    while (( $# >= 2 )); do
        subvol="$1"; target="$2"; shift 2
        mapfile -t found < <(awk -v target="$target" '!/^[[:space:]]*#/ && NF && $2 == target { print }' "$file")
        [[ ${#found[@]} -eq 1 ]] || return 1
        line="${found[0]}"; fstab_entry_is_correct "$line" "$subvol" || return 1
    done
}

reconcile_snapshot_store_mounts() {
    section "Snapshot Store Mounts"
    local options tmpfile backup store subvol target canonical existing changed=false
    local -a stores=() verify_args=() found=()
    mapfile -t stores < <(discover_snapshot_stores)
    [[ ${#stores[@]} -gt 0 ]] || { ok "No snapshot store mounts required."; return; }
    options="$(snapshot_mount_options)"; tmpfile="$(mktemp /tmp/bootprep-fstab.XXXXXX)"
    cp -a "$FSTAB" "$tmpfile"

    for store in "${stores[@]}"; do
        IFS=$'\t' read -r subvol target <<< "$store"
        canonical="UUID=$ROOT_UUID $target btrfs subvol=/$subvol,$options 0 0"
        verify_args+=("$subvol" "$target")
        mapfile -t found < <(awk -v target="$target" '!/^[[:space:]]*#/ && NF && $2 == target { print }' "$tmpfile")
        case ${#found[@]} in
            0) printf '%s\n' "$canonical" >> "$tmpfile"; changed=true; info "Adding $target" ;;
            1)
                existing="${found[0]}"
                if ! fstab_entry_is_correct "$existing" "$subvol"; then
                    awk -v target="$target" -v replacement="$canonical" '
                        !/^[[:space:]]*#/ && NF && $2 == target { if (!done++) print replacement; next }
                        { print }
                    ' "$tmpfile" > "${tmpfile}.new"
                    mv "${tmpfile}.new" "$tmpfile"; changed=true; info "Replacing $target"
                fi ;;
            *) die "Multiple active fstab entries found for $target." ;;
        esac
    done

    verify_fstab "$tmpfile" "${verify_args[@]}" || die "Snapshot store mount validation failed."
    if [[ "$changed" == false ]]; then
        rm -f "$tmpfile"
        ok "Snapshot store mounts verified."
        return
    fi
    mkdir -p "$BACKUP_DIR"; backup="$BACKUP_DIR/fstab.$(date +%Y%m%d-%H%M%S)"
    cp -a "$FSTAB" "$backup"; cp -a "$tmpfile" "$FSTAB"
    if ! verify_fstab "$FSTAB" "${verify_args[@]}"; then
        cp -a "$backup" "$FSTAB"
        rm -f "$tmpfile"
        die "fstab update failed and was restored."
    fi
    rm -f "$tmpfile"
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload
    printf 'Backup : %s\n' "$backup"; ok "Snapshot store mounts reconciled."
}

install_components() {
    section "Install BootPrep Components"
    install -Dm755 "$BOOTPREP_SOURCE" "$BOOTPREP_DEST"
    install -Dm755 "$BTRFS_SOURCE" "$BTRFS_DEST"
    install -Dm755 "$SNAPPER_SOURCE" "$SNAPPER_DEST"
    cmp -s "$BOOTPREP_SOURCE" "$BOOTPREP_DEST" || die "Installed bootprep verification failed."
    cmp -s "$BTRFS_SOURCE" "$BTRFS_DEST" || die "Installed bootprep-btrfs verification failed."
    cmp -s "$SNAPPER_SOURCE" "$SNAPPER_DEST" || die "Installed 99_bootprep verification failed."
    ok "BootPrep components installed and verified."
}

main() {
    section "BootPrep 2.0.1"
    require_root
    require_fresh_installation
    validate_environment
    prepare_grub_layout
    discover_btrfs_layout
    reconcile_snapshot_store_mounts
    install_components
    section "Result"
    ok "BootPrep 2.0.1 installed successfully."
}

main "$@"
