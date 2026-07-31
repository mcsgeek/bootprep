#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Scott McClain
#
###############################################################################
#
# BootPrep Upgrade
#
# Component : Upgrade
# Version   : 1.0
#
# Reinstalls and verifies the BootPrep executable and Snapper plugin for an
# existing BootPrep installation.
#
###############################################################################

set -Eeuo pipefail

###############################################################################
# Constants
###############################################################################

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

readonly BOOTPREP_SOURCE="${SCRIPT_DIR}/bootprep"
readonly BOOTPREP_SNAPPER_SOURCE="${SCRIPT_DIR}/99_bootprep"

readonly BOOTPREP_DEST="/usr/sbin/bootprep"
readonly BOOTPREP_SNAPPER_DEST="/usr/lib/snapper/plugins/99_bootprep"

###############################################################################
# Output
###############################################################################

section() {

    printf "\n"
    printf "============================================================\n"
    printf "%s\n" "$1"
    printf "============================================================\n"

}

ok() {

    printf "[ OK ] %s\n" "$1"

}

die() {

    printf "[FAIL] %s\n" "$1" >&2
    exit 1

}

###############################################################################
# Validation
###############################################################################

require_root() {

    [[ $EUID -eq 0 ]] || die "Please run with sudo."

}

require_existing_installation() {

    [[ -x "${BOOTPREP_DEST}" ]] \
        || die "BootPrep is not installed. Use bootprep-install.sh instead."

}

require_source_components() {

    [[ -f "${BOOTPREP_SOURCE}" ]] \
        || die "Missing source file: ${BOOTPREP_SOURCE}"

    [[ -f "${BOOTPREP_SNAPPER_SOURCE}" ]] \
        || die "Missing source file: ${BOOTPREP_SNAPPER_SOURCE}"

    bash -n "${BOOTPREP_SOURCE}" \
        || die "BootPrep source contains shell syntax errors."

    bash -n "${BOOTPREP_SNAPPER_SOURCE}" \
        || die "BootPrep Snapper source contains shell syntax errors."

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

    cmp -s "${BOOTPREP_SOURCE}" "${BOOTPREP_DEST}" \
        || die "Installed BootPrep does not match its source file."

    cmp -s "${BOOTPREP_SNAPPER_SOURCE}" "${BOOTPREP_SNAPPER_DEST}" \
        || die "Installed BootPrep Snapper does not match its source file."

    ok "BootPrep components verified."

}

###############################################################################
# Main
###############################################################################

main() {

    section "BootPrep Upgrade"

    require_root
    require_existing_installation
    require_source_components

    install_bootprep_components
    verify_bootprep_components

    section "Upgrade Complete"

    ok "BootPrep components upgraded successfully."

}

main "$@"
