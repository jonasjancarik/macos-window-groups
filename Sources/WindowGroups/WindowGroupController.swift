import AppKit
import ApplicationServices

final class WindowGroupController {
    private let eventQueue = DispatchQueue(label: "WindowGroups.eventQueue")
    private let windowProvider = WindowListProvider()
    private let logger = AppLogger.shared
    private var detector: TilingDetector

    private var suppressionUntil = Date.distantPast
    private var pendingWork: DispatchWorkItem?
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var lastGroupKey: String?
    private var lastFocusedWindowIdentifier: UInt?
    private var lastActivePID: pid_t?
    private var lastActiveAppName: String?
    private var autoTimer: DispatchSourceTimer?
    private var lastAutoLog = Date.distantPast
    private var lastDiagnosticsLog = Date.distantPast

    private let enabledKey = "WindowGroups.enabled"
    private let edgeToleranceKey = "WindowGroups.edgeTolerance"
    private let overlapRatioKey = "WindowGroups.minOverlapRatio"
    private let defaultEdgeTolerance: CGFloat = 8
    private let defaultOverlapRatio: CGFloat = 0.25

    private var loggedPermissionDenied = false

    init() {
        let edgeValue = UserDefaults.standard.object(forKey: edgeToleranceKey) as? Double
            ?? Double(defaultEdgeTolerance)
        let overlapValue = UserDefaults.standard.object(forKey: overlapRatioKey) as? Double
            ?? Double(defaultOverlapRatio)
        detector = TilingDetector(
            edgeTolerance: CGFloat(edgeValue),
            minOverlapRatio: CGFloat(overlapValue)
        )
    }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    var edgeToleranceValue: Double {
        Double(detector.edgeTolerance)
    }

    var minOverlapRatioValue: Double {
        Double(detector.minOverlapRatio)
    }

    func start() {
        let trusted = requestAccessibility(prompt: true)
        logger.log("Start. Accessibility trusted: \(trusted).")
        logger.log("Tiling config. Edge tolerance: \(edgeToleranceValue). Min overlap: \(minOverlapRatioValue).")
        logger.log("Log file: \(logger.logFileURL.path).")
        subscribeWorkspaceNotifications()
        refreshObserverForFrontmostApp()
        startAutoDiagnostics()
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        logger.log("Enabled set to \(enabled).")
    }

    @discardableResult
    func requestAccessibility(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        logger.log("Accessibility check. Trusted: \(trusted). Prompt: \(prompt).")
        if trusted {
            loggedPermissionDenied = false
        }
        return trusted
    }

    func updateEdgeTolerance(_ value: Double) {
        detector.edgeTolerance = CGFloat(value)
        UserDefaults.standard.set(value, forKey: edgeToleranceKey)
        logger.log("Edge tolerance set to \(value).")
    }

    func updateMinOverlapRatio(_ value: Double) {
        detector.minOverlapRatio = CGFloat(value)
        UserDefaults.standard.set(value, forKey: overlapRatioKey)
        logger.log("Min overlap ratio set to \(value).")
    }

    func currentGroups() -> [[AXWindowInfo]] {
        guard isAccessibilityTrusted else { return [] }
        let windows = windowProvider.visibleWindows()
        return detector.groups(in: windows).filter { $0.count > 1 }
    }

    func dumpVisibleWindows() {
        guard isAccessibilityTrusted else {
            logger.log("Dump requested. Accessibility permission missing.")
            return
        }

        let windows = windowProvider.visibleWindows()
        logger.log("Visible windows: \(windows.count).")
        for window in windows {
            logger.log("Window \(windowLabel(window)) frame \(formatFrame(window.frame)).")
        }
    }

