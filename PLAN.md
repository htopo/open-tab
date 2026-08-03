# OpenTab — Implementation Plan

> **Handoff document.** This is the complete specification and build plan for OpenTab, a
> native macOS window switcher. It is written to be executed by a fresh agent with no prior
> conversation context. Read it end to end before writing code.

---

## 0. Ground rules (read first)

**Origin.** OpenTab is a from-scratch implementation of a Windows-style window switcher for
macOS. The feature set was specified by the project owner from screenshots of a comparable
commercial app.

**Hard constraints — non-negotiable:**

1. **Write all code from scratch** against public, documented Apple APIs (plus the small,
   explicitly-listed set of undocumented CoreGraphics symbols in §6.3). Do not copy, port,
   translate, or adapt source code from any existing window-switcher project. Functionality
   and UI conventions are free to replicate; source code is not.
2. **No third-party branding anywhere** — not in code, comments, commit messages, docs,
   strings, asset names, the README, or the repo description. No competitor app names, no
   "inspired by X", no "alternative to X". The app is called **OpenTab** and stands alone.
3. **Design our own icon and assets.** Do not reuse anyone else's artwork.
4. **License: MIT.** This is only valid because §0.1 is followed. If any GPL-licensed code
   were copied in, the whole project would have to be GPL. Don't create that problem.
5. **Do not commit the reference screenshots** in the working directory. Add them to
   `.gitignore` (see §11.1). They are third-party UI captures used for spec purposes only.

**Repo:** `github.com/htopo/open-tab` — already created, private, owner `htopo`.
Local working directory: `/Users/topo/cmd-tab` (not yet a git repo — you will `git init` it).

**Environment facts (verified):**

- macOS 15.5 (24F74), Apple Silicon.
- Swift 6.1.2 available. **Xcode is NOT installed** — only Command Line Tools. `xcodebuild`
  does not work. This is why the build is SwiftPM + a bundling script, not an `.xcodeproj`.
- `gh` CLI authenticated as `htopo` (scopes: repo, workflow, gist, read:org).
- Homebrew installed at `/opt/homebrew`.

---

## 1. What we are building

A background utility (no Dock icon) that replaces the macOS ⌘Tab app switcher with a
**window** switcher: hold a modifier, press a key, and an overlay appears showing every open
window across every app, Space, and screen. Keep holding to cycle; release to focus the
selected window.

The three core differences from the built-in macOS switcher:

- Switches between **windows**, not apps — three Safari windows are three entries.
- Shows **live thumbnails** of each window, not just app icons.
- Includes **minimized, hidden, and other-Space** windows.

### 1.1 Decisions already locked by the project owner

| Decision | Choice | Consequence |
|---|---|---|
| Code signing | **Self-hosted Homebrew tap + local signing** (no Apple Developer ID) | Gatekeeper shows a first-launch warning. See §11 for how we minimize the pain. |
| Default hotkey | **⌘Tab, replacing the system switcher** | Requires disabling macOS's built-in symbolic hotkey via an undocumented API. Must be restored reliably on quit/uninstall — see §6.3. |
| v1 scope | **Full parity** with the specified feature surface | Everything in §5 ships. Build in the phase order of §12. |
| Crash reporting | **Explicitly out of scope** | Do not build it. Do not add a "Crash reports policy" setting. |

---

## 2. Architecture overview

```
┌──────────────────────────────────────────────────────────────┐
│  OpenTab (executable target)                                 │
│  AppDelegate · menu-bar item · wiring · lifecycle            │
└───────────┬──────────────────────────────────────────────────┘
            │
   ┌────────┴────────┬─────────────────┬──────────────────┐
   │                 │                 │                  │
┌──▼───────────┐ ┌───▼──────────┐ ┌────▼─────────┐ ┌──────▼──────┐
│ OpenTabInput │ │ OpenTabCore  │ │ OpenTabShot  │ │  OpenTabUI  │
│ event tap    │ │ window model │ │ thumbnails   │ │ overlay +   │
│ hotkey FSM   │ │ MRU · filter │ │ SCKit capture│ │ settings    │
│ symbolic key │ │ settings     │ │ cache        │ │ (SwiftUI)   │
└──────┬───────┘ └───┬──────────┘ └────┬─────────┘ └─────────────┘
       │             │                 │
       └─────────────▼─────────────────┘
              ┌──────────────┐
              │ OpenTabAX    │  Accessibility wrappers,
              │              │  private-symbol shims (dlsym)
              └──────────────┘
```

**Targets** (SwiftPM, `Package.swift`):

