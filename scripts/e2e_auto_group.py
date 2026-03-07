#!/usr/bin/env python3
"""End-to-end auto-grouping smoke test for WindowGroups on macOS.

What it does:
1) Ensures WindowGroups is running (optionally launches it).
2) Creates/positions Terminal + TextEdit windows as left/right halves.
3) Triggers focus transitions to drive auto pairing.
4) Verifies grouping from /tmp/WindowGroups.log.
5) Verifies both app windows are near the top of on-screen z-order.

Requirements:
- Accessibility permission for WindowGroups and Terminal/python.
- Automation permission for Terminal/python controlling Terminal/TextEdit/Finder.
"""

from __future__ import annotations

import argparse
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

import Quartz


REPO_ROOT = Path(__file__).resolve().parents[1]
LOG_PATH = Path("/tmp/WindowGroups.log")
TARGET_APPS = ("Terminal", "TextEdit")


def run(cmd: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, check=check, text=True, capture_output=True)


def run_osascript(lines: list[str]) -> str:
    cmd = ["osascript"]
    for line in lines:
        cmd.extend(["-e", line])
    result = run(cmd)
    return result.stdout.strip()


def parse_ints(text: str) -> list[int]:
    return [int(v) for v in re.findall(r"-?\d+", text)]


def desktop_bounds() -> tuple[int, int, int, int]:
    output = run_osascript(["tell application \"Finder\" to get bounds of window of desktop"])
    nums = parse_ints(output)
    if len(nums) != 4:
        raise RuntimeError(f"Failed to parse desktop bounds from: {output!r}")
    return nums[0], nums[1], nums[2], nums[3]


def arrange_terminal(bounds: tuple[int, int, int, int]) -> None:
    l, t, r, b = bounds
    run_osascript(
        [
            "tell application \"Terminal\"",
            "if (count of windows) is 0 then do script \"\"",
            "activate",
            f"set bounds of front window to {{{l}, {t}, {r}, {b}}}",
            "end tell",
        ]
    )


def arrange_textedit(bounds: tuple[int, int, int, int]) -> None:
    l, t, r, b = bounds
    run_osascript(
        [
            "tell application \"TextEdit\"",
            "if (count of documents) is 0 then make new document",
            "activate",
            f"set bounds of front window to {{{l}, {t}, {r}, {b}}}",
            "end tell",
        ]
    )


def activate_app(app_name: str) -> None:
    run_osascript([f"tell application \"{app_name}\" to activate"])


def clear_log() -> None:
    LOG_PATH.write_text("", encoding="utf-8")


def wait_for_group_log(timeout: float) -> bool:
    pattern = re.compile(r"Group windows: .*?(Terminal#.*TextEdit#|TextEdit#.*Terminal#)")
    deadline = time.time() + timeout
    while time.time() < deadline:
        if LOG_PATH.exists():
            text = LOG_PATH.read_text(encoding="utf-8", errors="replace")
            if pattern.search(text):
                return True
        time.sleep(0.2)
    return False


def layer0_window_owner_order() -> list[str]:
    options = Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements
    raw_list = Quartz.CGWindowListCopyWindowInfo(options, Quartz.kCGNullWindowID) or []
    owners: list[str] = []
    for entry in raw_list:
        if int(entry.get("kCGWindowLayer", 0)) != 0:
            continue
        if float(entry.get("kCGWindowAlpha", 1.0)) <= 0.01:
            continue
        owner = str(entry.get("kCGWindowOwnerName", ""))
        if owner:
            owners.append(owner)
    return owners


def top_indices_for_targets(max_scan: int = 60) -> dict[str, int]:
    owners = layer0_window_owner_order()[:max_scan]
    out: dict[str, int] = {}
    for app in TARGET_APPS:
        try:
            out[app] = owners.index(app)
        except ValueError:
            out[app] = -1
    return out


