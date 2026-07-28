# BootPrep

> **Business as usual... until you need it.**

BootPrep is a lightweight boot preparation layer for **Debian, Ubuntu, and their derivatives** using Snapper with the **default nested Btrfs subvolume layout**.

Rather than replacing Snapper, changing GRUB's normal boot behavior, or introducing another rollback framework, BootPrep integrates with the existing boot process and remains dormant until a writable rollback snapshot is intentionally prepared for the next boot.

Install BootPrep on a test system today.

Continue using the system exactly as usual.

Install and configure Snapper whenever you are ready.

When a rollback snapshot is needed, BootPrep is already present to prepare the next boot.

---

## Project Status

**Early Development (0.1.0-dev)**

BootPrep is under active development and is **not intended for production use**.

Development and testing should currently be limited to disposable virtual machines or systems with a verified recovery path.

The current focus is validating the complete boot preparation transaction and its integration with Snapper, Btrfs, GRUB, and UEFI systems.

---

## Mission

Snapper already provides snapshot management, rollback, cleanup, and snapshot lifecycle management.

Btrfs already provides subvolume management.

GRUB already provides boot management.

BootPrep intentionally does **not** duplicate or replace any of these components.

Instead, BootPrep prepares the writable rollback snapshot selected by Snapper or another tool so the next reboot enters that snapshot while preserving Debian's normal boot process.

---

## Design Philosophy

BootPrep follows one simple principle:

- Let **Snapper** manage snapshots and perform rollbacks.
- Let **Btrfs** manage subvolumes and the default subvolume.
- Let **GRUB** manage boot configuration.
- Let **BootPrep** prepare the next boot.

Each component performs the task it already does well.

BootPrep provides the missing integration between them.

For the detailed component boundaries and transaction flow, see [ARCHITECTURE.md](ARCHITECTURE.md).

---

## Business as Usual

Installing BootPrep is designed not to change normal system behavior.

After installation:

- The system continues to boot normally.
- GRUB continues to generate and use its normal configuration.
- The existing workflow does not change.
- Snapper does not need to be installed until rollback integration is required.

The installer places the Snapper plugin in its expected location, but the plugin remains inactive when Snapper is not present and ignores non-rollback operations.

BootPrep does not redirect the next boot until a rollback snapshot is explicitly prepared.

Until then...

**It's simply business as usual.**

---

## Compatibility

BootPrep is currently designed for systems with:

- Debian, Ubuntu, or a compatible derivative.
- A Debian-style GRUB installation using `/etc/grub.d/10_linux` and `update-grub`.
- UEFI boot with the EFI System Partition mounted at `/boot/efi`.
- A Btrfs root filesystem using the default nested snapshot layout.
- Root snapshots stored beneath `@/.snapshots/<number>/snapshot`.

Systems manually restructured to use a flat or another custom Btrfs subvolume layout are not currently supported.

Legacy BIOS boot is not currently supported by the implementation.

Let the operating-system installer create the initial Btrfs layout. BootPrep is designed to integrate with that layout rather than requiring users to redesign it.

---

## Why BootPrep?

Many snapshot boot solutions expect users to adopt a snapshot-based boot model immediately.

That often means restructuring subvolumes, changing normal boot behavior, or living inside an initial snapshot from the beginning.

BootPrep takes a different approach.

Installation and activation are separate.

You can install BootPrep and continue using the system normally. Later, after Snapper is installed and configured, BootPrep's Snapper plugin can prepare a rollback snapshot automatically when Snapper performs a rollback.

Nothing redirects the next boot until **you** initiate the rollback or manually prepare a selected snapshot.

---

## Current Components

The repository currently contains three executable components:

| Component | Responsibility | Installed location |
| --- | --- | --- |
| `bootprep` | Boot preparation engine | `/usr/sbin/bootprep` |
| `99_bootprep` | Snapper rollback plugin | `/usr/lib/snapper/plugins/99_bootprep` |
| `bootprep-install.sh` | Installer and GRUB integration | Run from the repository; not installed as a command |

The installer also generates:

- `/usr/lib/bootprep/bootprep-runtime.sh`
- BootPrep state and backups beneath `/var/lib/bootprep`

---

## Installation

> **Warning:** The installer is still under development. It diverts and patches `/etc/grub.d/10_linux`, updates `/etc/default/grub`, and regenerates the GRUB configuration. Use it only in a test environment with a verified recovery path.

Keep `bootprep`, `bootprep-install.sh`, and `99_bootprep` together in the repository root, then run:

```bash
chmod +x bootprep bootprep-install.sh 99_bootprep
sudo ./bootprep-install.sh
```

The installer validates the expected Debian-style GRUB layout before applying its integration.

An automated uninstaller is not yet included.

---

## Operation

### Snapper rollback

When Snapper runs a rollback operation, `99_bootprep` receives the selected snapshot number and invokes:

```text
/usr/sbin/bootprep prepare <snapshot-number>
```

### Manual preparation

The engine can also be invoked directly after an external tool has created or selected the writable snapshot and set the appropriate Btrfs default subvolume:

```bash
sudo bootprep prepare <snapshot-number>
```

BootPrep prepares the selected snapshot for the next boot. It does not create the snapshot, select it for you, or perform the Btrfs rollback itself.

---

## Project Goals

- Keep the code simple.
- Keep responsibilities clearly separated.
- Preserve Debian's normal boot process.
- Integrate with existing tools instead of replacing them.
- Minimize changes to upstream GRUB.
- Support the default nested Btrfs layouts used by Debian, Ubuntu, and their derivatives.
- Make snapshot booting work without requiring users to redesign their filesystem.

---

## Current Development

Current development is focused on validating the BootPrep engine, the `99_bootprep` Snapper rollback plugin, the installer, EFI handling, transaction state, cleanup, and failure recovery.

Packaging, broader distribution support, and additional automation will follow after the core transaction is proven reliable.

---

## License

BootPrep is licensed under the **GNU General Public License v3.0 or later** (`GPL-3.0-or-later`).

See [LICENSE](LICENSE) for the complete license text.
