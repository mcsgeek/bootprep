#!/usr/bin/env bash
#
# BootPrep Installer
#
# Installs BootPrep and integrates Debian-style GRUB with Btrfs snapshot boot support.
#
# Version: 1.0.1
# License: GPL-3.0-or-later
#
# Copyright (C) 2026 Scott McClain
# SPDX-License-Identifier: GPL-3.0-or-later

set -Eeuo pipefail

###############################################################################
# Constants
###############################################################################

readonly GRUB_SCRIPT="/etc/grub.d/10_linux"
readonly GRUB_DEFAULT="/etc/default/grub"
readonly FSTAB="/etc/fstab"

readonly BOOTPREP_VARIABLE="BOOTPREP_BTRFS_SNAPSHOT_BOOTING"

readonly BOOTPREP_CONFIG_DIR="/etc/bootprep"
readonly BOOTPREP_CONFIG="${BOOTPREP_CONFIG_DIR}/bootprep.conf"
readonly BOOTPREP_CONFIG_MODE="0644"

readonly PATCHED_GRUB_SCRIPT="/tmp/10_linux.bootprep"
readonly PATCHED_GRUB_SCRIPT_MODE="0755"
readonly BOOTPREP_BACKUP_DIR="/var/lib/bootprep/backups"
readonly GRUB_BACKUP="${BOOTPREP_BACKUP_DIR}/10_linux.original"
readonly GRUB_DIVERSION="${BOOTPREP_BACKUP_DIR}/10_linux.dist"
readonly GRUB_DEFAULT_BACKUP="${BOOTPREP_BACKUP_DIR}/grub.default.original"

EFI_GRUB_CFG=""
readonly EFI_GRUB_BACKUP="${BOOTPREP_BACKUP_DIR}/efi-grub.original.cfg"

readonly BOOTPREP_SOURCE="bootprep"
readonly BOOTPREP_SNAPPER_SOURCE="99_bootprep"

readonly BOOTPREP_DEST="/usr/sbin/bootprep"
readonly BOOTPREP_SNAPPER_DEST="/usr/lib/snapper/plugins/99_bootprep"

###############################################################################
# BootPrep Runtime
###############################################################################

readonly BOOTPREP_STATE_DIR="/var/lib/bootprep"
readonly BOOTPREP_STATE_FILE="${BOOTPREP_STATE_DIR}/next-boot"
readonly BOOTPREP_RUNTIME_DIR="/usr/lib/bootprep"
readonly BOOTPREP_RUNTIME="${BOOTPREP_RUNTIME_DIR}/bootprep-runtime.sh"
readonly BOOTPREP_RUNTIME_MODE="0644"

###############################################################################
# Output
###############################################################################

section() {

    printf "\n"
    printf "============================================================\n"
    printf "%s\n" "$1"
    printf "============================================================\n"

}

info() {

    printf "[INFO] %s\n" "$1"

}

ok() {

    printf "[ OK ] %s\n" "$1"

}

warn() {

    printf "[WARN] %s\n" "$1"

}

die() {

    printf "[FAIL] %s\n" "$1" >&2
    exit 1

}

###############################################################################
# Basic Validation
###############################################################################

require_root() {

    [[ $EUID -eq 0 ]] || die "Please run with sudo."

}

require_file() {

    local file="$1"

    [[ -f "$file" ]] || die "Missing file: $file"

}

require_command() {

    command -v "$1" >/dev/null 2>&1 \
        || die "Missing command: $1"

}

###############################################################################
# Discovery
###############################################################################

OS_NAME="Unknown"
OS_ID=""
OS_ID_LIKE=""
GRUB_STYLE="unknown"

ROOT_DEVICE=""
ROOT_UUID=""
ROOT_SUBVOL=""
BASE_SUBVOL=""
HOME_SUBVOL=""

discover_os() {

    section "Operating System"

    require_file "/etc/os-release"

    # shellcheck disable=SC1091
    source /etc/os-release

    OS_NAME="${PRETTY_NAME:-Unknown}"
    OS_ID="${ID}"
    OS_ID_LIKE="${ID_LIKE:-}"

    ok "Detected: ${OS_NAME}"

}

discover_environment() {

    section "Environment"

    require_file "${GRUB_SCRIPT}"
    require_file "${GRUB_DEFAULT}"
    require_file "${FSTAB}"

    require_command grep
    require_command sed
    require_command awk
    require_command nl
    require_command paste
    require_command findmnt
    require_command btrfs
    require_command update-grub

    ok "Found ${GRUB_SCRIPT}"
    ok "Found ${GRUB_DEFAULT}"
    ok "Found ${FSTAB}"

}

