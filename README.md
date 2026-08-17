# BootPrep

> **Business as usual... until you need it.**

BootPrep is the activation layer for GRUB-based Linux systems using a nested Btrfs snapshot layout.

It prepares the boot environment so a selected writable Snapper snapshot can become the next bootable system while preserving the existing filesystem layout.

Rather than replacing Snapper, changing GRUB's normal behavior, or introducing another rollback framework, BootPrep integrates with the existing Btrfs, Snapper, GRUB, and UEFI infrastructure. Nothing changes until a writable snapshot is intentionally selected for activation or produced by a rollback.

## Background

BootPrep began as a personal effort to expand the native Btrfs and Snapper experience provided by Debian and Ubuntu. While the distributions already provide strong Btrfs, Snapper, and GRUB support, there remained a gap between snapshot management and reliably preparing the next boot on systems using a nested snapshot layout.

What started as a proof of concept evolved into BootPrep—a dedicated boot preparation layer that works alongside the tools already provided by the distribution instead of replacing them.

Version 2.0.0 replaces the original patched-GRUB architecture with a direct preparation transaction performed from inside the selected writable snapshot.

## Business as Usual

Installing BootPrep does not alter the active boot configuration.

After installation:

- The system continues to boot normally.
- Distribution-provided GRUB scripts remain unchanged.
- No GRUB defaults or runtime state are added.
- The existing filesystem workflow does not change.
- The Snapper plugin remains inactive unless Snapper invokes a rollback operation.

Nothing changes until a writable snapshot is intentionally prepared for the next boot.

Until then...

**It's simply business as usual.**

---

## Compatibility

BootPrep 2.0.0 is designed for systems with:

- A Btrfs root filesystem using a nested Snapper layout.
- Root snapshots stored beneath `<root-subvolume>/.snapshots/<number>/snapshot`.
- GRUB with `grub-mkconfig` and `grub-install` available inside the selected snapshot.
- UEFI boot with the EFI System Partition mounted at `/boot/efi`.
- An existing, unambiguous GRUB or shim EFI loader directory.

The root subvolume does not have to be named `@`. BootPrep derives the base root subvolume from the running system and normalizes it when the system is already booted from a writable snapshot.

BootPrep is compatible with Debian, Ubuntu, EndeavourOS, CachyOS, and many related derivatives that meet these requirements. Version 2.0.0 has been exercised directly on Debian, Kubuntu, and GRUB-based installations of EndeavourOS and CachyOS. Distribution packaging and Snapper integration still vary, so testing with a verified recovery path is recommended before deployment on another distribution.

Legacy BIOS boot is not supported in Version 2.0.0.

---

## Why BootPrep?

Many snapshot boot solutions expect users to adopt a snapshot-based workflow immediately. That often means restructuring subvolumes, changing normal boot behavior, or living inside an initial snapshot from day one.

BootPrep takes a different approach.

Installation and activation are separate.

You can install BootPrep and continue using the system exactly as you do today. Later, after Snapper is installed and configured, BootPrep's Snapper plugin can automatically prepare the next boot whenever Snapper performs a rollback.

Snapper continues to manage snapshots, Btrfs continues to manage subvolumes, and GRUB continues to manage boot configuration. BootPrep provides the missing preparation step between a selected writable snapshot and the next boot.

---

## Components

The repository contains five executable components:

| Component | Responsibility | Installed location |
| --- | --- | --- |
| `bootprep` | Boot preparation engine | `/usr/sbin/bootprep` |
| `bootprep-btrfs` | Btrfs orchestrator | `/usr/sbin/bootprep-btrfs` |
| `99_bootprep` | Snapper rollback plugin | `/usr/lib/snapper/plugins/99_bootprep` |
| `bootprep-install.sh` | Fresh-install utility | Run from the repository |
| `bootprep-upgrade.sh` | Existing-install upgrade and v1 migration utility | Run from the repository |

Version 2.0.0 does not install a GRUB runtime library, maintain next-boot state, patch `/etc/grub.d/10_linux`, or add a setting to `/etc/default/grub`.

## Fresh Installation

Keep all repository components together, then run:

```bash
chmod +x bootprep bootprep-btrfs bootprep-install.sh bootprep-upgrade.sh 99_bootprep
sudo ./bootprep-install.sh
```

