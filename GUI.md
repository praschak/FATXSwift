# FATX Browser 1.0.0

A native SwiftUI/AppKit file browser using the FATX core. The existing `fatx` CLI is still included.

## Build and open

Run this in a **normal user Terminal**, not the root `sh-3.2#` shell used for the CLI tests. Type `exit` first if you are still in that shell.

```sh
./scripts/build-app.sh --open
```

The script builds and locally signs `dist/FATX Browser.app`. You can then move the app to `/Applications` and open it normally. No Xcode project, developer account, permanent privileged helper, or Homebrew packages are needed. Requires macOS 13+ and Swift 5.9+ Command Line Tools. Do not launch the app using `sudo`.

The archive contains source. The script must run on your Mac to produce the app. Native macOS compilation and interaction have not been executed in the Linux development environment; see `TESTING.md`.

## Open your memory unit

1. Click Refresh if the sidebar does not yet show the external disk.
2. Approve the administrator prompt once at app startup. If the Full Disk Access setup screen appears, use Open System Settings, add and enable the exact app shown by Reveal This App, then quit and reopen the browser. Click the memory unit in the sidebar to unmount and open it; folder navigation and device operations reuse the authorized session.
3. It probes both filesystem sector sizes and validates candidate volumes. Standalone memory units may use **4096-byte filesystem sectors**; detection checks both supported sizes.
4. If several volumes/layouts pass validation, choose one. Exact custom offset, length, and sector size remain available.

Device numbers are refreshed from macOS; the app does not assume your memory unit will always be `disk4`. Do not initialize the original device disk if macOS offers to do so.

## Drive security

Volume → Drive Security selects an external USB disk and inspects the ATA security state. Choose a matching HDD key or direct password to set, unlock or remove a password. The disk is unmounted and its adapter temporarily captured for each operation. Inspect its model and serial before confirming. See [DRIVE-SECURITY.md](DRIVE-SECURITY.md) for requirements and important recovery details. This new integration requires macOS and physical-device verification.

## Format device

Use **Volume → Format Device…** to review and format an external disk. This destroys its existing layout. Read [FORMATTING.md](FORMATTING.md) before starting. New C/E volumes are empty and must be populated from your own backup. ATA locking is available separately under Volume → Drive Security; see [DRIVE-SECURITY.md](DRIVE-SECURITY.md).

## File browser

- Double-click a folder to enter it; use the breadcrumb buttons or Up to navigate.
- Filter by filename and sort using column headers. Command-click / Shift-click selects multiple rows.
- Drop Finder files or folders into the file list to import them into the current folder. Drop directly onto a folder row to import into that folder.
- Folder imports recurse through their contents. All selected items form one journaled transaction. Symlinks and invalid FATX names are rejected; Finder `.DS_Store` files inside folder trees are skipped.
- Existing names cause a Replace & Merge prompt. Files can be replaced; matching folders can be merged. File-versus-folder conflicts are rejected. Cancel performs no import.
- Drag selected rows into a Finder folder to export. AppKit file promises perform the actual copy at drop time, with one provider per selected row. Folders export recursively.
- Import and Export toolbar buttons provide dialog alternatives to drag and drop.
- Drag rows onto a folder inside the browser to move them within the same volume. Use Move To for another absolute FATX folder, including the root. Cross-volume drag moves are rejected; export and import instead.
- Right-click or use Actions for Rename, Move To, Preview, and Delete. Deleting a folder removes its contents after an explicit confirmation. Creation, replacement, moves, and deletion are journaled and checked.
- Preview shows up to 64 KiB of UTF-8 text or a short hexadecimal preview. Export retains the entire file.
- Volume Info & Check reports geometry and allocation checks. Eject closes raw access and tells macOS to eject the device.

Exports require a new destination path and never overwrite an existing Mac file/folder. Use a different name or an empty destination folder. Incoming drag/drop supports Finder file URLs; promised data from apps such as Photos/Mail is not imported directly.

## Permissions and journals

The GUI runs as your normal user so Finder interaction works normally. At startup one macOS administrator prompt starts the bundled `fatxbridge` device helper. The authorization invocation stays in the foreground for the app session; raw-device requests reuse that helper and do not start another password prompt. Closing the main window keeps the authorization alive. Quitting the app ends it. If authorization is cancelled, images remain usable and Enable Device Access explicitly retries the setup.

The helper exchanges bounded JSON messages in a private directory. Each message is published atomically; the helper pins the directory by descriptor and rejects symlinks, hardlinks, public files, and incorrect ownership. Requests include a random session token. Privileged operations accept only external raw devices and private staged transfers. The helper watches the browser process's identity and exits after the browser quits or crashes, finishing an active operation first. No password is stored, no sudoers change is made, and no persistent system service is installed. A dead helper produces an error instead of silently requesting a password again.

Full Disk Access is separate from administrator authorization. The app tests actual read-only access to connected external raw devices at startup and on Refresh. Access denied by macOS opens the setup screen with Open System Settings and Reveal This App buttons. You must enable the permission yourself, then quit and reopen the app. Volume → Device Access & Permissions also opens the setup screen. A rebuilt/ad-hoc-signed app may need to be removed and re-added to Full Disk Access.

macOS provides no public API to read the Full Disk Access switch or present a normal consent dialog for it. The app does not inspect private TCC databases. With no external device attached, it reports access as unverified and shows first-time guidance; dismissing that guidance does not record a permission grant. Connect the device and Refresh to verify access. An access-denied result always shows the guidance again, regardless of previous successful checks.

Closing the red window button keeps the app running. Double-clicking the app, clicking its Dock icon, or choosing Show Browser (Command-0) brings the retained main window back. Command-Q quits the app.

Mac-side import/export copies run as your normal user. Imports are staged in a private temporary folder before the device operation; exports are staged there and copied to the chosen Finder destination afterward. This needs additional free Mac disk space and keeps the privileged command away from Finder destination files. Temporary transfer copies are removed after completion. If a host-side copy runs out of space, its partial destination may remain; the error identifies that path.

Device operations use the session’s private JSON message directory; ordinary image operations use one-shot private JSON request and response files. File names and transfer paths are not interpolated into shell commands. The bridge supports only the fixed operations represented in `BrowserCommand`; the elevated device process lasts only for the app session.

Journals are created automatically in:

```text
~/Library/Application Support/FATXBrowser/Journals
```

Use Volume → Show Journals in Finder to locate them. Device-operation journals can be root-owned because the write command runs with administrator privileges. The GUI can still select these paths for recovery through the elevated command.

If an interrupted operation blocks a device, choose it, then use Recover Interrupted Write and select its unfinished `.undo` journal. On a volume with damaged interim geometry, the volume chooser also offers Recover Write before browsing. Do not remove unfinished journals or pending state. Completed journals can be cleaned up after verifying the result.

## Included components

| Component | Purpose |
| --- | --- |
| `FATXBrowser` | Native UI, normal user permissions |
| `fatxbridge` | Session-scoped authorized device operations and one-shot image operations |
| `FATXService` | Codable browser protocol, probing, device validation, and operations |
| `FATXCore` | Existing filesystem engine plus recursive transfers |
| `fatx` | Existing command-line interface |

No Finder mounting, filesystem repair, or FATXplorer XL support is added by the GUI. FATX's existing filename and file-size limits still apply.
