# BootPrep Architecture

## Purpose

BootPrep is the activation layer for GRUB-based Linux systems using a nested Btrfs snapshot layout.

It prepares the boot environment after a selected writable snapshot has been presented by the invoking workflow, allowing that snapshot to become the next bootable system while preserving the existing filesystem layout.

BootPrep does **not** create snapshots, choose snapshots, make snapshots writable, set the Btrfs default subvolume, perform rollbacks, or replace GRUB. Those responsibilities remain with Btrfs, Snapper, GRUB, or the workflow that invokes BootPrep.

---

## Design Philosophy

No individual Linux component performs the complete transition between a selected writable snapshot and a successfully bootable system.

| Component | Responsibility |
| --- | --- |
| Btrfs | Creates writable snapshots, manages subvolumes, and presents the selected root filesystem |
| Snapper | Creates, manages, and rolls back snapshots |
| GRUB | Generates configuration and installs the platform loader |
| Linux kernel | Mounts and boots the selected root filesystem |
| BootPrep | Prepares the selected snapshot's boot environment |

BootPrep is therefore the **activation layer** between the invoking workflow and the next bootable system, not a replacement for any existing project.

> **Snapper and Btrfs present the selected writable snapshot. BootPrep prepares the boot environment for the next boot.**

---

## Core Responsibility

BootPrep has exactly one responsibility:

> **Prepare the boot environment so a selected writable snapshot becomes the next bootable system.**

Every operation performed by the engine exists solely to accomplish that goal.

## What BootPrep Does

The engine:

- Accepts a snapshot number through `prepare`.
- Validates the running Btrfs and UEFI environment.
- Resolves the base root subvolume and exact nested snapshot path.
- Mounts the selected snapshot and verifies that it is writable.
- Reconciles required snapshot-store mounts in the snapshot's `fstab`.
- Makes the runtime filesystems, separate `/boot`, and EFI System Partition available inside the snapshot as required.
- Discovers a safe existing EFI bootloader ID.
- Validates the GRUB platform target and tools inside the snapshot.
- Runs `grub-mkconfig` inside the snapshot.
- Refreshes the existing EFI loader inside the snapshot while preserving the firmware boot entry and boot order.
- Cleans up temporary mounts and files.

## What BootPrep Does Not Do

The engine does not:

- Create or delete snapshots.
- Choose the snapshot to activate.
- Make snapshots writable.
- Set the Btrfs default subvolume.
- Implement Snapper rollback behavior.
- Repair or change UEFI firmware boot entries or boot order.
- Patch distribution-provided GRUB scripts.
- Maintain persistent next-boot state.
- Manually rewrite EFI GRUB redirect files.

> **BootPrep exists to fill a missing responsibility—not to replace existing ones.**

---

## Boot Preparation Transaction

```text
Selected writable snapshot
        |
        v
Validate Btrfs, UEFI, and snapshot number
        |
        v
Discover base root and exact snapshot subvolume
        |
        v
Mount snapshot and verify it is writable
        |
        v
Reconcile snapshot store mounts
        |
        v
Bind runtime, boot, and EFI filesystems
        |
        v
Discover bootloader ID and EFI target
        |
        v
Enter chroot and run grub-mkconfig
        |
        v
Run grub-install --no-nvram
        |
        v
Clean up temporary mounts
        |
        v
Ready for reboot
```

The transaction succeeds only when every required stage completes. A cleanup trap attempts to unmount temporary mounts whenever the engine exits.

## Snapshot Discovery

The engine begins with the active root subvolume reported by `findmnt`.

When the active root is already a writable snapshot such as:

```text
@/.snapshots/8/snapshot
```

BootPrep removes the nested snapshot suffix to recover the base root:

```text
@
```

It also validates the selected snapshot through the snapshot store mounted at:

```text
/.snapshots/<number>/snapshot
```

The target must be a real Btrfs subvolume. BootPrep resolves its numeric subvolume ID and mounts by that ID, avoiding path-format differences when the running root is either the base root or an already nested snapshot. The derived base-root name is retained for snapshot-store reconciliation.

The mounted target must report `ro=false`. BootPrep refuses to prepare a read-only snapshot.

---

## Snapshot Store Reconciliation

Snapshot booting requires snapshot stores to remain available after entering a nested root snapshot.

BootPrep discovers root and home snapshot-store subvolumes directly from Btrfs and reconciles only the corresponding entries in the target system.

The policy is conservative:

- Correct entry → Leave unchanged.
- Missing entry → Add a canonical entry.
- Incorrect entry → Replace the complete entry.
- Duplicate active entries → Abort safely.
- No matching snapshot store → No action.

Persistent mount options are derived from the running root filesystem. Runtime-only state, `subvol`, `subvolid`, and `space_cache` options are filtered before a canonical entry is generated.

