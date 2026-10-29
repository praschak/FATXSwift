# FATXSwift + FATX Browser

A Swift command-line tool for reading and writing **FATX** and **XTAF** volumes on macOS. Includes a reusable `FATXCore` library and a small C shim for device geometry, locking, and flushing. No Homebrew packages, FUSE, or third-party Swift dependencies are needed to build the CLI.

## Native file browser

The 0.2.5 source package includes **FATX Browser**, with Finder drag/drop import and export, recursive folders, rename/move/delete, checks, and recovery. Build and open it on your Mac as your normal user:

```sh
./scripts/build-app.sh --open
```

Version 0.2.5 uses neutral filesystem terminology and a compact window toolbar. Device access is authorized once per app session, and Full Disk Access setup is guided at launch when needed. Quit any previously running copy before opening a new build.

Fixed FATX partition selectors are `fatx-x`, `fatx-y`, `fatx-z`, `fatx-c`, and `fatx-e`. Update saved CLI commands to use these names.

See [GUI.md](GUI.md) for setup and controls. The CLI examples below remain valid.

**Status: 0.2.5 prerelease.** Automated validation uses disposable images on Linux; a manual device workflow has also been reported working on macOS. Physical-media coverage remains limited. Start with an image copy and keep backups. See [TESTING.md](TESTING.md) for validation details. The project includes a macOS CI workflow and a local verification script.

## Build on your Mac

Install Apple's Command Line Tools if needed:

```sh
xcode-select --install
```

Then, in this project's directory:

```sh
swift test -j 1
swift build -c release -j 1
FATX_BIN_DIR="$(swift build -c release --show-bin-path)"
"$FATX_BIN_DIR/fatx" --help
```

Requirements: macOS 13 or newer, Swift 5.9 or newer. The result is built for your Mac's native architecture (Apple Silicon or Intel). The archive contains source, not a precompiled macOS binary.

Optionally install it in your user bin directory:

```sh
mkdir -p "$HOME/.local/bin"
cp "$FATX_BIN_DIR/fatx" "$HOME/.local/bin/fatx"
```

The examples below assume `fatx` is on your PATH. Otherwise use `"$FATX_BIN_DIR/fatx"` after the build steps above.

## Commands

| Command | Action |
| --- | --- |
| `devices` | List external physical macOS disks through `diskutil` |
| `scan SOURCE` | Probe known FATX partition locations; print candidate offsets and lengths as JSON |
| `info SOURCE` | Show selected volume geometry as JSON |
| `ls SOURCE /path` | List a directory; defaults to `/` |
| `cat SOURCE /file` | Write exact file bytes to stdout |
| `get SOURCE /file LOCAL` | Extract one file; local destination must not exist |
| `check SOURCE` | Check live chains, duplicate names, cross-links, orphan allocations, and file sizes |
| `put SOURCE LOCAL /file` | Import one file; `--replace` explicitly enables replacement |
| `mkdir SOURCE /folder` | Create a directory; parent must exist |
| `mv SOURCE /old /new` | Rename or move without replacing another entry |
| `rm SOURCE /path` | Delete a file or an empty directory |
| `recover SOURCE --journal FILE` | Roll back an interrupted operation using its undo journal |

Every mutation requires `--journal /absolute/path/to/a-new-file`. Successful writes run `check` before and after the operation. Nonzero exit status indicates failure. `cat` writes no informational messages to stdout.

## Start with a volume image

`volume.img` must contain exactly one partition with its FATX header at byte zero:

```sh
fatx info volume.img
fatx ls volume.img /
fatx check volume.img
fatx get volume.img /sample.bin ./sample-copy.bin

fatx mkdir volume.img /Tools --journal "$PWD/mkdir.undo"
fatx put volume.img ./tool.xbe /Tools/tool.xbe --journal "$PWD/import.undo"
fatx put volume.img ./new-tool.xbe /Tools/tool.xbe --replace --journal "$PWD/replace.undo"
fatx mv volume.img /Tools/tool.xbe /Tools/default.xbe --journal "$PWD/rename.undo"
fatx rm volume.img /Tools/default.xbe --journal "$PWD/delete.undo"
```

Use a different journal filename each time. Do not place the journal on the target FATX disk. Journal files contain original file data, so keep them private.

## Whole FATX disks and disk images

Find an external device and unmount it before access. macOS may offer to initialize the device: choose **Ignore**, not Initialize.

```sh
fatx devices
# Substitute the actual FATX disk number after inspecting the listing.
diskutil unmountDisk /dev/disk4
sudo fatx scan /dev/rdisk4
sudo fatx info /dev/rdisk4 --partition 360-data
sudo fatx ls /dev/rdisk4 / --partition 360-data
sudo fatx check /dev/rdisk4 --partition 360-data
sudo fatx put /dev/rdisk4 ./example.bin /example.bin \
  --partition 360-data --journal "$PWD/device-import.undo"
```

Raw access accepts only external, unmounted whole `/dev/rdiskN` devices. It refuses raw writes when a disk contains APFS/HFS partitions. Use the same privilege level for all raw-device commands because their coordination files are owned by the invoking user. Close every other disk utility; locks coordinate FATXSwift processes and are advisory for images, not a guarantee against unrelated programs.

