# BootPrep Architecture

## Purpose

BootPrep is a command-line utility that prepares a selected writable Btrfs snapshot to become the next bootable system.

BootPrep does **not** create snapshots, choose snapshots, perform the Btrfs rollback, or replace the boot loader. Instead, it coordinates existing Linux components after a snapshot has been selected so the next reboot enters the intended system state.

The BootPrep engine can be called directly or through the included Snapper rollback plugin.

---

## Design Philosophy

BootPrep exists because no individual Linux component performs the complete transition between a selected writable snapshot and a successfully bootable Debian-style system.

Each component already performs its own job well.

| Component | Responsibility |
| --- | --- |
| Btrfs | Stores and mounts subvolumes and tracks the default subvolume |
| Snapper | Creates, manages, and rolls back snapshots |
| GRUB | Generates boot configuration |
| Linux kernel | Mounts and boots the root filesystem selected through GRUB |
| BootPrep | Prepares the selected snapshot and boot metadata for the next boot |

BootPrep is therefore an **integration layer**, not a replacement for any existing project.

---

## Mission Statement

> **Snapper performs the rollback. BootPrep prepares the selected writable snapshot and boot environment for the next reboot.**

This statement defines the boundary between Snapper and BootPrep.

Snapper chooses and creates the rollback result.

BootPrep prepares it.

---

## Core Responsibility

BootPrep has exactly one responsibility:

> **Prepare a selected writable Btrfs snapshot so it becomes the next bootable system.**

It performs only the operations necessary to accomplish that goal.

---

## What BootPrep Does

The BootPrep engine:

- Accepts a snapshot number through the `prepare` command.
- Discovers the corresponding nested Btrfs snapshot subvolume.
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

---

## What BootPrep Does Not Do

BootPrep intentionally does not:

- Create snapshots.
- Delete snapshots.
- Perform snapshot cleanup.
- Manage snapshot retention.
- Choose which snapshot should be used.
- Set the Btrfs default subvolume.
- Replace GRUB.
- Replace Snapper.
- Replace Btrfs.

Those responsibilities belong to their respective projects or to the workflow that invokes BootPrep.

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

During a prepare transaction, the engine also backs up and patches the vendor EFI `grub.cfg` prefix so the firmware-loaded GRUB configuration points into the selected snapshot.

This integration is intended to preserve normal boot behavior when no pending BootPrep state exists.

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

The current repository intentionally keeps the three executable components together because the installer expects them in the same directory:

```text
bootprep/
├── .gitignore
├── 99_bootprep
├── ARCHITECTURE.md
├── LICENSE
├── README.md
├── bootprep
└── bootprep-install.sh
```

The installer is run from this directory and installs the engine and Snapper plugin into their system locations.

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

The engine, installer, generated runtime library, and Snapper plugin have distinct responsibilities.

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

## Version 1.0 Goal

BootPrep is currently in early development under the public project version `0.1.0-dev`.

Version 1.0 is reached when BootPrep can reliably prepare a selected supported Btrfs snapshot to become the next bootable system, with validated failure handling and recovery behavior.

Whether the snapshot was selected by Snapper, manual Btrfs commands, or another interface remains outside the engine's responsibility.

That separation of responsibilities defines the BootPrep architecture.

---

## License

BootPrep is licensed under the GNU General Public License v3.0 or later (`GPL-3.0-or-later`).
