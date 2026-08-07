# BootPrep Architecture

## Purpose

BootPrep is the activation layer for systems using a default nested Btrfs subvolume layout.

It prepares the boot environment after a selected writable snapshot has been presented by the invoking workflow, allowing that snapshot to become the next bootable system while preserving the existing filesystem layout.

BootPrep does **not** create snapshots, choose snapshots, make snapshots writable, set the Btrfs default subvolume, perform rollbacks, or replace the boot loader. Those responsibilities remain with Btrfs, Snapper, or the workflow that invokes BootPrep.

The BootPrep engine can be called directly or through the included Snapper rollback plugin.

---

## Design Philosophy

BootPrep exists because no individual Linux component performs the complete transition between a selected writable snapshot and a successfully bootable system.

Each component already performs its own job well.

| Component | Responsibility |
| --- | --- |
| Btrfs | Creates writable snapshots, manages subvolumes, and presents the selected root filesystem |
| Snapper | Creates, manages, and rolls back snapshots |
| GRUB | Generates boot configuration |
| Linux kernel | Mounts and boots the selected root filesystem |
| BootPrep | Prepares the boot environment for the next boot |

BootPrep is therefore the **activation layer** between the invoking workflow and the next bootable system, not a replacement for any existing project.

---

## Mission Statement

> **Snapper and Btrfs present the selected writable snapshot. BootPrep prepares the boot environment for the next boot.**

This statement defines the boundary between Snapper, Btrfs, and BootPrep.

Snapper manages the rollback workflow.

Btrfs creates and presents the writable snapshot.

BootPrep prepares the boot environment.

---

## Core Responsibility

BootPrep has exactly one responsibility:

> **Prepare the boot environment so a selected writable snapshot becomes the next bootable system.**

Every operation performed by BootPrep exists solely to accomplish that goal.

---

## What BootPrep Does

To fulfill its single responsibility, the BootPrep engine:

- Accepts a snapshot number through the `prepare` command.
- Discovers the corresponding nested Btrfs snapshot subvolume.
- Reconciles required snapshot store mounts.
- Mounts the selected snapshot.
- Bind-mounts the runtime filesystems required by the chroot.
- Enters the snapshot through a chroot.
- Runs `update-grub` inside the selected snapshot.
- Discovers and backs up the EFI GRUB configuration.
- Patches the EFI GRUB prefix for the selected snapshot.
- Records pending transaction state.
- Applies EFI backup retention.
- Cleans up temporary mounts and files.
- Exits.

> **Prepare the boot environment so a selected writable snapshot becomes the next bootable system.**

---

## Snapshot Store Reconciliation

Snapshot booting requires the appropriate snapshot store mounts to exist within the writable snapshot being prepared.

BootPrep discovers available snapshot stores directly from the Btrfs filesystem and reconciles only the required snapshot store entries in the target system.

The reconciliation policy is intentionally conservative:

- Correct entry → Leave unchanged.
- Missing entry → Add canonical entry.
- Incorrect entry → Replace the complete entry.
- Duplicate active entries → Abort safely.
- No matching snapshot store → No action.

BootPrep derives mount options from the running system, filters runtime-only mount options, and preserves the existing Btrfs mount policy when generating canonical `fstab` entries.

---

## What BootPrep Does Not Do

BootPrep intentionally avoids responsibilities that already belong to other system components.

Snapshot creation, writable snapshot management, rollback operations, filesystem management, and bootloader management remain the responsibility of Btrfs, Snapper, GRUB, or the workflow that presents the selected writable snapshot.

> **BootPrep exists to fill a missing responsibility—not to replace existing ones.**p.

---

## Boot Preparation Transaction

The BootPrep engine performs a single transaction:

```text
Selected writable snapshot
        |
        v
Discover nested snapshot subvolume
        |
        v
Reconcile snapshot store mounts
        |
        v
Mount snapshot and bind runtime filesystems
        |
        v
Enter chroot and run update-grub
        |
        v
Discover and back up EFI GRUB configuration
        |
        v
Patch EFI GRUB prefix
        |
        v
Write pending BootPrep state
        |
        v
Apply backup retention and clean up
        |
        v
Ready for reboot
```

