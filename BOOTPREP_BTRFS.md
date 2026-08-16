# BootPrep Btrfs Orchestrator

## Overview

`bootprep-btrfs` is the Btrfs orchestrator for BootPrep.

It provides BootPrep-aware Btrfs workflows while preserving direct access to the native `btrfs` command.

Its first workflow is:

```text
bootprep-btrfs activate <snapshot-number> [mount-point]
```

The `activate` workflow takes an existing Snapper snapshot, makes it writable, sets it as the Btrfs default subvolume, and then delegates final boot preparation to the existing BootPrep engine.

All other arguments are passed directly to `/usr/bin/btrfs`.

---

## Why `bootprep-btrfs` Exists

BootPrep has one responsibility:

> **Prepare the boot environment so an already-selected writable snapshot becomes the next bootable system.**

That means the BootPrep engine should not take ownership of Btrfs activation tasks such as changing a snapshot's read-only property or setting the default subvolume.

Those operations belong to Btrfs.

`bootprep-btrfs` provides a separate place to coordinate Btrfs-specific workflows without expanding the responsibility of the BootPrep engine.

The result is:

```text
Btrfs workflow
        |
        v
bootprep-btrfs
        |
        v
bootprep prepare
```

The orchestrator performs the Btrfs work. BootPrep prepares the next boot.

---

## The Wrapper Design

Although `bootprep-btrfs` is described as a Btrfs orchestrator, its implementation is intentionally a very thin wrapper around `/usr/bin/btrfs`.

It watches only for BootPrep-defined workflow arguments.

In Version 2.0.0, the only defined workflow is:

```text
activate
```

The command dispatcher is conceptually:

```text
bootprep-btrfs activate ...
        |
        +--> BootPrep-defined activation workflow

bootprep-btrfs anything-else ...
        |
        +--> /usr/bin/btrfs anything-else ...
```

The wrapper does not maintain its own list of valid Btrfs commands and does not attempt to interpret ordinary Btrfs syntax.

For any command other than `activate`, it executes:

```bash
exec /usr/bin/btrfs "$@"
```

This allows the native Btrfs command to remain responsible for its own syntax, validation, output, help, and error handling.

---

## Root Requirement

`bootprep-btrfs` requires root privileges for every invocation.

Run it with `sudo`:

```bash
sudo bootprep-btrfs ...
```

If it is not run as root, the orchestrator exits with:

```text
[ERROR] Please run with sudo.
```

This requirement applies both to BootPrep-defined workflows and commands passed through to `/usr/bin/btrfs`.

---

## Activate Workflow

The interface is:

```bash
sudo bootprep-btrfs activate <snapshot-number> [mount-point]
```

The mount point is optional and defaults to:

```text
/
```

For the standard root Snapper layout, this means:

```bash
sudo bootprep-btrfs activate 5
```

targets:

```text
/.snapshots/5/snapshot
```

An explicit mount point can be supplied when required:

```bash
sudo bootprep-btrfs activate 5 /mnt/system
```

In that case, the snapshot path is resolved beneath the supplied mount point.

---

## Activation Transaction

For a valid request, `bootprep-btrfs activate` performs three steps:

```text
Selected existing snapshot
        |
        v
Make snapshot writable
        |
        v
Set snapshot as Btrfs default subvolume
        |
        v
bootprep prepare <snapshot-number>
        |
        v
Ready for reboot
```

The actual Btrfs and BootPrep operations are:

```bash
btrfs property set <snapshot-path> ro false
btrfs subvolume set-default <subvolume-id> <mount-point>
bootprep prepare <snapshot-number>
```

The orchestrator resolves the selected snapshot's Btrfs subvolume ID before changing the default subvolume.

Because the script runs with `set -euo pipefail`, a failed Btrfs operation stops the workflow before the later steps are executed.

BootPrep is invoked only after the Btrfs activation steps complete successfully.

---

## What `activate` Validates

The orchestrator performs validation only for the workflow it owns.

For `activate`, it verifies that:

- No more than the supported arguments were supplied.
- The snapshot number is present and numeric.
- The requested mount point exists.
- The expected snapshot directory exists.
- The snapshot path is a Btrfs subvolume.
- The Btrfs subvolume ID can be resolved.

The expected usage is:

```text
bootprep-btrfs activate <snapshot-number> [mount-point]
```

The orchestrator does not perform BootPrep discovery or reproduce BootPrep's preparation validation. Once the Btrfs activation workflow is complete, `bootprep prepare` takes responsibility for the preparation transaction.

---

## Pass-Through Behavior

Commands not recognized as BootPrep-specific workflows are passed directly to the native Btrfs command.

For example:

```bash
sudo bootprep-btrfs subvolume list /
```

becomes:

```bash
/usr/bin/btrfs subvolume list /
```

Likewise:

```bash
sudo bootprep-btrfs filesystem usage /
```

is handled by the native Btrfs command.

The orchestrator deliberately does not validate these commands.

If required arguments are missing, Btrfs reports the error.

If an invalid Btrfs command is supplied, Btrfs reports the invalid command and displays its normal help output.