discover_efi() {

    section "EFI GRUB"

    mountpoint -q /boot/efi \
        || die "/boot/efi is not mounted."

    EFI_GRUB_CFG="/boot/efi/EFI/${OS_ID}/grub.cfg"

    if [[ -r "${EFI_GRUB_CFG}" ]]; then

        ok "Detected EFI GRUB."

        printf "File : %s\n" "${EFI_GRUB_CFG}"

        return

    fi

    if [[ -n "${OS_ID_LIKE}" ]]; then

        local like

        for like in ${OS_ID_LIKE}; do

            EFI_GRUB_CFG="/boot/efi/EFI/${like}/grub.cfg"

            if [[ -r "${EFI_GRUB_CFG}" ]]; then

                ok "Detected EFI GRUB."

                printf "File : %s\n" "${EFI_GRUB_CFG}"

                return

            fi

        done

    fi

    die "Unable to locate EFI grub.cfg."

}

discover_btrfs_layout() {

    section "Btrfs Layout"

    [[ "$(findmnt -n -o FSTYPE /)" == "btrfs" ]] \
        || die "The root filesystem is not Btrfs."

    ROOT_DEVICE="$(findmnt -n -o SOURCE /)"
    ROOT_DEVICE="${ROOT_DEVICE%%[*}"

    ROOT_UUID="$(findmnt -n -o UUID /)"

    [[ -n "${ROOT_UUID}" ]] \
        || die "Unable to determine the root Btrfs filesystem UUID."

    ROOT_SUBVOL="$(
        findmnt -n -o OPTIONS / |
        sed -n 's/.*subvol=\/\([^,]*\).*/\1/p'
    )"

    [[ -n "${ROOT_SUBVOL}" ]] \
        || die "Unable to determine the active root subvolume."

    BASE_SUBVOL="${ROOT_SUBVOL}"

    if [[ "${BASE_SUBVOL}" == @/.snapshots/* ]]; then
        BASE_SUBVOL="@"
    fi

    local home_target
    local home_options

    home_target="$(findmnt -n -o TARGET -T /home 2>/dev/null || true)"
    HOME_SUBVOL=""

    if [[ "${home_target}" == "/home" ]]; then
        home_options="$(findmnt -n -o OPTIONS /home 2>/dev/null || true)"

        HOME_SUBVOL="$(
            sed -n 's/.*subvol=\/\([^,]*\).*/\1/p' <<< "${home_options}"
        )"
    fi

    printf "Device         : %s\n" "${ROOT_DEVICE}"
    printf "UUID           : %s\n" "${ROOT_UUID}"
    printf "Root Subvolume : %s\n" "${BASE_SUBVOL}"
    printf "Home Subvolume : %s\n" "${HOME_SUBVOL:-not separate}"

    ok "Btrfs layout discovered."

}

detect_grub_style() {

    section "GRUB Integration"

    #
    # Detect an existing BootPrep installation.
    #
    if grep -q "${BOOTPREP_VARIABLE}" "${GRUB_DEFAULT}" ; then

        GRUB_STYLE="bootprep"

        warn "BootPrep integration detected."

        return

    fi

    #
    # Detect an existing snapshot boot integration.
    #
    if grep -q "SUSE_BTRFS_SNAPSHOT_BOOTING" "${GRUB_DEFAULT}" ; then

        GRUB_STYLE="opensuse"

        warn "Native openSUSE integration detected."

        return

    fi

    #
    # Default to the standard Debian-style GRUB implementation.
    #
    GRUB_STYLE="debian"

    ok "Detected stock Debian-style GRUB."

}

###############################################################################
# Determine Installation Eligibility
###############################################################################

check_installation_eligibility() {

    section "Installation Eligibility"

    local grub_script_installed=false
    local grub_defaults_installed=false

    grep -q "${BOOTPREP_VARIABLE}" "${GRUB_SCRIPT}" \
        && grub_script_installed=true

    grep -q "^${BOOTPREP_VARIABLE}=" "${GRUB_DEFAULT}" \
        && grub_defaults_installed=true

    printf "GRUB Script   : %s\n" "${grub_script_installed}"
    printf "GRUB Defaults : %s\n" "${grub_defaults_installed}"
    printf "\n"

    case "${GRUB_STYLE}" in

        opensuse)

            die "Native openSUSE integration is not supported."
            ;;

    esac

    if ${grub_script_installed} && ${grub_defaults_installed}; then

        ok "BootPrep is already installed."

        info "Nothing to do."

        exit 0

    fi

    if ${grub_script_installed} || ${grub_defaults_installed}; then

        warn "Partial BootPrep installation detected."

        info "Repair support will be added in a future release."

        exit 0

    fi

    ok "Installation is permitted."

}

###############################################################################
# Snapshot Store Mount Reconciliation
###############################################################################

