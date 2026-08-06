# Changelog

All notable changes to BootPrep will be documented in this file.

The project follows Semantic Versioning.

- Patch releases (x.y.Z) contain maintenance fixes and compatibility improvements.
- Minor releases (x.Y.z) introduce new functionality while maintaining compatibility.
- Major releases (X.y.z) may introduce incompatible changes.

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