The transaction is successful only when every required stage completes successfully.

A cleanup trap attempts to unmount temporary bind mounts and the selected snapshot whenever the engine exits.

---

## Why BootPrep Runs update-grub

BootPrep does not run `update-grub` to replace GRUB.

GRUB must regenerate its configuration **inside the environment that will become the next booted system**.

Running `update-grub` inside the selected snapshot allows the existing GRUB infrastructure, including BootPrep's installed GRUB runtime integration, to resolve the intended root subvolume correctly.

BootPrep delegates boot configuration generation to GRUB rather than generating `grub.cfg` itself.

---

## GRUB and EFI Integration

The current installer targets Debian-style GRUB systems.

It:

- Verifies `/etc/grub.d/10_linux` and `/etc/default/grub`.
- Backs up the original GRUB files.
- Uses `dpkg-divert` to preserve the distribution-provided `10_linux`.
- Installs a BootPrep-aware `10_linux`.
- Adds `BOOTPREP_BTRFS_SNAPSHOT_BOOTING="true"` to `/etc/default/grub`.
- Generates `/usr/lib/bootprep/bootprep-runtime.sh`.
- Runs `update-grub`.

`BOOTPREP_BTRFS_SNAPSHOT_BOOTING="true"` is the persistent enable switch for BootPrep's GRUB integration. The installer sets it once, allowing the generated GRUB configuration to remain BootPrep-aware without selecting a snapshot by itself. When no pending BootPrep state exists, normal root-subvolume resolution remains unchanged.

During a prepare transaction, the engine also backs up and patches the vendor EFI `grub.cfg` prefix so the firmware-loaded GRUB configuration points into the selected snapshot.

This integration is intended to preserve normal boot behavior when no pending BootPrep state exists.

Before the first rollback, the system continues to boot from its original root subvolume. After Snapper performs a rollback and BootPrep prepares the resulting writable snapshot, the system boots from a nested snapshot subvolume. From that point forward, BootPrep’s GRUB integration is required to resolve the nested root subvolume correctly. Removing BootPrep is therefore unsupported; returning to the original root-subvolume layout would require a deliberate filesystem and bootloader migration.

---

## Engine Independence

The BootPrep engine is independent of Snapper.

Its interface is:

```text
bootprep prepare <snapshot-number>
```

The engine does not care which external workflow selected the snapshot.

The snapshot may have been selected through:

- A Snapper rollback.
- Manual Btrfs commands.
- A future graphical interface.
- Another management utility.

The engine performs the same preparation transaction regardless of the caller.

---

## Snapper Integration

BootPrep includes the `99_bootprep` Snapper plugin, installed at:

```text
/usr/lib/snapper/plugins/99_bootprep
```

The current installer installs this component alongside the engine. The plugin ignores non-rollback operations.

For a rollback operation, Snapper supplies the resulting snapshot number and the plugin invokes:

```text
/usr/sbin/bootprep prepare <snapshot-number>
```

The normal integrated workflow is:

```text
snapper rollback
        |
        v
Snapper creates/selects the writable rollback result
        |
        v
99_bootprep receives the snapshot number
        |
        v
bootprep prepare <snapshot-number>
        |
        v
BootPrep engine prepares the next boot
```

The plugin intentionally contains minimal logic. Its responsibility is to validate the callback data and launch the engine.

---

## Manual Workflow

BootPrep also supports manual invocation.

The external workflow remains responsible for creating the writable snapshot and setting the correct Btrfs default subvolume:

```text
Create writable snapshot
        |
        v
Set the Btrfs default subvolume
        |
        v
bootprep prepare <snapshot-number>
        |
        v
Reboot
```

This allows BootPrep to prepare snapshots selected without Snapper.

---

## Future Activation Workflow