Known layouts: `fatx-x`, `fatx-y`, `fatx-z`, `fatx-c`, `fatx-e`, `360-data`, `360-compat`, `360-sysext`, `360-sysext2`, `360-mu`. `scan` probes headers at these offsets; it does not perform an exhaustive sector scan or certify the inferred length. Validate the layout before writing.

For a custom layout, supply **both exact values**:

```sh
fatx info disk.img --offset 0x12340000 --length 0x20000000
fatx ls disk.img / --offset 0x12340000 --length 0x20000000
```

Partition length affects FAT width, FAT size, and the location of file data. Do not substitute “to the end of disk” for a fixed partition's real length. `360-data` intentionally uses the remainder of a standard retail HDD. FATX E uses the retail size `0x1312d6000`. Custom F/G partitions and development disks require independently verified bounds.

For FATX memory-unit images that use 4096-byte filesystem sectors, select `--sector-size 4096`. FATX HDD volumes use the default 512. This is the filesystem's logical sector size, distinct from the USB bridge's device block size.

## Writes and interruption recovery

1. The entire selected volume is checked. Invalid chains, duplicate ASCII-case-insensitive names, cross-links, and orphan allocations prevent writes.
2. An external journal is created exclusively. A persistent `.fatx-pending` state beside an image, or `/var/tmp/fatxswift-rdiskN.pending` for a raw device, records the journal path before any source bytes change.
3. Each aligned write's original bytes and a CRC32 over its address, size, and payload are flushed to the journal first.
4. Replacement allocates a new chain before updating the entry and releasing the old chain. Insufficient space fails without deleting the old file.
5. A final volume check runs, the source is flushed, and a `.committed` completion marker is written. On a normal error, original bytes are replayed in reverse order.

If the process is killed or the computer loses power, **do not attach the disk to the original device or start another disk utility**. Recover first:

```sh
fatx recover volume.img --journal /absolute/path/to/interrupted.undo
fatx check volume.img
```

Use `sudo` and the same raw device for device recovery. Recovery validates source identity, header, partition bounds, and all complete record checksums before replay. An incomplete final record is ignored because its source write could not have started before that record was durably flushed. Recovery is repeatable after another interruption; a completed journal cannot be replayed accidentally.

The source path and identity must still match. Renaming/copying the image, or reconnecting/rebooting with a raw device, may change identity and cause recovery to refuse. Preserve the original source and journal; do not edit identity fields or delete pending state to force recovery. Never reuse an old uncommitted journal after intervening writes by another tool.

The journal is not a full disk backup or an on-console transaction mechanism. CRC32 detects accidental corruption, not hostile tampering. Recovery depends on a working host filesystem and storage hardware honoring flushes. Journal space must cover every overwritten block plus records; retain ample free space on your Mac. Completed journals and their `.committed` files can be removed together after verifying the result. Do not remove an unfinished journal or pending state.

## Scope and limitations

- Standard FATX16/FATX32 and XTAF16/XTAF32; automatic byte order from the header.
- Up to 512 KiB clusters, with conservative geometry and range validation.
- Single files up to 4 GiB minus one byte. Replacement needs room for the new file in addition to the old one.
- New and renamed names are 1–42 ASCII bytes. Existing single-byte names are displayed byte-for-byte as Latin-1 scalars; case matching folds ASCII only. No OEM code-page conversion is claimed.
- Existing attributes and creation/access fields are preserved during replacement. New entries use local FAT-style timestamps with the FATX epoch 2000 or XTAF epoch 1980.
- The CLI retains single-file import/extraction and empty-directory deletion. The GUI/service adds recursive import, export, and confirmed recursive deletion.
- No formatting, Finder mounting, ATA unlocking, undelete, filesystem repair, split USB `Data0000` container reconstruction, FAT32 USB content management, STFS package signing, or FATXplorer XL/extended-layout handling.
- Full-volume checks precede and follow each write; large volumes and fragmented media can be slow. Read-only commands do not modify FATX access timestamps.

## Verify

```sh
./scripts/verify.sh
```

This runs Swift tests, a release build, and independent Python CLI integration tests. Python 3 is needed only for the integration script, not the CLI. Test images are disposable and no hardware devices are used. See `TESTING.md` for exactly what was run during development.

## Implementation references

Independently implemented Swift code; no third-party filesystem library is embedded. Format research was cross-checked against:

- [FATX reference library](https://github.com/mborgerson/fatx): geometry, FAT addressing, fixed FATX partitions and epoch.
- [Free60 FATX documentation](https://free60.org/System-Software/Systems/FATX/): XTAF layout and directory fields.
- [FATXTools](https://github.com/aerosoul94/FATXTools): directory fields and timestamp interpretation.
- [Velocity](https://github.com/hetelek/Velocity): FATX chain traversal and XTAF timestamp layout.
- [Apple XNU](https://github.com/apple-oss-distributions/xnu): raw-device lock and flush behavior.

MIT license. This project is not affiliated with Microsoft or FATXplorer.