    func dumpFocusedContext() {
        guard isAccessibilityTrusted else {
            logger.log("Focused context dump requested. Accessibility permission missing.")
            return
        }

        let focusedWindow: AXWindowInfo?
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() {
            focusedWindow = focusedWindowInfo(for: app.processIdentifier, appName: app.localizedName)
        } else if let pid = lastActivePID {
            focusedWindow = focusedWindowInfo(for: pid, appName: lastActiveAppName)
        } else {
            focusedWindow = nil
        }

        guard let focusedWindow else {
            logger.log("Focused window not found. Last active pid: \(lastActivePID ?? -1).")
            return
        }

        logger.log("Focused window: \(windowLabel(focusedWindow)) frame \(formatFrame(focusedWindow.frame)).")
        let windows = windowProvider.visibleWindows()
        let adjacent = detector.adjacentWindows(to: focusedWindow, in: windows)
        if adjacent.isEmpty {
            logger.log("Adjacent windows: none.")
        } else {
            let summary = adjacent.map { windowLabel($0) }.joined(separator: ", ")
            logger.log("Adjacent windows: \(summary).")
        }

        let group = detector.group(for: focusedWindow, in: windows)
        logger.log("Group size: \(group.count).")
    }

    func dumpWindowDiagnostics() {
        windowProvider.dumpDiagnostics(logger: logger)
    }

    private func subscribeWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(frontmostAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func frontmostAppChanged(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            logger.log("Frontmost app: \(app.localizedName ?? "App").")
            if app.processIdentifier != getpid() {
                lastActivePID = app.processIdentifier
                lastActiveAppName = app.localizedName
            }
        }
        refreshObserverForFrontmostApp()
        scheduleGroupRefresh()
    }

