# BootPrep Snapper Plugin

## Overview

`99_bootprep` is the Snapper rollback plugin for BootPrep.

Its responsibility is intentionally small: when Snapper performs a
rollback, the plugin receives the resulting writable snapshot number and
passes it to the BootPrep preparation engine.

``` text
Snapper rollback
        |
        v
99_bootprep
        |
        v
bootprep prepare <snapshot-number>
```

Snapper remains responsible for the rollback. BootPrep remains
responsible for preparing the resulting writable snapshot for the next
boot.

------------------------------------------------------------------------

## Why the Plugin Exists

Snapper already knows how to create snapshots and perform rollbacks.
BootPrep already knows how to prepare an already-selected writable
snapshot and its boot environment.

The missing piece is the connection between them.

`99_bootprep` provides that connection without duplicating either tool's
responsibility. It allows a normal Snapper rollback to hand its result
directly to the same `bootprep prepare` engine used by other
BootPrep-aware workflows.

------------------------------------------------------------------------

## How It Works

The plugin is installed at:

``` text
/usr/lib/snapper/plugins/99_bootprep
```

When Snapper invokes the plugin, `99_bootprep` first examines the
operation supplied in its first argument.

Only operations beginning with:

``` text
rollback
```

are handled. All other Snapper operations exit successfully without
invoking BootPrep.

For a rollback callback, the plugin verifies that:

``` text
/usr/sbin/bootprep
```

is installed and executable.

It then reads the resulting snapshot number from Snapper's fifth plugin
argument:

``` bash
SNAPSHOT="${5:-}"
```

If no snapshot number is supplied, the plugin exits with an error rather
than invoking BootPrep with incomplete data.

Once validated, the plugin hands control directly to the BootPrep
engine:

``` bash
exec /usr/sbin/bootprep prepare "$SNAPSHOT"
```

The use of `exec` is intentional. The plugin does not remain as an
unnecessary intermediate process after its job is complete; BootPrep
replaces it and becomes responsible for the remainder of the preparation
transaction.

------------------------------------------------------------------------

## Rollback Workflow

The complete integration is:

``` text
User initiates a Snapper rollback
        |
        v
Snapper performs the rollback
        |
        v
Snapper creates/selects the writable rollback result
        |
        v
Snapper invokes 99_bootprep
        |
        v
99_bootprep recognizes the rollback callback
        |
        v
99_bootprep reads the resulting snapshot number
        |
        v
bootprep prepare <snapshot-number>
        |
        v
BootPrep prepares the next boot
```

The important distinction is that BootPrep receives the **resulting
writable snapshot number supplied by Snapper**. The snapshot originally
selected for rollback and the writable snapshot produced by that
rollback are not necessarily the same snapshot.

The plugin does not attempt to infer this relationship. Snapper already
knows the result of its own rollback operation, so the plugin simply
passes that result to BootPrep.

------------------------------------------------------------------------

## Separation of Responsibilities

The plugin follows BootPrep's single-responsibility design.

**Snapper is responsible for:**

-   Snapshot management.
-   Performing the rollback.
-   Creating/selecting the writable rollback result.
-   Setting the appropriate Btrfs default subvolume.
-   Supplying the resulting snapshot number through the plugin callback.

**`99_bootprep` is responsible for:**

-   Recognizing Snapper rollback callbacks.
-   Ignoring unrelated Snapper operations.
-   Verifying that BootPrep is available.
-   Validating that a resulting snapshot number was supplied.
-   Passing that snapshot number to `bootprep prepare`.

**BootPrep is responsible for:**

-   Preparing the already-selected writable snapshot and its boot
    environment.
-   Performing the BootPrep preparation transaction.
-   Leaving the selected snapshot ready for the next boot.

The plugin does not create snapshots, perform rollbacks, manage Btrfs
subvolumes, regenerate GRUB itself, or reproduce any part of the
BootPrep preparation engine.

------------------------------------------------------------------------

## Failure Behavior

`99_bootprep` deliberately performs only the validation required for its
own responsibility.

If the callback is not a rollback operation, the plugin exits
successfully and does nothing.

If BootPrep is not installed or is not executable, the plugin reports:

``` text
snapper-bootprep: BootPrep not found: /usr/sbin/bootprep
```

If Snapper does not supply a resulting snapshot number, the plugin
reports:

``` text
snapper-bootprep: No snapshot number supplied.
```

Otherwise, the plugin announces the snapshot being prepared and
transfers control to BootPrep.

Any failure after that point belongs to the BootPrep preparation
transaction and is reported by the BootPrep engine itself.

------------------------------------------------------------------------

## Installation and Upgrade

`99_bootprep` is installed automatically by `bootprep-install.sh` as
part of a normal BootPrep installation.

Installed location:

``` text
/usr/lib/snapper/plugins/99_bootprep
```

For an existing BootPrep installation, `bootprep-upgrade.sh` reinstalls
and verifies the Snapper plugin together with the BootPrep engine and
Btrfs orchestrator.

No separate plugin installation procedure is required.

------------------------------------------------------------------------

## Relationship to `bootprep-btrfs`

BootPrep 2.x provides two distinct paths into the same preparation
engine.

Snapper rollback:

``` text
snapper rollback
        |
        v
99_bootprep
        |
        v
bootprep prepare
```

Manual Btrfs activation:

``` text
bootprep-btrfs activate
        |
        v
Btrfs activation workflow
        |
        v
bootprep prepare
```

`99_bootprep` bridges Snapper's rollback workflow to BootPrep.

`bootprep-btrfs` orchestrates BootPrep-aware Btrfs workflows.

Both ultimately delegate final boot preparation to the same
`bootprep prepare` engine rather than duplicating its functionality.

------------------------------------------------------------------------

## Design Philosophy

`99_bootprep` is intentionally small.

It does not need to understand the BootPrep preparation transaction,
discover the Btrfs layout, or reproduce Snapper's rollback logic.
Snapper has already performed the rollback, and BootPrep already knows
how to prepare its result.

The plugin only connects them.

> **Snapper performs the rollback. The plugin passes the result.
> BootPrep prepares the next boot.**

That narrow boundary keeps the integration simple and allows the
BootPrep engine, Snapper integration, and other BootPrep-aware workflows
to evolve independently while continuing to share the same preparation
interface.

------------------------------------------------------------------------

## Technical Summary

  Item                             Value
  -------------------------------- ----------------------------------------
  Component                        `99_bootprep`
  Type                             Snapper rollback plugin
  Installed location               `/usr/lib/snapper/plugins/99_bootprep`
  Recognized operation             `rollback*`
  Snapshot argument                Snapper plugin argument `${5}`
  BootPrep interface               `bootprep prepare <snapshot-number>`
  Non-rollback operations          Ignored
  Snapshot creation and rollback   Snapper
  Boot preparation                 BootPrep

------------------------------------------------------------------------

## See Also

-   `README.md` --- BootPrep overview, installation, and operation.
-   `ARCHITECTURE.md` --- BootPrep architecture and separation of
    responsibilities.
-   `BOOTPREP_BTRFS.md` --- Btrfs orchestrator documentation.
-   `CHANGELOG.md` --- Release history.