For example:

```bash
sudo bootprep-btrfs nonsense
```

is intentionally left for `/usr/bin/btrfs` to handle.

This keeps `bootprep-btrfs` from becoming a second Btrfs command parser.

---

## Separation of Responsibilities

`bootprep-btrfs` exists to preserve the same separation of responsibilities used throughout BootPrep.

### Btrfs is responsible for

- Btrfs subvolume properties.
- Default-subvolume management.
- Native Btrfs command behavior.
- Native command syntax, validation, output, and errors.

### `bootprep-btrfs` is responsible for

- Recognizing BootPrep-defined Btrfs workflows.
- Validating the minimum inputs required by those workflows.
- Coordinating the required Btrfs commands in the correct order.
- Delegating final boot preparation to BootPrep when the workflow requires it.
- Passing all other commands directly to `/usr/bin/btrfs`.

### BootPrep is responsible for

- Preparing an already-selected writable snapshot and its boot environment.
- Performing Snapshot Store Reconciliation when required.
- Regenerating GRUB configuration inside the selected snapshot.
- Refreshing the validated EFI GRUB loader while preserving the existing firmware boot entry and boot order.
- Leaving the selected snapshot ready for the next boot.

The orchestrator does not duplicate BootPrep's preparation engine.

---

## Relationship to the Snapper Plugin

BootPrep Version 2.0.0 provides two separate integration paths into the same preparation engine.

### Snapper rollback

```text
snapper rollback
        |
        v
99_bootprep
        |
        v
bootprep prepare
```

Snapper already performs the rollback and selects the resulting writable snapshot. The `99_bootprep` plugin only passes the result to BootPrep.

### Manual Btrfs activation

```text
bootprep-btrfs activate
        |
        v
Make selected snapshot writable
        |
        v
Set Btrfs default subvolume
        |
        v
bootprep prepare
```

Here, there is no Snapper rollback workflow performing those Btrfs activation steps, so `bootprep-btrfs` coordinates them before handing the result to BootPrep.

Both paths converge on:

```text
bootprep prepare <snapshot-number>
```

That common handoff keeps the preparation logic in one place.

---

## Failure Behavior

The activation workflow fails before modifying the selected snapshot if its basic inputs cannot be validated.

Examples include:

```text
[ERROR] Mount point does not exist: /mnt/nonsense
```

and:

```text
[ERROR] Snapshot directory does not exist: /.snapshots/5/snapshot
```

If a Btrfs command fails after validation, `set -e` stops the workflow immediately.

If `bootprep prepare` fails, the orchestrator does not hide or replace that failure. BootPrep's own output and exit status describe the preparation failure.

For commands outside the `activate` workflow, error handling belongs entirely to `/usr/bin/btrfs`.

---

## Installation and Upgrade

`bootprep-btrfs` is installed automatically by `bootprep-install.sh`.

Installed location:

```text
/usr/sbin/bootprep-btrfs
```

For an existing BootPrep installation, `bootprep-upgrade.sh` reinstalls and verifies the orchestrator together with the BootPrep engine and Snapper plugin.

No separate installation procedure is required.

---

## Future Workflows

The wrapper design provides a natural extension point for future BootPrep-aware Btrfs workflows.

Additional workflow arguments can be added without changing the behavior of ordinary Btrfs commands and without expanding the responsibility of the BootPrep preparation engine.

Any future workflow should follow the same rule:

> **Orchestrate Btrfs work here. Delegate boot preparation to BootPrep only when boot preparation is required.**

Commands that are not explicitly defined by BootPrep should continue to pass directly to `/usr/bin/btrfs`.

---

## Design Philosophy

`bootprep-btrfs` is intentionally simple.

It does not try to replace Btrfs, hide Btrfs, or reproduce the Btrfs command interface.

It adds only the orchestration BootPrep needs and otherwise gets out of the way.

That design keeps the command useful as a normal Btrfs entry point while providing a clean home for higher-level Btrfs workflows.

> **Btrfs performs the filesystem operations. `bootprep-btrfs` coordinates the workflow. BootPrep prepares the next boot.**

---

## Technical Summary

| Item | Value |
| --- | --- |
| Component | `bootprep-btrfs` |
| Type | Btrfs orchestrator |
| Implementation | Thin wrapper around `/usr/bin/btrfs` |
| Installed location | `/usr/sbin/bootprep-btrfs` |
| Version 2.0.0 workflow | `activate` |
| Activate interface | `bootprep-btrfs activate <snapshot-number> [mount-point]` |
| Default mount point | `/` |
| Native Btrfs commands | Passed directly to `/usr/bin/btrfs` |
| Final preparation | `bootprep prepare <snapshot-number>` |
| Root privileges | Required |

---

## See Also

- `README.md` — BootPrep overview, installation, and operation.
- `ARCHITECTURE.md` — BootPrep architecture and separation of responsibilities.
- `SNAPPER_PLUGIN.md` — Snapper rollback plugin documentation.
- `CHANGELOG.md` — Release history.
