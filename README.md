# BootPrep

> **Business as usual... until you need it.**

BootPrep is a lightweight boot preparation layer for **Debian, Ubuntu, and their derivatives** using Snapper with the **default nested Btrfs subvolume layout**.

Rather than replacing Snapper, modifying GRUB's normal behavior, or introducing another rollback framework, BootPrep quietly integrates with the existing boot process and remains completely dormant until you intentionally prepare a writable rollback snapshot for the next boot.

Install BootPrep today.

Continue using your system exactly as you always have.

Install and configure Snapper whenever you're ready.

When the day comes that you need to boot a rollback snapshot, BootPrep is already there.

---

# Project Status

**Early Development (0.1.0-dev)**

BootPrep is currently under active development and is **not yet intended for production use**.

The current focus is validating the core architecture before expanding functionality.

---

# Mission

Snapper already provides excellent snapshot management, rollback, cleanup, and snapshot lifecycle management.

Btrfs already provides excellent subvolume management.

GRUB already provides reliable boot management.

BootPrep intentionally does **not** duplicate or replace any of these components.

Instead, BootPrep prepares the writable rollback snapshot created by Snapper so the next reboot boots into the selected snapshot while preserving Debian's normal boot process.

---

# Design Philosophy

BootPrep follows one simple principle:

* Let **Snapper** manage snapshots.
* Let **Btrfs** manage subvolumes.
* Let **GRUB** manage boot.
* Let **BootPrep** prepare the next boot.

Each component performs the task it already does well.

BootPrep simply provides the missing integration between them.

---

# Business as Usual

Installing BootPrep should **not** change how your system behaves.

After installation:

* Your system continues to boot normally.
* GRUB continues to function normally.
* Your existing workflow does not change.
* Snapper does not even need to be installed yet.

BootPrep remains dormant until you intentionally prepare a rollback snapshot for the next reboot.

Until then...

**It's simply business as usual.**

---

# Compatibility

BootPrep is designed for systems using the **default nested Btrfs subvolume layout** commonly found on Debian, Ubuntu, and many of their derivatives.

Systems that have been manually restructured to use a flat or other custom Btrfs subvolume layout are **not currently supported**.

Let the operating system installer create the initial Btrfs subvolume layout. BootPrep is designed to integrate with that layout rather than requiring users to redesign it.

---

# Why BootPrep?

Many snapshot boot solutions expect users to adopt a snapshot-based boot model immediately.

That often means restructuring subvolumes, changing boot behavior, or living inside an initial snapshot from the beginning.

BootPrep takes a different approach.

Installation and activation are completely separate.

You can install BootPrep today and continue using your system exactly as before. Weeks or months later, you can install Snapper, create your first rollback snapshot, and BootPrep is already present inside every snapshot created from that point forward.

Nothing changes until **you** decide to use it.

---

# Project Goals

* Keep the code simple.
* Keep responsibilities clearly separated.
* Preserve Debian's normal boot process.
* Integrate with existing tools instead of replacing them.
* Minimize changes to upstream GRUB.
* Support the default nested Btrfs layouts used by Debian, Ubuntu, and their derivatives.
* Make snapshot booting work without requiring users to redesign their filesystem.

---

# Current Development

Current development is focused on completing and validating the core boot preparation engine before implementing the Snapper `rollback-post` plugin and additional automation.
