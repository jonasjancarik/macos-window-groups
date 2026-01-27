import Foundation
import ApplicationServices
import Darwin

final class CGSWindowOrderer {
    private typealias CGSConnectionID = UInt32
    private typealias CGSMainConnectionIDFunc = @convention(c) () -> CGSConnectionID
    private typealias CGSOrderWindowFunc = @convention(c) (CGSConnectionID, CGWindowID, Int32, CGWindowID) -> Int32

    private let handle: UnsafeMutableRawPointer
    private let connectionID: CGSConnectionID
    private let orderWindow: CGSOrderWindowFunc

    static let shared: CGSWindowOrderer? = CGSWindowOrderer()

    private init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else {
            return nil
        }
        guard let mainSymbol = dlsym(handle, "CGSMainConnectionID"),
              let orderSymbol = dlsym(handle, "CGSOrderWindow") else {
            dlclose(handle)
            return nil
        }

        let mainFunc = unsafeBitCast(mainSymbol, to: CGSMainConnectionIDFunc.self)
        let orderFunc = unsafeBitCast(orderSymbol, to: CGSOrderWindowFunc.self)
        let connectionID = mainFunc()

        self.handle = handle
        self.connectionID = connectionID
        self.orderWindow = orderFunc
    }

    deinit {
        dlclose(handle)
    }

    func orderAboveAll(_ windowID: CGWindowID) -> Bool {
        let result = orderWindow(connectionID, windowID, 1, 0)
        return result == 0
    }
}
