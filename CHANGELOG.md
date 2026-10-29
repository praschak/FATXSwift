# Changelog

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