discover_snapshot_stores() {

    local path
    local root_store="${BASE_SUBVOL}/.snapshots"
    local home_store

    if [[ -n "${HOME_SUBVOL}" ]]; then
        home_store="${HOME_SUBVOL}/.snapshots"
    else
        home_store="${BASE_SUBVOL}/home/.snapshots"
    fi

    while IFS= read -r path; do
        case "${path}" in
            ".snapshots"|"${root_store}")
                printf '%s\t%s\n' "${root_store}" "/.snapshots"
                ;;
            "${home_store}")
                printf '%s\t%s\n' "${path}" "/home/.snapshots"
                ;;
        esac
    done < <(
        btrfs subvolume list / |
        awk '
            {
                sub(/^.* path /, "")
                if ($0 ~ /(^|\/)\.snapshots$/)
                    print
            }
        '
    )

    return 0

}

snapshot_mount_options() {

    local options

    options="$(
        findmnt -n -o OPTIONS / |
        tr ',' '\n' |
        awk '
            $0 == "rw" || $0 == "ro" { next }
            $0 ~ /^subvol=/ { next }
            $0 ~ /^subvolid=/ { next }
            $0 ~ /^space_cache=/ { next }
            NF { print }
        ' |
        paste -sd, -
    )"

    if [[ -n "${options}" ]]; then
        options="defaults,${options}"
    else
        options="defaults"
    fi

    printf '%s\n' "${options}"

}

fstab_entry_is_correct() {

    local line="$1"
    local expected_subvol="$2"
    local source
    local target
    local fstype
    local options

    read -r source target fstype options _ <<< "${line}"

    [[ "${fstype}" == "btrfs" ]] || return 1
    [[ ",${options}," == *",subvol=/${expected_subvol},"* ]] || return 1

    case "${source}" in
        "UUID=${ROOT_UUID}"|"${ROOT_DEVICE}")
            ;;
        *)
            return 1
            ;;
    esac

    return 0

}

canonical_fstab_entry() {

    local subvol="$1"
    local mountpoint="$2"
    local options="$3"

    printf 'UUID=%s %s btrfs subvol=/%s,%s 0 0\n' \
        "${ROOT_UUID}" \
        "${mountpoint}" \
        "${subvol}" \
        "${options}"

}

reconcile_fstab_entry() {

    local fstab="$1"
    local subvol="$2"
    local mountpoint="$3"
    local canonical="$4"
    local tmpfile="$5"

    local line
    local -a matches=()

    mapfile -t matches < <(
        awk -v target="${mountpoint}" '
            /^[[:space:]]*#/ || NF == 0 { next }
            $2 == target { print }
        ' "${fstab}"
    )

    case "${#matches[@]}" in
        0)
            printf '%s\n' "${canonical}" >> "${tmpfile}"
            info "Adding snapshot store mount: ${mountpoint}"
            ;;
        1)
            line="${matches[0]}"

            if fstab_entry_is_correct "${line}" "${subvol}"; then
                return 0
            fi

            awk -v target="${mountpoint}" -v replacement="${canonical}" '
                BEGIN {
                    replaced = 0
                }

                /^[[:space:]]*#/ || NF == 0 {
                    print
                    next
                }

                $2 == target {
                    if (replaced == 0) {
                        print replacement
                        replaced = 1
                    }
                    next
                }

                {
                    print
                }

                END {
                    if (replaced != 1)
                        exit 1
                }
            ' "${tmpfile}" > "${tmpfile}.new" \
                || die "Unable to replace the fstab entry for ${mountpoint}."

            mv "${tmpfile}.new" "${tmpfile}"
            info "Replacing snapshot store mount: ${mountpoint}"
            ;;
        *)
            die "Multiple active fstab entries found for ${mountpoint}."
            ;;
    esac

    return 0

}

