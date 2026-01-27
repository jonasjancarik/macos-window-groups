import AppKit
import ApplicationServices

struct WindowListProvider {
    struct CGWindowEntry {
        let windowID: CGWindowID
        let ownerPID: pid_t
        let bounds: CGRect
    }

    func visibleWindows(includeOffscreen: Bool = false) -> [AXWindowInfo] {
        let onScreenIDs = includeOffscreen ? Set<Int>() : onScreenWindowIDs()

        let apps = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular
        }

        var windows: [AXWindowInfo] = []
        windows.reserveCapacity(32)

        for app in apps {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            guard let axWindows: [AXUIElement] = AXHelpers.copyAttribute(appElement, kAXWindowsAttribute as CFString) else {
                continue
            }

            for window in axWindows {
                guard !AXHelpers.isMinimized(window) else { continue }
                guard AXHelpers.isStandardWindow(window) else { continue }
                guard let frame = AXHelpers.copyFrame(window) else { continue }
                guard isFrameOnAnyScreen(frame) else { continue }

                let windowID = AXHelpers.copyWindowNumber(window)
                if let windowID, !onScreenIDs.isEmpty, !onScreenIDs.contains(windowID) {
                    continue
                }

                let name = app.localizedName ?? "App"
                windows.append(
                    AXWindowInfo(
                        identifier: AXHelpers.elementIdentifier(window),
                        windowID: windowID,
                        pid: app.processIdentifier,
                        appName: name,
                        frame: frame,
                        axElement: window
                    )
                )
            }
        }

        return windows
    }

    func cgWindowEntries() -> [CGWindowEntry] {
        let listInfo = cgWindowInfo()
        var entries: [CGWindowEntry] = []
        entries.reserveCapacity(listInfo.count)

        for info in listInfo {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let isOnscreen = info[kCGWindowIsOnscreen as String] as? Bool, isOnscreen else { continue }
            guard let windowNumber = info[kCGWindowNumber as String] as? Int else { continue }
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            guard let bounds = boundsRect(from: info[kCGWindowBounds as String]) else { continue }
            entries.append(
                CGWindowEntry(
                    windowID: CGWindowID(windowNumber),
                    ownerPID: ownerPID,
                    bounds: bounds
                )
            )
        }

        return entries
    }

    func matchCGWindowID(for axWindow: AXWindowInfo, in entries: [CGWindowEntry]) -> CGWindowID? {
        if let windowID = axWindow.windowID {
            return CGWindowID(windowID)
        }

        let candidates = entries.filter { $0.ownerPID == axWindow.pid }
        guard !candidates.isEmpty else { return nil }

        let axCenter = CGPoint(x: axWindow.frame.midX, y: axWindow.frame.midY)
        let axSize = axWindow.frame.size
        var best: (id: CGWindowID, score: CGFloat)?

        for candidate in candidates {
            let center = CGPoint(x: candidate.bounds.midX, y: candidate.bounds.midY)
            let centerDist = abs(axCenter.x - center.x) + abs(axCenter.y - center.y)
            let sizeDist = abs(axSize.width - candidate.bounds.width) + abs(axSize.height - candidate.bounds.height)
            let score = centerDist + sizeDist
            if let current = best {
                if score < current.score {
                    best = (candidate.windowID, score)
                }
            } else {
                best = (candidate.windowID, score)
            }
        }

        guard let best else { return nil }
        return best.score < 80 ? best.id : nil
    }

    func dumpDiagnostics(logger: AppLogger) {
        let cgInfo = cgWindowInfo()
        logger.log("CGWindowList entries: \(cgInfo.count).")
        for info in cgInfo.prefix(12) {
            let owner = info[kCGWindowOwnerName as String] as? String ?? "Unknown"
            let windowNumber = info[kCGWindowNumber as String] as? Int ?? -1
            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            let bounds = boundsString(from: info[kCGWindowBounds as String])
            logger.log("CG window \(windowNumber) owner \(owner) layer \(layer) bounds \(bounds).")
        }

        let apps = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular
        }

        logger.log("AX apps: \(apps.count).")
        for app in apps {
            let name = app.localizedName ?? "App"
            let pid = app.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
            guard result == .success else {
                logger.log("AX windows failed for \(name) pid \(pid): \(result) (\(result.rawValue)).")
                continue
            }
            let axWindows = value as? [AXUIElement] ?? []
            logger.log("AX windows for \(name) pid \(pid): \(axWindows.count).")
            if let first = axWindows.first, AXHelpers.copyWindowNumber(first) == nil {
                logger.log("AXWindowNumber missing for \(name) pid \(pid).")
            }
        }
    }

    private func isFrameOnAnyScreen(_ frame: CGRect) -> Bool {
        for screen in NSScreen.screens {
            if screen.frame.intersects(frame) {
                return true
            }
        }
        return false
    }

    private func cgWindowInfo() -> [[String: Any]] {
        guard let listInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as NSArray? as? [[String: Any]] else {
            return []
        }
        return listInfo
    }

    private func boundsRect(from value: Any?) -> CGRect? {
        guard let bounds = value as? [String: Any],
              let x = bounds["X"] as? Double,
              let y = bounds["Y"] as? Double,
              let w = bounds["Width"] as? Double,
              let h = bounds["Height"] as? Double else {
            return nil
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func boundsString(from value: Any?) -> String {
        guard let rect = boundsRect(from: value) else { return "n/a" }
        return String(format: "x%.0f y%.0f w%.0f h%.0f", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
    }

    private func onScreenWindowIDs() -> Set<Int> {
        guard let listInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as NSArray? as? [[String: Any]] else {
            return []
        }

        var ids = Set<Int>()
        ids.reserveCapacity(listInfo.count)

        for info in listInfo {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let isOnscreen = info[kCGWindowIsOnscreen as String] as? Bool, isOnscreen else { continue }
            guard let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0.01 else { continue }
            guard let windowNumber = info[kCGWindowNumber as String] as? Int else { continue }
            ids.insert(windowNumber)
        }

        return ids
    }
}
