#!/usr/bin/env bash
#
# bundle.sh — build OpenTab with SwiftPM and assemble OpenTab.app.
#
# There is no .xcodeproj in this repo, so the .app is assembled by hand from the
# SwiftPM build products. Signing is delegated to Scripts/sign.sh.
#
# Usage:
#   Scripts/bundle.sh                 release build, current architecture
#   Scripts/bundle.sh --universal     release build, arm64 + x86_64
#   Scripts/bundle.sh --debug         debug build (faster; for local iteration)
#
# Output: dist/OpenTab.app

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

CONFIG="release"
UNIVERSAL=0
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=1 ;;
        --debug)     CONFIG="debug" ;;
        --release)   CONFIG="release" ;;
        *) echo "bundle.sh: unknown argument '$arg'" >&2; exit 2 ;;
    esac
done

VERSION="$(tr -d '[:space:]' < VERSION)"
# Build number: number of commits, so it increases monotonically. Falls back to 1
# outside a git checkout (e.g. a source tarball).
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

APP="$ROOT/dist/OpenTab.app"
CONTENTS="$APP/Contents"

echo "==> Building OpenTab $VERSION (build $BUILD, $CONFIG)"

BUILD_ARGS=(--configuration "$CONFIG" --disable-sandbox)

# The minimum deployment target has to match Package.swift; it is baked into the
# triple when cross-compiling.
DEPLOYMENT_TARGET="14.0"

if [[ "$UNIVERSAL" == "1" ]]; then
    # `swift build --arch arm64 --arch x86_64` produces a universal binary in one
    # pass, but only via XCBuild, which ships with Xcode. This project builds with
    # Command Line Tools, so each slice is built separately and merged with lipo.
    SLICES=()
    for arch in arm64 x86_64; do
        echo "--> Building $arch slice"
        swift build "${BUILD_ARGS[@]}" --triple "$arch-apple-macosx$DEPLOYMENT_TARGET"
        slice_path="$(swift build "${BUILD_ARGS[@]}" --triple "$arch-apple-macosx$DEPLOYMENT_TARGET" --show-bin-path)"
        if [[ ! -x "$slice_path/OpenTab" ]]; then
            echo "bundle.sh: missing $arch executable at $slice_path/OpenTab" >&2
            exit 1
        fi
        SLICES+=("$slice_path/OpenTab")
    done
    # Resource bundles are architecture independent, so either slice will do.
    BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --triple "arm64-apple-macosx$DEPLOYMENT_TARGET" --show-bin-path)"
else
    swift build "${BUILD_ARGS[@]}"
    BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
    if [[ ! -x "$BIN_PATH/OpenTab" ]]; then
        echo "bundle.sh: expected executable at $BIN_PATH/OpenTab" >&2
        exit 1
    fi
    SLICES=("$BIN_PATH/OpenTab")
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

if [[ "${#SLICES[@]}" -gt 1 ]]; then
    lipo -create "${SLICES[@]}" -output "$CONTENTS/MacOS/OpenTab"
else
    cp "${SLICES[0]}" "$CONTENTS/MacOS/OpenTab"
fi
chmod +x "$CONTENTS/MacOS/OpenTab"

# Sparkle ships as a framework containing XPC services and helper apps, so it has
# to live inside the bundle rather than being statically linked. SwiftPM links it
# with an rpath pointing at the build directory, which does not exist on a user's
# machine, so the bundle-relative one is added here.
SPARKLE_SOURCE=""
for candidate in "$BIN_PATH/Sparkle.framework" "$BIN_PATH/../Sparkle.framework"; do
    if [[ -d "$candidate" ]]; then SPARKLE_SOURCE="$candidate"; break; fi
done

if [[ -n "$SPARKLE_SOURCE" ]]; then
    echo "==> Embedding Sparkle.framework"
    mkdir -p "$CONTENTS/Frameworks"
    cp -R "$SPARKLE_SOURCE" "$CONTENTS/Frameworks/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS/MacOS/OpenTab" 2>/dev/null || true
else
    echo "    warning: Sparkle.framework not found; in-app updates will be unavailable" >&2
fi

# Icon. Generated from our own source artwork by Scripts/make-icon.swift.
if [[ ! -f "$ROOT/Resources/Assets/OpenTab.icns" ]]; then
    echo "==> Icon missing; generating"
    swift "$ROOT/Scripts/make-icon.swift" "$ROOT/Resources/Assets"
fi
cp "$ROOT/Resources/Assets/OpenTab.icns" "$CONTENTS/Resources/OpenTab.icns"

# SwiftPM emits one .bundle per target that declares resources. Copy any that exist.
shopt -s nullglob
for res in "$BIN_PATH"/*.bundle; do
    cp -R "$res" "$CONTENTS/Resources/"
done
shopt -u nullglob

# Info.plist with the version placeholders substituted.
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" \
    "$ROOT/Resources/Info.plist" > "$CONTENTS/Info.plist"

printf 'APPL????' > "$CONTENTS/PkgInfo"

# Sign. sign.sh picks a real identity when one is configured and falls back to
# ad-hoc with a loud warning otherwise.
"$ROOT/Scripts/sign.sh" "$APP"

echo "==> Verifying bundle"
codesign --verify --deep --strict "$APP" && echo "    signature OK"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CONTENTS/Info.plist" >/dev/null
echo "    architectures: $(lipo -archs "$CONTENTS/MacOS/OpenTab")"

echo "==> Built $APP"
