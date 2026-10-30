# FATX Browser

A native macOS browser for FATX devices and disk images. Browse files, move data to and from Finder, format supported disks, and manage ATA drive security from one window.

## Features

- Browse FATX volumes and disk images; select detected partitions or enter custom geometry.
- Drag files and folders between Finder and the browser. Import, export, create folders, rename, move, and delete.
- Check a volume and recover an interrupted write using the generated journal.
- Format a supported external disk with fixed retail partitions or an extended F / F+G layout. Formatting erases the selected disk; see [Formatting](FORMATTING.md).
- Inspect ATA security, set or remove a password, and unlock supported USB-connected ATA drives. Enter a 16-byte HDD key or a direct ATA password. If a failed scan reveals a locked drive, the browser offers the security dialog.
- Optionally save named HDD keys in the macOS Keychain. Select a saved key or enter one manually; keys are never tried automatically. Saved entries can be deleted from Drive Security.

FATX Browser does not decrypt EEPROM backups or include EEPROM decryption keys. Obtain the current HDD key separately and keep it private. See [Drive Security](DRIVE-SECURITY.md) before using ATA security features.

## Requirements

- macOS 13 or newer, with Apple Command Line Tools or Xcode and Swift 5.9 or newer.
- Administrator authorization for device access; the app requests it once per session. macOS may also require Full Disk Access.
- A USB adapter supporting ATA pass-through for drive security operations. Some locked drives do not appear as a disk in macOS; the browser cannot select those drives.

## Build and run

Open Terminal in the extracted source folder and run as your normal macOS user:

```sh
./scripts/build-app.sh --open
```

The script creates `dist/FATX Browser.app`. To build without opening it, omit `--open`. The app is locally ad-hoc signed, not notarized. If macOS blocks it, open it via Finder's **Open** context menu and follow the system prompts. Rebuilding replaces the app bundle; quit a running copy first.

## Getting started

1. Connect your device, open the app and authorize device access when prompted.
2. Choose the external disk in the sidebar, or choose **Open Disk Image…**. Select a detected volume if prompted.
3. Browse and drag files or folders to and from Finder. For other operations use the toolbar or the **Volume** menu.
4. For drive security, choose **Volume → Drive Security…**, inspect the selected drive and verify its model and serial. Enter the current HDD key or choose a saved key, then select the appropriate action. A password set on a drive normally becomes a lock after power is removed.

Write operations create undo journals in Application Support. Keep journals for interrupted operations and use **Volume → Recover Interrupted Write…** if needed. Preserve independent backups, especially before formatting or changing drive security.

## Compatibility and testing

Automated tests use disposable disk images and exercise formatting, file operations, recovery, password derivation and ATA command sequencing. The browser and locked-drive workflow have been reported working on macOS with a SATA SSD and USB adapter. Compatibility across other adapters and hardware varies. Device status confirms security flags; it does not prove that a supplied HDD key belongs to a particular console. See [Testing](TESTING.md), [Formatting](FORMATTING.md), and [Drive Security](DRIVE-SECURITY.md).

## License

[MIT](LICENSE). See [third-party notices](THIRD_PARTY_NOTICES.md).