def pids_for_name(name: str) -> list[int]:
    result = run(["pgrep", "-x", name], check=False)
    pids: list[int] = []
    if result.returncode != 0:
        return pids
    for line in result.stdout.splitlines():
        line = line.strip()
        if line.isdigit():
            pids.append(int(line))
    return pids


def ensure_windowgroups_running(launch_if_missing: bool) -> tuple[int | None, subprocess.Popen[str] | None]:
    existing = pids_for_name("WindowGroups")
    if existing:
        return existing[0], None

    if not launch_if_missing:
        raise RuntimeError("WindowGroups is not running. Start it first or pass --launch-windowgroups.")

    binary = REPO_ROOT / ".build" / "debug" / "WindowGroups"
    if not binary.exists():
        raise RuntimeError(f"Missing binary: {binary}. Run `swift build` first.")

    proc = subprocess.Popen(
        [str(binary)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    time.sleep(1.2)
    return proc.pid, proc


def stop_process(proc: subprocess.Popen[str] | None) -> None:
    if proc is None:
        return
    try:
        os.kill(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return


def split_bounds_for_halves(bounds: tuple[int, int, int, int]) -> tuple[tuple[int, int, int, int], tuple[int, int, int, int]]:
    l, t, r, b = bounds
    width = r - l
    height = b - t

    margin_x = max(8, int(width * 0.01))
    margin_top = max(36, int(height * 0.03))
    margin_bottom = max(24, int(height * 0.02))
    gap = max(8, int(width * 0.005))
    mid = l + width // 2

    left = (l + margin_x, t + margin_top, mid - gap, b - margin_bottom)
    right = (mid + gap, t + margin_top, r - margin_x, b - margin_bottom)
    return left, right


def main() -> int:
    parser = argparse.ArgumentParser(description="E2E auto-group smoke test for WindowGroups")
    parser.add_argument("--timeout", type=float, default=14.0, help="seconds to wait for group log")
    parser.add_argument(
        "--launch-windowgroups",
        action="store_true",
        help="launch .build/debug/WindowGroups if not already running",
    )
    parser.add_argument(
        "--top-threshold",
        type=int,
        default=12,
        help="required max layer-0 index for both target apps after bring-to-front",
    )
    args = parser.parse_args()

    wg_pid: int | None = None
    spawned_wg: subprocess.Popen[str] | None = None
    try:
        wg_pid, spawned_wg = ensure_windowgroups_running(args.launch_windowgroups)
        print(f"WindowGroups pid: {wg_pid}")

        clear_log()
        bounds = desktop_bounds()
        left, right = split_bounds_for_halves(bounds)
        print(f"Desktop bounds: {bounds}")
        print(f"Left bounds: {left}")
        print(f"Right bounds: {right}")

        arrange_terminal(left)
        time.sleep(0.3)
        arrange_textedit(right)
        time.sleep(0.3)

        # Drive focus transitions to trigger pairing on ambiguous focus state.
        activate_app("TextEdit")
        time.sleep(0.35)
        activate_app("Terminal")
        time.sleep(0.6)

        grouped = wait_for_group_log(args.timeout)
        print(f"Group detected in logs: {grouped}")
        if not grouped:
            print("FAIL: grouping not observed in /tmp/WindowGroups.log")
            return 1

        # Bring unrelated app front, then refocus a member to trigger group raise.
        activate_app("Finder")
        time.sleep(0.35)
        activate_app("Terminal")
        time.sleep(0.9)

        top = top_indices_for_targets()
        print(f"Top layer-0 indices: {top}")
        if any(v < 0 for v in top.values()):
            print("FAIL: could not find both target apps in on-screen window list")
            return 1
        if max(top.values()) > args.top_threshold:
            print(
                f"FAIL: bring-to-front weak (threshold={args.top_threshold}, indices={top})"
            )
            return 1

        print("PASS: auto grouping and bring-to-front smoke test passed.")
        return 0
    finally:
        stop_process(spawned_wg)


if __name__ == "__main__":
    sys.exit(main())