The current `prepare` command operates only after another tool, such as Snapper, has created the writable rollback snapshot and set the Btrfs default subvolume.

In the current Snapper-integrated workflow, the rollback has already occurred before BootPrep is invoked:

```text
User invokes Snapper rollback
        |
        v
Snapper performs the rollback
        |
        v
Snapper creates the resulting writable snapshot
        |
        v
Snapper sets it as the Btrfs default subvolume
        |
        v
99_bootprep receives the resulting snapshot number
        |
        v
bootprep prepare <resulting-snapshot-number>
        |
        v
BootPrep prepares the system for the next boot
```

A future BootPrep companion utility (`bootprep-btrfs`) may provide an `activate` workflow that creates a writable snapshot, sets it as the default Btrfs subvolume, and then invokes the existing BootPrep preparation engine.

The BootPrep engine itself will remain responsible only for preparing an already-selected writable snapshot for the next boot.

These additional responsibilities will belong to the higher-level `activate` workflow. They will not change the responsibility of the underlying `prepare` operation, which remains focused exclusively on preparing an already-selected writable snapshot and its boot environment for the next reboot.

---

## Runtime State

BootPrep uses:

```text
/var/lib/bootprep/next-boot
```

to record the pending subvolume, snapshot number, and transaction status.

The GRUB runtime integration consults this state while generating the boot configuration. If no BootPrep state file is present, normal root-subvolume resolution remains unchanged.

Installer backups are stored beneath:

```text
/var/lib/bootprep/backups
```

Transaction-time EFI backups are retained beneath:

```text
/var/lib/bootprep/efi-backups
```

---

## Project Structure

The repository keeps the BootPrep engine, Snapper plugin, installer, and component upgrade script together. The installer performs initial system and GRUB integration, while the upgrade script refreshes only the engine and Snapper plugin on an existing installation.

```text
bootprep/
├── .gitignore
├── 99_bootprep
├── ARCHITECTURE.md
├── LICENSE
├── README.md
├── bootprep
├── bootprep-install.sh
└── bootprep-upgrade.sh
```

The installer performs the initial installation of the engine, Snapper plugin, runtime library, and GRUB integration. The upgrade script requires an existing BootPrep installation and reinstalls only the engine and Snapper plugin.

---

## Design Principles

### 1. Use Existing Components

If Linux already provides a reliable solution, BootPrep should use it instead of replacing it.

Examples:

- Use Snapper for rollback.
- Use Btrfs for snapshot and subvolume management.
- Use GRUB for boot configuration generation.

### 2. Keep the Engine Focused

Every operation inside the BootPrep engine should contribute directly to preparing the next boot environment.

Anything else belongs to the invoking workflow or another component.

### 3. One Responsibility

The engine performs one preparation transaction.

It prepares the selected snapshot for boot.

Nothing more.

### 4. Separation of Responsibilities

The engine, Snapper plugin, installer, component upgrade script, and generated runtime library have distinct responsibilities.

No component should take ownership of another component's job.

### 5. Extensibility

Future interfaces should reuse the existing BootPrep engine rather than duplicate its functionality.

Possible future interfaces include:

- A graphical frontend.
- Recovery tools.
- Distribution integration.
- Other snapshot-management utilities.

All should invoke the same engine interface.

---

## Version 1.0.1

BootPrep Version 1.0.1 prepares a supported writable Btrfs snapshot to become the next bootable system while automatically performing Snapshot Store Reconciliation for any discovered snapshot stores.

The `prepare` operation remains responsible only for preparing an already-selected writable snapshot and its boot environment. Snapshot selection, rollback, writable snapshot creation, and Btrfs subvolume management remain the responsibility of the invoking workflow.

Future BootPrep companion utilities, including the planned `bootprep-btrfs`, will build upon this preparation engine rather than duplicating its functionality.

That separation of responsibilities defines the BootPrep architecture.

---

## License

BootPrep is licensed under the GNU General Public License v3.0 or later (`GPL-3.0-or-later`).
