import ApplicationServices
import CoreGraphics
import Foundation

/// Typed, timeout-guarded access to accessibility attributes.
///
/// Every read here goes through `AXUIElementCopyAttributeValue`, which is a
/// synchronous IPC call into the target application. If that application is busy,
/// stopped, or wedged, the call blocks the calling thread — so a single hung app
/// can freeze window enumeration for everyone. That is a real and common failure,
/// not a theoretical one, which is why `setMessagingTimeout` exists and why the
/// registry calls it on every element it touches.
public enum AX {

    // MARK: - Timeouts

    /// Caps how long any single AX call to this element may block.
    ///
    /// Applies to the element and, for application elements, everything beneath it.
    public static func setMessagingTimeout(_ element: AXUIElement, seconds: Float) {
        AXUIElementSetMessagingTimeout(element, seconds)
    }

    // MARK: - Generic reads

    /// Reads an attribute and casts it, returning nil on any failure.
    ///
    /// Failure is routine rather than exceptional: windows close between being
    /// listed and being read, and apps refuse attributes they do not implement.
    public static func value<T>(_ element: AXUIElement, _ attribute: String, as type: T.Type = T.self) -> T? {
        var raw: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
        guard result == .success else { return nil }
        return raw as? T
    }

    public static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute, as: String.self)
    }

    public static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        value(element, attribute, as: Bool.self)
    }

    public static func int(_ element: AXUIElement, _ attribute: String) -> Int? {
        (value(element, attribute, as: NSNumber.self))?.intValue
    }

    public static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        // AXUIElement is a CFType; the bridged array has to be cast through NSArray.
        guard let array = value(element, attribute, as: NSArray.self) else { return [] }
        return array.compactMap { item in
            guard CFGetTypeID(item as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
            return (item as! AXUIElement)
        }
    }

    public static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw,
              CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        return (raw as! AXUIElement)
    }

    // MARK: - Geometry

    /// Reads `kAXPositionAttribute` as a point in screen coordinates.
    public static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw,
              CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }

        var point = CGPoint.zero
        guard AXValueGetValue(raw as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    /// Reads `kAXSizeAttribute`.
    public static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw,
              CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }

        var size = CGSize.zero
        guard AXValueGetValue(raw as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    /// Convenience combining position and size. Returns nil if either is missing.
    public static func frame(_ element: AXUIElement) -> CGRect? {
        guard let origin = point(element, kAXPositionAttribute as String),
              let size = size(element, kAXSizeAttribute as String)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    // MARK: - Writes

    @discardableResult
    public static func setValue(_ element: AXUIElement, _ attribute: String, _ value: Any) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, value as CFTypeRef) == .success
    }

    @discardableResult
    public static func setBool(_ element: AXUIElement, _ attribute: String, _ value: Bool) -> Bool {
        setValue(element, attribute, value as CFBoolean)
    }

    @discardableResult
    public static func perform(_ element: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(element, action as CFString) == .success
    }

    /// Whether an attribute can be written. Used to decide whether an action is
    /// offered at all — asking an app to fullscreen a window it will not resize
    /// produces a silent no-op that looks like a bug.
    public static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
        else { return false }
        return settable.boolValue
    }

    // MARK: - Identity

    public static func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    /// The `CGWindowID` behind a window element, when resolvable.
    public static func windowID(of element: AXUIElement) -> CGWindowID? {
        PrivateSymbols.windowID(for: element)
    }
}

// MARK: - Attribute names

/// Attribute and action names that either have no constant in the SDK or read
/// badly at the call site as raw strings.
public enum AXAttribute {
    public static let fullScreen = "AXFullScreen"
    public static let frame = "AXFrame"

    public static let role = kAXRoleAttribute as String
    public static let subrole = kAXSubroleAttribute as String
    public static let title = kAXTitleAttribute as String
    public static let windows = kAXWindowsAttribute as String
    public static let focusedWindow = kAXFocusedWindowAttribute as String
    public static let minimized = kAXMinimizedAttribute as String
    public static let hidden = kAXHiddenAttribute as String
    public static let frontmost = kAXFrontmostAttribute as String
    public static let position = kAXPositionAttribute as String
    public static let size = kAXSizeAttribute as String
    public static let closeButton = kAXCloseButtonAttribute as String
    public static let main = kAXMainAttribute as String
}

public enum AXAction {
    public static let raise = kAXRaiseAction as String
    public static let press = kAXPressAction as String
}

public enum AXRole {
    public static let window = kAXWindowRole as String
    public static let application = kAXApplicationRole as String
}

public enum AXSubrole {
    public static let standardWindow = kAXStandardWindowSubrole as String
    public static let dialog = kAXDialogSubrole as String
    public static let systemDialog = kAXSystemDialogSubrole as String
    public static let floatingWindow = kAXFloatingWindowSubrole as String
    public static let unknown = "AXUnknown"
}
