import AppKit
import ApplicationServices

struct WindowListProvider {
    func visibleWindows() -> [AXWindowInfo] {
        let onScreenIDs = onScreenWindowIDs()

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

    private func boundsString(from value: Any?) -> String {
        guard let bounds = value as? [String: Any],
              let x = bounds["X"] as? Double,
              let y = bounds["Y"] as? Double,
              let w = bounds["Width"] as? Double,
              let h = bounds["Height"] as? Double else {
            return "n/a"
        }
        return String(format: "x%.0f y%.0f w%.0f h%.0f", x, y, w, h)
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
