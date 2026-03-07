# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]
### Added
- Manual grouping mode with global hotkeys:
  - `Control + Option + G` to start/add.
  - `Control + Option + Shift + G` to finish.
- Debug overlay panel for live log tail.
- Menu actions for focused/visible/diagnostic dumps.
- Swift unit tests for manual group state.

### Changed
- `main` now focuses on manual grouping; auto pairing, auto diagnostics, tuning controls, and the auto smoke script were removed from this branch.
- Window identity handling now prioritizes stable window IDs and improved matching when apps omit AX window numbers.
- Group bring-to-front path now attempts non-activating CGS ordering for multi-app groups, then falls back to AX raise.
- Group visibility/debug info is surfaced directly in the menu.

## [0.1.0] - 2026-01-18
### Added
- Menu bar app that raises adjacent tiled windows as a group.
- Accessibility-based window discovery and grouping.
- Diagnostics logging to `/tmp/WindowGroups.log`.
