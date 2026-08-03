#!/usr/bin/env bash
#
# make-signing-cert.sh — create the stable self-signed code-signing identity.
#
# Run this ONCE per machine. It is interactive: it needs your login password to
# unlock the keychain and to grant codesign access to the new private key.
#
# Safe to re-run. If a previous attempt left a half-configured certificate — the
# key imported but untrusted, or trusted but inaccessible to codesign — this
# repairs it in place rather than creating a second one.
#
# Why a certificate rather than ad-hoc signing:
#
#   macOS keys Accessibility and Screen Recording grants to an app's designated
#   requirement. Under ad-hoc signing that requirement is derived from the binary
#   hash, so it changes on every build and you must re-grant Accessibility after
#   every rebuild. A certificate keeps the requirement stable, so a grant survives
#   updates. This is the difference between a one-time setup and a permanent
#   annoyance.
#
# The resulting identity is named "OpenTab Self-Signed"; Scripts/sign.sh finds it
# automatically. Export it as a .p12 for CI with:
#
#   security export -k login.keychain -t identities -f pkcs12 \
#       -o opentab-signing.p12 -P '<password>'
#
# then store the base64 of that file as the SIGNING_CERT_P12 GitHub secret.

set -euo pipefail

NAME="OpenTab Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# MARK: - Already done?

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$NAME"; then
    echo "==> Identity '$NAME' is already set up — nothing to do."
    security find-identity -v -p codesigning | grep -F "$NAME"
    exit 0
fi

# MARK: - Unlock

# A locked login keychain makes every write below fail with "User interaction is
# not allowed" — an error that says nothing about keychains being locked. macOS
# locks it after a period of inactivity, and on some configurations logging in
# does not unlock it, so this is a normal state rather than an odd one.
if ! security show-keychain-info "$KEYCHAIN" >/dev/null 2>&1; then
    echo "==> Your login keychain is locked. Unlocking it:"
    if ! security unlock-keychain "$KEYCHAIN"; then
        echo "make-signing-cert: could not unlock the login keychain; nothing was changed." >&2
        exit 1
    fi
fi

# MARK: - Create or reuse

# A certificate may already exist from an attempt that failed partway. Reuse it
# rather than piling up a second one with the same name, which would leave
# codesign picking between them arbitrarily.
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "==> Found an existing '$NAME' certificate; repairing its configuration"
    security find-certificate -c "$NAME" -p > "$WORKDIR/cert.pem"
else
    echo "==> Generating a 10-year self-signed code-signing certificate"

    # extendedKeyUsage=codeSigning is what makes codesign accept the identity;
    # without it the certificate imports fine but is invisible to `-p codesigning`.
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

    P12_PASSWORD="opentab"

    # The PKCS#12 algorithms are pinned rather than left to openssl's defaults.
    #
    # OpenSSL 3.x defaults to AES-256-CBC with a SHA-256 MAC, and Apple's Security
    # framework cannot read that — `security import` fails with "MAC verification
    # failed during PKCS12 import (wrong password?)", which points at the password
    # and is about as misleading as an error message can be. Homebrew puts its own
    # openssl ahead of the system one in PATH, so this bites anyone with Homebrew
    # installed, which is most people building from source.
    #
    # These three options are understood by both OpenSSL 3.x and the LibreSSL that
    # ships with macOS, so the script need not care which one it found.
    openssl pkcs12 -export \
        -inkey "$WORKDIR/key.pem" \
        -in "$WORKDIR/cert.pem" \
        -out "$WORKDIR/identity.p12" \
        -passout "pass:$P12_PASSWORD" \
        -certpbe PBE-SHA1-3DES \
        -keypbe PBE-SHA1-3DES \
        -macalg sha1 2>/dev/null

    echo "==> Importing into the login keychain"
    # -T grants these tools access to the private key without a prompt per build.
    if ! security import "$WORKDIR/identity.p12" \
            -k "$KEYCHAIN" \
            -P "$P12_PASSWORD" \
            -T /usr/bin/codesign \
            -T /usr/bin/security; then
        echo "make-signing-cert: import failed (openssl: $(command -v openssl))." >&2
        exit 1
    fi
fi

# MARK: - Trust

# codesign refuses an identity it does not trust — `security find-identity` marks
# it CSSMERR_TP_NOT_TRUSTED and signing fails with errSecInternalComponent, which
# names neither trust nor the certificate.
#
# The user trust domain is preferred: it is scoped to this login account and
# needs no administrator rights. It does need the Security Agent to show an
# authorization dialog, which is not always possible — over SSH, from some
# terminal emulators, or under screen sharing. When that fails, the admin domain
# is offered instead, which authorises through sudo in the terminal.
echo "==> Trusting the certificate for code signing"
echo "    (macOS will ask for your login password)"

trust_added=0
if security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORKDIR/cert.pem" 2>"$WORKDIR/trust.err"; then
    trust_added=1
else
    sed 's/^/    /' "$WORKDIR/trust.err" >&2

    if grep -q "no user interaction was possible" "$WORKDIR/trust.err"; then
        cat <<'EOF'

    macOS could not show the authorization dialog this needs. That happens over
    SSH, under screen sharing, and in some terminal emulators.

    The alternative is to add the trust setting system-wide, which authorises
    through sudo in this terminal instead of a dialog. It is still scoped to code
    signing only — this certificate does not become a general-purpose trusted
    root — but it applies to every account on this Mac rather than just yours.

EOF
        read -r -p "    Add system-wide trust with sudo? [y/N] " reply
        if [[ "$reply" =~ ^[Yy]$ ]]; then
            if sudo security add-trusted-cert -d -r trustRoot -p codeSign \
                    -k /Library/Keychains/System.keychain "$WORKDIR/cert.pem"; then
                trust_added=1
            fi
        fi
    fi
fi

if [[ "$trust_added" != "1" ]]; then
    cat >&2 <<EOF

  The certificate exists but is not trusted, so codesign will not use it.

  To finish by hand: open Keychain Access, find "$NAME" under
  login → My Certificates, double-click it, expand Trust, and set
  "Code Signing" to "Always Trust".

  Then re-run this script to verify.

EOF
    exit 1
fi

# MARK: - Key access

# Without this, codesign can reach the certificate but not its private key, and
# fails with errSecInternalComponent — the same opaque error as an untrusted
# certificate, from an unrelated cause.
echo "==> Granting codesign access to the private key"
read -r -s -p "    Login password (used only to update the keychain ACL): " KEYCHAIN_PASSWORD
echo

if ! security set-key-partition-list \
        -S apple-tool:,apple:,codesign: \
        -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "    Could not update the key's access list. You may get a keychain"
    echo "    prompt on the first build; choosing \"Always Allow\" has the same effect."
fi
unset KEYCHAIN_PASSWORD

# MARK: - Verify

echo
if security find-identity -v -p codesigning | grep -qF "$NAME"; then
    echo "==> Success. Identity available:"
    security find-identity -v -p codesigning | grep -F "$NAME"
    echo
    echo "    Rebuild with Scripts/bundle.sh — it will now use this identity, and"
    echo "    your Accessibility grant will survive future rebuilds."
else
    cat >&2 <<EOF
==> The certificate is installed but still not a valid signing identity.

    Check its trust settings in Keychain Access: find "$NAME" under
    login → My Certificates, and set Trust → Code Signing to "Always Trust".

EOF
    exit 1
fi
