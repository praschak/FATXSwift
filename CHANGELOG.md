# Changelog

## 1.0.0

- Offer unlock after detecting a locked device during a failed scan.
- Optionally save named HDD keys in the macOS Keychain and choose or delete them from Drive Security.
- Rewrite the README around the browser.

## 0.3.0-preview.5

- Remove EEPROM decryption and embedded retail keys. Enter the HDD key directly.

## 0.3.0-preview.4

- Integrate user-supplied ATA USB transport for status, password derivation, set, unlock and disable. Support HDD key and direct user/master passwords with high/maximum settings.
- Re-read device identity and security state before each command; reject unsafe states and incomplete transfers; no automatic retries. Password data is passed via private IPC and stdin.
- Core test coverage is provided; native GUI and real-drive operations remain unverified in this environment.

## 0.3.0-preview.3

- Integrate the supplied USB transport as an experimental read-only ATA security probe with disk-to-USB selection, whole-disk checks and unmounting. It only sends ATA IDENTIFY and cannot change passwords.
- The supplied transport was initially delivered without licensing information; its owner subsequently authorized integration.

## 0.3.0-preview.2

- Reconstructed formatter preview with reviewed retail and LBA48 F/F-G layouts, metadata undo journal, GUI and CLI formatting, and table-based partition detection.
- Drive-specific password derivation preparation.
- Preview requires macOS GUI compilation and physical-device validation.

## 0.2.5

- Move the toolbar and title to the window level and use a compact unified style to address the sidebar/titlebar background seam.
- Use neutral filesystem terminology throughout the app, CLI, and documentation.
- Rename fixed partition selectors to `fatx-x`, `fatx-y`, `fatx-z`, `fatx-c`, and `fatx-e`. Update saved commands that select these layouts; geometry is unchanged.
- Report the same 0.2.5 version from the app and CLI.
- Ignore local undo journals, completion markers, and Python caches when sharing the repository.

## 0.2.4

- Authorize raw-device access once per app session and reuse the privileged helper for subsequent requests.
- Add guided Full Disk Access setup and actual connected-device access checks.
- Preserve native window reopening and Finder drag/drop transfers.