Before modifying `fstab`, BootPrep creates a timestamped copy beneath:

```text
/var/lib/bootprep/backups
```

The replacement is verified after writing. If verification fails, the original is restored.

The fresh installer performs the same reconciliation for the running system.

---

## Chroot Environment

GRUB configuration must be generated from the environment that will become the next system.

BootPrep mounts the selected Btrfs subvolume at a private directory beneath `/run` and makes these filesystems available inside it:

- `/dev`
- `/proc`
- `/sys`
- `/run`
- `/boot`, when it is a separate mount
- `/boot/efi`

`/dev` and `/sys` are recursively bound so required child mounts remain visible. Their propagation is made slave to prevent unmount operations inside the transaction from propagating back to the host.

`/boot/efi` must already be mounted on the running system. It is bound explicitly inside the snapshot whether or not `/boot` is separate.

Before GRUB operations begin, BootPrep verifies that `grub-mkconfig` and `grub-install` are installed in the selected snapshot.

---

## GRUB Configuration Generation

Inside the selected snapshot, BootPrep runs:

```text
grub-mkconfig -o /boot/grub/grub.cfg
```

The command runs through a sanitized environment with only the required home, path, locale, terminal, and temporary-directory values.

BootPrep does not generate `grub.cfg` itself. It delegates configuration generation to the distribution's installed GRUB tooling and verifies that the resulting file exists and is nonempty.

Version 2.x does not patch `10_linux`. The selected snapshot is the chroot root, allowing ordinary GRUB scripts to inspect and configure that environment directly.

---

## EFI Bootloader Discovery

BootPrep identifies the existing bootloader ID rather than inventing a new one.

The selected snapshot's `/etc/os-release` supplies `ID` and `ID_LIKE` candidates. BootPrep enumerates directories beneath:

```text
/boot/efi/EFI
```

A directory qualifies only when:

- Its name contains only safe bootloader-ID characters.
- It contains a GRUB or shim EFI executable.

OS identity comparison is case-insensitive because `os-release` capitalization may differ from the FAT EFI directory. The actual directory spelling is preserved when passed to GRUB.

If no OS identity matches, BootPrep accepts a nonstandard bootloader ID such as `GRUB` only when exactly one qualifying loader directory exists. Multiple unmatched candidates are ambiguous and cause a safe abort.

The host architecture maps to a supported GRUB EFI target:

| Machine architecture | GRUB target |
| --- | --- |
| `x86_64` | `x86_64-efi` |
| `aarch64`, `arm64` | `arm64-efi` |
| `i386` family | `i386-efi` |

The corresponding platform directory must exist beneath `/usr/lib/grub` inside the selected snapshot.

---

## GRUB Installation

After configuration generation, BootPrep runs the equivalent of:

```text
grub-install \
    --target=<validated-efi-target> \
    --efi-directory=/boot/efi \
    --bootloader-id=<validated-existing-id> \
    --no-nvram
```

`--no-nvram` is a deliberate safety boundary. BootPrep assumes the existing UEFI boot configuration is working, refreshes the loader files and prefix, and preserves the firmware boot entry and boot order. Repairing missing or damaged firmware entries is a separate recovery task outside BootPrep's scope.

This operation performs necessary per-snapshot work. The GRUB prefix must resolve into the newly selected nested snapshot.

On Debian, the prefix is commonly represented by an EFI-side redirect file:

```text
set prefix=($root)'/@/.snapshots/8/snapshot/boot/grub'
```

Other distributions, including tested GRUB-based installations of EndeavourOS and CachyOS, may embed the prefix directly in the EFI executable and have no EFI-side `grub.cfg`. Both layouts are handled by `grub-install`; BootPrep does not manually interpret or rewrite either representation.

---

## Engine Independence

The engine interface is:

```text
bootprep prepare <snapshot-number>
```

The engine does not care which external workflow selected the snapshot. The caller may be:

- A Snapper rollback.
- `bootprep-btrfs activate`.
- A manual Btrfs workflow.
- A future graphical interface.
- Another management utility.

Every path converges on the same preparation transaction.

---

## Snapper Integration

The `99_bootprep` plugin is installed at:

```text
/usr/lib/snapper/plugins/99_bootprep
```

It ignores non-rollback operations. For a rollback callback, Snapper supplies the resulting writable snapshot number and the plugin executes:

```text
/usr/sbin/bootprep prepare <snapshot-number>
```

```text
snapper rollback
        |
        v
Snapper creates and selects writable rollback result
        |
        v
99_bootprep receives resulting snapshot number
        |
        v
bootprep prepare <snapshot-number>
        |
        v
Ready for reboot
```

