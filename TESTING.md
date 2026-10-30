# Testing

## 1.0.0

- Linux Swift 6.0.3: 52 XCTest cases, zero failures and one skipped because a second UID is unavailable. A local test-host-only preload shim was used for a PID namespace mismatch; the shim is not part of the source package.
- macOS-only SwiftUI, Keychain and USB-helper source was syntax-parsed in this environment; it was not type-checked or built against an Apple SDK here.
- The user reported that 0.3.0-preview.5 could inspect an Intenso SATA SSD via an ASM1153 USB adapter and set ATA security, after which the drive reported password enabled and maximum security. This confirms that observed operation only; it does not verify the console-specific derived password, boot compatibility, or other adapters.
- The user reported successfully testing version 1.0.0 on their Mac, including the locked-drive and saved-key workflow. This environment did not independently repeat that test; compatibility with other adapters and drives remains limited.
- Formatting and write tests use disposable images. Preserve the original drive and backups when testing hardware.

Run `./scripts/verify.sh` on macOS to build the app and run automated tests and integration checks. A physical test should include locking, power cycling, detecting the lock, unlocking with a manually entered key and a saved key, reopening the volume, deleting the saved key, and verifying the result on the intended system. Do not share HDD keys or ATA passwords in logs or screenshots.
