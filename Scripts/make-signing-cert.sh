#!/usr/bin/env bash
#
# make-signing-cert.sh — create the stable self-signed code-signing identity.
#
# Run this ONCE per machine. It is interactive: macOS will ask for your login
# password to add trust settings for the new certificate.
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
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$NAME"; then
    echo "==> Identity '$NAME' already exists — nothing to do."
    security find-identity -v -p codesigning | grep -F "$NAME"
    exit 0
fi

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
openssl pkcs12 -export \
    -inkey "$WORKDIR/key.pem" \
    -in "$WORKDIR/cert.pem" \
    -out "$WORKDIR/identity.p12" \
    -passout "pass:$P12_PASSWORD" 2>/dev/null

echo "==> Importing into the login keychain"
# -T grants codesign access to the private key without prompting on every build.
security import "$WORKDIR/identity.p12" \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$P12_PASSWORD" \
    -T /usr/bin/codesign \
    -T /usr/bin/security

echo "==> Adding code-signing trust (macOS will ask for your login password)"
# User trust domain, so no sudo is required. Restricted to code signing only:
# this certificate must not become a general-purpose trusted root.
security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    "$WORKDIR/cert.pem"

# Stop the keychain prompting for permission on each codesign invocation.
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || \
    echo "    (partition list not updated; you may see a keychain prompt on first sign)"

echo
if security find-identity -v -p codesigning | grep -qF "$NAME"; then
    echo "==> Success. Identity available:"
    security find-identity -v -p codesigning | grep -F "$NAME"
    echo
    echo "    Rebuild with Scripts/bundle.sh — it will now use this identity, and"
    echo "    your Accessibility grant will survive future rebuilds."
else
    echo "==> Certificate was created but is not yet a usable code-signing identity."
    echo "    Open Keychain Access, find '$NAME' under 'My Certificates', and set"
    echo "    Trust → Code Signing to 'Always Trust'."
    exit 1
fi
