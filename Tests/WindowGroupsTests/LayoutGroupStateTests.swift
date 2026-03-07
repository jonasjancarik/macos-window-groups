import ApplicationServices
import XCTest
@testable import WindowGroups

final class LayoutGroupStateTests: XCTestCase {
    func testManualGroupReturnsAssignedMembers() {
        let state = LayoutGroupState()
        let first = makeWindow(windowID: 1, identifier: 1001, frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let second = makeWindow(windowID: 2, identifier: 1002, frame: CGRect(x: 600, y: 0, width: 600, height: 800))
        let windows = [first, second]

        state.update(windows: windows)
        let groupID = state.ensureGroup(for: first.key)
        state.addWindow(second.key, toGroup: groupID)

        let grouped = Set(state.group(for: first, in: windows))
        XCTAssertEqual(grouped, Set(windows))
    }

    func testReassigningWindowClearsSingletonPreviousGroup() {
        let state = LayoutGroupState()
        let first = makeWindow(windowID: 1, identifier: 1001, frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let second = makeWindow(windowID: 2, identifier: 1002, frame: CGRect(x: 600, y: 0, width: 600, height: 800))
        let third = makeWindow(windowID: 3, identifier: 1003, frame: CGRect(x: 1200, y: 0, width: 600, height: 800))
        let windows = [first, second, third]

        state.update(windows: windows)
        let firstGroup = state.ensureGroup(for: first.key)
        state.addWindow(second.key, toGroup: firstGroup)

        let secondGroup = state.ensureGroup(for: third.key)
        state.addWindow(second.key, toGroup: secondGroup)

        XCTAssertEqual(state.group(for: first, in: windows), [first])
        XCTAssertEqual(Set(state.group(for: third, in: windows)), Set([second, third]))
    }

    func testUpdateClearsGroupWhenWindowMoves() {
        let state = LayoutGroupState()
        let first = makeWindow(windowID: 1, identifier: 1001, frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let second = makeWindow(windowID: 2, identifier: 1002, frame: CGRect(x: 600, y: 0, width: 600, height: 800))
        let windows = [first, second]

        state.update(windows: windows)
        let groupID = state.ensureGroup(for: first.key)
        state.addWindow(second.key, toGroup: groupID)

        let movedSecond = makeWindow(windowID: 2, identifier: 1002, frame: CGRect(x: 640, y: 0, width: 600, height: 800))
        let invalidations = state.update(windows: [first, movedSecond])

        XCTAssertEqual(state.group(for: first, in: [first, movedSecond]), [first])
        XCTAssertEqual(state.group(for: movedSecond, in: [first, movedSecond]), [movedSecond])
        XCTAssertEqual(
            invalidations,
            [
                .init(
                    groupID: groupID,
                    members: [first.key, second.key],
                    reason: .frameChanged(windowKey: second.key, oldFrame: second.frame, newFrame: movedSecond.frame)
                )
            ]
        )
    }

    func testUpdateClearsGroupWhenMemberDisappears() {
        let state = LayoutGroupState()
        let first = makeWindow(windowID: 1, identifier: 1001, frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let second = makeWindow(windowID: 2, identifier: 1002, frame: CGRect(x: 600, y: 0, width: 600, height: 800))

        state.update(windows: [first, second])
        let groupID = state.ensureGroup(for: first.key)
        state.addWindow(second.key, toGroup: groupID)

        let invalidations = state.update(windows: [first])

        XCTAssertEqual(state.group(for: first, in: [first]), [first])
        XCTAssertEqual(
            invalidations,
            [
                .init(
                    groupID: groupID,
                    members: [first.key, second.key],
                    reason: .windowMissing(windowKey: second.key)
                )
            ]
        )
    }

    private func makeWindow(
        windowID: Int,
        identifier: UInt,
        frame: CGRect,
        pid: pid_t = 4242,
        appName: String = "TestApp"
    ) -> AXWindowInfo {
        AXWindowInfo(
            identifier: identifier,
            windowID: windowID,
            pid: pid,
            appName: appName,
            frame: frame,
            axElement: AXUIElementCreateSystemWide()
        )
    }
}
