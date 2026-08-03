# Troubleshooting

- [⌘Tab stopped working entirely](#command-tab-stopped-working-entirely)
- [Accessibility permission keeps resetting](#accessibility-permission-keeps-resetting)
- [macOS refuses to open the app](#macos-refuses-to-open-the-app)
- [The switcher does not appear](#the-switcher-does-not-appear)
- [Thumbnails are blank or stale](#thumbnails-are-blank-or-stale)
- [⌘Tab reaches OpenTab instead of my VM](#command-tab-reaches-opentab-instead-of-my-vm)
- [Updates are not being offered](#updates-are-not-being-offered)
- [Creating the signing certificate](#creating-the-signing-certificate)

---

## Command-Tab stopped working entirely

**Symptom:** ⌘Tab does nothing. Neither OpenTab nor the built-in macOS switcher
appears.

**Cause:** To bind ⌘Tab, OpenTab disables the corresponding *symbolic hotkey* —
the system-level reservation that sits above event taps. That change survives app
quit and reboot. If OpenTab was killed hard (`kill -9`, a power loss, a panic)
between disabling and restoring, the reservation stays off with nothing bound to
it.

**Fixes, in order of preference:**

1. **Relaunch OpenTab.** It records which hotkeys it disabled *before* disabling
   them, and repairs a dirty record on the next launch. This resolves the problem
   on its own in almost every case.

2. **Settings → Controls → Restore system shortcuts.** Re-enables every symbolic
   hotkey OpenTab is capable of touching, whether or not it believes it owns them.

3. **Manual recovery, with OpenTab not running.** Clear the record of what OpenTab
   thinks it disabled, then let macOS rebuild its hotkey state:

   ```sh
   defaults delete io.github.htopo.opentab DisabledSymbolicHotKeys
   killall -HUP SystemUIServer
   ```

4. **Reset the whole symbolic-hotkey table** — the last resort. This restores
   *all* system keyboard shortcuts to their defaults, including any you have
   customised yourself:

   ```sh
   defaults delete com.apple.symbolichotkeys
   killall -HUP SystemUIServer
   ```

   Log out and back in afterwards.

You can check the current state of the three hotkeys OpenTab can touch:

```sh
defaults read com.apple.symbolichotkeys AppleSymbolicHotKeys | grep -A4 -E '^\s+(1|2|27) ='
```

`enabled = 1` means the system owns that combination.

---

## Accessibility permission keeps resetting

**Symptom:** OpenTab asks for Accessibility again after every update, or appears
enabled in System Settings while behaving as though it is not.

**Cause:** macOS keys the grant to the app's *designated requirement*, derived
from its code signature. An **ad-hoc** signature derives that requirement from the
binary hash, so every rebuild is, as far as TCC is concerned, a different app.

**Fix:**

- If you installed via the Homebrew tap or the DMG, the release build carries a
  stable certificate and this should not happen. If it does, remove and re-add
  OpenTab in System Settings → Privacy & Security → Accessibility.
- If you are **building from source**, run
  [`Scripts/make-signing-cert.sh`](#creating-the-signing-certificate) once. Until
  you do, `Scripts/bundle.sh` warns on every build that permissions will reset.

Stale entries can also be cleared with:

```sh
tccutil reset Accessibility io.github.htopo.opentab
```

Then relaunch OpenTab and grant it once more.

---

## macOS refuses to open the app

**Symptom:** *"OpenTab" cannot be opened because Apple cannot check it for
malicious software.*

**Cause:** OpenTab is signed but **not notarized** — notarization requires a paid
Apple Developer ID, which this project does not have. This is stated plainly in
the README rather than worked around.

**Fixes:**

- **Homebrew tap** — installs handle this automatically; the cask strips the
  quarantine attribute after copying the app.
- **Downloaded DMG** — either right-click the app and choose **Open** (once), or:

  ```sh
  xattr -dr com.apple.quarantine /Applications/OpenTab.app
  ```

- **System Settings → Privacy & Security** shows an "Open Anyway" button for a
  few minutes after a blocked launch attempt.

---

## The switcher does not appear

Work through these in order:

1. **Is Accessibility granted?** System Settings → Privacy & Security →
   Accessibility. This is required; see [PERMISSIONS.md](PERMISSIONS.md).

2. **Is OpenTab running?** It has no Dock icon by design. Check with:

   ```sh
   pgrep -lf OpenTab
   ```

3. **Is the frontmost app on the exceptions list?** Settings → Exceptions. Rules
   with *Ignore shortcuts: Always* deliberately pass the hotkey through. Several
   remote-desktop and VM clients ship enabled by default.

4. **Did the event tap get disabled?** macOS disables a tap whose callback blocks
   for too long. OpenTab detects this and re-enables it, and logs when it happens:

   ```sh
   log show --predicate 'subsystem == "io.github.htopo.opentab"' --last 10m
   ```

5. **Is the shortcut actually bound to something reserved?** If
   `CGSSetSymbolicHotKeyEnabled` could not be resolved on your macOS version,
   OpenTab cannot free ⌘Tab and says so at launch. Pick a non-reserved shortcut
   such as ⌥Tab in Settings → Controls.

---

## Thumbnails are blank or stale

- **Blank for every window** — Screen Recording is not granted. Settings →
  Appearance shows an inline explanation and a Grant button.
- **Blank for minimized or other-Space windows only** — expected. macOS composites
  nothing for those windows, so there is no image to capture. OpenTab serves the
  last cached thumbnail when it has one and the app icon otherwise.
- **Stale thumbnails** — expected when *General → Capture windows in the
  background* is off. That setting exists to avoid the purple recording indicator
  and DRM video flicker; the trade-off is freshness.

---

## Command-Tab reaches OpenTab instead of my VM

Remote-desktop and virtual-machine clients need ⌘Tab to reach the guest OS.

Settings → Exceptions → **+**, enter the client's bundle identifier, and set
**Ignore shortcuts** to **Always**. OpenTab then passes its hotkeys through
untouched whenever that app is frontmost.

These ship configured out of the box:

`com.microsoft.rdc.macos`, `com.teamviewer.TeamViewer`,
`org.virtualbox.app.VirtualBoxVM`, `com.parallels.desktop.console`,
`com.citrix.XenAppViewer`, `com.vmware.fusion`, `com.nicesoftware.dcvviewer`,
`com.realvnc.vncviewer`

To find another app's bundle identifier:

```sh
osascript -e 'id of app "Some App"'
# or
mdls -name kMDItemCFBundleIdentifier /Applications/Some\ App.app
```

---

## Updates are not being offered

- **Updates policy is "Never check"** — Settings → General. When set to Never,
  OpenTab does not start its updater at all, so nothing runs in the background.
- **Running from a development build** — in-app updates only work from an
  installed `.app`. A `swift run` build has no updater.
- **Installed via Homebrew** — let Homebrew handle it instead:

  ```sh
  brew upgrade --cask open-tab
  ```

- **"Update is improperly signed"** — the release was published without a valid
  appcast signature. OpenTab refuses it rather than installing something it
  cannot verify, which is the correct behaviour. Download the DMG from
  [Releases](https://github.com/htopo/open-tab/releases) instead and report it.

To see what the updater is doing:

```sh
log show --predicate 'subsystem == "io.github.htopo.opentab"' --last 1h \
    | grep updates
```

---

## Creating the signing certificate

Needed only when **building from source**. Run once per machine:

```sh
Scripts/make-signing-cert.sh
```

It creates a 10-year self-signed certificate named **OpenTab Self-Signed**,
imports it into your login keychain, and marks it trusted for code signing only.
macOS will ask for your login password when trust is added.

`Scripts/sign.sh` picks the identity up automatically afterwards. To use a
different identity instead:

```sh
export OPENTAB_SIGN_IDENTITY="Developer ID Application: You (TEAMID)"
```

To verify what a built app is signed with:

```sh
codesign --display --verbose=2 dist/OpenTab.app
```

`Signature=adhoc` means permissions will reset on every rebuild; anything else
means they will persist.

Building from source also skips login-item registration: macOS records a login
item's *path*, and a build running out of `dist/` would leave an entry pointing
into a directory that disappears on the next clean build. Installed copies
register normally.

### For CI

Export the identity and store it as a repository secret:

```sh
security export -k login.keychain -t identities -f pkcs12 \
    -o opentab-signing.p12 -P 'a-strong-password'
base64 -i opentab-signing.p12 | pbcopy
```

Store the clipboard contents as `SIGNING_CERT_P12` and the password as
`SIGNING_CERT_PASSWORD`. Delete the local `.p12` afterwards — it is gitignored,
but it should not linger on disk either.
