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

## Notes

- Uses Accessibility APIs to read/raise windows.
- Auto-detects tiled groups by window edge adjacency on the same screen.
- Some apps do not expose window numbers; we fall back to AX element identifiers.