The installer is intentionally limited to fresh installations. If any complete or partial BootPrep installation is detected, it stops and directs the user to `bootprep-upgrade.sh`.

For a fresh system, the installer:

- Verifies the Btrfs and UEFI environment.
- Verifies required GRUB utilities and source components.
- Discovers the active root and optional home subvolumes.
- Reconciles discovered snapshot-store entries in `/etc/fstab`.
- Installs and verifies the engine, Btrfs orchestrator, and Snapper plugin.

The installer does not regenerate GRUB or change the currently selected root.

## Upgrading

Existing installations must use:

```bash
sudo ./bootprep-upgrade.sh
```

For a clean v2 or later installation, the upgrader verifies the environment and runs the current installer through its controlled internal upgrade path. This path does not require Debian's `dpkg-divert` and is available across supported distributions.

When upgrading an existing Debian system from BootPrep 1.x, the upgrader first performs a complete migration and then installs BootPrep 2.0.0:

- Creates a timestamped recovery archive beneath `/var/lib/bootprep/backups`.
- Validates BootPrep's saved and diverted upstream `10_linux` files.
- Archives the patched v1 `10_linux`.
- Removes the BootPrep diversion and restores the upstream script.
- Verifies the restored script byte-for-byte against the diverted upstream copy.
- Backs up `/etc/default/grub` and removes `BOOTPREP_BTRFS_SNAPSHOT_BOOTING`.
- Archives and removes the obsolete runtime, state, and configuration files.
- Verifies that no active v1 integration remains.
- Installs and verifies Version 2.0.0.

We recommend keeping the migration archive until the upgraded system has successfully completed activation, rollback, and reboot.

---

## Operation

### Snapper rollback

When Snapper performs a rollback, `99_bootprep` receives the resulting writable snapshot number and invokes:

```text
/usr/sbin/bootprep prepare <snapshot-number>
```

### Btrfs activation

`bootprep-btrfs` provides a manual activation workflow:

```bash
sudo bootprep-btrfs activate <snapshot-number> [mount-point]
```

The mount point defaults to `/`. The workflow makes the selected snapshot writable, sets it as the Btrfs default subvolume, and delegates final boot preparation to BootPrep.

All commands other than `activate` are passed directly to `/usr/bin/btrfs`.

### Manual preparation

The engine can be invoked directly after another workflow has selected a writable snapshot and set the appropriate Btrfs default subvolume:

```bash
sudo bootprep prepare <snapshot-number>
```

BootPrep does not create the snapshot, perform the rollback, or set the default subvolume. Those responsibilities remain with Snapper, Btrfs, or the invoking workflow.

## Boot Preparation

For a selected writable snapshot, BootPrep:

1. Discovers and validates the exact nested snapshot subvolume.
2. Mounts the snapshot and verifies that it is writable.
3. Reconciles required snapshot-store mounts in the snapshot's `fstab`.
4. Makes `/dev`, `/proc`, `/sys`, `/run`, `/boot`, and `/boot/efi` available as required inside the snapshot.
5. Discovers and validates the existing EFI bootloader ID and GRUB platform target.
6. Runs `grub-mkconfig -o /boot/grub/grub.cfg` inside the snapshot.
7. Refreshes GRUB's EFI loader inside the snapshot using the validated target, EFI directory, and bootloader ID while preserving the existing firmware boot entry and boot order.
8. Cleans up temporary mounts and files.

The EFI installation may take several seconds. This is normal: GRUB is refreshing the loader so its prefix resolves into the selected snapshot. Debian commonly represents that prefix in an EFI-side `grub.cfg`; other distributions may embed it directly in the EFI executable.

## Snapshot Store Reconciliation

BootPrep discovers available root and home snapshot stores and reconciles the corresponding `fstab` entries in the system being prepared.

The policy is intentionally conservative:

- Correct entries are preserved.
- Missing entries are created.
- Incorrect entries are replaced with canonical entries.
- Duplicate active entries cause a safe abort.
- Stores that do not exist are not added.

BootPrep derives persistent mount options from the running root filesystem while filtering runtime-only subvolume and state options. Before changing `fstab`, it creates a timestamped backup beneath `/var/lib/bootprep/backups`.

