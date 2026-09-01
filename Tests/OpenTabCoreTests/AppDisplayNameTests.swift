import Testing
@testable import OpenTabCore

/// Dropping the publisher from an application's name.
///
/// The vendor is the least useful word on a switcher row: identical for every
/// window of that application, usually the widest thing on the line, and never
/// what anyone is choosing between. But it is only safe to drop when what remains
/// still names the application.
@Suite("Application display names")
struct AppDisplayNameTests {

    @Test("Known publishers are dropped")
    func vendorPrefixesAreDropped() {
        #expect(AppDisplayName.shortened("Google Chrome") == "Chrome")
        #expect(AppDisplayName.shortened("Microsoft Word") == "Word")
        #expect(AppDisplayName.shortened("Adobe Photoshop") == "Photoshop")
    }

    @Test("The rest of the name survives intact")
    func multiWordRemaindersSurvive() {
        #expect(AppDisplayName.shortened("Google Chrome Canary") == "Chrome Canary")
        #expect(AppDisplayName.shortened("Microsoft Remote Desktop") == "Remote Desktop")
    }

    /// An application actually named after its publisher keeps that name; there is
    /// nothing left to call it otherwise.
    @Test("A publisher alone is left alone")
    func bareVendorNameIsKept() {
        #expect(AppDisplayName.shortened("Google") == "Google")
        #expect(AppDisplayName.shortened("Adobe") == "Adobe")
    }

    /// Guards against shortening to something unrecognisable.
    @Test("A very short remainder is not worth the trade")
    func tinyRemaindersAreKept() {
        #expect(AppDisplayName.shortened("Microsoft To") == "Microsoft To")
    }

    /// The list is of publishers, not of first words. Anything else keeps its name
    /// whole — the first word is frequently the part that identifies the app.
    @Test("Unlisted first words are never dropped")
    func onlyListedVendorsMatch() {
        #expect(AppDisplayName.shortened("Visual Studio Code") == "Visual Studio Code")
        #expect(AppDisplayName.shortened("Activity Monitor") == "Activity Monitor")
        #expect(AppDisplayName.shortened("Sublime Text") == "Sublime Text")
    }

    @Test("A publisher elsewhere in the name is not a prefix")
    func onlyPrefixesMatch() {
        #expect(AppDisplayName.shortened("Backup for Google Drive") == "Backup for Google Drive")
    }

    @Test("The setting turns it off")
    func settingIsHonoured() {
        #expect(AppDisplayName.display("Google Chrome", shorten: false) == "Google Chrome")
        #expect(AppDisplayName.display("Google Chrome", shorten: true) == "Chrome")
    }
}

/// The label a row shows, under each combination of the two settings.
@Suite("Window labels")
struct WindowLabelTests {

    private func window(app: String, title: String) -> WindowModel {
        WindowModel(
            id: WindowID(cgWindowID: 1, pid: 1),
            kind: .window,
            title: title,
            appBundleID: "com.example",
            appName: app
        )
    }

    @Test("Both settings on gives the full label")
    func fullLabel() {
        let w = window(app: "Google Chrome", title: "Inbox")
        #expect(w.displayLabel(shortenAppName: true, includeWindowTitle: true) == "Chrome — Inbox")
    }

    @Test("Titles off leaves the application name alone")
    func titleSuppressed() {
        let w = window(app: "Google Chrome", title: "Inbox")
        #expect(w.displayLabel(shortenAppName: true, includeWindowTitle: false) == "Chrome")
        #expect(w.displayLabel(shortenAppName: false, includeWindowTitle: false) == "Google Chrome")
    }

    /// A window whose title merely repeats the application name adds nothing, so
    /// the separator is not drawn for it either.
    @Test("A title that repeats the app name is not appended")
    func redundantTitleIsDropped() {
        let w = window(app: "Notes", title: "Notes")
        #expect(w.displayLabel(shortenAppName: true, includeWindowTitle: true) == "Notes")
    }

    @Test("An empty title is not appended")
    func emptyTitleIsDropped() {
        let w = window(app: "Preview", title: "")
        #expect(w.displayLabel(shortenAppName: true, includeWindowTitle: true) == "Preview")
    }

    /// Hiding a title is a display decision. Someone typing "google" must still
    /// find the browser, and a file name must still find its window.
    @Test("Search text is unaffected by either setting")
    func searchIsUnaffected() {
        let w = window(app: "Google Chrome", title: "Inbox")
        #expect(w.searchableText.contains("Google"))
        #expect(w.searchableText.contains("Inbox"))
    }
}
