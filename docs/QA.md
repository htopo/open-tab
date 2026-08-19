# Manual QA checklist

Automated tests cover the logic that does not need permissions or a running UI —
ordering, filtering, exceptions, settings migration, the hotkey state machine.
Everything below needs a real session with real windows, so it is run by hand
before every release.

Record the macOS version and whether the build is universal at the top of each
run.

```
Date:            ____________________
Version / build: ____________________
macOS:           ____________________
Machine:         ____________________ (Apple Silicon / Intel)
Displays:        ____________________
```

---

## Core interaction

- [ ] **Quick tap.** A fast ⌘Tab tap swaps to the previous window with **no panel
      flash**. Repeat ten times quickly; the panel must never blink.
- [ ] **Hold and cycle.** Hold ⌘, press Tab repeatedly, release. The window that
      was highlighted is the one that gets focus.
- [ ] **Rapid alternation.** Tap ⌘Tab about twice a second for ten seconds. Every
      tap must swap. A tap that lands while the background reconciliation from the
      previous one is still in flight used to select the window already in front,
      so the switch appeared to be skipped — check the log for two consecutive
      `Focusing` lines naming the same window.
- [ ] **Reverse.** With the switcher open, tapping ⇧ moves the selection back one
      entry per tap and wraps correctly at the start of the list. Holding ⇧ down
      must not repeat, and releasing it must not step.
- [ ] **Reverse, classic.** With *Shift steps backwards* off, ⌘⇧Tab moves back
      one entry per press and a lone ⇧ does nothing.
- [ ] **No double step.** A single ⌘⇧Tab never moves two entries, under either
      setting.
- [ ] **Arrow keys** navigate the grid in all four directions while the overlay is
      open, and move exactly **one** entry per press — not two.
- [ ] **Apps that hide from Accessibility.** Put a Catalyst or Electron app with a
      real window on a second Desktop. It must appear as a *window* — app name plus
      its title — never as an "app with no open window" entry. Check the log for
      `recovered N from the window server`.
- [ ] **No phantom windows.** Count a browser's entries in the switcher against its
      real windows. The window server lists offscreen scratch windows and tab
      previews too; recovery must not put those in the list.
