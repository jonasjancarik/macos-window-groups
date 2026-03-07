# macos-window-groups

Prototype menu bar app that brings manually grouped windows to the front when you switch windows/apps.

## Requirements

- macOS 13+
- Accessibility permission (System Settings → Privacy & Security → Accessibility)

## Run

```bash
swift run
```

The app shows a "WG" menu bar icon. Grant Accessibility permission when prompted.
Use the menu to create manual groups, inspect stored groups, and inspect logs.

## Features

- Manual grouping mode:
  - `Control + Option + G`: enable mode and add focused window (or add another focused window if already enabled).
  - `Control + Option + Shift + G`: finish manual group.
- Stored manual groups come to the front together when focus returns to any member.
- Optional debug overlay panel (live tail of recent logs).
- Group list in menu ("Groups") and quick diagnostics in menu ("Logs").

## Menu options

- `Manual Grouping Mode`, `Add Focused to Manual Group`, `Finish Manual Group`.
- `Remove Focused Window From Group`, `Delete Current Group`.
- `Groups`, `Logs`, `Debug Overlay`, `Request Accessibility Permission`.

## Logging and diagnostics

- Logs are written to `/tmp/WindowGroups.log` (trimmed automatically).
- Open/copy/clear logs from the `Logs` submenu.
- `Dump Focused Context`, `Dump Visible Windows`, and `Dump Window Diagnostics` help troubleshoot matching/visibility problems.
- Expect occasional messages like `Non-activating raise failed; falling back to AXRaise.` This indicates the CGS path failed and AX raise was used instead.

## Notes

- Uses Accessibility APIs to read/raise windows.
- Stored groups are cleared if a member moves/resizes significantly or disappears.
- Stored groups can be edited explicitly from the menu by removing the focused window or deleting the current group.
- Some apps do not expose stable window metadata; matching falls back to best available identifiers.
- Multi-app groups try non-activating CGS ordering first, then fall back to AX raise.
