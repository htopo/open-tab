# Undocumented symbols

OpenTab is written against public, documented Apple APIs with one exception: a
small set of undocumented CoreGraphics/SkyLight functions, without which the
app cannot do the things it exists to do. Every one is resolved at runtime with
`dlsym` and used behind an availability flag, so a symbol Apple removes costs one
feature and never stops the app launching.

`PrivateSymbols.report()` says what resolved on the current system. It is logged
at every launch and asserted in the test suite, so a macOS release that breaks
one of these surfaces as a failing test rather than a bug report.

## The set

| Symbol | Needed for | Without it |
|---|---|---|
| `_AXUIElementGetWindow` | Joining accessibility elements to window-server records | No thumbnails, no Desktop information, no capture |
| `CGSSetSymbolicHotKeyEnabled` | Freeing ⌘Tab from the system switcher | OpenTab warns and suggests a shortcut macOS does not reserve |
| `CGSIsSymbolicHotKeyEnabled` | Reading a hotkey's state before touching it | Hotkey IDs cannot be verified empirically |
| `CGSCopyWindowsWithOptionsAndTags` | Enumerating windows across every Desktop | Enumeration is limited to the current Desktop |
| `CGSCopySpacesForWindows` | Which Desktop a window is on | Per-Desktop filtering matches everything |
| `CGSGetWindowWorkspace` | The same question, older interface | — (fallback only) |
| `CGSCopyManagedDisplayForSpace` | Which display shows a given Desktop | Desktop switching cannot target the right screen |
| `CGSManagedDisplaySetCurrentSpace` | Moving to another Desktop | Some windows on other Desktops are unreachable |

## Deviations from the original plan

PLAN.md §6.3 listed four: `_AXUIElementGetWindow`,
`CGSSetSymbolicHotKeyEnabled`, `CGSCopyWindowsWithOptionsAndTags` and
`CGSGetWindowWorkspace`. Four more were added during implementation, each
because the planned approach did not survive contact with a real machine.

**`CGSIsSymbolicHotKeyEnabled`** — the plan called for verifying hotkey IDs
empirically rather than trusting constants across macOS versions, which needs a
way to read the state.

**`CGSCopySpacesForWindows`** — `CGSGetWindowWorkspace` still *resolves* on
current macOS, so the availability check passed, but it answers workspace 0 for
every window. That is indistinguishable from "unknown", so Desktop filtering
silently matched everything and the feature looked supported while doing
nothing. The older call is kept as a fallback.

**`CGSCopyManagedDisplayForSpace`** and **`CGSManagedDisplaySetCurrentSpace`** —
the only pair here that *changes* something rather than reading it, and the only
way to reach a class of window that is otherwise unreachable. Some applications,
browsers especially, publish over Accessibility only the window on the Desktop
currently in front. For the others there is no element to raise; activating the
application brings it forward where the user already is and never travels. Once
the Desktop they live on is current, the application publishes them and an
ordinary raise works. The display is asked for by Desktop rather than assumed,
because with "Displays have separate Spaces" enabled each display has its own
set and setting the wrong one moves the wrong screen.