- [ ] **Another Desktop.** With windows on a second Desktop, pick one. macOS
      travels to that Desktop and the window is frontmost. (Requires Desktop &
      Dock → "When switching to an application, switch to a Space with open
      windows for the application", which is on by default.)
- [ ] **Space peek.** Set *Controls → Filtering → Show windows from Spaces* to
      **Active Space**. The list now holds only this Desktop's windows. Hold the
      space bar: the rest appear, and the highlight stays on the same window
      rather than sliding to a different one. Let go: they disappear again.
      Release ⌘ while holding space and the revealed window is the one focused.
- [ ] **Space is still a space.** With *After keys are released* set to
      **Search**, typing a space into the search field inserts a space instead of
      revealing Spaces.
- [ ] **Mouse hover** changes the selection; **click** commits it.
- [ ] **Scroll damping.** With the overlay open, flick two fingers across the
      trackpad once and lift them. The selection moves a step or two and then
      *stops*. It must not keep travelling while the momentum coasts — check the
      log for a burst of `Navigate by scroll` lines after your fingers left.
- [ ] **Esc** dismisses the overlay and focuses nothing — the app you started from
      is still frontmost.
- [ ] **Click away** dismisses the overlay without focusing anything.
- [ ] **Focus is never stolen.** While the overlay is open, the previously focused
      app still shows as active (its menu bar remains). Type into it after
      dismissing with Esc — keystrokes land in the right place.

## Window coverage

- [ ] **Minimized window** appears in the list, is selectable, and un-minimizes
      and focuses on commit.
- [ ] **Hidden app's window** (⌘H the app first) appears, and the app unhides on
      commit.
- [ ] **Window on another Space** appears, focuses, and macOS switches Space.
- [ ] **Fullscreen app** appears, and the overlay draws **above** it rather than
      behind or on another Space.
- [ ] **Multiple windows of one app** appear as separate entries (open three
      Finder windows; expect three).
- [ ] **Apps with no open window** appear at the end when that filter is set to
      "Show at the end", and activate correctly on commit.
- [ ] **A newly opened window** appears without needing a relaunch — the
      incremental registry is tracking it.
- [ ] **A closed window** disappears from the list immediately.
- [ ] **A renamed window** (change a browser tab) shows the new title.

## Display and appearance

- [ ] All three styles — **Thumbnails**, **App Icons**, **Titles** — render and
      navigate correctly.
- [ ] All four sizes render, and **Auto** visibly adapts between a 3-window and a
      40-window session.
- [ ] **Light / Dark / System** themes each apply, including when the system theme
      changes while the overlay is open.
- [ ] **Multi-monitor:** the overlay appears on the screen chosen by *Show on* for
      each of "Active screen", "Screen with mouse", "Screen with focused window",
      and a specific named display.
- [ ] Unplugging or plugging a display while the app runs does not misplace the
      overlay on the next open.
- [ ] **Reduce motion** (System Settings → Accessibility → Display) suppresses
      animations even with OpenTab's own animation settings on.

## Permissions

- [ ] **Fresh install, no Accessibility:** onboarding appears and explains what is
      needed; the "Open System Settings" button lands on the right pane.
- [ ] Granting Accessibility makes the app start working **without a relaunch**.
- [ ] **Deny Screen Recording:** the app still works. Thumbnails style is disabled
      with an inline explanation and a Grant button; the switcher shows app icons.
- [ ] Granting Screen Recording afterwards enables the Thumbnails style without a
      relaunch.

## Hotkey ownership — the highest-risk area

- [ ] **Quit the app** → ⌘Tab returns to the system switcher.
- [ ] **`kill -9` the app, then relaunch** → ⌘Tab state is repaired at launch and
      the switcher works.
- [ ] **`kill -9` the app and do NOT relaunch** → the documented recovery in
      TROUBLESHOOTING.md restores ⌘Tab.
- [ ] **Settings → Controls → Restore system shortcuts** restores ⌘Tab
      immediately, with OpenTab still running.
- [ ] **Log out and back in** with OpenTab running: hotkeys still work, and
      quitting still restores them.
- [ ] Binding a shortcut to a **non-reserved** combination (⌥Tab) leaves the
      system ⌘Tab untouched.

## Exceptions

- [ ] With a VM or RDP client frontmost and *Ignore shortcuts: Always*, ⌘Tab
      passes through to the guest and OpenTab does not appear.
- [ ] Switching away from that app restores normal OpenTab behaviour immediately.
- [ ] A rule with *Hide windows: Always* removes that app's windows from the list.
- [ ] *Hide windows: When app is not active* behaves differently depending on
      which app is frontmost.

## Actions while the overlay is open

- [ ] ⌘W closes the selected window; the list updates in place.
- [ ] ⌘M minimizes it; it stays in the list marked as minimized.
- [ ] ⌘Q quits its app; every window of that app leaves the list.
- [ ] ⌘H hides its app.
- [ ] ⌘F toggles fullscreen on it.
- [ ] Each of the above can be rebound and disabled individually.

## Performance and robustness

- [ ] **50+ open windows:** the overlay still appears in **under 100 ms**. Measure
      with `log show --predicate 'subsystem == "io.github.htopo.opentab"'` and read
      the timing line.
- [ ] **Unresponsive app** (`kill -STOP` a GUI app): the switcher still opens and
      does not hang. Resume it afterwards with `kill -CONT`.
- [ ] **Sleep and wake:** the hotkey still works afterwards — the event tap was
      reinstalled.
- [ ] **Fast repeated triggering** (hold ⌘ and mash Tab for ten seconds) does not
      leak windows, stall, or desynchronise the selection.
- [ ] **Typing stutter check:** with OpenTab running, type a long paragraph in a
      text editor. There must be no perceptible input lag — this catches blocking
      work in the event-tap callback.
- [ ] Leave the app running for a **full working day** and confirm memory has not
      grown unboundedly (thumbnail cache eviction is working).

## Settings

- [ ] Every control persists across a relaunch.
- [ ] The sidebar **search field** finds settings in all four panes and jumps to
      the match.
- [ ] **Export settings** writes a readable JSON file; **Import settings** on a
      fresh profile restores every value.
- [ ] **Reset settings and restart** returns to defaults, including re-enabling the
      shipped exception rules.
- [ ] Editing `settings.json` to an unknown future `schemaVersion` makes the app
      back it up and start from defaults rather than crash.
- [ ] Nine shortcuts can be configured independently, and each applies its own
      filtering, appearance, and ordering.

## Updates

- [ ] **Check for Updates Now…** reaches the appcast and reports either an update
      or "you're up to date". Sparkle's window comes to the front rather than
      opening behind other apps.
- [ ] After that window closes, OpenTab returns to having **no Dock icon**.
- [ ] Setting **Updates policy → Never** and relaunching starts no updater
      (`log show … | grep updates` shows the "not started" line).
- [ ] An appcast entry with a **bad signature is refused**, not installed.
- [ ] Installing an update **does not reset Accessibility** — this is the whole
      point of the stable signing certificate.

## Gesture (opt-in)

- [ ] Ships **disabled**; a trackpad swipe does nothing until it is turned on.
- [ ] Once enabled, a deliberate three-finger horizontal swipe opens the switcher.
- [ ] Continuing the swipe moves the selection one entry at a time rather than
      flying through the list.
- [ ] A short or vertical swipe does **not** trigger it, and still reaches
      whatever app it was aimed at (Mission Control, browser back, page scroll).
- [ ] A mouse wheel never triggers it.

## Packaging

- [ ] `Scripts/bundle.sh --universal` produces a binary containing both `arm64`
      and `x86_64` (`lipo -info`).
- [ ] The DMG mounts, and drag-to-Applications works.
- [ ] `brew install --cask htopo/tap/open-tab` on a **clean machine** installs an
      app that opens without a Gatekeeper dialog.
- [ ] A direct DMG download opens after the documented right-click → Open.
- [ ] Updating over an existing install **does not** reset Accessibility.
- [ ] `brew uninstall --cask open-tab` with `--zap` removes settings and leaves
      ⌘Tab working.
