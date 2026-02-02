import AppKit

final class DebugOverlayController {
    private let logger: AppLogger
    private let panel: NSPanel
    private let textView: NSTextView
    private var timer: Timer?

    init(logger: AppLogger = .shared) {
        self.logger = logger

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let visual = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        visual.autoresizingMask = [.width, .height]
        visual.material = .hudWindow
        visual.state = .active
        visual.blendingMode = .behindWindow

        let textView = NSTextView(frame: visual.bounds.insetBy(dx: 8, dy: 8))
        textView.autoresizingMask = [.width, .height]
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .white

        visual.addSubview(textView)
        panel.contentView = visual

        self.panel = panel
        self.textView = textView

        positionPanel()
    }

    var isVisible: Bool {
        panel.isVisible
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard !isVisible else { return }
        positionPanel()
        refresh()
        panel.orderFrontRegardless()
        startTimer()
    }

    func hide() {
        stopTimer()
        panel.orderOut(nil)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let entries = logger.recentEntries(limit: 80)
        textView.string = entries.joined(separator: "\n")
        scrollToBottom()
    }

    private func scrollToBottom() {
        let range = NSRange(location: max(0, textView.string.count - 1), length: 1)
        textView.scrollRangeToVisible(range)
    }

    private func positionPanel() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width: CGFloat = 460
        let height: CGFloat = 260
        let x = visible.maxX - width - 16
        let y = visible.maxY - height - 24
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}
