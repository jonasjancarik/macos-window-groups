# macos-window-groups

Prototype menu bar app that brings tiled window neighbors to the front when you switch windows/apps.

## Requirements

- macOS 13+
- Accessibility permission (System Settings → Privacy & Security → Accessibility)

## Run

```bash
swift run
```

The app shows a "WG" menu bar icon. Grant Accessibility permission when prompted.
Use the menu to adjust grouping sensitivity, inspect detected groups, and inspect logs.

## Features

- Auto grouping for snapped left/right pairs (half-screen layouts), based on adjacency + focus transitions.
- Manual grouping mode:
  - `Control + Option + G`: enable mode and add focused window (or add another focused window if already enabled).
  - `Control + Option + Shift + G`: finish manual group.
- Optional debug overlay panel (live tail of recent logs).
- Group list in menu ("Groups") and quick diagnostics in menu ("Logs").
- Auto diagnostics in background, including current frontmost app and current groups.

## Menu options

- `Enable Snap Groups`: global on/off.
- `Keep Cmd-Tab Order (experimental)`: tries non-activating raise through private CGS APIs first; falls back to AX raise when unavailable/failing.
- `Include other spaces (experimental)`: include windows from other Spaces in discovery/grouping.
- `Edge tolerance` / `Min overlap ratio`: tune adjacency detection.
- `Manual Grouping Mode`, `Add Focused to Manual Group`, `Finish Manual Group`.

## Logging and diagnostics

- Logs are written to `/tmp/WindowGroups.log` (trimmed automatically).
- Open/copy/clear logs from the `Logs` submenu.
- `Dump Focused Context`, `Dump Visible Windows`, and `Dump Window Diagnostics` help troubleshoot matching/visibility problems.
- Expect occasional messages like `Non-activating raise failed; falling back to AXRaise.` This indicates CGS path failed and AX path was used.

## Notes

- Uses Accessibility APIs to read/raise windows.
- Current auto-grouping target is left/right half-screen arrangements.
- In ambiguous layouts (3+ snapped windows on one screen), focus history is used as tie-breaker.
- Some apps do not expose stable window metadata; matching falls back to best available identifiers.
- Manual mode disables auto-pairing while mode is enabled.
