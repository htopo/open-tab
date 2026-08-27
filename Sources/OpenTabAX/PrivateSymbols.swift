import ApplicationServices
import CoreGraphics
import Foundation

/// Runtime access to the handful of undocumented system symbols OpenTab needs.
///
/// There is no public API for any of the four capabilities below. Rather than link
/// against them — which would make the app fail to *launch* the day Apple removes
/// one — every symbol is resolved lazily with `dlsym` and exposed behind an
/// availability flag. A missing symbol costs one feature and nothing else.
///
/// `PrivateSymbols.report()` describes what resolved on the current system; the
/// settings UI uses it to disable options that cannot work, and the unit tests
/// assert on it so a future macOS breaking one of these shows up as a test failure
/// rather than a bug report.
public enum PrivateSymbols {

    // MARK: - Handles

    /// Symbols are looked up in the global scope first. Anything not already
    /// mapped into the process is searched for in the framework that owns it.
    private static let skyLightHandle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
        RTLD_LAZY | RTLD_NOLOAD
    ) ?? dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
        RTLD_LAZY
    )

    private static let hiServicesHandle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/Versions/A/HIServices",
        RTLD_LAZY | RTLD_NOLOAD
    ) ?? dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/Versions/A/HIServices",
        RTLD_LAZY
    )

    /// Looks `name` up in the global scope, then in each supplied handle.
    private static func lookup(_ name: String, in handles: [UnsafeMutableRawPointer?]) -> UnsafeMutableRawPointer? {
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) { // RTLD_DEFAULT
            return sym
        }
        for handle in handles {
            guard let handle else { continue }
            if let sym = dlsym(handle, name) { return sym }
        }
        return nil
    }

    // MARK: - C function types

    private typealias AXUIElementGetWindowFn =
        @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private typealias CGSMainConnectionIDFn =
        @convention(c) () -> Int32

    private typealias CGSSetSymbolicHotKeyEnabledFn =
        @convention(c) (Int32, Bool) -> CGError

    private typealias CGSIsSymbolicHotKeyEnabledFn =
        @convention(c) (Int32) -> Bool

    private typealias CGSGetWindowWorkspaceFn =
        @convention(c) (Int32, CGWindowID, UnsafeMutablePointer<Int32>) -> CGError

    private typealias CGSCopySpacesForWindowsFn =
        @convention(c) (Int32, UInt32, CFArray) -> Unmanaged<CFArray>?

    private typealias CGSCopyManagedDisplayForSpaceFn =
        @convention(c) (Int32, Int) -> Unmanaged<CFString>?

    /// Declared as returning nothing. Headers in the wild disagree about whether
    /// it returns void or a `CGError`, and reading a return value that was never
    /// written is worse than discarding one that was.
    private typealias CGSManagedDisplaySetCurrentSpaceFn =
        @convention(c) (Int32, CFString, Int) -> Void

    private typealias CGSCopyWindowsWithOptionsAndTagsFn =
        @convention(c) (Int32, UInt32, CFArray?, UInt32,
                        UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>) -> Unmanaged<CFArray>?

    // MARK: - Resolved pointers

    private static let axGetWindowSym = lookup("_AXUIElementGetWindow", in: [hiServicesHandle])
        .map { unsafeBitCast($0, to: AXUIElementGetWindowFn.self) }

    private static let mainConnectionSym = lookup("CGSMainConnectionID", in: [skyLightHandle])
        .map { unsafeBitCast($0, to: CGSMainConnectionIDFn.self) }

    private static let setSymbolicHotKeyEnabledSym = lookup("CGSSetSymbolicHotKeyEnabled", in: [skyLightHandle])
        .map { unsafeBitCast($0, to: CGSSetSymbolicHotKeyEnabledFn.self) }

    private static let isSymbolicHotKeyEnabledSym = lookup("CGSIsSymbolicHotKeyEnabled", in: [skyLightHandle])
        .map { unsafeBitCast($0, to: CGSIsSymbolicHotKeyEnabledFn.self) }

    private static let getWindowWorkspaceSym = lookup("CGSGetWindowWorkspace", in: [skyLightHandle])
        .map { unsafeBitCast($0, to: CGSGetWindowWorkspaceFn.self) }

    private static let copySpacesForWindowsSym = lookup("CGSCopySpacesForWindows", in: [skyLightHandle])
        .map { unsafeBitCast($0, to: CGSCopySpacesForWindowsFn.self) }

    private static let copyManagedDisplayForSpaceSym = lookup("CGSCopyManagedDisplayForSpace", in: [skyLightHandle])
        .map { unsafeBitCast($0, to: CGSCopyManagedDisplayForSpaceFn.self) }

    private static let setCurrentSpaceSym = lookup("CGSManagedDisplaySetCurrentSpace", in: [skyLightHandle])
        .map { unsafeBitCast($0, to: CGSManagedDisplaySetCurrentSpaceFn.self) }

    private static let copyWindowsWithOptionsAndTagsSym = lookup("CGSCopyWindowsWithOptionsAndTags", in: [skyLightHandle])
        .map { unsafeBitCast($0, to: CGSCopyWindowsWithOptionsAndTagsFn.self) }

    // MARK: - Availability

    /// Whether `AXUIElement` values can be converted to `CGWindowID` directly.
    /// When false, the registry falls back to matching on (pid, title, frame).
    public static var canMapElementToWindowID: Bool { axGetWindowSym != nil }

    /// Whether the system's reserved ⌘Tab-family shortcuts can be freed up.
    /// When false, OpenTab keeps the binding but warns that the system switcher
    /// will also appear, and suggests a non-reserved shortcut instead.
    public static var canControlSymbolicHotKeys: Bool {
        setSymbolicHotKeyEnabledSym != nil && mainConnectionSym != nil
    }

    /// Whether the current enabled/disabled state of a symbolic hotkey can be read
    /// back. Used to verify hotkey IDs empirically instead of trusting constants.
    public static var canReadSymbolicHotKeyState: Bool { isSymbolicHotKeyEnabledSym != nil }

    /// Whether the Space a window lives on can be determined.
    /// When false, `spaceID` is nil everywhere and Space filtering degrades to "all".
    public static var canQueryWindowSpace: Bool {
        (copySpacesForWindowsSym != nil || getWindowWorkspaceSym != nil) && mainConnectionSym != nil
    }

    /// Whether OpenTab can move the user to another Desktop.
    ///
    /// When false, a window on another Desktop that its application refuses to
    /// publish over Accessibility cannot be reached: the application is brought
    /// forward and the screen stays where it is.
    public static var canSwitchSpace: Bool {
        setCurrentSpaceSym != nil && copyManagedDisplayForSpaceSym != nil && mainConnectionSym != nil
    }

    /// Whether windows across every Space can be enumerated.
    /// When false, enumeration is limited to the current Space.
    public static var canEnumerateAllSpaces: Bool {
        copyWindowsWithOptionsAndTagsSym != nil && mainConnectionSym != nil
    }

    // MARK: - Wrapped calls

    /// The window server connection for this process, or nil if unavailable.
    public static var mainConnectionID: Int32? {
        mainConnectionSym?()
    }

    /// Returns the `CGWindowID` backing an accessibility element, or nil.
    ///
    /// This is the join key between the Accessibility world (which can see
    /// minimized windows and windows on other Spaces) and the CoreGraphics world
    /// (which owns geometry, layer, and capture).
    public static func windowID(for element: AXUIElement) -> CGWindowID? {
        guard let fn = axGetWindowSym else { return nil }
        var id: CGWindowID = 0
        guard fn(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    /// Enables or disables one of the system's reserved symbolic hotkeys.
    ///
    /// - Returns: true when the call succeeded. Callers must persist their intent
    ///   *before* invoking this: the change survives app quit and reboot, so a
    ///   crash between disabling and restoring would leave the user with a broken
    ///   ⌘Tab and no switcher.
    @discardableResult
    public static func setSymbolicHotKeyEnabled(_ hotKeyID: Int32, _ enabled: Bool) -> Bool {
        guard let fn = setSymbolicHotKeyEnabledSym else { return false }
        return fn(hotKeyID, enabled) == .success
    }

    /// Reads whether a symbolic hotkey is currently enabled, or nil if unreadable.
    public static func isSymbolicHotKeyEnabled(_ hotKeyID: Int32) -> Bool? {
        guard let fn = isSymbolicHotKeyEnabledSym else { return nil }
        return fn(hotKeyID)
    }

    /// Moves the display showing `spaceID` to that Desktop.
    ///
    /// The one call in here that *changes* something rather than reading it, and
    /// the only way to reach a window whose application will not admit it exists.
    /// Some applications — browsers especially — publish over Accessibility only
    /// the window on the Desktop currently in front. There is no element to raise
    /// for the others, activating the application does not travel, and the window
    /// is unreachable until the Desktop it lives on is the current one. Once it
    /// is, the application publishes it and an ordinary raise works.
    ///
    /// Which display shows a Desktop matters: with "Displays have separate
    /// Spaces" on, each has its own set, and setting the wrong one moves the wrong
    /// screen. The display is asked for by Space rather than assumed.
    ///
    /// - Returns: false when the symbols are unavailable, which degrades to the
    ///   behaviour before they were used — the application comes forward and the
    ///   screen stays put.
    @discardableResult
    public static func switchToSpace(_ spaceID: Int) -> Bool {
        guard let set = setCurrentSpaceSym,
              let displayFor = copyManagedDisplayForSpaceSym,
              let cid = mainConnectionID,
              let display = displayFor(cid, spaceID)?.takeRetainedValue()
        else { return false }

        set(cid, display, spaceID)
        return true
    }

    /// Returns the Space (workspace) number a window is on, or nil.
    ///
    /// A return of 0 means "no Space" — typically a window that is minimized or
    /// belongs to a hidden app — and is reported as nil.
    /// Which Space a window lives on, or nil if it cannot be determined.
    ///
    /// Two implementations, tried in order, because the older one has stopped
    /// working. `CGSGetWindowWorkspace` dates from the original Spaces and still
    /// resolves — so an availability check passes — but on current macOS it
    /// reports workspace 0 for every window. That is indistinguishable from
    /// "unknown", so Space filtering silently matched everything and holding
    /// space to reveal other Spaces revealed nothing: the list was already the
    /// whole list.
    ///
    /// `CGSCopySpacesForWindows` is the modern replacement. It answers for a
    /// batch of windows at once but returns the *union* of their Spaces rather
    /// than a per-window mapping, so it is asked about one window at a time. That
    /// is a WindowServer round trip per window, which is why this is only ever
    /// called from the background enumeration and never while the switcher is
    /// open.
    public static func workspace(for windowID: CGWindowID) -> Int? {
        guard let cid = mainConnectionID else { return nil }

        if let fn = copySpacesForWindowsSym {
            let ids = [NSNumber(value: windowID)] as CFArray
            if let spaces = fn(cid, allSpacesMask, ids)?.takeRetainedValue() as? [NSNumber],
               let first = spaces.first?.intValue,
               first != 0 {
                return first
            }
        }

        guard let fn = getWindowWorkspaceSym else { return nil }
        var workspace: Int32 = 0
        guard fn(cid, windowID, &workspace) == .success, workspace != 0 else { return nil }
        return Int(workspace)
    }

    /// `kCGSSpaceIncludesCurrent | kCGSSpaceIncludesOthers | kCGSSpaceIncludesUser`
    /// — every Space the user can reach, which is the only mask that answers
    /// "where is this window" rather than "is it here".
    private static let allSpacesMask: UInt32 = 7

    /// Enumerates window IDs across every Space.
    ///
    /// `CGWindowListCopyWindowInfo` only reports windows composited on the current
    /// Space; this reaches the rest. Returns nil when the symbol is unavailable,
    /// which callers treat as "current Space only".
    public static func allSpaceWindowIDs() -> [CGWindowID]? {
        guard let fn = copyWindowsWithOptionsAndTagsSym, let cid = mainConnectionID else { return nil }

        // Options value 0x2 asks for all windows regardless of Space. The tag
        // pointers are in/out parameters; zero means "no tag filtering".
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        guard let result = fn(cid, 0, nil, 0x2, &setTags, &clearTags) else { return nil }

        let array = result.takeRetainedValue() as NSArray
        return array.compactMap { element in
            (element as? NSNumber).map { CGWindowID($0.uint32Value) }
        }
    }

    // MARK: - Diagnostics

    public struct Availability: Sendable, Equatable {
        public let elementToWindowID: Bool
        public let symbolicHotKeyControl: Bool
        public let symbolicHotKeyRead: Bool
        public let windowSpaceQuery: Bool
        public let allSpacesEnumeration: Bool

        /// True when every symbol resolved, i.e. no feature is degraded.
        public var isComplete: Bool {
            elementToWindowID && symbolicHotKeyControl && symbolicHotKeyRead
                && windowSpaceQuery && allSpacesEnumeration
        }
    }

    public static func report() -> Availability {
        Availability(
            elementToWindowID: canMapElementToWindowID,
            symbolicHotKeyControl: canControlSymbolicHotKeys,
            symbolicHotKeyRead: canReadSymbolicHotKeyState,
            windowSpaceQuery: canQueryWindowSpace,
            allSpacesEnumeration: canEnumerateAllSpaces
        )
    }

    /// Human-readable summary, logged once at launch to make field reports useful.
    public static func describe() -> String {
        let r = report()
        return """
        PrivateSymbols: \
        _AXUIElementGetWindow=\(r.elementToWindowID) \
        CGSSetSymbolicHotKeyEnabled=\(r.symbolicHotKeyControl) \
        CGSIsSymbolicHotKeyEnabled=\(r.symbolicHotKeyRead) \
        CGSCopySpacesForWindows=\(copySpacesForWindowsSym != nil) \
        CGSManagedDisplaySetCurrentSpace=\(canSwitchSpace) \
        CGSGetWindowWorkspace=\(getWindowWorkspaceSym != nil) \
        CGSCopyWindowsWithOptionsAndTags=\(r.allSpacesEnumeration)
        """
    }
}
