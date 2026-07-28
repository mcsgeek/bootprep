# BootPrep Architecture

## Purpose

BootPrep is a command-line utility that prepares a selected Btrfs snapshot to become the next bootable system.

BootPrep does **not** perform rollbacks, create snapshots, manage Btrfs, or generate boot loaders. Instead, it coordinates existing Linux components so the selected snapshot becomes the new **system of record** after the next reboot.

BootPrep integrates with Snapper through an optional plugin, allowing standard Snapper rollback operations to automatically prepare the boot environment without requiring user intervention.

---

# Design Philosophy

BootPrep exists because no existing Linux component performs the complete transition between a selected snapshot and a successfully bootable system.

Each component already performs its own job well.

| Component    | Responsibility                                                    |
| ------------ | ----------------------------------------------------------------- |
| Btrfs        | Stores and mounts subvolumes                                      |
| Snapper      | Creates, manages, and rolls back snapshots                        |
| GRUB         | Generates boot configuration                                      |
| Linux Kernel | Boots the filesystem selected by GRUB                             |
| BootPrep     | Prepares the selected snapshot to become the new system of record |

BootPrep is therefore an **integration layer**, not a replacement for any existing project.

---

# Mission Statement

> **Snapper performs the rollback. BootPrep makes the necessary changes for the system to recognize the default snapshot as the new system of record.**

This statement defines the boundary between Snapper and BootPrep.

Snapper chooses the snapshot.

BootPrep prepares it.

---

# Core Responsibility

BootPrep has exactly one responsibility:

> **Prepare a selected Btrfs snapshot so it becomes the next bootable system.**

It should perform only those operations necessary to accomplish that goal.

---

# What BootPrep Does

The BootPrep engine:

* Accepts a selected snapshot.
* Mounts the snapshot.
* Creates the temporary runtime environment.
* Enters the snapshot through a chroot.
* Executes the required boot preparation commands.
* Records transaction state.
* Cleans up temporary resources.
* Exits.

---

# What BootPrep Does NOT Do

BootPrep intentionally does not:

* Create snapshots.
* Delete snapshots.
* Perform snapshot cleanup.
* Manage snapshot retention.
* Choose which snapshot should be used.
* Replace GRUB.
* Replace Snapper.
* Replace Btrfs.

Those responsibilities belong to their respective projects.

---

# Boot Preparation Transaction

The BootPrep Engine performs a single transaction.

```
Selected Snapshot
        │
        ▼
Discover Snapshot
        │
        ▼
Mount Snapshot
        │
        ▼
Create Runtime Environment
        │
        ▼
Enter chroot
        │
        ▼
Run update-grub
        │
        ▼
Record Transaction State
        │
        ▼
Cleanup
        │
        ▼
Ready for Reboot
```

The transaction is considered successful only if every stage completes successfully.

---

# Why BootPrep Runs update-grub

BootPrep does not regenerate GRUB because it wants to replace GRUB.

It runs `update-grub` because GRUB must regenerate its configuration **inside the environment that will become the next booted system**.

Running `update-grub` inside the selected snapshot allows the existing GRUB infrastructure—including BootPrep's GRUB extensions—to prepare the system correctly.

BootPrep delegates boot configuration generation to GRUB rather than attempting to generate it itself.

---

# Engine Independence

The BootPrep Engine is independent of Snapper.

Its interface is simply:

```
bootprep <snapshot-id>
```

The engine does not care how the snapshot became selected.

The snapshot may have been selected by:

* Snapper rollback
* Manual Btrfs commands
* A future graphical interface
* Another management utility

The engine performs exactly the same transaction regardless of the caller.

---

# Snapper Integration

BootPrep includes an optional Snapper plugin.

The plugin exists only to automatically invoke the BootPrep engine after Snapper performs a rollback.

Normal workflow:

```
snapper rollback
        │
        ▼
Snapper Plugin
        │
        ▼
bootprep <snapshot-id>
        │
        ▼
BootPrep Engine
```

The Snapper plugin contains as little logic as possible.

Its purpose is simply to launch the BootPrep engine.

---

# Manual Workflow

BootPrep also supports manual operation.

Example:

```
Create writable snapshot
        │
        ▼
btrfs subvolume set-default
        │
        ▼
bootprep <snapshot-id>
        │
        ▼
Reboot
```

This allows BootPrep to prepare manually selected snapshots without requiring Snapper.

---

# Project Structure

Proposed project layout:

```
bootprep/

├── bin/
│   └── bootprep
│
├── engine/
│   └── bootprep-engine.sh
│
├── runtime/
│   ├── bootprep-runtime.sh
│   └── bootprep-common.sh
│
├── plugins/
│   └── snapper/
│       └── 99-bootprep
│
├── installer/
│   └── install.sh
│
├── docs/
│   ├── ARCHITECTURE.md
│   ├── ROADMAP.md
│   └── DESIGN.md
│
└── README.md
```

---

# Design Principles

BootPrep follows several core principles.

## 1. Use Existing Components

If Linux already provides a reliable solution, BootPrep should use it instead of replacing it.

Examples:

* Use Snapper for rollback.
* Use Btrfs for snapshot management.
* Use GRUB for boot generation.

---

## 2. Keep the Engine Small

Every line inside the BootPrep Engine should contribute directly to preparing the next boot environment.

Anything else belongs elsewhere.

---

## 3. One Responsibility

The engine performs one transaction.

It prepares the selected snapshot for boot.

Nothing more.

---

## 4. Separation of Responsibilities

The CLI, engine, runtime library, installer, and Snapper plugin each have separate responsibilities.

No component should perform another component's job.

---

## 5. Extensibility

Future interfaces should reuse the existing BootPrep Engine rather than duplicate functionality.

Possible future interfaces include:

* Snapper plugin
* GUI frontend
* REST service
* Recovery tools
* Distribution integration

All should invoke the same engine.

---

# Version 1.0 Goal

BootPrep Version 1.0 is complete when the engine can reliably prepare any selected Btrfs snapshot to become the next bootable system.

Whether the snapshot was selected by Snapper, Btrfs commands, or another interface is outside the scope of the engine.

That separation of responsibilities defines the BootPrep architecture.
