import AppKit
import ApplicationServices

final class WindowGroupController {
    private let eventQueue = DispatchQueue(label: "WindowGroups.eventQueue")
    private let eventQueueKey = DispatchSpecificKey<Void>()
    private let windowProvider = WindowListProvider()
    private let logger = AppLogger.shared
    private let layoutGroups = LayoutGroupState()
    private var detector: TilingDetector

    private var suppressionUntil = Date.distantPast
    private var pendingWork: DispatchWorkItem?
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var lastGroupKey: String?
    private var lastTriggeredFocusedWindowIdentifier: UInt?
    private var previousFocusedWindowIdentifier: UInt?
    private var lastActivePID: pid_t?
    private var lastActiveAppName: String?
    private var autoTimer: DispatchSourceTimer?
    private var lastAutoLog = Date.distantPast
    private var lastDiagnosticsLog = Date.distantPast
    private var manualModeEnabled = false
    private var manualGroupID: UUID?
    private var manualMemberWindowIDs = Set<Int>()
    private var manualMemberIdentifiers = Set<UInt>()
    private var manualMemberElementPointers = Set<UInt>()

    private let enabledKey = "WindowGroups.enabled"
    private let edgeToleranceKey = "WindowGroups.edgeTolerance"
    private let overlapRatioKey = "WindowGroups.minOverlapRatio"
    private let nonActivatingRaiseKey = "WindowGroups.nonActivatingRaise"
    private let includeAllSpacesKey = "WindowGroups.includeAllSpaces"
    private let defaultEdgeTolerance: CGFloat = 8
    private let defaultOverlapRatio: CGFloat = 0.25

    private var loggedPermissionDenied = false
    private var loggedOrdererUnavailable = false
    private var loggedFocusedMappingMissing = false
    private var loggedNeighborMappingMissing = false

    var onGroupChange: (([AXWindowInfo]) -> Void)?

    init() {
        eventQueue.setSpecific(key: eventQueueKey, value: ())
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

    var isNonActivatingRaiseEnabled: Bool {
        UserDefaults.standard.object(forKey: nonActivatingRaiseKey) as? Bool ?? false
    }

    var isIncludeAllSpacesEnabled: Bool {
        UserDefaults.standard.object(forKey: includeAllSpacesKey) as? Bool ?? false
    }

    var isManualModeEnabled: Bool {
        withEventQueue { manualModeEnabled }
    }

    func start() {
        let trusted = requestAccessibility(prompt: true)
        logger.log("Start. Accessibility trusted: \(trusted).")
        logger.log("Tiling config. Edge tolerance: \(edgeToleranceValue). Min overlap: \(minOverlapRatioValue).")
        logger.log("Log file: \(logger.logFileURL.path).")
        logger.log("Non-activating raise: \(isNonActivatingRaiseEnabled).")
        logger.log("Include other spaces: \(isIncludeAllSpacesEnabled).")
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

    func setNonActivatingRaiseEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: nonActivatingRaiseKey)
        logger.log("Non-activating raise set to \(enabled).")
    }

