import ApplicationServices

enum AXHelpers {
    private static let windowNumberAttribute = "AXWindowNumber" as CFString

    static func copyAttribute<T>(_ element: AXUIElement, _ attribute: CFString) -> T? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else { return nil }
        return value as? T
    }

    static func copyWindowNumber(_ element: AXUIElement) -> Int? {
        guard let number: NSNumber = copyAttribute(element, windowNumberAttribute) else {
            return nil
        }
        return number.intValue
    }

    static func elementIdentifier(_ element: AXUIElement) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(element).toOpaque())
    }

    static func copyFrame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = copyAttribute(element, kAXPositionAttribute as CFString) else {
            return nil
        }
        guard let sizeValue: AXValue = copyAttribute(element, kAXSizeAttribute as CFString) else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue, .cgPoint, &position)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    static func isMinimized(_ element: AXUIElement) -> Bool {
        guard let minimized: NSNumber = copyAttribute(element, kAXMinimizedAttribute as CFString) else {
            return false
        }
        return minimized.boolValue
    }

    static func isStandardWindow(_ element: AXUIElement) -> Bool {
        guard let subrole: String = copyAttribute(element, kAXSubroleAttribute as CFString) else {
            return true
        }
        return subrole == (kAXStandardWindowSubrole as String)
    }

    static func raise(_ element: AXUIElement) {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }
}
