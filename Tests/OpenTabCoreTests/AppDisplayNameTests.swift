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

    @Test("Full shows the title as the application wrote it")
    func fullLabel() {
        let w = window(app: "Google Chrome", title: "Inbox")
        #expect(w.displayLabel(shortenAppName: true, windowTitle: .full) == "Chrome — Inbox")
    }

    @Test("Off leaves the application name alone")
    func titleSuppressed() {
        let w = window(app: "Google Chrome", title: "Inbox")
        #expect(w.displayLabel(shortenAppName: true, windowTitle: .hidden) == "Chrome")
        #expect(w.displayLabel(shortenAppName: false, windowTitle: .hidden) == "Google Chrome")
    }

    /// The case that prompted the setting: an editor's title is the file, its
    /// state, and then the project. Only the project distinguishes two of its
    /// windows; the file is what the user is choosing *between*, not by.
    @Test("Last part keeps the project and drops the file")
    func lastPartOfAnEditorTitle() {
        let w = window(app: "Cursor", title: "index.mdx (Working Tree) (index.mdx) — horizon")
        #expect(w.displayLabel(shortenAppName: true, windowTitle: .lastComponent) == "Cursor — horizon")
    }

    /// A window whose title merely repeats the application name adds nothing, so
    /// the separator is not drawn for it either.
    @Test("A title that repeats the app name is not appended")
    func redundantTitleIsDropped() {
        let w = window(app: "Notes", title: "Notes")
        #expect(w.displayLabel(shortenAppName: true, windowTitle: .full) == "Notes")
        #expect(w.displayLabel(shortenAppName: true, windowTitle: .lastComponent) == "Notes")
    }

    @Test("An empty title is not appended")
    func emptyTitleIsDropped() {
        let w = window(app: "Preview", title: "")
        #expect(w.displayLabel(shortenAppName: true, windowTitle: .full) == "Preview")
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

/// Reducing a title to its last component.
///
/// Titles are written most-specific-first, so the tail is what tells two windows
/// of one application apart and the head is the document being chosen *between*.
/// Every fixture here is a real title taken from a running machine.
@Suite("Window title trimming")
struct WindowTitleFormatterTests {

    @Test("An editor's project survives, the file does not")
    func editorTitle() {
        #expect(WindowTitleFormatter.lastComponent(
            of: "index.mdx (Working Tree) (index.mdx) — horizon", appName: "Cursor"
        ) == "horizon")

        #expect(WindowTitleFormatter.lastComponent(
            of: "collaborator-interview-robustness.canvas.tsx — horizon [SSH: mac-mini]",
            appName: "Cursor"
        ) == "horizon [SSH: mac-mini]")
    }

    /// A browser writes page, then itself, then the profile. Two profiles are
    /// exactly what makes two of its windows different.
    @Test("A browser's profile survives")
    func browserTitle() {
        #expect(WindowTitleFormatter.lastComponent(
            of: "Inbox (3,998) - htrnbs@gmail.com - Gmail - Google Chrome - Hernán",
            appName: "Google Chrome"
        ) == "Hernán")
    }

    /// Plenty of applications end their titles with their own name, which the row
    /// already shows in larger type.
    @Test("A trailing application name is stepped over")
    func trailingAppNameIsSkipped() {
        #expect(WindowTitleFormatter.lastComponent(
            of: "agente-ofertas (Channel) - AI R&D - Slack", appName: "Slack"
        ) == "AI R&D")
    }

    @Test("A title with no separator is left whole")
    func singleComponentTitle() {
        #expect(WindowTitleFormatter.lastComponent(of: "Untitled", appName: "TextEdit") == "Untitled")
    }

    /// All three separators appear in practice, and which one an application chose
    /// says nothing about what it put on either side.
    @Test("Em dash, en dash and hyphen all count")
    func allSeparators() {
        #expect(WindowTitleFormatter.lastComponent(of: "a — b", appName: "X") == "b")
        #expect(WindowTitleFormatter.lastComponent(of: "a – b", appName: "X") == "b")
        #expect(WindowTitleFormatter.lastComponent(of: "a - b", appName: "X") == "b")
    }

    /// A hyphen inside a word is not a separator; only a spaced one is.
    @Test("Hyphenated words are not split")
    func hyphenInsideAWordIsNotASeparator() {
        #expect(WindowTitleFormatter.lastComponent(
            of: "well-known-file.txt", appName: "TextEdit"
        ) == "well-known-file.txt")
    }

    @Test("Nothing worth adding returns nil")
    func nothingToAdd() {
        #expect(WindowTitleFormatter.title("", appName: "Preview", display: .full) == nil)
        #expect(WindowTitleFormatter.title("Notes", appName: "Notes", display: .full) == nil)
        #expect(WindowTitleFormatter.title("x", appName: "Preview", display: .hidden) == nil)
    }
}
