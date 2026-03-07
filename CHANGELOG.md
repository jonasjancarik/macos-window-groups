# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]
### Added
- Manual grouping mode with global hotkeys:
  - `Control + Option + G` to start/add.
  - `Control + Option + Shift + G` to finish.
- Debug overlay panel for live log tail.
- Periodic auto-diagnostics and richer pairing/grouping logs.
- Menu actions for focused/visible/diagnostic dumps.
- Python E2E auto-group smoke test script (`scripts/e2e_auto_group.py`).

### Changed
- Window identity handling now prioritizes stable window IDs and improved matching when apps omit AX window numbers.
- Group bring-to-front path now attempts non-activating CGS ordering, then falls back to AX raise.
- Group visibility/debug info is surfaced directly in the menu.
- Auto pairing in ambiguous snapped layouts now uses spatial fallback when previous-focus pairing is unavailable.

## [0.1.0] - 2026-01-18
### Added
- Menu bar app that raises adjacent tiled windows as a group.
- Accessibility-based window discovery and grouping.
- Diagnostics logging to `/tmp/WindowGroups.log`.
