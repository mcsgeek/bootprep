#!/usr/bin/env bash
#
# BootPrep Installer
#
# Installs BootPrep 2.1.0 on a fresh system. Existing and partial installations
# must be handled by bootprep-upgrade.sh.
#
# Version: 2.1.0
# License: GPL-3.0-or-later
#
# Copyright (C) 2026 Scott McClain
# SPDX-License-Identifier: GPL-3.0-or-later

set -Eeuo pipefail

# Wrap once so nested installer/engine calls share the same bounded run log.
if [[ $EUID -eq 0 && "${BOOTPREP_LOG_ACTIVE:-}" != 1 ]]; then
    command -v python3 >/dev/null 2>&1 || { echo "Please install Python 3 for BootPrep logging." >&2; exit 1; }
    BOOTPREP_LOG_HELPER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/bootprep-log.py"
    [[ -f "$BOOTPREP_LOG_HELPER" ]] || { echo "Missing BootPrep logging helper: $BOOTPREP_LOG_HELPER" >&2; exit 1; }
    exec python3 "$BOOTPREP_LOG_HELPER" /bin/bash "${BASH_SOURCE[0]}" "$@"
fi


SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly FSTAB="/etc/fstab"
readonly BACKUP_DIR="/var/lib/bootprep/backups"
readonly BOOTPREP_SOURCE="${SCRIPT_DIR}/bootprep"
readonly SUBVOLUME_SOURCE="${SCRIPT_DIR}/bootprep-reconcile.sh"
readonly SUBVOLUME_DEST="/usr/lib/bootprep/bootprep-reconcile.sh"
readonly LOG_SOURCE="${SCRIPT_DIR}/bootprep-log.py"
readonly LOG_DEST="/usr/lib/bootprep/bootprep-log.py"
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

    for file in "$LOG_SOURCE" "$FSTAB" "$BOOTPREP_SOURCE" "$BTRFS_SOURCE" "$SNAPPER_SOURCE" "$SUBVOLUME_SOURCE"; do
        require_file "$file"
    done
    for command in awk bash btrfs findmnt grub-install grub-mkconfig install mountpoint paste sed mount umount systemd-escape cmp sync; do
        require_command "$command"
    done
    for file in "$BOOTPREP_SOURCE" "$BTRFS_SOURCE" "$SNAPPER_SOURCE" "$SUBVOLUME_SOURCE"; do
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
    local present=0
    local missing=0

    for path in \
        "$LOG_DEST" \
        "$SUBVOLUME_DEST" \
        "$BOOTPREP_DEST" \
        "$BTRFS_DEST" \
        "$SNAPPER_DEST"; do
        if path_exists "$path"; then
            ((present += 1))
        else
            ((missing += 1))
        fi
    done

    if (( present > 0 && missing == 0 )); then
        info "BootPrep is already installed."
        info "Use bootprep-upgrade.sh to update the existing installation."
        info "No changes were made."
        exit 0
    fi

    if (( present > 0 )); then
        die "A partial BootPrep installation was detected. Use bootprep-upgrade.sh to repair or complete the installation."
    fi

    for path in "$LEGACY_RUNTIME" "$LEGACY_STATE"; do
        if path_exists "$path"; then
            die "Legacy BootPrep files were detected. Use bootprep-upgrade.sh to migrate the existing installation."
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

reconcile_subvolume_mounts() {
    section "Subvolume Mounts"
    # shellcheck source=bootprep-reconcile.sh
    source "$SUBVOLUME_SOURCE"
    bp_reconcile_subvolumes / "$BASE_SUBVOL" "$ROOT_SUBVOL" "$ROOT_UUID" "$BACKUP_DIR"
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload
    info "New persistent mounts take effect on reboot."
}

install_components() {
    section "Install BootPrep Components"
    install -Dm644 "$LOG_SOURCE" "$LOG_DEST"
    cmp -s "$LOG_SOURCE" "$LOG_DEST" || die "Installed logging helper verification failed."
    install -Dm644 "$SUBVOLUME_SOURCE" "$SUBVOLUME_DEST"
    cmp -s "$SUBVOLUME_SOURCE" "$SUBVOLUME_DEST" || die "Installed subvolume helper verification failed."
    install -Dm755 "$BOOTPREP_SOURCE" "$BOOTPREP_DEST"
    install -Dm755 "$BTRFS_SOURCE" "$BTRFS_DEST"
    install -Dm755 "$SNAPPER_SOURCE" "$SNAPPER_DEST"
    cmp -s "$BOOTPREP_SOURCE" "$BOOTPREP_DEST" || die "Installed bootprep verification failed."
    cmp -s "$BTRFS_SOURCE" "$BTRFS_DEST" || die "Installed bootprep-btrfs verification failed."
    cmp -s "$SNAPPER_SOURCE" "$SNAPPER_DEST" || die "Installed 99_bootprep verification failed."
    ok "BootPrep components installed and verified."
}

main() {
    section "BootPrep 2.1.0"
    require_root
    require_fresh_installation
    validate_environment
    prepare_grub_layout
    discover_btrfs_layout
    reconcile_subvolume_mounts
    install_components
    section "Result"
    ok "BootPrep 2.1.0 installed successfully."
}

main "$@"
