import Foundation
import ApplicationServices

enum WindowKey: Hashable, CustomStringConvertible {
    case windowID(Int)
    case fallback(pid: pid_t, identifier: UInt)

    init(windowID: Int?, pid: pid_t, identifier: UInt) {
        if let windowID {
            self = .windowID(windowID)
        } else {
            self = .fallback(pid: pid, identifier: identifier)
        }
    }

    var description: String {
        switch self {
        case .windowID(let windowID):
            return "winID:\(windowID)"
        case .fallback(let pid, let identifier):
            return "fallback:\(pid):\(identifier)"
        }
    }
}

struct AXWindowInfo: Hashable {
    let identifier: UInt
    let windowID: Int?
    let pid: pid_t
    let appName: String
    let frame: CGRect
    let axElement: AXUIElement

    var key: WindowKey {
        WindowKey(windowID: windowID, pid: pid, identifier: identifier)
    }

    static func == (lhs: AXWindowInfo, rhs: AXWindowInfo) -> Bool {
        lhs.key == rhs.key
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
    }
}