| Target | Kind | Responsibility |
|---|---|---|
| `OpenTabAX` | library | Typed wrappers over `AXUIElement`; AX observers; `dlsym`-based access to the undocumented symbols in §6.3. No app logic. |
| `OpenTabCore` | library | `WindowModel`, `AppModel`, window registry, MRU ordering, filtering/grouping, `Settings` store + schema, exceptions engine. Pure logic, unit-testable. |
| `OpenTabShot` | library | ScreenCaptureKit thumbnail capture, cache, invalidation, background refresh. |
| `OpenTabInput` | library | `CGEventTap` management, hotkey state machine, symbolic-hotkey takeover/restore, trackpad gesture. |
| `OpenTabUI` | library | SwiftUI views: overlay content, all settings panes, onboarding. |
| `OpenTab` | executable | `AppDelegate`, menu-bar item, `NSPanel` overlay host, dependency wiring, login item, updates. |
| `OpenTabCoreTests` | test | Unit tests for ordering, filtering, exceptions, settings migration. |

Rationale for the split: `OpenTabCore` holds everything testable without a running UI or TCC
permissions, which is most of the behavioral surface. AX and capture are isolated because they
are the parts that break across macOS releases.

### 2.1 Minimum deployment target

**macOS 14.0 (Sonoma).** Driven by `SCScreenshotManager.captureImage(contentFilter:configuration:)`,
which is 14.0+ and is the only non-deprecated way to grab a single window image.
`CGWindowListCreateImage` is deprecated as of macOS 14.

If macOS 13 support is later requested, add a `CGWindowListCreateImage` fallback path behind
an availability check in `OpenTabShot` — that is the only 14.0-gated API in the design. Do not
build that fallback now.

Test on macOS 15 (the dev machine) and macOS 26 if available.

### 2.2 UI framework

**SwiftUI for all view content; AppKit for window/panel shells.**

- The overlay must be an `NSPanel` with `.nonactivatingPanel` — SwiftUI cannot express this,
  and getting it wrong means the switcher steals focus from the app you are switching away
  from, which breaks the whole interaction. Host SwiftUI inside it via `NSHostingView`.
- The settings window is a plain SwiftUI window; it matches the sidebar + search layout
  naturally and is by far the fastest way to build the ~60 controls in §5.
- **Selection state is driven by the event tap, never by SwiftUI focus.** The overlay panel
  never becomes key except in Search mode. Treat the SwiftUI layer as a pure render of
  `SwitcherState`.

---

## 3. Permissions model

| Permission | Required for | Behavior if denied |
|---|---|---|
| **Accessibility** | Everything. Window enumeration, focusing, and the keyboard event tap all need it. | App is non-functional. Show onboarding window with a "Open System Settings" button; poll until granted. |
| **Screen Recording** | Thumbnails only. | Degrade gracefully: force style to App Icons, disable the Thumbnails option with an inline explanation and a "Grant" button. **The app must remain fully usable without it.** |

APIs: `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`,
`CGPreflightScreenCaptureAccess()` / `CGRequestScreenCaptureAccess()`.

**Important:** macOS caches the Accessibility grant against the app's code-signing identity.
Re-check `AXIsProcessTrusted()` on every launch and whenever the event tap fails to install —
do not assume a grant persists. See §11.3 for why the signing identity choice matters here.

---

## 4. Core interaction model

### 4.1 Hotkey state machine

This is the most subtle part of the app. Get it right before building any UI.

```
        ┌──────┐  modifier down + trigger key down
        │ IDLE │──────────────────────────────────┐
        └──▲───┘                                  ▼
           │                            ┌──────────────────┐
           │   modifier released        │  ARMED           │
           │   before holdThreshold     │  (panel hidden,  │
           │   ── instant MRU swap ─────│   selection = 1) │
           │                            └────────┬─────────┘
           │                                     │ holdThreshold elapses
           │                                     │ OR trigger pressed again
           │                                     ▼
           │                            ┌──────────────────┐
           │   modifier released        │  VISIBLE         │
           └────────────────────────────│  (overlay shown) │
               ── focus selection ──    └────────┬─────────┘
                                                 │ Esc / click-away
                                                 ▼  ── cancel, focus nothing ──
```

Key behaviors:

- **`holdThreshold` (default 150 ms, configurable).** A quick ⌘Tab tap performs an immediate
  swap to the previous window with **no visible panel flash**. This is what makes the app feel
  native. Do not skip it.
- While `VISIBLE`: trigger key advances selection, ⇧+trigger reverses, arrow keys navigate the
  grid, mouse hover selects, click commits.
- **"After keys are released"** setting (§5.1) changes what modifier-release does:
  - `Focus` — commit and focus the selected window. (default)
  - `Hold` — the panel stays open after release; commit requires Return or click.
  - `Search` — the panel stays open and keyboard input goes to a search field.
