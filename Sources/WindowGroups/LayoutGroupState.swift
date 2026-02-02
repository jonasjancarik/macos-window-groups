import Foundation
import AppKit

final class LayoutGroupState {
    struct PairDecision {
        let formed: Bool
        let reason: String
    }

    struct State {
        var frame: CGRect
        var lastMoved: Date
        var groupID: UUID?
    }

    private var states: [UInt: State] = [:]
    private let moveThreshold: CGFloat

    init(
        moveThreshold: CGFloat = 4
    ) {
        self.moveThreshold = moveThreshold
    }

    func update(windows: [AXWindowInfo], now: Date = Date()) {
        var seen = Set<UInt>()
        var groupsToClear = Set<UUID>()
        for window in windows {
            let id = window.identifier
            seen.insert(id)
            if var state = states[id] {
                if frameChanged(from: state.frame, to: window.frame) {
                    if let gid = state.groupID {
                        groupsToClear.insert(gid)
                    }
                    state.frame = window.frame
                    state.lastMoved = now
                    state.groupID = nil
                } else {
                    state.frame = window.frame
                }
                states[id] = state
            } else {
                states[id] = State(frame: window.frame, lastMoved: .distantPast, groupID: nil)
            }
        }
        let removed = states.keys.filter { !seen.contains($0) }
        for id in removed {
            if let gid = states[id]?.groupID {
                groupsToClear.insert(gid)
            }
        }
        states = states.filter { seen.contains($0.key) }
        for gid in groupsToClear {
            clearGroup(groupID: gid)
        }
    }

    func group(
        for focused: AXWindowInfo,
        in windows: [AXWindowInfo],
        updated: Bool = false,
        now: Date = Date()
    ) -> [AXWindowInfo] {
        if !updated {
            update(windows: windows, now: now)
        }
        guard let gid = states[focused.identifier]?.groupID else {
            return [focused]
        }
        let group = windows.filter { states[$0.identifier]?.groupID == gid }
        return group.count > 1 ? group : [focused]
    }

    func groups(in windows: [AXWindowInfo], now: Date = Date()) -> [[AXWindowInfo]] {
        update(windows: windows, now: now)
        var grouped: [UUID: [AXWindowInfo]] = [:]
        for window in windows {
            guard let gid = states[window.identifier]?.groupID else { continue }
            grouped[gid, default: []].append(window)
        }
        return grouped.values.filter { $0.count > 1 }
    }

    func groupID(for windowID: UInt) -> UUID? {
        states[windowID]?.groupID
    }

    func ensureGroup(for windowID: UInt) -> UUID {
        if var state = states[windowID] {
            if let gid = state.groupID {
                return gid
            }
            let gid = UUID()
            state.groupID = gid
            states[windowID] = state
            return gid
        }
        let gid = UUID()
        states[windowID] = State(frame: .zero, lastMoved: .distantPast, groupID: gid)
        return gid
    }

    func addWindow(_ windowID: UInt, toGroup groupID: UUID) {
        let previous: UUID?
        if var state = states[windowID] {
            previous = state.groupID
            state.groupID = groupID
            states[windowID] = state
        } else {
            previous = nil
            states[windowID] = State(frame: .zero, lastMoved: .distantPast, groupID: groupID)
        }
        if let previous, previous != groupID {
            clearGroupIfSingleton(previous)
        }
    }

    func assignWindow(_ window: AXWindowInfo, toGroup groupID: UUID, now: Date = Date()) {
        let previous: UUID?
        if var state = states[window.identifier] {
            previous = state.groupID
            state.frame = window.frame
            state.lastMoved = now
            state.groupID = groupID
            states[window.identifier] = state
        } else {
            previous = nil
            states[window.identifier] = State(frame: window.frame, lastMoved: now, groupID: groupID)
        }
        if let previous, previous != groupID {
            clearGroupIfSingleton(previous)
        }
    }

    func windows(inGroup groupID: UUID, from windows: [AXWindowInfo]) -> [AXWindowInfo] {
        windows.filter { states[$0.identifier]?.groupID == groupID }
    }

    func registerPairIfEligible(
        focused: AXWindowInfo,
        previous: AXWindowInfo,
        detector: TilingDetector
    ) -> PairDecision {
        let focusedSide = detector.snapSide(for: focused)
        let previousSide = detector.snapSide(for: previous)

        guard focused.identifier != previous.identifier else {
            return PairDecision(formed: false, reason: "skip: same window")
        }

        guard sameScreen(focused, previous, detector: detector) else {
            return PairDecision(formed: false, reason: "skip: different screens (\(sideLabel(focusedSide))/\(sideLabel(previousSide)))")
        }

        guard detector.isAdjacent(focused.frame, previous.frame) else {
            return PairDecision(formed: false, reason: "skip: not adjacent (\(sideLabel(focusedSide))/\(sideLabel(previousSide)))")
        }

        guard isOppositeSide(focusedSide, previousSide) else {
            return PairDecision(formed: false, reason: "skip: not opposite sides (\(sideLabel(focusedSide))/\(sideLabel(previousSide)))")
        }

        assignGroup(ids: [focused.identifier, previous.identifier])
        return PairDecision(formed: true, reason: "paired: prev focus + \(sideLabel(focusedSide))/\(sideLabel(previousSide))")
    }

    private func assignGroup(ids: [UInt]) {
        var groupsToClear = Set<UUID>()
        for id in ids {
            if let gid = states[id]?.groupID {
                groupsToClear.insert(gid)
            }
        }
        for gid in groupsToClear {
            clearGroup(groupID: gid)
        }

        let gid = UUID()
        for id in ids {
            states[id]?.groupID = gid
        }
    }

    private func clearGroup(groupID: UUID) {
        for (id, state) in states where state.groupID == groupID {
            var updated = state
            updated.groupID = nil
            states[id] = updated
        }
    }

    private func clearGroupIfSingleton(_ groupID: UUID) {
        let ids = states.filter { $0.value.groupID == groupID }.map { $0.key }
        guard ids.count <= 1 else { return }
        for id in ids {
            if var state = states[id] {
                state.groupID = nil
                states[id] = state
            }
        }
    }

    private func sameScreen(_ a: AXWindowInfo, _ b: AXWindowInfo, detector: TilingDetector) -> Bool {
        guard let aIndex = detector.screenIndex(for: a.frame),
              let bIndex = detector.screenIndex(for: b.frame) else {
            return false
        }
        return aIndex == bIndex
    }

    private func isOppositeSide(_ a: TilingDetector.SnapSide, _ b: TilingDetector.SnapSide) -> Bool {
        switch (a, b) {
        case (.left, .right), (.right, .left):
            return true
        default:
            return false
        }
    }

    private func sideLabel(_ side: TilingDetector.SnapSide) -> String {
        switch side {
        case .left:
            return "left"
        case .right:
            return "right"
        case .none:
            return "none"
        }
    }

    private func frameChanged(from old: CGRect, to new: CGRect) -> Bool {
        let dx = abs(old.origin.x - new.origin.x)
        let dy = abs(old.origin.y - new.origin.y)
        let dw = abs(old.size.width - new.size.width)
        let dh = abs(old.size.height - new.size.height)
        return dx > moveThreshold || dy > moveThreshold || dw > moveThreshold || dh > moveThreshold
    }

}