verify_reconciled_fstab() {

    local fstab="$1"
    shift

    local subvol
    local mountpoint
    local line
    local -a matches=()

    while (( $# >= 2 )); do
        subvol="$1"
        mountpoint="$2"
        shift 2

        mapfile -t matches < <(
            awk -v target="${mountpoint}" '
                /^[[:space:]]*#/ || NF == 0 { next }
                $2 == target { print }
            ' "${fstab}"
        )

        [[ "${#matches[@]}" -eq 1 ]] \
            || die "Snapshot store mount validation failed for ${mountpoint}."

        line="${matches[0]}"

        fstab_entry_is_correct "${line}" "${subvol}" \
            || die "Snapshot store mount validation failed for ${mountpoint}."
    done

    return 0

}

reconcile_snapshot_store_mounts() {

    section "Snapshot Store Mounts"

    local options
    local tmpfile
    local backup_file
    local changed=false
    local subvol
    local mountpoint
    local canonical
    local existing_line
    local store
    local -a stores=()
    local -a verify_args=()

    mapfile -t stores < <(discover_snapshot_stores)

    if [[ "${#stores[@]}" -eq 0 ]]; then
        ok "No snapshot store mounts required."
        return 0
    fi

    options="$(snapshot_mount_options)"
    tmpfile="$(mktemp /tmp/bootprep-fstab.XXXXXX)"
    cp -a "${FSTAB}" "${tmpfile}"

    for store in "${stores[@]}"; do
        IFS=$'\t' read -r subvol mountpoint <<< "${store}"

        canonical="$(canonical_fstab_entry "${subvol}" "${mountpoint}" "${options}")"
        verify_args+=("${subvol}" "${mountpoint}")

        if ! awk -v target="${mountpoint}" '
            /^[[:space:]]*#/ || NF == 0 { next }
            $2 == target { found = 1 }
            END { exit(found ? 0 : 1) }
        ' "${FSTAB}"; then
            changed=true
        else
            existing_line="$(
                awk -v target="${mountpoint}" '
                    /^[[:space:]]*#/ || NF == 0 { next }
                    $2 == target { print; exit }
                ' "${FSTAB}"
            )"

            if ! fstab_entry_is_correct "${existing_line}" "${subvol}"; then
                changed=true
            fi
        fi

        reconcile_fstab_entry \
            "${FSTAB}" \
            "${subvol}" \
            "${mountpoint}" \
            "${canonical}" \
            "${tmpfile}"
    done

    verify_reconciled_fstab "${tmpfile}" "${verify_args[@]}"

    if [[ "${changed}" == "false" ]]; then
        rm -f "${tmpfile}"
        ok "Snapshot store mounts verified."
        return 0
    fi

    mkdir -p "${BOOTPREP_BACKUP_DIR}"
    backup_file="${BOOTPREP_BACKUP_DIR}/fstab.$(date +%Y%m%d-%H%M%S)"

    cp -a "${FSTAB}" "${backup_file}"
    cp -a "${tmpfile}" "${FSTAB}"

    if ! verify_reconciled_fstab "${FSTAB}" "${verify_args[@]}"; then
        cp -a "${backup_file}" "${FSTAB}"
        rm -f "${tmpfile}"
        die "fstab update failed and was restored."
    fi

    rm -f "${tmpfile}"

    systemctl daemon-reload

    printf "Backup : %s\n" "${backup_file}"
    ok "Snapshot store mounts reconciled."

}

###############################################################################
# BootPrep Runtime
###############################################################################

install_bootprep_runtime() {

    section "Install BootPrep Runtime"

    mkdir -p "${BOOTPREP_RUNTIME_DIR}"

    cat > "${BOOTPREP_RUNTIME}" <<'EOF'
#!/usr/bin/env bash

###############################################################################
# BootPrep Global Definitions
###############################################################################

bootprep_read_state_file() {

    local current="$1"

    local resolved="${current}"

    resolved="$(
        bootprep_state_value \
            "BOOTPREP_SUBVOLUME" \
            "${current}"
    )"

    printf '%s\n' "${resolved}"

}

bootprep_state_value() {

    local key="$1"
    local default="$2"

    local line

    while IFS= read -r line; do

        case "${line}" in

            "${key}"=*)

                printf '%s\n' "${line#*=}"

                return

                ;;

        esac

    done < "${BOOTPREP_STATE_FILE}"

    printf '%s\n' "${default}"

}

bootprep_validate_subvolume() {

    local current="$1"
    local resolved="$2"

    resolved="$(
        bootprep_normalize_subvolume \
            "${current}" \
            "${resolved}"
    )"

    resolved="$(
        bootprep_verify_subvolume \
            "${current}" \
            "${resolved}"
    )"

    printf '%s\n' "${resolved}"

}

bootprep_normalize_subvolume() {

    local current="$1"
    local resolved="$2"

    if [[ -z "${resolved}" ]]; then
        resolved="${current}"
    fi

    printf '%s\n' "${resolved}"

}

bootprep_verify_subvolume() {

    local current="$1"
    local resolved="$2"

    case "${resolved}" in

        @*)
            ;;

        *)
            resolved="${current}"
            ;;

    esac

    printf '%s\n' "${resolved}"

}

bootprep_resolve_subvolume() {

    local current="$1"

    local resolved

    resolved="${current}"

    #
    # If no BootPrep state exists, continue using the current subvolume.
    #
    if [[ ! -f "${BOOTPREP_STATE_FILE}" ]]; then
        printf '%s\n' "${resolved}"
        return
    fi

    resolved="$(
        bootprep_read_state_file "${current}"
    )"

    resolved="$(
        bootprep_validate_subvolume \
            "${current}" \
            "${resolved}"
    )"

    printf '%s\n' "${resolved}"

}

EOF

    chmod "${BOOTPREP_RUNTIME_MODE}" "${BOOTPREP_RUNTIME}"

    ok "BootPrep runtime installed."

    printf "File : %s\n" "${BOOTPREP_RUNTIME}"

}

