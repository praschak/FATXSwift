# Validation record — 0.2.5

Date: 2026-10-29. Automated platform: Swift 6.0.3 on x86_64 Linux.

## Release changes

- Move navigation title and toolbar ownership from the detail column to the window-level split view, keep the toolbar background visible, and select the compact unified window style. This addresses the background seam beside the sidebar without fixed pixel offsets.
- Use filesystem terminology throughout application strings, CLI output, source, and documentation.
- Rename fixed FATX partition selectors to `fatx-x`, `fatx-y`, `fatx-z`, `fatx-c`, and `fatx-e`. Preserve their offsets and lengths. Existing CLI scripts must use the new selectors.
- Align the CLI and app versions at 0.2.5. Retain session authorization, Full Disk Access guidance, window reopening, and transfer behavior.

## Automated checks

- Debug and release builds of the core, service/client, CLI and bridge passed.
- XCTest: **29 passed, 1 skipped, 0 failures** (30 registered).
- The new partition test checks all five selectors against literal expected geometry and scans a sparse image for the new label.
- Live helper tests cover startup, repeated requests through one launch, explicit shutdown, invalid authentication, parent-process exit, and startup failure without automatic reauthorization.
- File transport tests cover permissions, symlink/hardlink rejection, size limits, atomic publication, and symlink target protection.
- The cross-user ownership test is skipped because this Linux user namespace maps only UID 0. It cannot change ownership to the second UID used by that test. Production ownership checks remain enabled.
- **92 CLI integration checks passed** across FATX/XTAF and FAT16/FAT32.
- **14 browser JSON-bridge checks passed**, including recursive transfer byte comparisons.
- UI Swift syntax parsing and shell-script syntax validation passed. Source and documentation were checked for consistent filesystem terminology.

Core and transfer tests also cover fragmented chains, FAT boundaries, directory growth, recursive operations, conflicts, merge/replace, rollback, journal integrity, torn tails, stale recovery rejection, pending-write guards, and normal-user client staging/export.

An environment-only preload shim corrects a process/thread namespace mismatch when Swift reads `/proc/PID/stat` on the automated host. The shim is not part of this project and is not needed on macOS. Final logs are retained in `validation/`; local absolute workspace prefixes are removed from those logs.

## Manual macOS evidence and remaining checks

The CLI has been manually exercised on a 261,095,424-byte FATX memory unit with 4096-byte filesystem sectors, including read, check, directory creation, listing, and removal. The 0.2.4 app and device workflow were subsequently reported working on macOS.

The 0.2.5 toolbar appearance still requires visual confirmation on macOS. The Linux environment cannot compile AppKit/SwiftUI against the Apple SDK or render native window chrome. Broader device, long-session, power-interruption, USB-failure, and extended-layout coverage remains limited.

Run `./scripts/verify.sh` on macOS for local automated checks and app compilation. Quit the old running app before opening a new build. Rebuilding an ad-hoc-signed app may require removing and re-adding its Full Disk Access entry.
