### Source of truth for the OpenTab cask.
#
# This file lives here so it is versioned alongside the app, and is copied into
# the separate `htopo/homebrew-tap` repository. The release workflow bumps
# `version` and `sha256` there automatically.
#
# It cannot live in Homebrew's main cask tap: as of 2026-09-01 that tap disables
# casks which fail Gatekeeper checks, and OpenTab is not notarized. A personal
# tap can still ship one, and may strip the quarantine attribute in a postflight.

cask "open-tab" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/htopo/open-tab/releases/download/v#{version}/OpenTab-#{version}.dmg",
      verified: "github.com/htopo/open-tab/"
  name "OpenTab"
  desc "Window switcher for macOS"
  homepage "https://github.com/htopo/open-tab"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "OpenTab.app"

  # OpenTab is signed but not notarized, so Gatekeeper would refuse the first
  # launch. Removing the quarantine attribute is what turns a scary dialog into
  # an app that just opens. Anyone downloading the DMG directly does this step by
  # hand instead; the README documents it.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/OpenTab.app"],
                   sudo: false
  end

  uninstall quit: "io.github.htopo.opentab"

  zap trash: [
    "~/Library/Application Support/OpenTab",
    "~/Library/Preferences/io.github.htopo.opentab.plist",
    "~/Library/Caches/io.github.htopo.opentab",
  ]

  caveats <<~EOS
    OpenTab needs Accessibility access to list and focus your windows. It will
    ask on first launch:

      System Settings → Privacy & Security → Accessibility

    Screen Recording is optional and only adds live thumbnails.

    OpenTab replaces #{Formatter.bold("Cmd-Tab")} by default and hands it back when you quit.
    If the system switcher ever stops working, relaunch OpenTab — it repairs the
    state at launch — or see the troubleshooting guide.
  EOS
end