verify_bootprep_runtime() {

    section "Verify BootPrep Runtime"

    [[ -f "${BOOTPREP_RUNTIME}" ]] \
        || die "BootPrep runtime is missing."

    bash -n "${BOOTPREP_RUNTIME}" \
        || die "BootPrep runtime contains shell syntax errors."

    ok "BootPrep runtime verified."

    printf "File : %s\n" "${BOOTPREP_RUNTIME}"

}

install_bootprep_config() {

    section "Install BootPrep Configuration"

    mkdir -p "${BOOTPREP_CONFIG_DIR}"

    cat > "${BOOTPREP_CONFIG}" <<EOF
###############################################################################
# BootPrep Configuration
#
# Generated by the BootPrep Installer.
#
# This file defines the installation layout shared by all BootPrep
# components.
#
# BootPrep applications should source this file rather than hardcoding
# installation paths.
###############################################################################

BOOTPREP_VERSION="1"

BOOTPREP_RUNTIME_DIR="${BOOTPREP_RUNTIME_DIR}"
BOOTPREP_RUNTIME="${BOOTPREP_RUNTIME}"

BOOTPREP_STATE_DIR="${BOOTPREP_STATE_DIR}"
BOOTPREP_STATE_FILE="${BOOTPREP_STATE_FILE}"

BOOTPREP_GRUB_SCRIPT="${GRUB_SCRIPT}"
BOOTPREP_GRUB_DEFAULT="${GRUB_DEFAULT}"

EOF

    chmod "${BOOTPREP_CONFIG_MODE}" "${BOOTPREP_CONFIG}"

    ok "BootPrep configuration installed."

    printf "File : %s\n" "${BOOTPREP_CONFIG}"

}

verify_bootprep_config() {

    section "Verify BootPrep Configuration"

    [[ -f "${BOOTPREP_CONFIG}" ]] \
        || die "BootPrep configuration is missing."

    bash -n "${BOOTPREP_CONFIG}" \
        || die "BootPrep configuration contains syntax errors."

    ok "BootPrep configuration verified."

    printf "File : %s\n" "${BOOTPREP_CONFIG}"

}

###############################################################################
# Install BootPrep Components
###############################################################################

install_bootprep_components() {

    section "Install BootPrep Components"

    install -Dm755 \
        "${BOOTPREP_SOURCE}" \
        "${BOOTPREP_DEST}"

    ok "BootPrep installed."

    printf "File : %s\n" "${BOOTPREP_DEST}"

    install -Dm755 \
        "${BOOTPREP_SNAPPER_SOURCE}" \
        "${BOOTPREP_SNAPPER_DEST}"

    ok "BootPrep Snapper installed."

    printf "File : %s\n" "${BOOTPREP_SNAPPER_DEST}"
}

verify_bootprep_components() {

    section "Verify BootPrep Components"

    [[ -x "${BOOTPREP_DEST}" ]] \
        || die "BootPrep is missing."

    [[ -x "${BOOTPREP_SNAPPER_DEST}" ]] \
        || die "BootPrep Snapper is missing."

    bash -n "${BOOTPREP_DEST}" \
        || die "BootPrep contains shell syntax errors."

    bash -n "${BOOTPREP_SNAPPER_DEST}" \
        || die "BootPrep Snapper contains shell syntax errors."

    ok "BootPrep components verified."
}

###############################################################################
# Analyze 10_linux
###############################################################################

INSERTION_LINE=0

find_insertion_point() {

    section "Analyzing ${GRUB_SCRIPT}"

    #
    # Locate the standard Btrfs rootflags section.
    #
    INSERTION_LINE="$(
        grep -n "make_system_path_relative_to_its_root /" "${GRUB_SCRIPT}" \
        | head -n1 \
        | cut -d: -f1
    )"

    [[ -n "${INSERTION_LINE}" ]] \
        || die "Unable to locate the rootflags section."

    ok "Candidate insertion point located."

    printf "\n"
    printf "Line : %s\n\n" "${INSERTION_LINE}"

    local start=$((INSERTION_LINE-5))
    local end=$((INSERTION_LINE+10))

    (( start < 1 )) && start=1

    printf '%s\n' "Context"
    printf '%s\n' "-------"

    nl -ba "${GRUB_SCRIPT}" | sed -n "${start},${end}p"

}

###############################################################################
# Report
###############################################################################

report() {

    section "Summary"

    printf "Distribution   : %s\n" "${OS_NAME}"
    printf "GRUB Style     : %s\n" "${GRUB_STYLE}"
    printf "Insertion Line : %s\n" "${INSERTION_LINE}"

    printf "\n"

    case "${GRUB_STYLE}" in

        bootprep)

            warn "BootPrep is already installed."

            ;;

        opensuse)

            warn "Native openSUSE integration detected."

            ;;

        debian)

            ok "Installation completed successfully."

            ;;

        *)

            warn "Unknown GRUB implementation."

            ;;

    esac

}

