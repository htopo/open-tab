import Testing
@testable import OpenTabAX

/// Availability smoke tests for the undocumented symbols OpenTab depends on.
///
/// The point of these is early warning. Each symbol has a graceful fallback, so a
/// failure here is not a crash — it is "a feature silently degraded on this OS
/// version", which is exactly the class of regression that otherwise reaches users
/// as a confusing bug report.
///
/// Tests use swift-testing rather than XCTest: XCTest ships only inside Xcode, and
/// this project is built with Command Line Tools.
@Suite("Private symbol resolution")
struct PrivateSymbolsTests {

    @Test("_AXUIElementGetWindow resolves")
    func elementToWindowIDResolves() {
        #expect(
            PrivateSymbols.canMapElementToWindowID,
            """
            _AXUIElementGetWindow did not resolve. Window enumeration falls back to \
            heuristic (pid, title, frame) matching, which is lossy. See PLAN §6.3.
            """
        )
    }

    @Test("CGSSetSymbolicHotKeyEnabled resolves")
    func symbolicHotKeyControlResolves() {
        #expect(
            PrivateSymbols.canControlSymbolicHotKeys,
            """
            CGSSetSymbolicHotKeyEnabled did not resolve. ⌘Tab cannot be taken over from \
            the system switcher; users must pick a non-reserved shortcut. See PLAN §4.3.
            """
        )
    }

    @Test("CGSIsSymbolicHotKeyEnabled resolves")
    func symbolicHotKeyStateIsReadable() {
        #expect(
            PrivateSymbols.canReadSymbolicHotKeyState,
            """
            CGSIsSymbolicHotKeyEnabled did not resolve. Hotkey IDs can no longer be \
            verified empirically before being written. See PLAN §4.3.1.
            """
        )
    }

    @Test("CGSGetWindowWorkspace resolves")
    func windowSpaceQueryResolves() {
        #expect(
            PrivateSymbols.canQueryWindowSpace,
            """
            CGSGetWindowWorkspace did not resolve. Per-window Space information is \
            unavailable and Space filtering degrades to "all". See PLAN §6.3.
            """
        )
    }

    @Test("CGSCopyWindowsWithOptionsAndTags resolves")
    func allSpacesEnumerationResolves() {
        #expect(
            PrivateSymbols.canEnumerateAllSpaces,
            """
            CGSCopyWindowsWithOptionsAndTags did not resolve. Window enumeration is \
            limited to the current Space. See PLAN §6.3.
            """
        )
    }

    /// Several CGS calls take a connection ID as their first argument, so a zero
    /// connection would make them fail in a way that looks like a missing symbol
    /// but is not.
    @Test("Window server connection is usable")
    func mainConnectionIDIsUsable() throws {
        let cid = try #require(PrivateSymbols.mainConnectionID,
                               "CGSMainConnectionID did not resolve")
        #expect(cid != 0, "Window server connection ID should be non-zero")
    }

    @Test("Availability report matches the individual flags")
    func reportIsInternallyConsistent() {
        let report = PrivateSymbols.report()
        #expect(report.elementToWindowID == PrivateSymbols.canMapElementToWindowID)
        #expect(report.symbolicHotKeyControl == PrivateSymbols.canControlSymbolicHotKeys)
        #expect(report.symbolicHotKeyRead == PrivateSymbols.canReadSymbolicHotKeyState)
        #expect(report.windowSpaceQuery == PrivateSymbols.canQueryWindowSpace)
        #expect(report.allSpacesEnumeration == PrivateSymbols.canEnumerateAllSpaces)
        #expect(!PrivateSymbols.describe().isEmpty)
    }

    /// Reading a symbolic hotkey's state must not change it. This would catch an
    /// implementation that accidentally wrote while probing — which would leave the
    /// user's ⌘Tab broken just by running the test suite.
    @Test("Probing a symbolic hotkey is side-effect free")
    func readingSymbolicHotKeyStateIsNonMutating() throws {
        try #require(PrivateSymbols.canReadSymbolicHotKeyState)

        let commandTab: Int32 = 1
        let before = PrivateSymbols.isSymbolicHotKeyEnabled(commandTab)
        let again = PrivateSymbols.isSymbolicHotKeyEnabled(commandTab)
        #expect(before == again, "Probing a symbolic hotkey must be side-effect free")
    }
}
