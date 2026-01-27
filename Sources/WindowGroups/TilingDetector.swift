import AppKit

struct TilingDetector {
    var edgeTolerance: CGFloat = 8
    var minOverlapRatio: CGFloat = 0.25

    enum SnapSide {
        case left
        case right
        case none
    }

    func group(for focused: AXWindowInfo, in windows: [AXWindowInfo]) -> [AXWindowInfo] {
        guard let focusedScreenIndex = screenIndex(for: focused.frame) else {
            return [focused]
        }

        let sameScreen = windows.filter { window in
            screenIndex(for: window.frame) == focusedScreenIndex
        }

        var visited = Set<UInt>()
        var queue: [AXWindowInfo] = [focused]
        var result: [AXWindowInfo] = []

        while let current = queue.popLast() {
            guard !visited.contains(current.identifier) else { continue }
            visited.insert(current.identifier)
            result.append(current)

            for candidate in sameScreen {
                guard !visited.contains(candidate.identifier) else { continue }
                if isAdjacent(current.frame, candidate.frame) {
                    queue.append(candidate)
                }
            }
        }

        return result
    }

    func adjacentWindows(to focused: AXWindowInfo, in windows: [AXWindowInfo]) -> [AXWindowInfo] {
        guard let focusedScreenIndex = screenIndex(for: focused.frame) else { return [] }

        return windows.filter { window in
            guard window.identifier != focused.identifier else { return false }
            guard screenIndex(for: window.frame) == focusedScreenIndex else { return false }
            return isAdjacent(focused.frame, window.frame)
        }
    }

    func groups(in windows: [AXWindowInfo]) -> [[AXWindowInfo]] {
        var visited = Set<UInt>()
        var groups: [[AXWindowInfo]] = []

        for window in windows {
            guard !visited.contains(window.identifier) else { continue }
            guard let currentScreenIndex = screenIndex(for: window.frame) else { continue }

            var queue: [AXWindowInfo] = [window]
            var group: [AXWindowInfo] = []

            while let current = queue.popLast() {
                guard !visited.contains(current.identifier) else { continue }
                visited.insert(current.identifier)
                group.append(current)

                for candidate in windows {
                    guard !visited.contains(candidate.identifier) else { continue }
                    guard screenIndex(for: candidate.frame) == currentScreenIndex else { continue }
                    if isAdjacent(current.frame, candidate.frame) {
                        queue.append(candidate)
                    }
                }
            }

            groups.append(group)
        }

        return groups
    }

    func screenIndex(for frame: CGRect) -> Int? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        for (index, screen) in NSScreen.screens.enumerated() {
            if screen.frame.contains(center) {
                return index
            }
        }
        return nil
    }

    func screen(for frame: CGRect) -> NSScreen? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        for screen in NSScreen.screens {
            if screen.frame.contains(center) {
                return screen
            }
        }
        return nil
    }

    func snapSide(for window: AXWindowInfo) -> SnapSide {
        guard let screen = screen(for: window.frame) else { return .none }
        let visible = screen.visibleFrame
        let frame = window.frame
        let heightRatio = frame.height / max(1, visible.height)
        guard heightRatio >= 0.8 else { return .none }

        let widthRatio = frame.width / max(1, visible.width)
        guard widthRatio >= 0.35, widthRatio <= 0.7 else { return .none }

        let sideTolerance = max(12, edgeTolerance * 2)
        if abs(frame.minX - visible.minX) <= sideTolerance {
            return .left
        }
        if abs(frame.maxX - visible.maxX) <= sideTolerance {
            return .right
        }

        return .none
    }

    func isAdjacent(_ a: CGRect, _ b: CGRect) -> Bool {
        let intersection = a.intersection(b)
        if intersection.width > edgeTolerance && intersection.height > edgeTolerance {
            return false
        }

        let verticalOverlap = overlapLength(a.minY, a.maxY, b.minY, b.maxY)
        let horizontalOverlap = overlapLength(a.minX, a.maxX, b.minX, b.maxX)

        let verticalEdgeTouch = abs(a.maxX - b.minX) <= edgeTolerance || abs(b.maxX - a.minX) <= edgeTolerance
        let horizontalEdgeTouch = abs(a.maxY - b.minY) <= edgeTolerance || abs(b.maxY - a.minY) <= edgeTolerance

        let minVerticalOverlap = min(a.height, b.height) * minOverlapRatio
        let minHorizontalOverlap = min(a.width, b.width) * minOverlapRatio

        if verticalEdgeTouch && verticalOverlap >= minVerticalOverlap {
            return true
        }
        if horizontalEdgeTouch && horizontalOverlap >= minHorizontalOverlap {
            return true
        }

        return false
    }

    private func overlapLength(_ minA: CGFloat, _ maxA: CGFloat, _ minB: CGFloat, _ maxB: CGFloat) -> CGFloat {
        let start = max(minA, minB)
        let end = min(maxA, maxB)
        return max(0, end - start)
    }
}
