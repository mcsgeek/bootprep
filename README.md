# BootPrep

> **Business as usual... until you need it.**

BootPrep is the activation layer for systems using a default nested Btrfs subvolume layout, such as Debian, Ubuntu, and many of their derivatives.

It prepares the boot environment so a selected writable Snapper snapshot can become the next bootable system while preserving the existing filesystem layout.

Rather than replacing Snapper, changing GRUB's normal boot behavior, or introducing another rollback framework, BootPrep integrates with the existing Btrfs, Snapper, and GRUB infrastructure. It remains dormant until a writable snapshot is intentionally presented for the next boot.

## Background

BootPrep began as a personal effort to expand the native Btrfs and Snapper experience provided by Debian and Ubuntu. While the distributions already provide excellent support for Btrfs, Snapper, and GRUB, there remained a gap between snapshot management and reliably preparing the next boot on systems using the default nested Btrfs layout.

What started as a proof of concept evolved into BootPrep—a dedicated boot preparation layer that works alongside the tools already provided by the distribution instead of replacing them.

## Business as Usual

Installing BootPrep is designed not to change normal system behavior.

After installation:

- The system continues to boot normally.
- GRUB continues to generate and use its normal configuration.
- The existing workflow does not change.
- Snapper does not need to be installed until rollback integration is required.

The installer places the Snapper plugin in its expected location, but the plugin remains inactive when Snapper is not present and ignores non-rollback operations.

Nothing changes until a writable snapshot is intentionally prepared for the next boot.

Until then...

**It's simply business as usual.**

---

## Compatibility

BootPrep is currently designed for systems with:

- Debian, Ubuntu, or a compatible derivative.
- A Debian-style GRUB installation using `/etc/grub.d/10_linux` and `update-grub`.
- UEFI boot with the EFI System Partition mounted at `/boot/efi`.
- A Btrfs root filesystem using the default nested subvolume layout.
- Root snapshots stored beneath `@/.snapshots/<number>/snapshot`.

Systems manually restructured to use a flat or other custom Btrfs subvolume layout are not currently supported.

Legacy BIOS boot is not currently supported.

BootPrep is designed to integrate with the filesystem layout created by the operating-system installer rather than requiring users to redesign it.

---

## Why BootPrep?

Many snapshot boot solutions expect users to adopt a snapshot-based workflow immediately. That often means restructuring subvolumes, changing normal boot behavior, or living inside an initial snapshot from day one.

BootPrep takes a different approach.

Installation and activation are separate.

You can install BootPrep and continue using the system exactly as you do today. Later, after Snapper is installed and configured, BootPrep's Snapper plugin can automatically prepare the next boot whenever Snapper performs a rollback.

BootPrep was created to complement—not replace—the tools already provided by Debian and Ubuntu. Snapper continues to manage snapshots, Btrfs continues to manage subvolumes, and GRUB continues to manage boot configuration. BootPrep simply provides the missing integration between them.

Nothing redirects the next boot until **you** initiate a rollback or intentionally prepare a selected snapshot.

---

## Current Components

The repository currently contains four executable components:

| Component | Responsibility | Installed location |
| --- | --- | --- |
| `bootprep` | Boot preparation engine | `/usr/sbin/bootprep` |
| `99_bootprep` | Snapper rollback plugin | `/usr/lib/snapper/plugins/99_bootprep` |
| `bootprep-install.sh` | Installer and GRUB integration | Run from the repository; not installed as a command |
| `bootprep-upgrade.sh` | Reinstalls and verifies the BootPrep engine and Snapper plugin on an existing installation | Run from the repository; not installed as a command |

The installer also generates:

- `/usr/lib/bootprep/bootprep-runtime.sh`
- BootPrep state and backups beneath `/var/lib/bootprep`

## Installation

> **Warning:** The installer diverts and patches `/etc/grub.d/10_linux`, updates `/etc/default/grub`, and regenerates the GRUB configuration. Test BootPrep first in an environment with a verified recovery path before deploying it on a daily-use system.

> **Important:** Installing BootPrep does not immediately change how the system boots. However, after the first rollback has been prepared and the system begins operating from a writable snapshot, BootPrep’s GRUB integration becomes part of the boot architecture. BootPrep should not be removed from such a system. Returning to the original root-subvolume model would require a deliberate filesystem and bootloader migration, not a normal uninstall.