    private func refreshObserverForFrontmostApp() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        guard app.processIdentifier != getpid() else { return }
        attachObserver(to: app.processIdentifier)
    }

    private func attachObserver(to pid: pid_t) {
        guard observedPID != pid else { return }
        detachObserver()

        var newObserver: AXObserver?
        let result = AXObserverCreate(pid, Self.axObserverCallback, &newObserver)
        guard result == .success, let observer = newObserver else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(observer, appElement, kAXMainWindowChangedNotification as CFString, refcon)

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = observer
        self.observedPID = pid
    }

    private func detachObserver() {
        guard let observer = observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
        self.observedPID = nil
    }

    private static let axObserverCallback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let controller = Unmanaged<WindowGroupController>.fromOpaque(refcon).takeUnretainedValue()
        controller.scheduleGroupRefresh()
    }

    private func scheduleGroupRefresh() {
        guard isEnabled else { return }
        guard isAccessibilityTrusted else {
            if !loggedPermissionDenied {
                logger.log("Accessibility permission missing. Grouping paused.")
                loggedPermissionDenied = true
            }
            return
        }
        guard Date() >= suppressionUntil else { return }

        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshGroup()
        }
        pendingWork = work
        eventQueue.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    private func startAutoDiagnostics() {
        if autoTimer != nil {
            return
        }

        logger.log("Auto diagnostics enabled.")
        let timer = DispatchSource.makeTimerSource(queue: eventQueue)
        timer.schedule(deadline: .now() + 1, repeating: 2, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            self?.autoDiagnosticsTick()
        }
        timer.resume()
        autoTimer = timer
    }

    private func autoDiagnosticsTick() {
        let now = Date()
        guard now.timeIntervalSince(lastAutoLog) >= 5 else { return }
        lastAutoLog = now

        guard isAccessibilityTrusted else {
            logger.log("Auto diag. Accessibility not trusted.")
            return
        }

        let activeApp = activeAppContext()
        let focused = activeApp.flatMap { focusedWindowInfo(for: $0.pid, appName: $0.name) }
        let windows = windowProvider.visibleWindows()

        let activeName = activeApp?.name ?? "n/a"
        let activePid = activeApp?.pid ?? -1
        logger.log("Auto diag. Frontmost: \(activeName) pid \(activePid). Focused: \(focused != nil). Visible windows: \(windows.count).")

        if (focused == nil || windows.isEmpty),
           now.timeIntervalSince(lastDiagnosticsLog) >= 15 {
            lastDiagnosticsLog = now
            logger.log("Auto diag. Deep dump triggered.")
            windowProvider.dumpDiagnostics(logger: logger)
        }
    }

    private func activeAppContext() -> (pid: pid_t, name: String)? {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() {
            return (app.processIdentifier, app.localizedName ?? "App")
        }
        if let pid = lastActivePID {
            return (pid, lastActiveAppName ?? "App")
        }
        return nil
    }

    private func refreshGroup() {
        guard isEnabled else { return }
        guard isAccessibilityTrusted else { return }
        guard Date() >= suppressionUntil else { return }

        guard let focusedWindow = focusedWindowInfo() else { return }
        let windows = windowProvider.visibleWindows()
        let group = detector.group(for: focusedWindow, in: windows)
        guard group.count > 1 else { return }

        let groupKey = group.map { String($0.identifier) }.sorted().joined(separator: ",")
        if groupKey == lastGroupKey, focusedWindow.identifier == lastFocusedWindowIdentifier {
            return
        }

        logger.log("Group detected. \(groupSummary(group)) Focused: \(windowLabel(focusedWindow)).")
        suppressionUntil = Date().addingTimeInterval(0.3)
        bringGroupToFront(group, focusedWindowIdentifier: focusedWindow.identifier)
        lastGroupKey = groupKey
        lastFocusedWindowIdentifier = focusedWindow.identifier
    }

    private func focusedWindowInfo() -> AXWindowInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        guard app.processIdentifier != getpid() else { return nil }
        return focusedWindowInfo(for: app.processIdentifier, appName: app.localizedName)
    }

    private func focusedWindowInfo(for pid: pid_t, appName: String?) -> AXWindowInfo? {
        let appElement = AXUIElementCreateApplication(pid)
        let windowElement: AXUIElement? =
            AXHelpers.copyAttribute(appElement, kAXFocusedWindowAttribute as CFString) ??
            AXHelpers.copyAttribute(appElement, kAXMainWindowAttribute as CFString)
        guard let windowElement else { return nil }
        guard let frame = AXHelpers.copyFrame(windowElement) else { return nil }
        let windowID = AXHelpers.copyWindowNumber(windowElement)
        let identifier = AXHelpers.elementIdentifier(windowElement)
        let name = appName ?? "App"

        return AXWindowInfo(
            identifier: identifier,
            windowID: windowID,
            pid: pid,
            appName: name,
            frame: frame,
            axElement: windowElement
        )
    }

    private func bringGroupToFront(_ group: [AXWindowInfo], focusedWindowIdentifier: UInt) {
        for window in group where window.identifier != focusedWindowIdentifier {
            AXHelpers.raise(window.axElement)
        }

        if let focused = group.first(where: { $0.identifier == focusedWindowIdentifier }) {
            AXHelpers.raise(focused.axElement)
            if let app = NSRunningApplication(processIdentifier: focused.pid) {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }
    }

    private func groupSummary(_ group: [AXWindowInfo]) -> String {
        let names = uniqueNames(from: group)
        let nameList = names.prefix(3).joined(separator: ", ")
        let suffix = names.count > 3 ? " +\(names.count - 3)" : ""
        return "\(group.count) windows: \(nameList)\(suffix)."
    }

    private func uniqueNames(from group: [AXWindowInfo]) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for window in group {
            if seen.insert(window.appName).inserted {
                names.append(window.appName)
            }
        }
        return names
    }

    private func formatFrame(_ frame: CGRect) -> String {
        String(
            format: "x%.0f y%.0f w%.0f h%.0f",
            frame.origin.x,
            frame.origin.y,
            frame.size.width,
            frame.size.height
        )
    }

    private func windowLabel(_ window: AXWindowInfo) -> String {
        if let windowID = window.windowID {
            return "\(window.appName)#\(windowID)"
        }
        return "\(window.appName)#\(window.identifier)"
    }
}
