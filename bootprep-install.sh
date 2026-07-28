#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Scott McClain
#
###############################################################################
#
# BootPrep Installer
#
# Component : Installer
# Version   : 1.0
#
# Installs BootPrep and integrates Debian-style GRUB with Btrfs snapshot boot support.
#
###############################################################################

set -Eeuo pipefail

###############################################################################
# Constants
###############################################################################

readonly GRUB_SCRIPT="/etc/grub.d/10_linux"
readonly GRUB_DEFAULT="/etc/default/grub"

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

    require_command grep
    require_command sed
    require_command awk
    require_command nl
    require_command update-grub

    ok "Found ${GRUB_SCRIPT}"
    ok "Found ${GRUB_DEFAULT}"

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