Keep `bootprep`, `bootprep-install.sh`, and `99_bootprep` together in the repository root, then run:

```bash
chmod +x bootprep bootprep-install.sh 99_bootprep
sudo ./bootprep-install.sh
```

The installer validates the expected Debian-style GRUB layout before applying its integration.

## Upgrading

Keep `bootprep`, `99_bootprep`, and `bootprep-upgrade.sh` together in the repository root, then run:

```bash
chmod +x bootprep 99_bootprep bootprep-upgrade.sh
sudo ./bootprep-upgrade.sh
```

The upgrade script requires an existing BootPrep installation. It reinstalls and verifies only:

- `/usr/sbin/bootprep`
- `/usr/lib/snapper/plugins/99_bootprep`

It does not modify the GRUB integration, generated runtime, configuration, state, or backups. New installations must use `bootprep-install.sh`.

---

## Operation

### Snapper rollback

When Snapper performs a rollback operation, the `99_bootprep` plugin receives the selected snapshot number and invokes:

```text
/usr/sbin/bootprep prepare <snapshot-number>
```

### Manual preparation

The BootPrep engine can also be invoked directly after another tool has created or selected the writable snapshot and configured the appropriate Btrfs default subvolume:

```bash
sudo bootprep prepare <snapshot-number>
```

BootPrep prepares the selected snapshot for the next boot. It does **not** create the snapshot, perform the rollback, or manage Btrfs subvolumes. Those responsibilities remain with the tools designed for those tasks.

---

## Project Goals

BootPrep is guided by a few simple principles:

- Keep the code simple.
- Keep responsibilities clearly separated.
- Preserve Debian's normal boot process.
- Integrate with existing tools instead of replacing them.
- Minimize changes to upstream GRUB.
- Support the default nested Btrfs layouts used by Debian, Ubuntu, and their derivatives.
- Build upon the distributions' default filesystem layout instead of requiring users to redesign it.
- Make snapshot booting reliable without changing how users normally interact with their systems.

---

## Version 1.0

BootPrep Version 1.0 has been extensively tested across multiple Debian, Ubuntu, and derivative systems using different supported configurations.

Final development cleanup is complete. The project is currently completing release documentation.

Future development will expand BootPrep beyond rollback preparation while maintaining the same philosophy of integrating with existing system components rather than replacing them.

Packaging, broader distribution support, and additional automation may follow after the initial release.

---

## Companion Utilities

BootPrep is the flagship project in a growing collection of companion utilities designed to enhance the native Btrfs, Snapper, and GRUB experience on Debian, Ubuntu, and their derivatives.

Each utility has a single responsibility and can be used independently or together to enhance the native Btrfs, Snapper, and GRUB experience on Debian, Ubuntu, and their derivatives.

Current companion projects include:

- **cleanup-bootstrap-root** – Safely cleans the original bootstrap `@` root while preserving its Btrfs subvolumes.
- **dpkg-pre-post-snapper** – Creates descriptive Snapper pre/post snapshots around package transactions.
- **add_subvolumes** – Converts selected root and home directories into independent Btrfs subvolumes.
- **add_updategrub-service** – Installs a systemd service that runs `update-grub` during shutdown and reboot.

---

## Acknowledgements

BootPrep began as a personal effort to expand the native Btrfs and Snapper experience provided by Debian and Ubuntu while preserving the distributions' default filesystem layout.

The original proof of concept was inspired by two outstanding community articles:

- **Reliable Btrfs snapshots with Snapper on Debian and Ubuntu** by Hossein Moslehi
- **Install Fedora with Snapshot and Rollback Support** by Madhu Desai

The Debian article inspired the original proof of concept using a patched `10_linux` script and a custom `99_efi` plugin. The Fedora article demonstrated shell scripting techniques and installation methods that influenced the early implementation, even though Fedora's Btrfs implementation differs significantly from Debian and Ubuntu.

As development continued, those early experiments evolved into BootPrep—a dedicated boot preparation layer—and a collection of companion utilities that extend the native Btrfs, Snapper, and GRUB experience without replacing the tools already provided by the distribution.

I'd like to thank both authors for sharing their knowledge and helping inspire what has become BootPrep.

---

## License

BootPrep is licensed under the **GNU General Public License v3.0 or later** (`GPL-3.0-or-later`).

See [LICENSE](LICENSE) for the complete license text.