###############################################################################
# Installation
###############################################################################

backup_grub_script() {

    section "Backup GRUB Script"

    if [[ -f "${GRUB_BACKUP}" ]]; then

        ok "Existing backup found."

        printf "Backup : %s\n" "${GRUB_BACKUP}"

        return

    fi
    mkdir -p "${BOOTPREP_BACKUP_DIR}"
    cp -a "${GRUB_SCRIPT}" \
        "${GRUB_BACKUP}"

    ok "Backup created."

    printf "Backup : %s\n" "${GRUB_BACKUP}"

}

###############################################################################
# Divert GRUB Script
###############################################################################

divert_grub_script() {

    section "Divert GRUB Script"

    #
    # Nothing to do if already diverted.
    #
    if dpkg-divert --list "${GRUB_SCRIPT}" | grep -q "^diversion of"; then

        ok "GRUB script is already diverted."

        printf "File : %s\n" "${GRUB_SCRIPT}"

        return

    fi

    #
    # Ensure the backup directory exists.
    #
    mkdir -p "${BOOTPREP_BACKUP_DIR}"

    #
    # Divert the upstream Debian GRUB script.
    #
    dpkg-divert \
        --package local \
        --divert "${GRUB_DIVERSION}" \
        --rename \
        "${GRUB_SCRIPT}"

    [[ -f "${GRUB_DIVERSION}" ]] \
        || die "Failed to divert GRUB script."

    ok "GRUB script diverted."

    printf "Original : %s\n" "${GRUB_SCRIPT}"
    printf "Diverted : %s\n" "${GRUB_DIVERSION}"

}

backup_grub_defaults() {

    section "Backup GRUB Defaults"

    if [[ -f "${GRUB_DEFAULT_BACKUP}" ]]; then

        ok "Existing GRUB defaults backup found."

        printf "Backup : %s\n" "${GRUB_DEFAULT_BACKUP}"

        return

    fi
    mkdir -p "${BOOTPREP_BACKUP_DIR}"
    cp -a "${GRUB_DEFAULT}" "${GRUB_DEFAULT_BACKUP}"

    ok "GRUB defaults backup created."

    printf "Backup : %s\n" "${GRUB_DEFAULT_BACKUP}"

}

backup_efi_grub() {

    section "Backup EFI GRUB"

    if [[ -f "${EFI_GRUB_BACKUP}" ]]; then

        ok "Existing EFI GRUB backup found."

        printf "Backup : %s\n" "${EFI_GRUB_BACKUP}"

        return

    fi

    mkdir -p "${BOOTPREP_BACKUP_DIR}"

    cp -a "${EFI_GRUB_CFG}" \
        "${EFI_GRUB_BACKUP}"

    [[ -f "${EFI_GRUB_BACKUP}" ]] \
        || die "Failed to create EFI GRUB backup."

    ok "EFI GRUB backup created."

    printf "Backup : %s\n" "${EFI_GRUB_BACKUP}"

}

configure_grub_defaults() {

    section "Configure GRUB Defaults"

    if grep -q "^${BOOTPREP_VARIABLE}=" "${GRUB_DEFAULT}"; then

        local value

        value="$(
            grep "^${BOOTPREP_VARIABLE}=" "${GRUB_DEFAULT}" \
            | tail -n1 \
            | cut -d= -f2-
        )"

        ok "BootPrep configuration already exists."

        printf "Setting : %s=%s\n" \
            "${BOOTPREP_VARIABLE}" \
            "${value}"

        return

    fi

    printf '\n%s="true"\n' \
        "${BOOTPREP_VARIABLE}" \
        >> "${GRUB_DEFAULT}"

    ok "BootPrep configuration added."

    printf "Setting : %s=\"true\"\n" \
        "${BOOTPREP_VARIABLE}"

}

verify_upstream_layout() {

    section "Verifying Upstream Layout"

    grep -q 'case x"\$GRUB_FS" in' "${GRUB_SCRIPT}" \
        || die "Unable to locate GRUB_FS case statement."

    grep -q 'make_system_path_relative_to_its_root /' "${GRUB_SCRIPT}" \
        || die "Unable to locate rootsubvol logic."

    grep -q 'GRUB_CMDLINE_LINUX="rootflags=subvol=' "${GRUB_SCRIPT}" \
        || die "Unable to locate rootflags assignment."

    ok "Upstream Debian layout verified."

}

###############################################################################
# Locate Patch Region
###############################################################################

PATCH_START=0
PATCH_END=0

