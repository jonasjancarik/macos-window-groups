import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = WindowGroupController()
    private let logger = AppLogger.shared
    private var statusItem: NSStatusItem?
    private var enableItem: NSMenuItem?
    private var permissionItem: NSMenuItem?
    private var groupsItem: NSMenuItem?
    private var logsItem: NSMenuItem?
    private var edgeToleranceSlider: NSSlider?
    private var overlapSlider: NSSlider?
    private var edgeValueLabel: NSTextField?
    private var overlapValueLabel: NSTextField?
    private var nonActivatingItem: NSMenuItem?
    private var includeSpacesItem: NSMenuItem?
    private var debugOverlayItem: NSMenuItem?
    private var debugOverlayController: DebugOverlayController?
    private var manualModeItem: NSMenuItem?
    private var manualAddItem: NSMenuItem?
    private var manualFinishItem: NSMenuItem?
    private var keyMonitor: Any?
    private var indicatorResetWork: DispatchWorkItem?
    private let statusTitle = "WG"

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.onGroupChange = { [weak self] group in
            self?.showGroupIndicator(for: group)
        }
        controller.start()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = statusTitle
        statusItem?.menu = buildMenu()
        startKeyMonitor()
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        let next = sender.state == .off
        controller.setEnabled(next)
        sender.state = next ? .on : .off
    }

    @objc private func requestAccessibility(_ sender: NSMenuItem) {
        _ = controller.requestAccessibility(prompt: true)
        refreshPermissionMenuItem()
    }

    @objc private func toggleNonActivatingRaise(_ sender: NSMenuItem) {
        let next = sender.state == .off
        controller.setNonActivatingRaiseEnabled(next)
        sender.state = next ? .on : .off
    }

    @objc private func toggleIncludeSpaces(_ sender: NSMenuItem) {
        let next = sender.state == .off
        controller.setIncludeAllSpacesEnabled(next)
        sender.state = next ? .on : .off
    }

    @objc private func toggleDebugOverlay(_ sender: NSMenuItem) {
        let overlay = debugOverlayController ?? DebugOverlayController()
        debugOverlayController = overlay
        overlay.toggle()
        sender.state = overlay.isVisible ? .on : .off
    }

    @objc private func toggleManualMode(_ sender: NSMenuItem) {
        controller.toggleManualMode()
        syncManualModeToggle()
    }

    @objc private func addFocusedToManualGroup(_ sender: NSMenuItem) {
        controller.addFocusedToManualGroup()
    }

    @objc private func finishManualGroup(_ sender: NSMenuItem) {
        controller.finishManualGroup()
        syncManualModeToggle()
    }

    @objc private func edgeToleranceChanged(_ sender: NSSlider) {
        controller.updateEdgeTolerance(sender.doubleValue)
        edgeValueLabel?.stringValue = formatEdgeValue(sender.doubleValue)
    }

    @objc private func overlapChanged(_ sender: NSSlider) {
        controller.updateMinOverlapRatio(sender.doubleValue)
        overlapValueLabel?.stringValue = formatOverlapValue(sender.doubleValue)
    }

    @objc private func copyLogs(_ sender: NSMenuItem) {
        let logs = logger.recentEntries(limit: 100).joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(logs, forType: .string)
    }

    @objc private func openLogFile(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(logger.logFileURL)
    }

    @objc private func clearLogs(_ sender: NSMenuItem) {
        logger.clear()
    }

    @objc private func dumpVisibleWindows(_ sender: NSMenuItem) {
        controller.dumpVisibleWindows()
    }

    @objc private func dumpFocusedContext(_ sender: NSMenuItem) {
        controller.dumpFocusedContext()
    }

    @objc private func dumpDiagnostics(_ sender: NSMenuItem) {
        controller.dumpWindowDiagnostics()
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(nil)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let enableItem = NSMenuItem(
            title: "Enable Snap Groups",
            action: #selector(toggleEnabled(_:)),
            keyEquivalent: ""
        )
        enableItem.state = controller.isEnabled ? .on : .off
        enableItem.target = self
        menu.addItem(enableItem)
        self.enableItem = enableItem

        let nonActivatingItem = NSMenuItem(
            title: "Keep Cmd-Tab Order (experimental)",
            action: #selector(toggleNonActivatingRaise(_:)),
            keyEquivalent: ""
        )
        nonActivatingItem.state = controller.isNonActivatingRaiseEnabled ? .on : .off
        nonActivatingItem.target = self
        menu.addItem(nonActivatingItem)
        self.nonActivatingItem = nonActivatingItem

        let includeSpacesItem = NSMenuItem(
            title: "Include other spaces (experimental)",
            action: #selector(toggleIncludeSpaces(_:)),
            keyEquivalent: ""
        )
        includeSpacesItem.state = controller.isIncludeAllSpacesEnabled ? .on : .off
        includeSpacesItem.target = self
        menu.addItem(includeSpacesItem)
        self.includeSpacesItem = includeSpacesItem

        let manualModeItem = NSMenuItem(
            title: "Manual Grouping Mode (⌃⌥G)",
            action: #selector(toggleManualMode(_:)),
            keyEquivalent: ""
        )
        manualModeItem.state = controller.isManualModeEnabled ? .on : .off
        manualModeItem.target = self
        menu.addItem(manualModeItem)
        self.manualModeItem = manualModeItem

        let manualAddItem = NSMenuItem(
            title: "Add Focused to Manual Group (Enter)",
            action: #selector(addFocusedToManualGroup(_:)),
            keyEquivalent: ""
        )
        manualAddItem.target = self
        manualAddItem.isEnabled = controller.isManualModeEnabled
        menu.addItem(manualAddItem)
        self.manualAddItem = manualAddItem

        let manualFinishItem = NSMenuItem(
            title: "Finish Manual Group (⌃⌥⇧G)",
            action: #selector(finishManualGroup(_:)),
            keyEquivalent: ""
        )
        manualFinishItem.target = self
        manualFinishItem.isEnabled = controller.isManualModeEnabled
        menu.addItem(manualFinishItem)
        self.manualFinishItem = manualFinishItem

        let edgeItem = buildSliderItem(
            title: "Edge tolerance",
            min: 2,
            max: 40,
            value: controller.edgeToleranceValue,
            action: #selector(edgeToleranceChanged(_:)),
            assign: { slider, label in
                self.edgeToleranceSlider = slider
                self.edgeValueLabel = label
            }
        )
        menu.addItem(edgeItem)

        let overlapItem = buildSliderItem(
            title: "Min overlap ratio",
            min: 0.1,
            max: 0.9,
            value: controller.minOverlapRatioValue,
            action: #selector(overlapChanged(_:)),
            assign: { slider, label in
                self.overlapSlider = slider
                self.overlapValueLabel = label
            }
        )
        menu.addItem(overlapItem)

        menu.addItem(.separator())

        let groupsItem = NSMenuItem(title: "Groups", action: nil, keyEquivalent: "")
        groupsItem.submenu = NSMenu()
        menu.addItem(groupsItem)
        self.groupsItem = groupsItem

        let logsItem = NSMenuItem(title: "Logs", action: nil, keyEquivalent: "")
        logsItem.submenu = NSMenu()
        menu.addItem(logsItem)
        self.logsItem = logsItem

        let debugOverlayItem = NSMenuItem(
            title: "Debug Overlay",
            action: #selector(toggleDebugOverlay(_:)),
            keyEquivalent: ""
        )
        debugOverlayItem.target = self
        debugOverlayItem.state = debugOverlayController?.isVisible == true ? .on : .off
        menu.addItem(debugOverlayItem)
        self.debugOverlayItem = debugOverlayItem

        let permissionItem = NSMenuItem(
            title: "Request Accessibility Permission",
            action: #selector(requestAccessibility(_:)),
            keyEquivalent: ""
        )
        permissionItem.target = self
        menu.addItem(permissionItem)
        self.permissionItem = permissionItem

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(quitApp(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        refreshPermissionMenuItem()
        syncSliderValues()
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshPermissionMenuItem()
        syncSliderValues()
        syncNonActivatingToggle()
        syncIncludeSpacesToggle()
        syncDebugOverlayToggle()
        syncManualModeToggle()
        refreshGroupsMenu()
        refreshLogsMenu()
    }

    private func refreshPermissionMenuItem() {
        let trusted = controller.isAccessibilityTrusted
        permissionItem?.isEnabled = !trusted
        permissionItem?.title = trusted
            ? "Accessibility Permission Granted"
            : "Request Accessibility Permission"
    }

    private func syncSliderValues() {
        let edgeValue = controller.edgeToleranceValue
        edgeToleranceSlider?.doubleValue = edgeValue
        edgeValueLabel?.stringValue = formatEdgeValue(edgeValue)

        let overlapValue = controller.minOverlapRatioValue
        overlapSlider?.doubleValue = overlapValue
        overlapValueLabel?.stringValue = formatOverlapValue(overlapValue)
    }

    private func syncNonActivatingToggle() {
        nonActivatingItem?.state = controller.isNonActivatingRaiseEnabled ? .on : .off
    }

    private func syncIncludeSpacesToggle() {
        includeSpacesItem?.state = controller.isIncludeAllSpacesEnabled ? .on : .off
    }

    private func syncDebugOverlayToggle() {
        debugOverlayItem?.state = debugOverlayController?.isVisible == true ? .on : .off
    }

    private func syncManualModeToggle() {
        let enabled = controller.isManualModeEnabled
        manualModeItem?.state = enabled ? .on : .off
        manualAddItem?.isEnabled = enabled
        manualFinishItem?.isEnabled = enabled
    }

    private func refreshGroupsMenu() {
        guard let submenu = groupsItem?.submenu else { return }
        submenu.removeAllItems()

        let groups = controller.currentGroups()
        if groups.isEmpty {
            let item = NSMenuItem(title: "No groups detected", action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
            return
        }

        for (index, group) in groups.enumerated() {
            let title = "Group \(index + 1): \(groupTitle(group))"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        }
    }

    private func refreshLogsMenu() {
        guard let submenu = logsItem?.submenu else { return }
        submenu.removeAllItems()

        let entries = logger.recentEntries(limit: 12).reversed()
        if entries.isEmpty {
            let item = NSMenuItem(title: "No logs yet", action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        } else {
            for entry in entries {
                let item = NSMenuItem(title: entry, action: nil, keyEquivalent: "")
                item.isEnabled = false
                submenu.addItem(item)
            }
        }

        submenu.addItem(.separator())
        let focusedItem = NSMenuItem(title: "Dump Focused Context", action: #selector(dumpFocusedContext(_:)), keyEquivalent: "")
        focusedItem.target = self
        submenu.addItem(focusedItem)

        let windowsItem = NSMenuItem(title: "Dump Visible Windows", action: #selector(dumpVisibleWindows(_:)), keyEquivalent: "")
        windowsItem.target = self
        submenu.addItem(windowsItem)

        let diagnosticsItem = NSMenuItem(title: "Dump Window Diagnostics", action: #selector(dumpDiagnostics(_:)), keyEquivalent: "")
        diagnosticsItem.target = self
        submenu.addItem(diagnosticsItem)

        let openItem = NSMenuItem(title: "Open Log File", action: #selector(openLogFile(_:)), keyEquivalent: "")
        openItem.target = self
        submenu.addItem(openItem)

        let copyItem = NSMenuItem(title: "Copy Logs", action: #selector(copyLogs(_:)), keyEquivalent: "")
        copyItem.target = self
        submenu.addItem(copyItem)

        let clearItem = NSMenuItem(title: "Clear Logs", action: #selector(clearLogs(_:)), keyEquivalent: "")
        clearItem.target = self
        submenu.addItem(clearItem)
    }

    private func buildSliderItem(
        title: String,
        min: Double,
        max: Double,
        value: Double,
        action: Selector,
        assign: (NSSlider, NSTextField) -> Void
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 46))

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 12)
        titleLabel.frame = NSRect(x: 10, y: 26, width: 170, height: 16)

        let valueLabel = NSTextField(labelWithString: "")
        valueLabel.font = NSFont.systemFont(ofSize: 12)
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: 180, y: 26, width: 70, height: 16)

        let slider = NSSlider(value: value, minValue: min, maxValue: max, target: self, action: action)
        slider.isContinuous = true
        slider.frame = NSRect(x: 10, y: 6, width: 240, height: 16)

        view.addSubview(titleLabel)
        view.addSubview(valueLabel)
        view.addSubview(slider)
        menuItem.view = view

        assign(slider, valueLabel)

        return menuItem
    }

    private func formatEdgeValue(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    private func formatOverlapValue(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func groupTitle(_ group: [AXWindowInfo]) -> String {
        var seen = Set<String>()
        var names: [String] = []
        for window in group {
            if seen.insert(window.appName).inserted {
                names.append(window.appName)
            }
        }
        let nameList = names.prefix(3).joined(separator: ", ")
        let suffix = names.count > 3 ? " +\(names.count - 3)" : ""
        return "\(group.count) windows - \(nameList)\(suffix)"
    }

    private func showGroupIndicator(for group: [AXWindowInfo]) {
        guard let button = statusItem?.button else { return }
        indicatorResetWork?.cancel()

        let count = group.count
        button.title = "\(statusTitle) \(count)"

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.statusItem?.button?.title = self.statusTitle
        }
        indicatorResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event)
        }
    }

    private func handleKey(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = event.keyCode

        if flags.contains([.control, .option]), keyCode == 5 {
            if flags.contains(.shift) {
                controller.finishManualGroup()
            } else {
                controller.toggleManualMode()
            }
            syncManualModeToggle()
            return
        }

        if controller.isManualModeEnabled, (keyCode == 36 || keyCode == 76) {
            controller.addFocusedToManualGroup()
        }
    }
}
