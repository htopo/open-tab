#!/usr/bin/env bash
#
# sign.sh — code-sign OpenTab.app.
#
# Why this script cares which identity it uses:
#
#   macOS keys TCC grants (Accessibility, Screen Recording) to an app's designated
#   requirement, which is derived from the signing identity. An ad-hoc signature
#   derives that requirement from the binary hash, so it changes on every single
#   build and the user is forced to re-grant Accessibility after every update.
#   A stable self-signed certificate keeps the requirement constant, so permissions
#   survive updates. See docs/TROUBLESHOOTING.md for how to create the certificate.
#
# Identity selection, in order:
#   1. $OPENTAB_SIGN_IDENTITY, if set.
#   2. The first "OpenTab Self-Signed" identity found in the keychain.
#   3. Ad-hoc, with a warning.
#
# Usage: Scripts/sign.sh path/to/OpenTab.app

set -euo pipefail

APP="${1:?usage: sign.sh path/to/OpenTab.app}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS="$ROOT/Resources/OpenTab.entitlements"

OPENTAB_KEYCHAIN="opentab-signing.keychain"
OPENTAB_KEYCHAIN_PASSWORD="opentab-local-signing"

# macOS locks keychains when the machine sleeps, regardless of the "no timeout"
# setting make-signing-cert.sh applies. codesign then fails with
# `errSecInternalComponent` — an error that says nothing about keychains and
# sends you looking at certificates, trust settings and entitlements instead.
# So unlock first, every time. It is a no-op when already unlocked, and the
# password is not a secret: it exists because the API demands one, and the
# keychain holds nothing but a self-signed certificate that is worthless off
# this machine.
unlock_keychain() {
    if security list-keychains -d user | grep -qF "$OPENTAB_KEYCHAIN"; then
        security unlock-keychain -p "$OPENTAB_KEYCHAIN_PASSWORD" "$OPENTAB_KEYCHAIN" 2>/dev/null || true
    fi
}

pick_identity() {
    if [[ -n "${OPENTAB_SIGN_IDENTITY:-}" ]]; then
        printf '%s' "$OPENTAB_SIGN_IDENTITY"
        return
    fi

    # Deliberately no -v. That filters to identities macOS considers *trusted*,
    # and this certificate is intentionally untrusted: trust governs signature
    # verification, not signing, and configuring it needs either a GUI
    # authorization dialog or sudo for no benefit. See make-signing-cert.sh.
    #
    # The SHA-1 fingerprint is used rather than the name because it is
    # unambiguous even if another certificate shares the common name.
    local found
    found="$(security find-identity -p codesigning "$OPENTAB_KEYCHAIN" 2>/dev/null \
             | grep -F 'OpenTab Self-Signed' \
             | head -n1 \
             | awk '{print $2}')" || true

    # Fall back to the default search list, which covers a real Developer ID in
    # the login keychain as well as identities set up before the dedicated
    # keychain existed.
    if [[ -z "$found" ]]; then
        found="$(security find-identity -v -p codesigning 2>/dev/null \
                 | grep -F 'OpenTab Self-Signed' \
                 | head -n1 \
                 | sed -E 's/.*"(.*)".*/\1/')" || true
    fi

    printf '%s' "$found"
}

unlock_keychain
IDENTITY="$(pick_identity)"

if [[ -z "$IDENTITY" ]]; then
    cat >&2 <<'WARN'

  ⚠  No stable code-signing identity found — falling back to an ad-hoc signature.

     Consequence: macOS will treat every rebuild as a different application, so
     you will have to re-grant Accessibility and Screen Recording after each one.

     To fix this permanently, create the self-signed certificate described in
     docs/TROUBLESHOOTING.md ("Creating the signing certificate"), or set
     OPENTAB_SIGN_IDENTITY to an identity you already have.

WARN
    codesign --force --deep --sign - \
             --options runtime \
             --entitlements "$ENTITLEMENTS" \
             "$APP"
else
    echo "==> Signing with identity: $IDENTITY"
    codesign --force --deep --sign "$IDENTITY" \
             --options runtime \
             --timestamp=none \
             --entitlements "$ENTITLEMENTS" \
             "$APP"
fi

codesign --display --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
