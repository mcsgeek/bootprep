#!/usr/bin/env bash
# Version: 2.1.0
# Shared nested-subvolume reconciliation. SPDX-License-Identifier: GPL-3.0-or-later
# Inputs are the target root, stable root subvolume, active root subvolume,
# filesystem UUID, and backup directory relative to the target root.

bp_subvolume_candidates() {
    local base="$1" active="$2"
    # One metadata listing. Snapshot descendants are excluded before any
    # directory inspection; this does not walk snapshot contents.
    awk -v base="$base" -v active="$active" '
        {
            if ($1 != "ID" || $2 !~ /^[0-9]+$/ || !index($0, " path ")) exit 2
            id=$2; parent="";
            for (i=1;i<NF;i++) if ($i=="parent_uuid") parent=$(i+1)
            if (parent=="") exit 2
            path=$0; sub(/^.* path /,"",path)
            paths[++n]=path; ids[n]=id; parents[n]=parent
            # Newer listings include filesystem-rooted paths without the
            # older <FS_TREE> marker, including the root itself.
            if (path==base || path==active || index(path,base "/")==1 || index(path,active "/")==1) absolute=1
        }
        END {
            for (i=1;i<=n;i++) {
                path=paths[i]
                if (path ~ /^<FS_TREE>\//) sub(/^<FS_TREE>\//,"",path)
                else if (!absolute) path=active "/" path
                paths[i]=path
                if (parents[i]!="-") snapshots[path]=1
            }
            for (i=1;i<=n;i++) {
                path=paths[i]; rel=""
                if (index(path,active "/")==1) rel=substr(path,length(active)+2)
                else if (index(path,base "/")==1) rel=substr(path,length(base)+2)
                if (rel=="" || rel ~ /(^|\/)\.snapshots\//) continue
                excluded=0
                ancestor=path
                while (ancestor!="") {
                    if (ancestor!=active && ancestor in snapshots) { excluded=1; break }
                    if (ancestor !~ /\//) break
                    sub(/\/[^/]*$/,"",ancestor)
                }
                if (!excluded) print path "\t/" rel "\t" ids[i]
            }
        }
    '
}

bp_safe_path() {
    [[ "$1" =~ ^/?[a-zA-Z0-9_@.+/-]+$ && "$1" != *//* && "/${1#/}/" != */../* && "/${1#/}/" != */./* ]]
}

bp_check_directory() {
    local relative="$2" part path="${1%/}"
    local -a bp_parts=()
    IFS=/ read -r -a bp_parts <<< "${relative#/}"
    for part in "${bp_parts[@]}"; do
        path="$path/$part"
        [[ ! -L "$path" ]] || { echo "Symlink in reconciliation path: $path" >&2; return 1; }
        [[ ! -e "$path" || -d "$path" ]] || { echo "Not a directory: $path" >&2; return 1; }
    done
}

# systemd ships this legacy image mount even on systems using an inline
# subvolume. Allow only the unmodified vendor definition with no image or
# drop-ins; fstab takes precedence over a vendor unit without changing it.
bp_unused_machines_compatibility_unit() {
    local root="$1" file="$2" directory dropin
    case "$file" in
        "$root/usr/lib/systemd/system/var-lib-machines.mount"|"$root/lib/systemd/system/var-lib-machines.mount") ;;
        *) return 1 ;;
    esac
    [[ -f "$file" && ! -L "$file" ]] || return 1
    [[ ! -e "$root/var/lib/machines.raw" && ! -L "$root/var/lib/machines.raw" ]] || return 1
    # An image in the running root must not be displaced when preparing a
    # different snapshot either.
    [[ ! -e /var/lib/machines.raw && ! -L /var/lib/machines.raw ]] || return 1
    for directory in "$root/etc/systemd/system" "$root/run/systemd/system" "$root/usr/lib/systemd/system" "$root/lib/systemd/system"; do
        for dropin in mount.d var-.mount.d var-lib-.mount.d var-lib-machines.mount.d; do
            [[ ! -e "$directory/$dropin" && ! -L "$directory/$dropin" ]] || return 1
        done
    done
    awk '
        /^[[:space:]]*([#;]|$)/ { next }
        { gsub(/^[[:space:]]+|[[:space:]]+$/, "") }
        /^\[/ { section=$0; if (section!="[Unit]" && section!="[Mount]") bad=1; next }
        {
            split_at=index($0,"=")
            if (!split_at) { bad=1; next }
            key=substr($0,1,split_at-1); value=substr($0,split_at+1)
            gsub(/[[:space:]]+$/, "", key); gsub(/^[[:space:]]+/, "", value)
            if (section=="[Unit]" && (key=="Description" || key=="Documentation")) next
            full=section key
            if (++seen[full]!=1) bad=1
            if (full=="[Unit]ConditionPathExists" && value=="/var/lib/machines.raw") condition=1
            else if (full=="[Mount]What" && value=="/var/lib/machines.raw") what=1
            else if (full=="[Mount]Where" && value=="/var/lib/machines") where=1
            else if (full=="[Mount]Type" && value=="btrfs") type=1
            else if (full=="[Mount]Options" && value=="loop") options=1
            else bad=1
        }
        END { exit !(condition && what && where && type && options && !bad) }
    ' "$file"
}

bp_reconcile_subvolumes() (
    set -euo pipefail
    local target_root="${1%/}" base="$2" active="$3" uuid="$4" backup_dir="$5"
    local fstab="${1%/}/etc/fstab" scratch="" top="" mounted=false
    local subvol target id parent field source flags unit row option ro expected
    local count=0 backup stage=""
    local -a rows=() mounts=() options=() additions=()
    local -A targets=() fstab_targets=()
    bp_safe_path "$base" && bp_safe_path "$active" || { echo 'Unsupported root path' >&2; return 1; }
    [[ "$uuid" =~ ^[a-fA-F0-9-]+$ && -f "$fstab" && ! -L "$fstab" ]] || return 1
    bp_check_directory "$target_root" /etc
    scratch=$(mktemp -d /run/bootprep-subvolumes.XXXXXX)
    trap 'if [[ "$mounted" == true ]]; then umount "$top" || exit 1; fi; [[ -z "$stage" ]] || rm -f -- "$stage"; rm -rf -- "$scratch"' EXIT
    btrfs subvolume list -a -q / > "$scratch/inventory"
    bp_subvolume_candidates "$base" "$active" < "$scratch/inventory" > "$scratch/candidates"
    mapfile -t rows < "$scratch/candidates"
    # Fstab and actual mounts establish boundaries. Do not adopt children of
    # an unchanged /home, /var, or another independent mount.
    while read -r source target field flags _; do
        [[ -z "$source" || "$source" == \#* ]] && continue
        [[ "$target" == /* ]] || continue
        [[ -z "${fstab_targets[$target]:-}" ]] || { echo "Duplicate fstab mount: $target" >&2; return 1; }
        fstab_targets[$target]=1
        [[ "$target" == /* && "$target" != / ]] && mounts+=("$target")
    done < "$fstab"
    findmnt -rn -o TARGET > "$scratch/mounts"
    while IFS= read -r target; do
        [[ "$target" == / ]] && continue
        if [[ -n "$target_root" && ( "$target" == "$target_root" || "$target" == "$target_root/"* ) ]]; then continue; fi
        mounts+=("$target")
    done < "$scratch/mounts"
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r subvol target id <<< "$row"
        bp_safe_path "$subvol" && bp_safe_path "$target" || { echo "Unsupported subvolume path: $subvol" >&2; return 1; }
        [[ "$target" != /boot && "$target" != /boot/* && "$target" != /dev && "$target" != /dev/* && "$target" != /proc && "$target" != /proc/* && "$target" != /sys && "$target" != /sys/* && "$target" != /run && "$target" != /run/* ]] || continue
        [[ -z "${fstab_targets[$target]:-}" ]] || continue
        # An exact live mount without fstab needs explicit review, not a
        # guessed persistent replacement. Parent mounts delimit scope.
        for parent in "${mounts[@]}"; do
            if [[ "$target" == "$parent" ]]; then
                echo "Existing mount without target fstab entry: $target; review its mount definition" >&2
                return 1
            fi
            [[ "$target" != "$parent/"* ]] || continue 2
        done
        [[ -z "${targets[$target]:-}" || "${targets[$target]}" == "$subvol" ]] || { echo "Ambiguous subvolumes for $target" >&2; return 1; }
        [[ -z "${targets[$target]:-}" ]] || continue
        targets[$target]="$subvol"
        # Honour mount/automount definitions, except the unused vendor
        # compatibility image mount identified below.
        unit=$(systemd-escape --path "$target")
        for field in mount automount; do
            for parent in "$target_root/etc/systemd/system" "$target_root/run/systemd/system" "$target_root/usr/lib/systemd/system" "$target_root/lib/systemd/system"; do
                [[ -e "$parent/$unit.$field" || -L "$parent/$unit.$field" ]] || continue
                if bp_unused_machines_compatibility_unit "$target_root" "$parent/$unit.$field"; then
                    continue
                fi
                echo "Existing $unit.$field requires review" >&2
                return 1
            done
        done
        bp_check_directory "$target_root" "$target"
        additions+=("$row")
    done
    if ((${#additions[@]}==0)); then
        echo '[ OK ] Subvolume mounts verified; nothing to change.'
        return
    fi
    # Mount the filesystem top level only when there is actual adoption work.
    top="$scratch/top"; mkdir "$top"
    mount -t btrfs -o ro,subvolid=5 "UUID=$uuid" "$top"; mounted=true
    [[ "$(findmnt -n -o UUID --mountpoint "$top")" == "$uuid" && "$(findmnt -n -o FSROOT --mountpoint "$top")" == / ]] || return 1
    findmnt -n -o OPTIONS / > "$scratch/options"
    IFS=, read -r -a options < "$scratch/options"
    flags=defaults
    for option in "${options[@]}"; do
        case "$option" in rw|ro|subvol=*|subvolid=*|bind|rbind) ;; *) flags+=",$option" ;; esac
    done
    cp -a -- "$fstab" "$scratch/original"
    cp -a -- "$fstab" "$scratch/staged"
    # Terminate an unterminated last line without adding a blank separator.
    if [[ -s "$scratch/staged" && -n "$(tail -c 1 -- "$scratch/staged")" ]]; then
        printf '\n' >> "$scratch/staged"
    fi
    for row in "${additions[@]}"; do
        IFS=$'\t' read -r subvol target id <<< "$row"
        bp_check_directory "$top" "/$subvol"
        [[ "$(btrfs inspect-internal rootid "$top/$subvol")" == "$id" ]] || return 1
        ro=$(btrfs property get -ts "$top/$subvol" ro)
        case "$ro" in ro=true) expected="$flags,ro" ;; ro=false) expected="$flags" ;; *) return 1 ;; esac
        printf 'UUID=%s %s btrfs subvol=/%s,%s 0 0\n' "$uuid" "$target" "$subvol" "$expected" >> "$scratch/staged"
        echo "[INFO] Adopting $target from /$subvol"
        count=$((count+1))
    done
    # Only create empty mountpoint directories; never mount over the live
    # namespace here. The installer applies mounts on reboot.
    for row in "${additions[@]}"; do
        IFS=$'\t' read -r subvol target id <<< "$row"
        bp_check_directory "$target_root" "$target"
        mkdir -p -- "$target_root$target"
    done
    bp_check_directory "$target_root" "$backup_dir"
    mkdir -p -- "$target_root$backup_dir"
    backup=$(mktemp "$target_root$backup_dir/fstab.XXXXXXXX")
    cp -a -- "$fstab" "$backup"
    stage=$(mktemp "$target_root/etc/.bootprep-fstab.XXXXXXXX")
    cp -a -- "$scratch/staged" "$stage"
    cmp -s "$fstab" "$scratch/original" || { rm -f "$stage"; echo 'fstab changed during reconciliation' >&2; return 1; }
    sync -f "$stage"
    mv -T -- "$stage" "$fstab"
    echo "[ OK ] Reconciled $count subvolume mount(s). Backup: ${backup#"$target_root"}"
)