- Typing any printable character while `VISIBLE` enters search-filter mode.

### 4.2 Event tap

- `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
  eventsOfInterest: keyDown | keyUp | flagsChanged, ...)`.
- Must be `.defaultTap` (not `.listenOnly`) so we can swallow the trigger event and prevent it
  reaching the focused app.
- **Handle tap disable-by-timeout.** macOS disables a tap that blocks too long and posts
  `.tapDisabledByTimeout`. Listen for it and re-enable via `CGEvent.tapEnable`. Never do
  blocking work (capture, enumeration, disk I/O) inside the tap callback — post to a serial
  queue and return immediately. A slow callback here makes the whole system's typing stutter.
- Re-install the tap on wake from sleep and on display reconfiguration.

### 4.3 Taking over ⌘Tab

macOS reserves ⌘Tab, ⌘⇧Tab, and ⌘` at a level above event taps. To bind them we disable the
corresponding *symbolic hotkeys* via the undocumented `CGSSetSymbolicHotKeyEnabled` (§6.3).

**This is the highest-risk area in the app.** Requirements:

1. Only disable the specific IDs whose key combination a user shortcut actually claims.
   Symbolic hotkey IDs: `1` = ⌘Tab, `2` = ⌘⇧Tab, `27` = ⌘\` (next window in app).
   **Verify these IDs empirically at runtime** by reading the current state before writing —
   do not trust the constants blindly across macOS versions.
2. **Persist a "hotkeys currently disabled by us" record in UserDefaults before disabling.**
   The change survives app quit and even reboot. If the app crashes without restoring, the
   user is left with a broken ⌘Tab and no switcher — the worst possible failure.
3. Restore on: normal quit (`applicationWillTerminate`), `SIGINT`/`SIGTERM` handlers, and
   **at next launch** if the persisted record shows a dirty state from a previous run.
4. Provide **Settings → Controls → "Restore system shortcuts"** as a manual escape hatch, and
   document the `defaults`-based recovery command in the README's troubleshooting section.
5. If the symbol cannot be resolved (Apple removed it), fall back gracefully: keep the
   shortcut bound but show a one-time notice that the system switcher will also appear, and
   suggest ⌥Tab instead. Do not crash, do not silently do nothing.

---

## 5. Feature specification

Every setting below ships in v1. Persist all of it in a single versioned settings store
(§8). Options are listed as `Label: option | option | option` with the default in **bold**.

### 5.1 Appearance pane

**Style** — three switcher looks, shown as three preview tiles:
- **Thumbnails** — grid of live window previews with app icon, title, and window-count badge.
- **App Icons** — compact dock-like row of large app icons.
- **Titles** — vertical list of `AppName — Window Title` rows with small icons.

| Setting | Options |
|---|---|
| Size | **Small** \| Medium \| Large \| Auto |
| Theme | Light \| Dark \| **System** |
| After keys are released | **Focus** \| Hold \| Search |
| Preview selected window | toggle, **off** |

- **Auto size**: scale thumbnails to the window count — larger when few windows, smaller when
  many — targeting a stable overall panel area.
- **Preview selected window**: dim/highlight the actual selected window on screen while the
  switcher is open, so you can see it behind the overlay.

**Multiple screens → Show on:** **Active screen** | Screen with mouse | Screen with the
focused window | (list of connected displays by name).

**"Animations…" sheet:** fade-in duration, fade-out duration, selection-move animation
on/off, master "reduce animations" toggle (also honor
`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`).

**"Customize more…" sheet** (advanced appearance): max rows, max columns, panel opacity,
corner radius, inter-cell padding, title font size, show/hide app icon badge on thumbnails,
show/hide window-count badge, show/hide minimized & hidden indicator badges, show window title
under thumbnail, highlight style (border vs fill).

### 5.2 Controls pane

**Shortcut list** with `+` / `−` buttons, up to **9** shortcuts. Each row shows its name and
current binding. Shortcut 1 defaults to **⌘ + Tab**; shortcut 2 defaults to **⌥ + \`**.

Each shortcut has:

**Trigger:** `Hold [modifier field] and press [key field]`. The modifier field accepts any
combination of ⌘⌥⌃⇧ (captured by recording a keypress). The key field accepts any key.

Then three tabs of per-shortcut configuration:

**Filtering tab**

| Setting | Options |
|---|---|
| Show windows from applications | **All apps** \| Active app \| All apps except active |
| Show windows from Spaces | **All Spaces** \| Active Space \| Visible Spaces |
| Show windows from screens | **All screens** \| Active screen |
| Show minimized windows | **Show** \| Hide \| Show at the end |
| Show hidden windows | **Show** \| Hide \| Show at the end |
| Show fullscreen windows | **Show** \| Hide \| Show at the end |
| Show apps with no open window | Show \| Hide \| **Show at the end** |

**Appearance tab** — per-shortcut override of style / size / theme, or "use global".

**Ordering & Grouping tab**
- Order: **Most recently used** \| Least recently used \| Application launch order \|
  Alphabetical by app \| Space then app
- Group windows by application: toggle, **off**
- Put the active window first: toggle, **on**

**Gesture** — an entry below the shortcut list, **Disabled** by default. When enabled, a
three- or four-finger trackpad swipe opens the switcher. Implement via
`NSEvent.addGlobalMonitorForEvents(matching: [.swipe, .magnify])` or a scroll-wheel monitor
with `momentumPhase` tracking. This is the lowest-priority item in the spec — build it last
and ship it disabled.

**"Additional controls…" sheet:** hold threshold (ms), mouse hover selects (on/off),
click-outside-to-dismiss, scroll-to-navigate, Esc cancels, wrap-around at list ends.

**"Shortcuts when active…" sheet** — keys that work while the overlay is open:
close window (**⌘W**), minimize window (**⌘M**), quit app (**⌘Q**), hide app (**⌘H**),
toggle fullscreen (**⌘F**), select next/previous. Each is individually rebindable and
disableable.

### 5.3 General pane

| Setting | Type | Default |
|---|---|---|
| Start at login | toggle | on |
| Menubar icon | toggle + icon-variant picker | off |
| Capture windows in the background | toggle | on |
| Language | picker (System Default + shipped localizations) | System Default |
| Updates policy | Auto-install periodically \| Check and notify \| Never check | Check and notify |

- **Capture windows in the background** needs the exact explanatory subtitle from the spec:
  *"When disabled, avoids the macOS purple screen-recording indicator, and avoids flickers when
  playing DRM video. Thumbnails will be less up-to-date."*
  When off, capture on demand at switcher-open time only.
- **Check for updates now…** button.
- **Export settings… / Import settings… / Reset settings and restart…** buttons.
- **No crash reporting.** Owner explicitly excluded it.

### 5.4 Exceptions pane

A master list of per-app rules with `+` / `−`, plus a detail editor on the right.

Each rule: app icon, **Bundle ID** (text field, with an app-picker for browsing
`/Applications`), and two policies:

| Setting | Options |
|---|---|
| Hide windows | Always \| Never \| When app is not active |
| Ignore shortcuts | Always \| **Never** \| When app is fullscreen |

"Ignore shortcuts = Always" means OpenTab passes its hotkeys through untouched while that app
is frontmost — essential for remote-desktop and VM clients where ⌘Tab must reach the guest OS.

**Ship these defaults** (all remote-desktop/VM apps, `Ignore shortcuts: Always`):
`com.microsoft.rdc.macos`, `com.teamviewer.TeamViewer`, `org.virtualbox.app.VirtualBoxVM`,
`com.parallels.desktop.console`, `com.citrix.XenAppViewer`, `com.vmware.fusion`,
`com.nicesoftware.dcvviewer`, `com.realvnc.vncviewer`.

### 5.5 Settings-window chrome

- Left sidebar: **Search field**, then Appearance / Controls / General / Exceptions with SF
  Symbol icons. Search filters across *all* panes by setting label and jumps to the match —
  implement by giving every setting a stable id + searchable keyword list in one registry.
- Bottom-left: a **Quit OpenTab** button.
- No trial/upgrade/paywall UI. Every feature is free.

---

## 6. Window discovery engine (`OpenTabCore` + `OpenTabAX`)

### 6.1 Data model

```swift
struct WindowID: Hashable { let cgWindowID: CGWindowID; let pid: pid_t }

