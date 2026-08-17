# Changelog

All notable changes to BootPrep will be documented in this file.

The project follows Semantic Versioning.

- Patch releases (x.y.Z) contain maintenance fixes and compatibility improvements.
- Minor releases (x.Y.z) introduce new functionality while maintaining compatibility.
- Major releases (X.y.z) may introduce incompatible changes.

---

## [2.0.0] - 2026-08-16

### Changed

- Replaced the patched `10_linux`, runtime-state, and manual EFI redirect architecture with direct preparation inside the selected writable snapshot.
- BootPrep now mounts and enters the selected snapshot, runs `grub-mkconfig -o /boot/grub/grub.cfg`, and refreshes the existing EFI loader while preserving the system's firmware boot entry and boot order.
- Snapshot discovery now derives the base root subvolume instead of requiring it to be named `@`, validates the selected snapshot directly, and mounts it by numeric Btrfs subvolume ID so discovery is independent of the running root's path-reporting context.
- EFI bootloader discovery now validates existing GRUB or shim loader directories, compares OS identities case-insensitively, preserves the existing bootloader ID spelling, and refuses ambiguous targets.
- The installer is now limited to fresh installations and redirects complete or partial existing installations to the upgrader.
- The upgrader now supports clean upgrades across supported distributions and migration from BootPrep 1.x.

### Removed

- Removed the BootPrep patch and diversion of `/etc/grub.d/10_linux` from the active architecture.
- Removed `BOOTPREP_BTRFS_SNAPSHOT_BOOTING` from `/etc/default/grub`.
- Removed `/usr/lib/bootprep/bootprep-runtime.sh`.
- Removed `/var/lib/bootprep/next-boot` and pending boot transaction state.
- Removed manual backup, retention, and rewriting of EFI-side `grub.cfg` files.

### Migration

- Version 1 installations are migrated through `bootprep-upgrade.sh`.
- The upgrader verifies and restores the diverted upstream `10_linux`, removes the diversion, archives the patched v1 script, removes the obsolete GRUB setting, and archives legacy runtime artifacts.
- All removed v1 files are preserved in a timestamped migration archive beneath `/var/lib/bootprep/backups`.
- The v1 migration path remains available for users upgrading directly from v1 to later releases.

### Compatibility

- Retained UEFI-only support with the EFI System Partition mounted at `/boot/efi`.
- Added support for distributions that embed the GRUB prefix in the EFI executable instead of using an EFI-side `grub.cfg`.
- Validated fresh installation, clean upgrades, migration from BootPrep 1.x to 2.0.0 on Debian, explicit snapshot activation, native Snapper rollback, and reboot testing on Debian, Kubuntu, and EndeavourOS.

### Safety

- Added writable snapshot verification.
- Added early Btrfs, UEFI, ESP, GRUB tool, platform-target, and bootloader-ID validation.
- GRUB installation deliberately uses `--no-nvram` to preserve existing firmware boot entries and boot order while refreshing the loader files on the EFI System Partition.
- Cleanup no longer removes temporary directories while mounts remain active.

---

## [1.1.0] - 2026-08-09

### Added

- Added `bootprep-btrfs`, a lightweight Btrfs orchestrator.
- Added `bootprep-btrfs activate <snapshot-number> [mount-point]` for activating an existing snapshot and preparing it for the next boot.
- The `activate` workflow makes the selected snapshot writable, sets it as the Btrfs default subvolume, and invokes `bootprep prepare <snapshot-number>` as the final preparation step.
- The optional mount point defaults to `/`.
- Commands not handled as BootPrep-specific workflows are passed directly to `/usr/bin/btrfs` without interpretation.

### Changed

- `bootprep-install.sh` now installs and verifies `bootprep-btrfs` alongside the BootPrep engine and Snapper plugin.
- `bootprep-upgrade.sh` now reinstalls and verifies `bootprep-btrfs` alongside the BootPrep engine and Snapper plugin.
- Manual Btrfs snapshot activation can now be performed through `bootprep-btrfs activate` instead of manually coordinating the individual Btrfs operations and BootPrep preparation step.

### Architecture

- Btrfs workflow orchestration is separated from the BootPrep preparation engine.
- `bootprep` remains responsible only for preparing an already-selected writable snapshot for the next boot.
- `bootprep-btrfs` handles Btrfs-specific workflows while delegating final boot preparation to `bootprep`.
- `99_bootprep` remains the minimal Snapper rollback bridge to the BootPrep preparation engine.

---

## [1.0.1] - 2026-08-06

### Added

- Automatic Snapshot Store Reconciliation.
- Automatic discovery of available root and home snapshot stores.
- Automatic creation of required `/.snapshots` and `/home/.snapshots`
  mount entries when corresponding snapshot stores exist.

### Changed

- BootPrep now derives snapshot store mount options from the running
  system rather than using fixed mount options.
- Runtime-only mount options are filtered before generating persistent
  `fstab` entries.
- Generated snapshot store entries now follow the same persistent
  mount style as the remainder of the system.
- The installer now performs the same Snapshot Store Reconciliation
  as the BootPrep preparation engine.

### Fixed

- Missing snapshot store mount entries are automatically created.
- Incorrect snapshot store mount entries are replaced with canonical
  entries.
- Duplicate active snapshot store mount entries are detected and
  safely rejected.
- Snapshot store discovery now correctly supports both standard
  root (`@`) and writable snapshot boot environments.
- Improved compatibility with systems installed before BootPrep by
  automatically preparing existing snapshots for successful boot.

---

## [1.0.0] - 2026-07-31

### Added

- Initial public release.
- Automatic preparation of writable Btrfs snapshots for boot.
- Snapper rollback integration through the `99_bootprep` plugin.
- Automatic GRUB integration for writable snapshot booting.
- BootPrep installer.
- BootPrep upgrade utility.
- Automatic EFI GRUB update after snapshot preparation.
