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
Use the menu to adjust edge tolerance/min overlap, view detected groups, and see logs.
Logs are written to `/tmp/WindowGroups.log` (trimmed automatically) and can be opened from the Logs submenu.
The Logs submenu also includes dump actions to inspect window frames.
Auto diagnostics now run in the background; just reproduce and share the log file.
The optional "Keep Cmd-Tab Order" toggle uses private CGS APIs and may not work on all macOS versions.
The optional "Include other spaces" toggle includes windows from other Spaces (experimental).
When a group change is detected, the menu bar title briefly shows the group count.
The optional "Debug Overlay" toggle shows a live log panel on screen.

## Notes

- Uses Accessibility APIs to read/raise windows.
- Pairs snapped left/right windows based on focus changes and edge adjacency (halves only).
- Some apps do not expose window numbers; we fall back to AX element identifiers.
- If a group is not detected, nudge/re-tile the windows so their moves happen close together.