struct WindowModel {
    let id: WindowID
    let axElement: AXUIElement
    var title: String
    var appBundleID: String
    var appName: String
    var appIcon: NSImage?
    var isMinimized: Bool
    var isHidden: Bool          // owning app is hidden
    var isFullscreen: Bool
    var spaceID: Int?           // nil if undeterminable
    var displayID: CGDirectDisplayID?
    var frame: CGRect
    var lastFocusedAt: Date     // drives MRU
}
```

### 6.2 Discovery strategy

Primary source is the **Accessibility API**, because it is the only route that sees minimized
windows, windows on other Spaces, and windows of hidden apps.

1. Enumerate `NSWorkspace.shared.runningApplications`, keeping `.regular` policy apps plus
   `.accessory` apps that report windows.
2. For each: `AXUIElementCreateApplication(pid)` → `kAXWindowsAttribute`.
3. Filter to real windows: `kAXRoleAttribute == kAXWindowRole`, and
   `kAXSubroleAttribute` in `{kAXStandardWindowSubrole, kAXDialogSubrole}`. Drop
   `AXUnknown`, sheets, popovers, and zero-size windows.
4. Read `kAXTitleAttribute`, `kAXMinimizedAttribute`, `kAXPositionAttribute`, `kAXSizeAttribute`,
   and `AXFullScreen`.
5. Map each `AXUIElement` to a `CGWindowID` via `_AXUIElementGetWindow` (§6.3) — required to
   join with capture and Space data.
6. Cross-reference `CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)` for geometry,
   `kCGWindowLayer` (drop non-zero layers: menus, docks, overlays), and to catch windows AX
   misses.

**Performance is a hard requirement — the overlay must appear in well under 100 ms.**
Full AX enumeration is far too slow to run on every hotkey press (it can take hundreds of ms
with many apps open). Therefore:

- Build the registry **once at launch**, then maintain it **incrementally** via AX observers:
  `kAXWindowCreatedNotification`, `kAXUIElementDestroyedNotification`,
  `kAXFocusedWindowChangedNotification`, `kAXWindowMiniaturizedNotification`,
  `kAXWindowDeminiaturizedNotification`, `kAXTitleChangedNotification`,
  `kAXApplicationHiddenNotification`, `kAXApplicationShownNotification`.
- Plus `NSWorkspace` notifications: `didLaunchApplicationNotification`,
  `didTerminateApplicationNotification`, `didActivateApplicationNotification`,
  `activeSpaceDidChangeNotification`.
- Run a **cheap reconciliation pass** on a background queue when the switcher opens, to catch
  drift; never block the overlay on it.
- Guard every AX call with a timeout — `AXUIElementSetMessagingTimeout(element, 1.0)`. A hung
  or unresponsive app will otherwise block the enumeration thread indefinitely. This is a real
  and common failure; do not skip it.

### 6.3 Undocumented symbols

We need four symbols with no public equivalent. **Resolve every one via `dlsym` at runtime,
never by direct linkage**, so that a missing symbol on a future macOS degrades a feature
instead of preventing launch.

| Symbol | Purpose | Fallback if unavailable |
|---|---|---|
| `_AXUIElementGetWindow` | `AXUIElement` → `CGWindowID` | Heuristic match on (pid, title, frame) against `CGWindowListCopyWindowInfo`. Lossy but workable. |
| `CGSSetSymbolicHotKeyEnabled` | Free up ⌘Tab / ⌘⇧Tab / ⌘\` | Disable ⌘Tab binding; tell the user to use ⌥Tab. See §4.3.5. |
| `CGSCopyWindowsWithOptionsAndTags` | Windows across all Spaces | Fall back to current-Space-only filtering; disable the "All Spaces" filter option with a tooltip. |
| `CGSGetWindowWorkspace` | Which Space a window is on | Report `spaceID = nil`; Space filtering degrades to "all". |

Wrap all four in a single `PrivateSymbols` enum in `OpenTabAX` that resolves lazily and exposes
`Bool` availability flags the UI can query. Add a unit test asserting each resolves on the
current OS, so a future macOS breaking one shows up as a test failure rather than a bug report.

### 6.4 Focusing a window

Order matters — this exact sequence is what works reliably on macOS 14+:

1. If `isMinimized`: `AXUIElementSetAttributeValue(window, kAXMinimizedAttribute, false)`.
2. If owning app `isHidden`: `NSRunningApplication.unhide()`.
3. `AXUIElementPerformAction(window, kAXRaiseAction)` — this is what actually raises the
   specific window, and it triggers the Space switch if needed.
4. `AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute, true)`.
5. `NSRunningApplication.activate()` — use the macOS 14+ signature.
   `NSApplicationActivateIgnoringOtherApps` is deprecated; do not use it.

Steps 3 and 4 are both required. `activate()` alone does not reliably raise a *specific*
window on macOS 14+, and `kAXRaiseAction` alone does not always bring the app forward.

---

## 7. Thumbnail capture (`OpenTabShot`)

- List capturable windows: `SCShareableContent.excludingDesktopWindows(false,
  onScreenWindowsOnly: false)`; match `SCWindow.windowID` to our `CGWindowID`.
- Capture: `SCScreenshotManager.captureImage(contentFilter:configuration:)` with an
  `SCContentFilter(desktopIndependentWindow:)`.
- Set `SCStreamConfiguration.width/height` to the **target display size in pixels**, not the
  window's native size. Capturing a 6K window to render a 200 pt thumbnail is pure waste.
- `captureImage` is `async` — never call it from the event-tap callback or the main thread.
  Capture concurrently with a `TaskGroup`, bounded to ~4 in flight.
- **Cache** by `CGWindowID` with the capture timestamp. Invalidate on window resize, on
  title change, and after a staleness interval.
- **Show something immediately.** Render the overlay from cache (or the app icon as a
  placeholder) on the first frame and fill thumbnails in as they arrive. Never block the
  overlay on capture.
- **Minimized and other-Space windows cannot be captured** — nothing is composited for them.
  Serve the last cached image if we have one, otherwise the app icon. Capture eagerly *before*
  a window is minimized (on `kAXWindowMiniaturizedNotification` the content is often already
  gone, so capture on focus-loss instead).
- Honor the **"Capture windows in the background"** setting: when on, refresh cached
  thumbnails on a low-priority timer; when off, capture only at switcher-open time.

---

## 8. Settings store

- Single `Codable` `Settings` struct with an explicit `schemaVersion: Int`.
- Persist as JSON in `~/Library/Application Support/OpenTab/settings.json` — **not** in
  `UserDefaults`. JSON gives us free Export/Import (§5.3) and human-readable diffs.
  (`UserDefaults` is still used for the small crash-safety flags in §4.3.)
- Write atomically (`Data.write(to:options:.atomic)`), debounced ~500 ms.
- Migration: a `migrate(from:to:)` chain keyed on `schemaVersion`. Unknown future version →
  back up the file and start from defaults rather than crashing.
- Every setting needs a stable string id + searchable keywords, registered in one place, so
  the settings search field (§5.5) can be implemented as a lookup rather than hand-maintained.

---

## 9. Overlay panel

```swift
let panel = NSPanel(contentRect: .zero,
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false)
panel.level = .popUpMenu          // above .floating; must clear fullscreen apps
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hidesOnDeactivate = false
panel.becomesKeyOnlyIfNeeded = true
panel.ignoresMouseEvents = false
```

- `.nonactivatingPanel` + `becomesKeyOnlyIfNeeded` is what keeps the previously-focused app
  focused while the switcher is open. Critical — verify this early.
- `.fullScreenAuxiliary` is what lets the overlay appear over fullscreen apps.
- Only make the panel key when entering **Search** mode (it needs a first responder for text
  input); drop key status again on exit.
- One panel per screen is unnecessary — create a single panel and reposition it per the
  "Show on" setting. Recompute placement on `NSApplication.didChangeScreenParametersNotification`.
- Background: `NSVisualEffectView` with `.hudWindow` material, honoring the Theme setting via
  `appearance = NSAppearance(named: .darkAqua / .aqua)` or nil for System.

---

## 10. Testing

**Unit tests (`OpenTabCoreTests`)** — no TCC permissions needed, must pass in CI:
- MRU ordering, including "active window first" and each ordering mode.
- Every filter combination in §5.2, and filter composition order.
- Exceptions matching, including bundle-ID prefix behavior and the shipped defaults.
- Settings round-trip encode/decode; migration from each prior schema version; corrupt-file
  and future-version recovery.
- Hotkey state-machine transitions, driven by a synthetic event source (inject events into the
  FSM directly — do not require a real event tap).
- `PrivateSymbols` resolution smoke test (§6.3).

**Manual QA checklist** — put this in `docs/QA.md` and run before each release:
- Quick ⌘Tab tap swaps to previous window with no panel flash.
- Hold ⌘, press Tab repeatedly, release → correct window focused.
- Minimized window: appears, is selectable, un-minimizes and focuses.
- Window on another Space: appears, focuses, Space switches.
- Fullscreen app: overlay draws *above* it.
- Multi-monitor: overlay appears on the screen chosen by "Show on".
- Deny Screen Recording → app still works, Thumbnails style disabled with explanation.
- Quit the app → ⌘Tab returns to the system switcher.
- `kill -9` the app, relaunch → ⌘Tab state is repaired on launch.
- Exception app (e.g. a VM client) frontmost → ⌘Tab passes through to the guest.
- 50+ open windows → overlay still appears in under 100 ms.

---

## 11. Packaging and distribution

Owner's choice: **no Apple Developer ID.** This has real consequences; the plan below
minimizes them.

### 11.1 Repo layout

```
open-tab/
├── Package.swift
├── Sources/{OpenTab,OpenTabCore,OpenTabAX,OpenTabShot,OpenTabInput,OpenTabUI}/
├── Tests/OpenTabCoreTests/
├── Resources/
│   ├── Info.plist            # LSUIElement=1, bundle id, version
│   ├── OpenTab.entitlements
│   └── Assets/               # our own icon (.icns), SF Symbol overrides
├── Scripts/
│   ├── bundle.sh             # SPM build → OpenTab.app
│   ├── sign.sh               # codesign with local identity
│   └── dmg.sh                # OpenTab.app → OpenTab.dmg
├── .github/workflows/{ci.yml,release.yml}
├── docs/{QA.md,PERMISSIONS.md,TROUBLESHOOTING.md}
├── .gitignore                # MUST include: *.png screenshots, .build/, *.app, *.dmg
├── LICENSE                   # MIT
└── README.md
```

`.gitignore` must exclude the reference screenshots currently sitting in the working directory
(`Screenshot*.png`). Per §0.5 they must never be committed.

### 11.2 Build

`Scripts/bundle.sh`:
1. `swift build -c release --arch arm64 --arch x86_64` (universal binary).
2. Assemble `OpenTab.app/Contents/{MacOS,Resources,Info.plist}`.
3. Copy the `.icns` and any resource bundles.
4. Sign (§11.3).

`Info.plist` essentials: `LSUIElement = true` (no Dock icon), `CFBundleIdentifier =
io.github.htopo.opentab` (**never change this** — TCC grants are keyed to it),
`LSMinimumSystemVersion = 14.0`, `NSAccessibilityUsageDescription`, and a clear
`CFBundleShortVersionString`.

Not sandboxed. The Accessibility API and event taps do not function in the App Sandbox, so
there is no sandbox entitlement to add — say so explicitly in `docs/PERMISSIONS.md`.

### 11.3 Signing — use a stable self-signed certificate, not ad-hoc

This detail matters more than it looks. macOS keys TCC permission grants (Accessibility,
Screen Recording) to an app's **designated requirement**, which is derived from its signing
identity:

- **Ad-hoc signed** (`codesign -s -`): the requirement is derived from the binary hash, which
  changes on every build. **The user must re-grant Accessibility after every single update.**
  For a window switcher that is a miserable experience.
- **Self-signed certificate**: the requirement references the certificate, which is stable
  across builds. **Permissions survive updates.** Gatekeeper still warns on first launch
  (it is not notarized), but that is a one-time cost instead of a per-update one.

Therefore: generate a self-signed code-signing certificate **once**, export it as a `.p12`,
store it as the GitHub Actions secret `SIGNING_CERT_P12` (+ `SIGNING_CERT_PASSWORD`), and have
`Scripts/sign.sh` import it into a temporary keychain and sign with it. Document the
generation steps in `docs/TROUBLESHOOTING.md` so the identity can be recreated.

Fall back to `codesign -s - --deep` only when no certificate is configured (e.g. a
contributor's local build), and print a warning explaining the permission-reset consequence.

### 11.4 Homebrew tap

Homebrew's main `cask` tap **disables casks that fail Gatekeeper checks as of 2026-09-01**,
so an unnotarized OpenTab cannot live there. A personal tap can, and personal taps may still
strip the quarantine attribute in a `postflight`.

Create a second repo `htopo/homebrew-tap` containing `Casks/open-tab.rb`:

```ruby
cask "open-tab" do
  version "0.1.0"
  sha256 "..."
  url "https://github.com/htopo/open-tab/releases/download/v#{version}/OpenTab-#{version}.dmg"
  name "OpenTab"
  desc "Window switcher for macOS"
  homepage "https://github.com/htopo/open-tab"
  depends_on macos: ">= :sonoma"
  app "OpenTab.app"
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/OpenTab.app"],
                   sudo: false
  end
  zap trash: ["~/Library/Application Support/OpenTab",
              "~/Library/Preferences/io.github.htopo.opentab.plist"]
