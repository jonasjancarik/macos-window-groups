import Foundation
import AppKit

final class LayoutGroupState {
    struct State {
        var frame: CGRect
        var lastMoved: Date
        var groupID: UUID?
    }

    private var states: [WindowKey: State] = [:]
    private let moveThreshold: CGFloat

    init(
        moveThreshold: CGFloat = 4
    ) {
        self.moveThreshold = moveThreshold
    }

    func update(windows: [AXWindowInfo], now: Date = Date()) {
        var seen = Set<WindowKey>()
        var groupsToClear = Set<UUID>()
        for window in windows {
            let id = window.key
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
        guard let gid = states[focused.key]?.groupID else {
            return [focused]
        }
        let group = windows.filter { states[$0.key]?.groupID == gid }
        return group.count > 1 ? group : [focused]
    }

    func groups(in windows: [AXWindowInfo], now: Date = Date()) -> [[AXWindowInfo]] {
        update(windows: windows, now: now)
        var grouped: [UUID: [AXWindowInfo]] = [:]
        for window in windows {
            guard let gid = states[window.key]?.groupID else { continue }
            grouped[gid, default: []].append(window)
        }
        return grouped.values.filter { $0.count > 1 }
    }

    func groupID(for key: WindowKey) -> UUID? {
        states[key]?.groupID
    }

    func ensureGroup(for key: WindowKey) -> UUID {
        if var state = states[key] {
            if let gid = state.groupID {
                return gid
            }
            let gid = UUID()
            state.groupID = gid
            states[key] = state
            return gid
        }
        let gid = UUID()
        states[key] = State(frame: .zero, lastMoved: .distantPast, groupID: gid)
        return gid
    }

    func addWindow(_ key: WindowKey, toGroup groupID: UUID) {
        let previous: UUID?
        if var state = states[key] {
            previous = state.groupID
            state.groupID = groupID
            states[key] = state
        } else {
            previous = nil
            states[key] = State(frame: .zero, lastMoved: .distantPast, groupID: groupID)
        }
        if let previous, previous != groupID {
            clearGroupIfSingleton(previous)
        }
    }

    func assignWindow(_ window: AXWindowInfo, toGroup groupID: UUID, now: Date = Date()) {
        let previous: UUID?
        if var state = states[window.key] {
            previous = state.groupID
            state.frame = window.frame
            state.lastMoved = now
            state.groupID = groupID
            states[window.key] = state
        } else {
            previous = nil
            states[window.key] = State(frame: window.frame, lastMoved: now, groupID: groupID)
        }
        if let previous, previous != groupID {
            clearGroupIfSingleton(previous)
        }
    }

    func windows(inGroup groupID: UUID, from windows: [AXWindowInfo]) -> [AXWindowInfo] {
        windows.filter { states[$0.key]?.groupID == groupID }
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

    private func frameChanged(from old: CGRect, to new: CGRect) -> Bool {
        let dx = abs(old.origin.x - new.origin.x)
        let dy = abs(old.origin.y - new.origin.y)
        let dw = abs(old.size.width - new.size.width)
        let dh = abs(old.size.height - new.size.height)
        return dx > moveThreshold || dy > moveThreshold || dw > moveThreshold || dh > moveThreshold
    }
}