    func setIncludeAllSpacesEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: includeAllSpacesKey)
        logger.log("Include other spaces set to \(enabled).")
    }

    func setManualModeEnabled(_ enabled: Bool) {
        withEventQueue {
            manualModeEnabled = enabled
            manualGroupID = nil
            manualMemberWindowIDs.removeAll()
            manualMemberIdentifiers.removeAll()
            manualMemberElementPointers.removeAll()
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
            layoutGroups.update(windows: windows)
            let existingID = layoutGroups.groupID(for: focusedWindow.identifier)

            if let manualGroupID {
                layoutGroups.addWindow(focusedWindow.identifier, toGroup: manualGroupID)
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

            let groupID = existingID ?? layoutGroups.ensureGroup(for: focusedWindow.identifier)
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
            let memberWindowIDs = manualMemberWindowIDs
            let memberIdentifiers = manualMemberIdentifiers
            let memberElementPointers = manualMemberElementPointers
            manualModeEnabled = false
            manualGroupID = nil
            manualMemberWindowIDs.removeAll()
            manualMemberIdentifiers.removeAll()
            manualMemberElementPointers.removeAll()
            logger.log("Manual mode disabled.")

            guard let groupID else {
                logger.log("Manual finish. No group created.")
                return
            }

            let addedCount = memberWindowIDs.count + memberIdentifiers.count + memberElementPointers.count
            guard addedCount > 1 else {
                logger.log("Manual finish. Not enough windows added to group \(shortGroupID(groupID)).")
                return
            }

            let windows = visibleWindows(includeOffscreen: true)
            var groupWindows: [AXWindowInfo] = []
            groupWindows.reserveCapacity(addedCount)
            for window in windows {
                if let windowID = window.windowID, memberWindowIDs.contains(windowID) {
                    groupWindows.append(window)
                    continue
                }
                if memberIdentifiers.contains(window.identifier) {
                    groupWindows.append(window)
                    continue
                }
                let pointer = UInt(bitPattern: Unmanaged.passUnretained(window.axElement).toOpaque())
                if memberElementPointers.contains(pointer) {
                    groupWindows.append(window)
                }
            }

            for window in groupWindows {
                layoutGroups.addWindow(window.identifier, toGroup: groupID)
            }
            if groupWindows.count > 1 {
                logger.log("Manual finish. \(groupSummary(groupWindows)) Windows: \(groupWindowList(groupWindows)).")
                if let focused = focusedWindowInfo(),
                   groupWindows.contains(where: { $0.identifier == focused.identifier }) {
                    bringGroupToFront(groupWindows, focusedWindowIdentifier: focused.identifier)
                }
            } else {
                logger.log("Manual finish. Group \(shortGroupID(groupID)) created with \(addedCount) members. Visible match: \(groupWindows.count).")
            }
        }
    }

    func currentGroups() -> [[AXWindowInfo]] {
        guard isAccessibilityTrusted else { return [] }
        return eventQueue.sync {
            let windows = visibleWindows()
            return layoutGroups.groups(in: windows).filter { $0.count > 1 }
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
        let (adjacent, group, fallbackGroup) = eventQueue.sync {
            let windows = visibleWindows()
            let adjacent = detector.adjacentWindows(to: focusedWindow, in: windows)
            let group = layoutGroups.group(for: focusedWindow, in: windows)
            if group.count <= 1 {
                let fallback = detector.group(for: focusedWindow, in: windows)
                return (adjacent, fallback, fallback.count > 1 ? fallback : nil)
            }
            return (adjacent, group, nil)
        }
        if adjacent.isEmpty {
            logger.log("Adjacent windows: none.")
        } else {
            let summary = adjacent.map { windowLabel($0) }.joined(separator: ", ")
            logger.log("Adjacent windows: \(summary).")
        }

        logger.log("Group size: \(group.count).")
        if let fallbackGroup, fallbackGroup.count > 1 {
            logger.log("Fallback group size: \(fallbackGroup.count).")
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
        guard isAccessibilityTrusted else {
            logger.log("Auto diag. Accessibility not trusted.")
            return
        }

        let activeApp = activeAppContext()
        let focused = activeApp.flatMap { focusedWindowInfo(for: $0.pid, appName: $0.name) }
        let windows = visibleWindows()
        _ = layoutGroups.groups(in: windows, now: now)

        guard now.timeIntervalSince(lastAutoLog) >= 5 else { return }
        lastAutoLog = now

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
        defer { previousFocusedWindowIdentifier = focusedWindow.identifier }
        let windows = visibleWindows(includeOffscreen: manualModeEnabled)
        layoutGroups.update(windows: windows)
        var pairingDecision: LayoutGroupState.PairDecision?
        if !manualModeEnabled {
            let focusedSide = detector.snapSide(for: focusedWindow)
            let focusedSideLabel = snapSideLabel(focusedSide)
            let focusedScreenIndex = detector.screenIndex(for: focusedWindow.frame)
            let snappedOnScreen = focusedScreenIndex.map { index in
                windows.filter {
                    detector.screenIndex(for: $0.frame) == index && detector.snapSide(for: $0) != .none
                }
            } ?? []

            if focusedSide == .none {
                logger.log("Pairing check. Focused: \(windowLabel(focusedWindow)) Side: none -> skip: focused not snapped. (snapped on screen: \(snappedOnScreen.count))")
            } else if snappedOnScreen.count == 2,
                      let other = snappedOnScreen.first(where: { $0.identifier != focusedWindow.identifier }) {
                let decision = layoutGroups.registerPairIfEligible(
                    focused: focusedWindow,
                    previous: other,
                    detector: detector
                )
                pairingDecision = decision
                logger.log("Pairing check. Focused: \(windowLabel(focusedWindow)) Side: \(focusedSideLabel) Prev: \(windowLabel(other)) -> \(decision.reason). (two-snapped)")
            } else if snappedOnScreen.count > 2 {
                if let previousID = previousFocusedWindowIdentifier,
                   previousID != focusedWindow.identifier,
                   let previousWindow = windows.first(where: { $0.identifier == previousID }) {
                    let previousSide = detector.snapSide(for: previousWindow)
                    if previousSide == .none {
                        logger.log("Pairing check. Focused: \(windowLabel(focusedWindow)) Side: \(focusedSideLabel) Prev: \(windowLabel(previousWindow)) -> skip: previous not snapped. (snapped on screen: \(snappedOnScreen.count))")
                    } else {
                        let decision = layoutGroups.registerPairIfEligible(
                            focused: focusedWindow,
                            previous: previousWindow,
                            detector: detector
                        )
                        pairingDecision = decision
                        logger.log("Pairing check. Focused: \(windowLabel(focusedWindow)) Side: \(focusedSideLabel) Prev: \(windowLabel(previousWindow)) -> \(decision.reason). (ambiguous, snapped on screen: \(snappedOnScreen.count))")
                    }
                } else {
                    logger.log("Pairing check. Focused: \(windowLabel(focusedWindow)) Side: \(focusedSideLabel) Prev: none -> skip: ambiguous. (snapped on screen: \(snappedOnScreen.count))")
                }
            } else {
                logger.log("Pairing check. Focused: \(windowLabel(focusedWindow)) Side: \(focusedSideLabel) Prev: none -> skip: not enough snapped. (snapped on screen: \(snappedOnScreen.count))")
            }
        }
        let group = layoutGroups.group(for: focusedWindow, in: windows, updated: true)
        guard group.count > 1 else { return }

        let groupKey = group.map { String($0.identifier) }.sorted().joined(separator: ",")
        if groupKey == lastGroupKey, focusedWindow.identifier == lastTriggeredFocusedWindowIdentifier {
            return
        }

        let reason = pairingDecision?.formed == true ? pairingDecision?.reason ?? "paired" : "existing pair"
        logger.log("Group detected. \(groupSummary(group)) Focused: \(windowLabel(focusedWindow)). Reason: \(reason).")
        logger.log("Group windows: \(groupWindowList(group)).")
        DispatchQueue.main.async { [weak self] in
            self?.onGroupChange?(group)
        }
        suppressionUntil = Date().addingTimeInterval(0.3)
        bringGroupToFront(group, focusedWindowIdentifier: focusedWindow.identifier)
        lastGroupKey = groupKey
        lastTriggeredFocusedWindowIdentifier = focusedWindow.identifier
    }

    private func focusedWindowInfo() -> AXWindowInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        guard app.processIdentifier != getpid() else { return nil }
        return focusedWindowInfo(for: app.processIdentifier, appName: app.localizedName)
    }

    private func visibleWindows(includeOffscreen: Bool? = nil) -> [AXWindowInfo] {
        let useOffscreen = includeOffscreen ?? isIncludeAllSpacesEnabled
        return windowProvider.visibleWindows(includeOffscreen: useOffscreen)
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
        guard let focused = group.first(where: { $0.identifier == focusedWindowIdentifier }) else { return }

        if isNonActivatingRaiseEnabled, raiseGroupWithoutActivation(group, focused: focused) {
            return
        }

        for window in group where window.identifier != focusedWindowIdentifier {
            AXHelpers.raise(window.axElement)
        }

        AXHelpers.raise(focused.axElement)
        if let app = NSRunningApplication(processIdentifier: focused.pid) {
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

    private func snapSideLabel(_ side: TilingDetector.SnapSide) -> String {
        switch side {
        case .left:
            return "left"
        case .right:
            return "right"
        case .none:
            return "none"
        }
    }

    private func shortGroupID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    private func recordManualMember(_ window: AXWindowInfo) {
        if let windowID = window.windowID {
            manualMemberWindowIDs.insert(windowID)
        } else {
            manualMemberIdentifiers.insert(window.identifier)
        }
        let pointer = UInt(bitPattern: Unmanaged.passUnretained(window.axElement).toOpaque())
        manualMemberElementPointers.insert(pointer)
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