end
```

Install becomes: `brew install --cask htopo/tap/open-tab`. The `postflight` removes the
quarantine flag so the app opens without the Gatekeeper dialog. The README must still document
the manual first-launch path (right-click → Open, or
`xattr -dr com.apple.quarantine /Applications/OpenTab.app`) for people who download the DMG
directly.

**Be honest in the README** about the app being unnotarized and why. Do not paper over it.

### 11.5 Auto-updates

Use **Sparkle 2** (SPM dependency). Sparkle's EdDSA appcast signing is independent of Apple
code signing, so it works fine for an unnotarized app. Generate the EdDSA key pair once, keep
the private key in the GitHub secret `SPARKLE_PRIVATE_KEY`, ship the public key in
`Info.plist`. `release.yml` builds the DMG, signs the appcast entry, and publishes
`appcast.xml` to GitHub Pages or the release assets.

Wire the three "Updates policy" options (§5.3) to `SPUUpdater`'s
`automaticallyChecksForUpdates` / `automaticallyDownloadsUpdates`.

### 11.6 CI

- `ci.yml` — on push/PR: `swift build` + `swift test` on `macos-14`. Unit tests only; no
  TCC-dependent tests in CI.
- `release.yml` — on tag `v*`: universal build, sign, DMG, checksum, GitHub Release, appcast
  update, and open a PR against `htopo/homebrew-tap` bumping version + sha256.

---

## 12. Build phases

Work in this order and commit at each phase boundary. Each phase should leave the app in a
launchable state.

| # | Phase | Deliverable | Done when |
|---|---|---|---|
| 0 | **Scaffold** | Repo init, `Package.swift`, all targets, `bundle.sh`, MIT LICENSE, `.gitignore` (incl. screenshots) | `./Scripts/bundle.sh` produces a launchable `OpenTab.app` that shows a menu-bar item and quits cleanly |
| 1 | **Permissions & onboarding** | AX + Screen Recording checks, onboarding window, polling for grant | Fresh install walks a user to a working permission state |
| 2 | **Window engine** | `OpenTabAX`, `PrivateSymbols`, registry, AX observers, MRU | A debug menu item logs the full window list, correct and under 100 ms warm |
| 3 | **Hotkey engine** | Event tap, FSM (§4.1), symbolic-hotkey takeover + restore (§4.3) | ⌘Tab tap swaps windows; hold shows a placeholder panel; quit restores system ⌘Tab |
| 4 | **Overlay UI** | `NSPanel` shell, Thumbnails/App Icons/Titles, sizes, themes, multi-screen | All three styles render and navigate correctly, over fullscreen apps |
| 5 | **Capture** | `OpenTabShot`, cache, background refresh, graceful no-permission path | Thumbnails appear progressively; denying Screen Recording degrades cleanly |
| 6 | **Actions** | Focus (§6.4), close/minimize/quit/hide/fullscreen, "Shortcuts when active" | Every action in §5.2 works on the selected window |
| 7 | **Settings: Appearance + General** | Settings window shell, sidebar, search registry, two panes | Every §5.1 and §5.3 control is wired and persists |
| 8 | **Settings: Controls** | Multi-shortcut list, trigger recorder, Filtering/Appearance/Ordering tabs | 9 independent shortcuts with per-shortcut filters all work |
| 9 | **Exceptions** | Exceptions pane, matching engine, shipped defaults | ⌘Tab passes through to a VM/RDP client |
| 10 | **Polish** | Search mode, Auto size, Preview selected window, animations, login item, import/export, localization scaffolding | Full §5 parity |
| 11 | **Gesture** | Trackpad gesture trigger, shipped disabled | Opt-in gesture opens the switcher |
| 12 | **Ship** | Sparkle, `release.yml`, self-signed cert, DMG, `homebrew-tap` repo, README + docs | `brew install --cask htopo/tap/open-tab` installs a working app on a clean machine |

Phases 0–6 are the app. Phases 7–9 are the configuration surface. 10–12 are polish and
delivery. If time pressure appears, phases 11 (gesture) and the Language picker in 10 are the
only safely deferrable items — everything else is spec.

---

## 13. Known risks

| Risk | Impact | Mitigation |
|---|---|---|
| Symbolic-hotkey state left dirty by a crash | User's ⌘Tab is broken with no switcher — worst case failure | Persist-before-disable + repair-on-launch + manual restore button + documented recovery (§4.3) |
| Apple removes an undocumented symbol | Feature loss or launch failure | `dlsym` resolution + per-symbol fallbacks + availability unit test (§6.3) |
| AX enumeration too slow | Overlay feels laggy, app feels broken | Incremental registry via observers, never full-enumerate on hotkey, `AXUIElementSetMessagingTimeout` (§6.2) |
| Unresponsive app hangs AX calls | Switcher freezes | Messaging timeout on every element; enumerate off the main thread |
| Event tap disabled by timeout | Hotkey silently stops working | Handle `.tapDisabledByTimeout`, re-enable, never block in the callback (§4.2) |
| Gatekeeper friction on first launch | Users bounce during install | Tap `postflight` strips quarantine; README documents the manual path honestly (§11.4) |
| TCC re-prompt on every update | Users abandon the app | Stable self-signed certificate rather than ad-hoc signing (§11.3) |
| Panel steals focus | Breaks the core interaction | `.nonactivatingPanel` + `becomesKeyOnlyIfNeeded`; verify in phase 3 before building UI |

---

## 14. First actions for the implementing agent

1. `cd /Users/topo/cmd-tab && git init && git branch -M main`
2. Write `.gitignore` **first**, with `Screenshot*.png`, `.build/`, `*.app`, `*.dmg`, `.DS_Store`.
   Confirm `git status` does not list the screenshots before the first commit.
3. `git remote add origin https://github.com/htopo/open-tab.git`
4. Build phase 0, commit, push, and confirm CI is green.
5. Then proceed through §12 in order.

Do not push anything referencing another product's name. Re-read §0 before the first commit.