The plugin contains no Btrfs, GRUB, or discovery logic.

---

## Btrfs Orchestration

`bootprep-btrfs` is a thin wrapper around `/usr/bin/btrfs`.

Its BootPrep-defined interface is:

```text
bootprep-btrfs activate <snapshot-number> [mount-point]
```

The activation transaction:

```text
Validate existing snapshot
        |
        v
Set snapshot ro=false
        |
        v
Set snapshot as Btrfs default subvolume
        |
        v
bootprep prepare <snapshot-number>
```

All other arguments pass directly to native Btrfs. This prevents the wrapper from becoming a second Btrfs command parser.

---

## Fresh Installation

`bootprep-install.sh` is fresh-install only.

Before installation it checks for the installed engine, orchestrator, Snapper plugin, and known legacy component files. Any complete or partial footprint causes the installer to stop and direct the user to `bootprep-upgrade.sh`.

For an eligible system, it validates the environment, reconciles snapshot-store mounts, installs the three runtime components, and verifies them byte-for-byte.

The installer does not alter GRUB configuration or install persistent boot integration.

---

## Upgrade and Version 1 Migration

`bootprep-upgrade.sh` is the only supported path for an existing installation.

### Clean future upgrade

If no v1 artifacts exist, migration is skipped and the upgrader invokes the current installer through a controlled internal upgrade mode. Clean upgrades do not require Debian's `dpkg-divert`, allowing the same path to operate on other supported distributions.

### Version 1 migration

If a v1 diversion, patched GRUB script, GRUB setting, runtime, state file, or configuration is detected, the upgrader performs a recoverable migration:

```text
Validate complete v2 environment
        |
        v
Create timestamped migration archive
        |
        v
Validate saved and diverted upstream 10_linux
        |
        v
Archive patched v1 10_linux
        |
        v
Remove diversion and restore upstream 10_linux
        |
        v
Verify restored script byte-for-byte
        |
        v
Back up grub defaults and remove legacy setting
        |
        v
Archive runtime, state, and configuration
        |
        v
Verify complete legacy cleanup
        |
        v
Install current BootPrep version
```

The v1 migration remains permanently available because users may upgrade directly from v1 to a much later release.

The migration archive is stored beneath `/var/lib/bootprep/backups` with mode `0700`. Active legacy files are moved into the archive rather than discarded.

Version 1 migration is supported only on systems with the Debian `dpkg-divert` mechanism used by that release. If legacy artifacts are detected without it, the upgrader stops before making changes.

---

## Failure and Cleanup Behavior

The scripts use strict shell execution and stop when required validation or commands fail.

The engine cleanup sequence unmounts:

1. `/boot/efi`
2. A separately bound `/boot`
3. Runtime bind mounts
4. The selected snapshot

Temporary directories are removed only after their mounts have been removed. Failed cleanup produces a warning and leaves the working directory available for inspection rather than deleting through a live mount.

Migration refuses unexpected diversion paths, unexpected diversion owners, symbolic legacy artifacts, invalid upstream GRUB scripts, ambiguous loader identities, and restoration mismatches.

---

## Repository Layout

```text
bootprep/
├── bootprep
├── bootprep-btrfs
├── 99_bootprep
├── bootprep-install.sh
├── bootprep-upgrade.sh
├── README.md
├── ARCHITECTURE.md
├── BOOTPREP_BTRFS.md
├── SNAPPER_PLUGIN.md
├── CHANGELOG.md
└── LICENSE
```

## Installed Layout

```text
/usr/sbin/bootprep
/usr/sbin/bootprep-btrfs
/usr/lib/snapper/plugins/99_bootprep
```

Backups and migration archives are stored beneath:

```text
/var/lib/bootprep/backups
```

There is no v2 runtime library or next-boot state file.

---

## Version 2.0.1 Architecture

BootPrep 2.0.1 uses a direct, transactional architecture:

- Validates the selected snapshot and makes it writable when necessary.
- Reconciles the snapshot-store mounts required after boot.
- Mounts the snapshot as a complete system root.
- Mounts the EFI System Partition and required virtual filesystems within it.
- Enters the prepared snapshot environment.
- Generates `/boot/grub/grub.cfg` using the snapshot's own GRUB tooling.
- Refreshes the existing EFI loader without modifying firmware boot entries or boot order.
- Verifies the result and removes all temporary mounts.

This architecture:

- Preserves distribution-owned GRUB files.
- Requires no persistent runtime integration or next-boot state.
- Supports EFI layouts where the GRUB prefix is stored either in a redirect file or in the EFI executable itself.
- Keeps activation and rollback preparation within one controlled transaction.

It replaces the Version 1 architecture based on a diverted `10_linux`, a custom GRUB setting, runtime state files, and manual EFI redirect patching.