find_patch_region() {

    section "Finding Patch Region"

    #
    # Locate the beginning of the Btrfs case block.
    #
    PATCH_START="$(
        grep -n '^[[:space:]]*xbtrfs)' "${GRUB_SCRIPT}" \
        | head -n1 \
        | cut -d: -f1
    )"

    [[ -n "${PATCH_START}" ]] \
        || die "Unable to locate xbtrfs) block."

    #
    # Locate the end of the Btrfs case block.
    #
    PATCH_END="$(
        awk -v start="${PATCH_START}" '
            NR >= start && /^[[:space:]]*;;$/ {
                print NR
                exit
            }
        ' "${GRUB_SCRIPT}"
    )"

    [[ -n "${PATCH_END}" ]] \
        || die "Unable to determine end of xbtrfs block."

    ok "Patch region identified."

    printf "Start Line : %s\n" "${PATCH_START}"
    printf "End Line   : %s\n" "${PATCH_END}"

}

show_patch_region() {

    section "Patch Preview"

    nl -ba "${GRUB_SCRIPT}" | sed -n "${PATCH_START},${PATCH_END}p"

}

###############################################################################
# Generate BootPrep Block
###############################################################################

ORIGINAL_BLOCK=""
REPLACEMENT_BLOCK=""

capture_original_block() {

    section "Capture Original Block"

    ORIGINAL_BLOCK="$(
        sed -n "${PATCH_START},${PATCH_END}p" "${GRUB_SCRIPT}"
    )"

    [[ -n "${ORIGINAL_BLOCK}" ]] \
        || die "Failed to capture original block."

    ok "Original block captured."

}

###############################################################################
# BootPrep Replacement Block
###############################################################################

generate_bootprep_btrfs_block() {

cat <<'EOF'
    xbtrfs)

        #
        # Determine the current root subvolume.
        #
        rootsubvol="`make_system_path_relative_to_its_root /`"
        rootsubvol="${rootsubvol#/}"
        #
        # Load the BootPrep runtime library.
        #
        if [ -f /usr/lib/bootprep/bootprep-runtime.sh ]; then
            . /usr/lib/bootprep/bootprep-runtime.sh
        fi
        #
        # BootPrep integration.
        #
        # If enabled, ask BootPrep to determine the correct
        # subvolume to boot.
        #
        if [ "x${BOOTPREP_BTRFS_SNAPSHOT_BOOTING}" = "xtrue" ]; then
            newsubvol="$(bootprep_resolve_subvolume "${rootsubvol}")"
            if [ "x${newsubvol}" != x ]; then
                rootsubvol="${newsubvol}"
            fi
        fi
        #
        # Continue with the standard Debian-style behavior.
        #
        if [ "x${rootsubvol}" != x ]; then
            GRUB_CMDLINE_LINUX="rootflags=subvol=${rootsubvol} ${GRUB_CMDLINE_LINUX}"
        fi
        ;;
EOF

}

###############################################################################

build_replacement_block() {

    section "Generate BootPrep Block"

    REPLACEMENT_BLOCK="$(
        generate_bootprep_btrfs_block
    )"

    ok "Replacement block generated."

    printf "\n"
}

###############################################################################
# Compare Blocks
###############################################################################

compare_blocks() {

    section "Original Block"

    printf '%s\n' "${ORIGINAL_BLOCK}"

    section "Replacement Block"

    printf '%s\n' "${REPLACEMENT_BLOCK}"

    section "Comparison"

    if [[ "${ORIGINAL_BLOCK}" == "${REPLACEMENT_BLOCK}" ]]; then

        warn "Replacement block is currently identical."

        printf '%s\n' \
            "This is expected until the BootPrep logic is implemented."

    else

        ok "Replacement block differs from the original."

    fi

}

###############################################################################
# Create Patched GRUB Script
###############################################################################

build_patched_grub_script() {

    section "Create Patched GRUB Script"

    cp -a "${GRUB_SCRIPT}" "${PATCHED_GRUB_SCRIPT}"

    ok "Temporary copy created."

    printf "Output : %s\n" "${PATCHED_GRUB_SCRIPT}"

}

###############################################################################
# Patch GRUB Script
###############################################################################

apply_replacement_block() {

    section "Patch GRUB Script"

    awk \
        -v start="${PATCH_START}" \
        -v end="${PATCH_END}" \
        -v replacement="${REPLACEMENT_BLOCK}" '
BEGIN {
    split(replacement, block, "\n")
}

NR < start || NR > end {
    print
    next
}

NR == start {
    for (i = 1; i in block; i++)
        print block[i]
    next
}

NR > start && NR <= end {
    next
}
' "${PATCHED_GRUB_SCRIPT}" > "${PATCHED_GRUB_SCRIPT}.new"

    mv "${PATCHED_GRUB_SCRIPT}.new" "${PATCHED_GRUB_SCRIPT}"

    ok "Replacement block inserted."

}