---

## Safety Model

BootPrep treats boot preparation as a transaction and stops on failed validation or failed commands.

Important safeguards include:

- Root and UEFI validation before changes.
- Exact snapshot-subvolume discovery.
- Writable snapshot verification.
- Refusal to guess between ambiguous EFI loader directories.
- Existing UEFI firmware boot entries and boot order are preserved.
- Duplicate `fstab` entry detection.
- Verified `fstab` backups and replacement.
- Cleanup traps for temporary mounts.
- Verified v1 migration archives and GRUB restoration.

BootPrep should still be tested with a known recovery path. Snapshot activation and bootloader preparation are inherently privileged operations.

BootPrep assumes the system's existing UEFI boot configuration is working. Repairing missing or damaged firmware boot entries is outside its scope and should be handled separately with standard GRUB recovery tools.

## Verifying an Activation or Rollback

After reboot:

```bash
findmnt /
sudo snapper ls
```

`findmnt /` should identify the expected nested snapshot, and Snapper should mark the corresponding snapshot with `*`.

On Debian-style EFI layouts, the redirect can also be inspected with:

```bash
cat /boot/efi/EFI/debian/grub.cfg
```

An EFI-side `grub.cfg` is distribution-specific and may not exist. Its absence is not a failure when the system boots successfully and the EFI prefix is embedded in the GRUB executable.

---

## Project Goals

BootPrep is guided by a few simple principles:

- Keep the code simple.
- Keep responsibilities clearly separated.
- Preserve distribution-provided GRUB scripts.
- Integrate with existing tools instead of replacing them.
- Support nested Btrfs snapshot layouts without requiring filesystem redesign.
- Fail safely rather than guessing about boot-critical state.
- Make snapshot activation and rollback reliable without changing ordinary system use.

---

## Version 2.0.0

Version 2.0.0 replaces the v1 runtime-state and patched-`10_linux` design with direct GRUB preparation inside the selected writable snapshot.

The new architecture:

- Preserves upstream GRUB scripts.
- Eliminates persistent BootPrep boot state.
- Eliminates manual EFI redirect editing.
- Uses the distribution's own `grub-mkconfig` and `grub-install` tools.
- Supports both Debian's EFI redirect file and distributions that embed the GRUB prefix in the EFI executable.
- Provides a verified, recoverable migration from Version 1.

Across Debian, Kubuntu, and GRUB-based installations of EndeavourOS and CachyOS, Version 2.0.0 has been tested through fresh installation, v1 migration where applicable, clean upgrade, explicit activation, native Snapper rollback, and reboot.

---

## Companion Utilities

BootPrep is the flagship project in a collection of companion utilities designed to enhance native Btrfs, Snapper, and GRUB workflows.

Compatibility statements in this README apply only to BootPrep. Companion utilities are separate projects with their own platform requirements and test coverage.

Current companion projects include:

- **cleanup-bootstrap-root** – Safely cleans the original bootstrap root while preserving its Btrfs subvolumes.
- **snapshot-chroot** – Creates a recovery chroot from the last successfully booted or manually selected Btrfs/Snapper snapshot.
- **dpkg-pre-post-snapper** – Creates descriptive Snapper pre/post snapshots around package transactions.
- **add_subvolumes** – Converts selected root and home directories into independent Btrfs subvolumes.
- **add_updategrub-service** – Installs a systemd service that runs `update-grub` during shutdown and reboot.

## Acknowledgements

BootPrep began as a personal effort to expand the native Btrfs and Snapper experience provided by Debian and Ubuntu while preserving the distributions' default filesystem layout.

The original proof of concept was inspired by two community articles:

- **Reliable Btrfs snapshots with Snapper on Debian and Ubuntu** by Hossein Moslehi
- **Install Fedora with Snapshot and Rollback Support** by Madhu Desai

The Debian article inspired the original patched-`10_linux` proof of concept. The Fedora article demonstrated shell scripting and installation techniques that influenced the early implementation. Version 2.0.0 moves beyond that original architecture while preserving the project's core purpose and separation of responsibilities.

## License

BootPrep is licensed under the **GNU General Public License v3.0 or later** (`GPL-3.0-or-later`).

See [LICENSE](LICENSE) for the complete license text.
