#!/usr/bin/env bash
#
# make-signing-cert.sh — create the stable code-signing identity used for local
# builds.
#
# Run this ONCE per machine. It needs no passwords and no administrator rights.
#
# Why a certificate rather than ad-hoc signing:
#
#   macOS keys Accessibility and Screen Recording grants to an app's designated
#   requirement. Ad-hoc signing derives that from the binary hash:
#
#       designated => cdhash H"b02936120b8c30..."      <- changes every build
#
#   so every rebuild is a different app as far as TCC is concerned, and you must
#   re-grant Accessibility each time. Signing with a certificate derives it from
#   the certificate instead:
#
#       designated => identifier OpenTab and certificate leaf = H"2082852..."
#
#   which is stable for the certificate's ten-year life.
#
# Why a dedicated keychain rather than the login keychain:
#
#   The login keychain needs its own password to write to, and that password is
#   not always the account password — it keeps the old one when a password is
#   reset through Apple ID or FileVault recovery, and there is then no way to
#   unlock it non-interactively. A dedicated keychain sidesteps all of that: this
#   script owns it, knows its password, and touches nothing else.
#
#   The keychain password is not a secret. It protects a self-signed certificate
#   that is only good for signing local development builds of this app, and
#   anyone with access to your account could create an equivalent one in seconds.
#
# Deliberately does NOT configure trust settings. codesign signs happily with an
# untrusted certificate — trust governs verification, not signing — and adding
# trust needs either a GUI authorization dialog (impossible over SSH or screen
# sharing) or sudo. Neither is worth it for something that changes nothing.
#
# Safe to re-run: it repairs an existing setup rather than duplicating it.

set -euo pipefail

NAME="OpenTab Self-Signed"
KEYCHAIN_NAME="opentab-signing.keychain"
KEYCHAIN_PATH="$HOME/Library/Keychains/${KEYCHAIN_NAME}-db"
KEYCHAIN_PASSWORD="opentab-local-signing"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# MARK: - Already done?

if security find-identity -p codesigning "$KEYCHAIN_NAME" 2>/dev/null | grep -qF "$NAME"; then
    echo "==> Identity '$NAME' is already set up."
    security find-identity -p codesigning "$KEYCHAIN_NAME" | grep -F "$NAME" | sed 's/^/    /'
    echo
    echo "    Build with Scripts/bundle.sh — it finds this automatically."
    exit 0
fi

# MARK: - Keychain

if [[ -f "$KEYCHAIN_PATH" ]]; then
    echo "==> Reusing the existing OpenTab signing keychain"
else
    echo "==> Creating a dedicated signing keychain"
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
fi

# No -t and no -l: never lock on a timeout or on sleep. A locked keychain would
# make builds fail later with an error that names neither locking nor keychains.
security set-keychain-settings "$KEYCHAIN_NAME"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"

# codesign only searches keychains in the user's search list, so add it while
# preserving whatever is already there.
if ! security list-keychains -d user | grep -qF "$KEYCHAIN_NAME"; then
    echo "==> Adding it to the keychain search list"
    EXISTING="$(security list-keychains -d user | sed 's/[",]//g' | xargs)"
    security list-keychains -d user -s $EXISTING "$KEYCHAIN_NAME"
fi

# MARK: - Certificate

echo "==> Generating a 10-year self-signed code-signing certificate"

# extendedKeyUsage=codeSigning is what makes the identity visible to
# `find-identity -p codesigning`; without it the import succeeds and the
# certificate is then invisible to every tool that wants it.
cat > "$WORKDIR/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
prompt             = no
x509_extensions    = ext

[ dn ]
CN = $NAME

[ ext ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORKDIR/key.pem" \
    -out "$WORKDIR/cert.pem" \
    -config "$WORKDIR/openssl.cnf" 2>/dev/null

# The PKCS#12 algorithms are pinned rather than left to openssl's defaults.
# OpenSSL 3.x defaults to AES-256-CBC with a SHA-256 MAC, which Apple's Security
# framework cannot read — `security import` then fails with "MAC verification
# failed during PKCS12 import (wrong password?)", blaming the password. Homebrew
# puts its own openssl ahead of the system one in PATH, so this hits most people
# building from source. These options work on both OpenSSL 3.x and the LibreSSL
# macOS ships.
openssl pkcs12 -export \
    -inkey "$WORKDIR/key.pem" \
    -in "$WORKDIR/cert.pem" \
    -out "$WORKDIR/identity.p12" \
    -passout "pass:$KEYCHAIN_PASSWORD" \
    -certpbe PBE-SHA1-3DES \
    -keypbe PBE-SHA1-3DES \
    -macalg sha1 2>/dev/null

echo "==> Importing it"
# -A allows any application to use the key. Combined with the partition list
# below, this is what stops codesign failing with errSecInternalComponent — an
# error that mentions neither keys nor access.
security import "$WORKDIR/identity.p12" \
    -k "$KEYCHAIN_NAME" \
    -P "$KEYCHAIN_PASSWORD" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    -A

security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME" >/dev/null 2>&1 || true

# MARK: - Verify

# Proving it can actually sign is the only check worth making. Every failure mode
# in this area surfaces as the same opaque codesign error, so an end-to-end test
# is more informative than inspecting the pieces.
HASH="$(security find-identity -p codesigning "$KEYCHAIN_NAME" 2>/dev/null \
        | grep -F "$NAME" | head -n1 | awk '{print $2}')"

if [[ -z "$HASH" ]]; then
    echo "make-signing-cert: the certificate imported but is not a usable identity." >&2
    exit 1
fi

cp /bin/echo "$WORKDIR/probe"
if ! codesign --force --sign "$HASH" "$WORKDIR/probe" 2>"$WORKDIR/sign.err"; then
    echo "make-signing-cert: the identity exists but cannot sign:" >&2
    sed 's/^/    /' "$WORKDIR/sign.err" >&2
    exit 1
fi

echo
echo "==> Success."
echo "    Identity:    $NAME"
echo "    Fingerprint: $HASH"
echo "    Keychain:    $KEYCHAIN_PATH"
echo
echo "    Designated requirement produced:"
codesign -d -r- "$WORKDIR/probe" 2>&1 | grep designated | sed 's/^/      /'
echo
echo "    That references the certificate rather than the binary, so your"
echo "    Accessibility grant will survive rebuilds."
echo
echo "    Next:  Scripts/bundle.sh && open dist/OpenTab.app"