###############################################################################
# Verify Patched GRUB Script
###############################################################################

verify_patched_grub_script() {

    section "Verify Patched GRUB Script"

    grep -q "${BOOTPREP_VARIABLE}" "${PATCHED_GRUB_SCRIPT}" \
        || die "BootPrep integration was not found in the patched copy."

    ok "BootPrep integration verified."

    printf "Verified : %s\n" "${PATCHED_GRUB_SCRIPT}"

}

###############################################################################
# Prepare Patched GRUB Script
###############################################################################

prepare_patched_grub_script() {

    section "Prepare Patched GRUB Script"

    chmod "${PATCHED_GRUB_SCRIPT_MODE}" "${PATCHED_GRUB_SCRIPT}"

    [[ -x "${PATCHED_GRUB_SCRIPT}" ]] \
        || die "Patched GRUB script is not executable."

    ok "Patched GRUB script is executable."

    printf "Mode : %s\n" "${PATCHED_GRUB_SCRIPT_MODE}"
    printf "File : %s\n" "${PATCHED_GRUB_SCRIPT}"

}

###############################################################################
# Install Patched GRUB Script
###############################################################################

install_patched_grub_script() {

    section "Install Patched GRUB Script"

    install \
        -o root \
        -g root \
        -m "${PATCHED_GRUB_SCRIPT_MODE}" \
        "${PATCHED_GRUB_SCRIPT}" \
        "${GRUB_SCRIPT}"

    ok "Patched GRUB script installed."

    printf "Source : %s\n" "${PATCHED_GRUB_SCRIPT}"
    printf "Target : %s\n" "${GRUB_SCRIPT}"

}

###############################################################################
# Verify Installed GRUB Script
###############################################################################

verify_installed_grub_script() {

    section "Verify Installed GRUB Script"

    [[ -f "${GRUB_SCRIPT}" ]] \
        || die "Installed GRUB script is missing."

    bash -n "${GRUB_SCRIPT}" \
        || die "Installed GRUB script contains shell syntax errors."

    grep -q "${BOOTPREP_VARIABLE}" "${GRUB_SCRIPT}" \
        || die "BootPrep integration is missing from the installed GRUB script."

    grep -q "bootprep_resolve_subvolume" "${GRUB_SCRIPT}" \
        || die "BootPrep resolver call is missing from the installed GRUB script."

    ok "Installed GRUB script verified."

    printf "File : %s\n" "${GRUB_SCRIPT}"

}

###############################################################################
# Regenerate GRUB Configuration
###############################################################################

regenerate_grub_configuration() {

    section "Regenerate GRUB Configuration"

    if update-grub; then

        ok "GRUB configuration regenerated."

    else

        die "update-grub failed."

    fi

}

###############################################################################
# Main
###############################################################################

main() {

    section "BootPrep"

    printf "GRUB Integration\n"

    require_root

    #
    # Discovery
    #
    discover_os
    discover_environment
    discover_efi
    detect_grub_style

    # Prevent reinstalling over an existing BootPrep installation.
    check_installation_eligibility

    #
    # Boot environment preparation
    #
    discover_btrfs_layout
    reconcile_snapshot_store_mounts

    #
    # Installation validation
    #
    verify_upstream_layout
    backup_grub_script
    backup_grub_defaults
    backup_efi_grub
    configure_grub_defaults

    install_bootprep_runtime
    verify_bootprep_runtime

    # ------------------------------------------------------------------
    # FUTURE DEVELOPMENT (v2.x)
    #
    # Configuration file support has been deferred until the core
    # BootPrep workflow is fully validated. Version 1.x uses built-in
    # defaults only.
    #
    # install_bootprep_config
    # verify_bootprep_config
    # ------------------------------------------------------------------

    install_bootprep_components
    verify_bootprep_components

    #
    # Patch discovery
    #
    find_insertion_point
    find_patch_region
    show_patch_region

    #
    # Replacement generation
    #
    capture_original_block
    build_replacement_block
    compare_blocks
    build_patched_grub_script
    apply_replacement_block
    verify_patched_grub_script
    prepare_patched_grub_script
    divert_grub_script
    install_patched_grub_script
    verify_installed_grub_script
    regenerate_grub_configuration

    #
    # Summary
    #
    report

    section "Result"

    cat <<EOF

BootPrep GRUB integration installed successfully.

Installed:
    /etc/grub.d/10_linux
    /etc/default/grub

Backups:
    ${GRUB_BACKUP}
    ${GRUB_DEFAULT_BACKUP}
    ${EFI_GRUB_BACKUP}

GRUB:
    Configuration regenerated successfully.

BootPrep is ready for snapshot boot integration.

EOF

}

###############################################################################

main "$@"
