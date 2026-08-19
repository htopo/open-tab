# Permissions

OpenTab asks for two macOS privacy permissions. One is required, one is optional.

| Permission | Required? | What breaks without it |
|---|---|---|
| **Accessibility** | Yes | Everything. The app cannot list windows, cannot focus them, and cannot observe the keyboard. |
| **Screen Recording** | No | Thumbnails, and window titles for the few apps that publish nothing over Accessibility. The switcher falls back to app icons and app names, and stays fully usable. |

---

## Accessibility

### Why it is needed

Three separate things depend on it:

1. **Window enumeration.** The Accessibility API is the only route that sees
   minimized windows, windows on other Spaces, and windows belonging to hidden
   apps. `CGWindowListCopyWindowInfo` alone sees none of those.
2. **Focusing a window.** Raising one specific window of an app — as opposed to
   just activating the app — goes through `AXUIElementPerformAction`.
3. **The keyboard event tap.** `CGEvent.tapCreate` requires Accessibility. Without
   it, the hotkey is never observed.

There is no subset of OpenTab that works without this permission, which is why
the app shows onboarding instead of a degraded mode when it is missing.

### Granting it

System Settings → Privacy & Security → Accessibility → enable **OpenTab**.

OpenTab polls for the grant and starts working the moment it lands; you do not
need to relaunch.

### If the grant does not stick

macOS keys the grant to the app's *designated requirement*, which comes from its
code signature. A build signed ad-hoc gets a new requirement every time it is
compiled, so the grant silently stops applying after an update. See
[TROUBLESHOOTING.md](TROUBLESHOOTING.md#accessibility-permission-keeps-resetting).

---

## Screen Recording

### Why it is needed

Mainly to draw live window thumbnails. macOS classifies reading the pixels of
another app's window as screen recording, so `SCScreenshotManager` is gated
behind it.

It also affects a small number of window *titles*. Most titles come from the
accessibility API, which is not gated this way. But a few applications — Catalyst
ones especially — publish no windows over Accessibility at all, and OpenTab
reconstructs those from the window server instead. The window server will not
hand over `kCGWindowName` without Screen Recording, so those entries show the
application name alone until it is granted. OpenTab recovers the title of such an
app's *focused* window through Accessibility regardless; it is the others that
stay bare.

### What OpenTab does without it

- The **Thumbnails** style is disabled in Settings with an inline explanation and
  a "Grant" button.
- The switcher renders app icons instead.
- Every other feature — enumeration, ordering, filtering, focusing, all window
  actions — works normally.

This is a deliberate design constraint: the app must remain fully usable for
people who will not grant screen capture to a background utility.

### The purple recording indicator

When "Capture windows in the background" is enabled, OpenTab refreshes thumbnails
on a low-priority timer, which can make macOS show its purple screen-recording
indicator and can cause flicker in DRM-protected video. Turning that setting off
restricts capture to the moment the switcher opens, at the cost of slightly
staler thumbnails.

---

## Why OpenTab is not sandboxed

The App Sandbox blocks both `AXUIElement` and `CGEventTap`. There is no
entitlement that re-enables them for a non-Apple app — sandboxing OpenTab would
not harden it, it would stop it working at all.

`Resources/OpenTab.entitlements` therefore contains no
`com.apple.security.app-sandbox` key. The app does run under the **hardened
runtime**, and requests only `com.apple.security.cs.disable-library-validation`,
which it needs to resolve system framework symbols at runtime.

---

## What OpenTab does not do

- No network access, except explicit update checks you can turn off.
- No crash reporting or telemetry of any kind.
- No reading of window *contents* beyond the thumbnail image itself.
- Nothing is written outside `~/Library/Application Support/OpenTab` and the
  app's own preferences domain.
