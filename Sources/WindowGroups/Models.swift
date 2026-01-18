import Foundation
import ApplicationServices

struct AXWindowInfo: Hashable {
    let identifier: UInt
    let windowID: Int?
    let pid: pid_t
    let appName: String
    let frame: CGRect
    let axElement: AXUIElement

    static func == (lhs: AXWindowInfo, rhs: AXWindowInfo) -> Bool {
        lhs.identifier == rhs.identifier && lhs.pid == rhs.pid
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
        hasher.combine(pid)
    }
}
