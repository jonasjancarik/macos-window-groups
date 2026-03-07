import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = WindowGroupController()
    private let logger = AppLogger.shared
    private var statusItem: NSStatusItem?
    private var permissionItem: NSMenuItem?
    private var groupsItem: NSMenuItem?
    private var logsItem: NSMenuItem?
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

    @objc private func requestAccessibility(_ sender: NSMenuItem) {
        _ = controller.requestAccessibility(prompt: true)
        refreshPermissionMenuItem()
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
            title: "Add Focused to Manual Group",
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
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshPermissionMenuItem()
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
            } else if controller.isManualModeEnabled {
                controller.addFocusedToManualGroup()
            } else {
                controller.setManualModeEnabled(true)
                controller.addFocusedToManualGroup()
            }
            syncManualModeToggle()
            return
        }
    }
}
