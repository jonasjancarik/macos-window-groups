import AppKit
import ApplicationServices

final class WindowGroupController {
    private let eventQueue = DispatchQueue(label: "WindowGroups.eventQueue")
    private let eventQueueKey = DispatchSpecificKey<Void>()
    private let windowProvider = WindowListProvider()
    private let logger = AppLogger.shared
    private let layoutGroups = LayoutGroupState()

    private var suppressionUntil = Date.distantPast
    private var pendingWork: DispatchWorkItem?
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var lastGroupKey: String?
    private var lastTriggeredFocusedWindowKey: WindowKey?
    private var lastActivePID: pid_t?
    private var lastActiveAppName: String?
    private var manualModeEnabled = false
    private var manualGroupID: UUID?
    private var manualMemberKeys = Set<WindowKey>()

    private var loggedPermissionDenied = false
    private var loggedOrdererUnavailable = false
    private var loggedFocusedMappingMissing = false
    private var loggedNeighborMappingMissing = false

    var onGroupChange: (([AXWindowInfo]) -> Void)?

    init() {
        eventQueue.setSpecific(key: eventQueueKey, value: ())
    }

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    var isManualModeEnabled: Bool {
        withEventQueue { manualModeEnabled }
    }

    func start() {
        let trusted = requestAccessibility(prompt: true)
        logger.log("Start. Accessibility trusted: \(trusted).")
        logger.log("Log file: \(logger.logFileURL.path).")
        subscribeWorkspaceNotifications()
        refreshObserverForFrontmostApp()
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

    func setManualModeEnabled(_ enabled: Bool) {
        withEventQueue {
            manualModeEnabled = enabled
            manualGroupID = nil
            manualMemberKeys.removeAll()
            logger.log("Manual mode \(enabled ? "enabled" : "disabled").")
        }
    }

    func toggleManualMode() {
        setManualModeEnabled(!isManualModeEnabled)
    }

    func addFocusedToManualGroup() {
        withEventQueue {
            guard manualModeEnabled else {
                logger.log("Manual add skipped: manual mode off.")
                return
            }
            guard isAccessibilityTrusted else {
                logger.log("Manual add skipped: accessibility not trusted.")
                return
            }
            guard let focusedWindow = focusedWindowInfo() else {
                logger.log("Manual add skipped: focused window missing.")
                return
            }
            let windows = visibleWindows(includeOffscreen: true)
            logGroupInvalidations(layoutGroups.update(windows: windows))
            let existingID = layoutGroups.groupID(for: focusedWindow.key)

            if let manualGroupID {
                layoutGroups.addWindow(focusedWindow.key, toGroup: manualGroupID)
                recordManualMember(focusedWindow)
                let note: String
                if existingID == manualGroupID {
                    note = "already in group"
                } else if existingID == nil {
                    note = "added"
                } else {
                    note = "moved from other group"
                }
                logger.log("Manual add. \(windowLabel(focusedWindow)) -> group \(shortGroupID(manualGroupID)). \(note).")
                return
            }

            let groupID = existingID ?? layoutGroups.ensureGroup(for: focusedWindow.key)
            manualGroupID = groupID
            recordManualMember(focusedWindow)
            let note = existingID != nil ? "using existing group" : "new group"
            logger.log("Manual add. \(windowLabel(focusedWindow)) -> group \(shortGroupID(groupID)). \(note).")
        }
    }

    func finishManualGroup() {
        withEventQueue {
            guard manualModeEnabled else { return }
            let groupID = manualGroupID
            let memberKeys = manualMemberKeys
            manualModeEnabled = false
            manualGroupID = nil
            manualMemberKeys.removeAll()
            logger.log("Manual mode disabled.")

            guard let groupID else {
                logger.log("Manual finish. No group created.")
                return
            }

            let addedCount = memberKeys.count
            guard addedCount > 1 else {
                logger.log("Manual finish. Not enough windows added to group \(shortGroupID(groupID)).")
                return
            }

            let windows = visibleWindows(includeOffscreen: true)
            let groupWindows = windows.filter { memberKeys.contains($0.key) }

            for window in groupWindows {
                layoutGroups.assignWindow(window, toGroup: groupID)
            }
            if groupWindows.count > 1 {
                logger.log("Manual finish. \(groupSummary(groupWindows)) Windows: \(groupWindowList(groupWindows)).")
                if let focused = focusedWindowInfo(),
                   groupWindows.contains(where: { $0.key == focused.key }) {
                    suppressionUntil = Date().addingTimeInterval(0.3)
                    bringGroupToFront(groupWindows, focusedWindowKey: focused.key)
                }
            } else if groupWindows.isEmpty {
                let keyList = memberKeys.map { $0.description }.sorted().joined(separator: ", ")
                logger.log("Manual finish. Group \(shortGroupID(groupID)) created with \(addedCount) members. Visible match: 0. Keys: \(keyList).")
            } else {
                logger.log("Manual finish. Group \(shortGroupID(groupID)) created with \(addedCount) members. Visible match: \(groupWindows.count).")
            }
        }
    }

    func currentGroups() -> [[AXWindowInfo]] {
        guard isAccessibilityTrusted else { return [] }
        return eventQueue.sync {
            let windows = visibleWindows(includeOffscreen: manualModeEnabled)
            logGroupInvalidations(layoutGroups.update(windows: windows))
            return layoutGroups.groups(in: windows, updated: true).filter { $0.count > 1 }
        }
    }

    func isFocusedWindowGrouped() -> Bool {
        guard isAccessibilityTrusted else { return false }
        return eventQueue.sync {
            guard let focusedWindow = focusedWindowInfo() else { return false }
            let windows = visibleWindows(includeOffscreen: manualModeEnabled)
            logGroupInvalidations(layoutGroups.update(windows: windows))
            return layoutGroups.group(for: focusedWindow, in: windows, updated: true).count > 1
        }
    }

    func removeFocusedWindowFromGroup() {
        withEventQueue {
            guard isAccessibilityTrusted else {
                logger.log("Remove focused from group skipped: accessibility not trusted.")
                return
            }
            guard let focusedWindow = focusedWindowInfo() else {
                logger.log("Remove focused from group skipped: focused window missing.")
                return
            }

            let windows = visibleWindows(includeOffscreen: manualModeEnabled)
            logGroupInvalidations(layoutGroups.update(windows: windows))
            guard let mutation = layoutGroups.removeWindow(focusedWindow.key) else {
                logger.log("Remove focused from group skipped: focused window not in a stored group.")
                return
            }

            lastGroupKey = nil
            lastTriggeredFocusedWindowKey = nil
            manualMemberKeys.remove(focusedWindow.key)
            if manualGroupID == mutation.groupID, mutation.membersAfter.isEmpty {
                manualGroupID = nil
                manualMemberKeys.subtract(mutation.membersBefore)
            }

            if mutation.membersAfter.count > 1 {
                let remaining = mutation.membersAfter.map(\.description).joined(separator: ", ")
                logger.log(
                    "Stored group \(shortGroupID(mutation.groupID)) updated. Removed \(windowLabel(focusedWindow)). Remaining members: \(remaining)."
                )
            } else {
                let previous = mutation.membersBefore.map(\.description).joined(separator: ", ")
                logger.log(
                    "Stored group \(shortGroupID(mutation.groupID)) deleted. Reason: removing \(windowLabel(focusedWindow)) left fewer than 2 members. Previous members: \(previous)."
                )
            }
        }
    }

    func deleteFocusedWindowGroup() {
        withEventQueue {
            guard isAccessibilityTrusted else {
                logger.log("Delete group skipped: accessibility not trusted.")
                return
            }
            guard let focusedWindow = focusedWindowInfo() else {
                logger.log("Delete group skipped: focused window missing.")
                return
            }

            let windows = visibleWindows(includeOffscreen: manualModeEnabled)
            logGroupInvalidations(layoutGroups.update(windows: windows))
            guard let mutation = layoutGroups.clearGroup(containing: focusedWindow.key) else {
                logger.log("Delete group skipped: focused window not in a stored group.")
                return
            }

            lastGroupKey = nil
            lastTriggeredFocusedWindowKey = nil
            if manualGroupID == mutation.groupID {
                manualGroupID = nil
            }
            manualMemberKeys.subtract(mutation.membersBefore)

            let members = mutation.membersBefore.map(\.description).joined(separator: ", ")
            logger.log("Stored group \(shortGroupID(mutation.groupID)) deleted. Members: \(members).")
        }
    }

    func dumpVisibleWindows() {
        guard isAccessibilityTrusted else {
            logger.log("Dump requested. Accessibility permission missing.")
            return
        }

        let windows = visibleWindows()
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
        let group = eventQueue.sync {
            let windows = visibleWindows(includeOffscreen: true)
            return layoutGroups.group(for: focusedWindow, in: windows)
        }

        if group.count <= 1 {
            logger.log("Stored group: none.")
        } else {
            logger.log("Stored group. \(groupSummary(group)) Windows: \(groupWindowList(group)).")
        }
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
        AXObserverAddNotification(observer, appElement, kAXWindowMovedNotification as CFString, refcon)
        AXObserverAddNotification(observer, appElement, kAXWindowResizedNotification as CFString, refcon)

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

    private func refreshGroup() {
        guard isAccessibilityTrusted else { return }
        guard Date() >= suppressionUntil else { return }

        guard let focusedWindow = focusedWindowInfo() else {
            lastGroupKey = nil
            lastTriggeredFocusedWindowKey = nil
            return
        }
        let windows = visibleWindows(includeOffscreen: manualModeEnabled)
        logGroupInvalidations(layoutGroups.update(windows: windows))
        let group = layoutGroups.group(for: focusedWindow, in: windows, updated: true)
        guard group.count > 1 else {
            lastGroupKey = nil
            lastTriggeredFocusedWindowKey = nil
            return
        }

        let groupKey = group.map { $0.key.description }.sorted().joined(separator: ",")
        if groupKey == lastGroupKey, focusedWindow.key == lastTriggeredFocusedWindowKey {
            return
        }

        logger.log("Stored group activated. \(groupSummary(group)) Focused: \(windowLabel(focusedWindow)).")
        logger.log("Group windows: \(groupWindowList(group)).")
        DispatchQueue.main.async { [weak self] in
            self?.onGroupChange?(group)
        }
        suppressionUntil = Date().addingTimeInterval(0.3)
        bringGroupToFront(group, focusedWindowKey: focusedWindow.key)
        lastGroupKey = groupKey
        lastTriggeredFocusedWindowKey = focusedWindow.key
    }

    private func focusedWindowInfo() -> AXWindowInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        guard app.processIdentifier != getpid() else { return nil }
        return focusedWindowInfo(for: app.processIdentifier, appName: app.localizedName)
    }

    private func visibleWindows(includeOffscreen: Bool = false) -> [AXWindowInfo] {
        windowProvider.visibleWindows(includeOffscreen: includeOffscreen)
    }

    private func focusedWindowInfo(for pid: pid_t, appName: String?) -> AXWindowInfo? {
        let appElement = AXUIElementCreateApplication(pid)
        let windowElement: AXUIElement? =
            AXHelpers.copyAttribute(appElement, kAXFocusedWindowAttribute as CFString) ??
            AXHelpers.copyAttribute(appElement, kAXMainWindowAttribute as CFString)
        guard let windowElement else { return nil }
        guard let frame = AXHelpers.copyFrame(windowElement) else { return nil }
        var windowID = AXHelpers.copyWindowNumber(windowElement)
        let identifier = AXHelpers.elementIdentifier(windowElement)
        let name = appName ?? "App"

        if windowID == nil {
            let temp = AXWindowInfo(
                identifier: identifier,
                windowID: nil,
                pid: pid,
                appName: name,
                frame: frame,
                axElement: windowElement
            )
            let entries = windowProvider.cgWindowEntries()
            if let matched = windowProvider.matchCGWindowID(for: temp, in: entries) {
                windowID = Int(matched)
            }
        }

        return AXWindowInfo(
            identifier: identifier,
            windowID: windowID,
            pid: pid,
            appName: name,
            frame: frame,
            axElement: windowElement
        )
    }

    private func bringGroupToFront(_ group: [AXWindowInfo], focusedWindowKey: WindowKey) {
        guard let focused = group.first(where: { $0.key == focusedWindowKey }) else {
            logger.log("Bring group skipped: focused window not in group.")
            return
        }

        let groupByPID = Dictionary(grouping: group, by: { $0.pid })
        let shouldUseOrderer = groupByPID.count > 1
        if shouldUseOrderer, raiseGroupWithoutActivation(group, focused: focused) {
            return
        }
        if shouldUseOrderer {
            logger.log("Non-activating raise failed; falling back to AXRaise.")
        }

        func raiseWindows(_ windows: [AXWindowInfo]) {
            for window in windows {
                let result = AXHelpers.raise(window.axElement)
                if result != .success {
                    logger.log("Raise failed for \(windowLabel(window)): \(result.rawValue).")
                }
            }
        }

        let others = group.filter { $0.key != focusedWindowKey }
        raiseWindows(others)
        let focusedResult = AXHelpers.raise(focused.axElement)
        if focusedResult != .success {
            logger.log("Raise failed for focused \(windowLabel(focused)): \(focusedResult.rawValue).")
        }
        if let app = NSRunningApplication(processIdentifier: focused.pid),
           NSWorkspace.shared.frontmostApplication?.processIdentifier != focused.pid {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    private func raiseGroupWithoutActivation(_ group: [AXWindowInfo], focused: AXWindowInfo) -> Bool {
        guard let orderer = CGSWindowOrderer.shared else {
            if !loggedOrdererUnavailable {
                logger.log("Non-activating raise unavailable (CGS symbols missing).")
                loggedOrdererUnavailable = true
            }
            return false
        }

        let cgEntries = windowProvider.cgWindowEntries()
        guard let focusedID = windowProvider.matchCGWindowID(for: focused, in: cgEntries) else {
            if !loggedFocusedMappingMissing {
                logger.log("Non-activating raise missing CGWindowID for focused \(windowLabel(focused)).")
                loggedFocusedMappingMissing = true
            }
            return false
        }

        var raisedCount = 0
        for window in group where window.identifier != focused.identifier {
            guard let windowID = windowProvider.matchCGWindowID(for: window, in: cgEntries) else {
                if !loggedNeighborMappingMissing {
                    logger.log("Non-activating raise missing CGWindowID for neighbor \(windowLabel(window)).")
                    loggedNeighborMappingMissing = true
                }
                continue
            }
            if orderer.orderAboveAll(windowID) {
                raisedCount += 1
            }
        }

        _ = orderer.orderAboveAll(focusedID)
        return raisedCount > 0
    }

    private func groupSummary(_ group: [AXWindowInfo]) -> String {
        let names = uniqueNames(from: group)
        let nameList = names.prefix(3).joined(separator: ", ")
        let suffix = names.count > 3 ? " +\(names.count - 3)" : ""
        return "\(group.count) windows: \(nameList)\(suffix)."
    }

    private func groupWindowList(_ group: [AXWindowInfo]) -> String {
        group.map { windowLabel($0) }.joined(separator: ", ")
    }

    private func shortGroupID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    private func recordManualMember(_ window: AXWindowInfo) {
        manualMemberKeys.insert(window.key)
    }

    private func logGroupInvalidations(_ invalidations: [LayoutGroupState.GroupInvalidation]) {
        for invalidation in invalidations {
            let memberList = invalidation.members.map(\.description).joined(separator: ", ")
            switch invalidation.reason {
            case .frameChanged(let windowKey, let oldFrame, let newFrame):
                logger.log(
                    "Stored group \(shortGroupID(invalidation.groupID)) cleared. Reason: \(windowKey.description) moved/resized from \(formatFrame(oldFrame)) to \(formatFrame(newFrame)). Members: \(memberList)."
                )
            case .windowMissing(let windowKey):
                logger.log(
                    "Stored group \(shortGroupID(invalidation.groupID)) cleared. Reason: \(windowKey.description) disappeared from the tracked window set. Members: \(memberList)."
                )
            }
        }
    }

    private func withEventQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: eventQueueKey) != nil {
            return work()
        }
        return eventQueue.sync(execute: work)
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
