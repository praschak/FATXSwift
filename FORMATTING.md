# Whole-disk FATX formatting — preview

Formatting erases the selected disk's layout and filesystem metadata. Back up your files first. This preview has not been verified on physical disks or compiled with an Apple SDK; first test only on expendable media.

The formatter accepts external physical whole disks with 512-byte logical sectors (including 512e), and ordinary disk images for testing. Native 4Kn disks, memory units, development and XL layouts are not supported by this formatter. Existing 4096-byte filesystem-sector memory-unit browsing remains supported.

| Profile | Result |
| --- | --- |
| Retail | C/E/X/Y/Z at the fixed standard offsets; extra space unused. |
| LBA48 F | The same five volumes plus F for the remaining space, with a partition table. |
| LBA48 F/G | The same five volumes plus split F/G, with a partition table. |

F/G profiles need firmware that supports LBA48 and the partition table. Retail volumes use 16 KiB clusters; extended volumes use 64 KiB clusters. Extended volumes are limited to 1 TiB and 0xFFFFFF usable clusters each. Disk size must be at least 8,004,132,864 bytes and at most 2 TiB.

In the app select **Volume → Format Device**, choose the disk and layout, review, type the exact device name, then confirm the erase. Existing mounted volumes are unmounted without forcing. The app requires a private undo journal and validates each new volume. The new C/E volumes are empty: import your own matching system and dashboard files afterwards. Formatting does not lock the drive.

For CLI use, substitute the actual device and inspect the plan before writing:

```sh
sudo .build/release/fatx format-plan /dev/rdisk4 --profile lba48-fg > format-plan.json
cat format-plan.json
diskutil unmountDisk /dev/disk4
sudo .build/release/fatx format /dev/rdisk4 --plan "$PWD/format-plan.json" --confirm /dev/rdisk4 --journal "$PWD/format.undo"
sudo .build/release/fatx scan /dev/rdisk4
```

Depending on your SwiftPM installation, find binaries using `swift build -c release --show-bin-path`. An image may be used instead; its confirmation must be its absolute canonical path. The reviewed plan is recalculated after opening and must match the source identity, size and layout. Keep other disk tools closed and review again after reconnecting.

A quick format clears old partition layout information and new filesystem metadata, but does not securely wipe all old file contents. Before each write, the original bytes are saved and flushed to an undo journal. Failures attempt rollback; an interrupted write can be recovered using the unfinished journal, e.g. `sudo .build/release/fatx recover /dev/rdisk4 --journal "$PWD/format.undo"`. The app provides Recover Interrupted Write. Keep the journal and pending state; a completed journal cannot be replayed later as an undo. The journal is not a disk backup, and failing hardware can prevent recovery.
