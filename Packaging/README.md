# Packaging

Everything needed to publish a release. Run through
[docs/QA.md](../docs/QA.md) first — most of this app's surface cannot be covered
by unit tests.

## One-time setup

### 1. Code-signing certificate

```sh
Scripts/make-signing-cert.sh
```

Creates the stable **OpenTab Self-Signed** identity. This matters more than it
looks: macOS keys Accessibility and Screen Recording grants to an app's
designated requirement, which comes from its signing identity. An ad-hoc
signature changes on every build, so users would have to re-grant Accessibility
after every single update.

Export it for CI:

```sh
security export -k login.keychain -t identities -f pkcs12 \
    -o opentab-signing.p12 -P 'a-strong-password'
base64 -i opentab-signing.p12 | pbcopy
rm opentab-signing.p12
```

Store the clipboard as the `SIGNING_CERT_P12` secret and the password as
`SIGNING_CERT_PASSWORD`.

### 2. Sparkle EdDSA key pair

Sparkle signs the appcast with its own key, independent of Apple code signing —
which is exactly why in-app updates work for an unnotarized app.

```sh
# generate_keys ships inside Sparkle's SwiftPM artifact bundle.
swift build   # populates .build/artifacts
find .build/artifacts -name generate_keys -type f -exec {} \;
```

It prints a public key and stores the private key in your login keychain.

- Put the **public key** in `Resources/Info.plist` as `SUPublicEDKey`.
- Export the **private key** and store it as the `SPARKLE_PRIVATE_KEY` secret:

  ```sh
  find .build/artifacts -name generate_keys -type f -exec {} -x - \; | pbcopy
  ```

> Losing the private key means no existing installation can ever be updated
> again — Sparkle will reject every future release as unsigned. Back it up
> somewhere you will still have in a year.

### 3. Homebrew tap repository

Create `htopo/homebrew-tap` (public) and copy the cask into it:

```sh
gh repo create htopo/homebrew-tap --public \
    --description "Homebrew tap for OpenTab"

git clone https://github.com/htopo/homebrew-tap.git /tmp/tap
mkdir -p /tmp/tap/Casks
cp Packaging/homebrew-tap/Casks/open-tab.rb /tmp/tap/Casks/
cd /tmp/tap && git add . && git commit -m "Add open-tab cask" && git push
```

`Packaging/homebrew-tap/Casks/open-tab.rb` in this repository is the source of
truth; the tap holds a copy that the release workflow bumps.

For the workflow to open that pull request it needs a `TAP_TOKEN` secret — a
fine-grained personal access token with **contents: write** and
**pull requests: write** on `htopo/homebrew-tap`. Without it the release still
publishes and the workflow prints the version and checksum to update by hand.

### 4. GitHub Pages

The appcast is served from the `gh-pages` branch, which the release workflow
creates and force-pushes. Enable Pages for that branch once, in the repository
settings, so `https://htopo.github.io/open-tab/appcast.xml` resolves — the URL
already in `Info.plist` as `SUFeedURL`.

## Cutting a release

1. Work through [docs/QA.md](../docs/QA.md).
2. Bump `VERSION`.
3. Commit, tag, push:

   ```sh
   git commit -am "Release 0.2.0"
   git tag v0.2.0
   git push && git push --tags
   ```

The tag triggers `release.yml`, which builds a universal binary, signs it,
produces the DMG, signs the appcast entry, publishes the GitHub release, updates
`gh-pages`, and opens a bump PR against the tap.

The workflow fails fast if the tag and the `VERSION` file disagree — otherwise
the DMG filename, the appcast, and the cask would each claim a different version.

## Building a release by hand

```sh
Scripts/bundle.sh --universal
Scripts/dmg.sh
```

Produces `dist/OpenTab-<version>.dmg` and its `.sha256`.

## Required secrets

| Secret | Needed for | Missing behaviour |
|---|---|---|
| `SIGNING_CERT_P12` | Stable signing identity | Ad-hoc signature; permissions reset on every update |
| `SIGNING_CERT_PASSWORD` | Importing the above | As above |
| `SPARKLE_PRIVATE_KEY` | Appcast signature | Release publishes; in-app updates refuse it |
| `TAP_TOKEN` | Automated cask bump | Release publishes; tap must be updated by hand |

Each one degrades rather than breaking the release, and the workflow says so in
its log when one is absent.
