#!/bin/bash
# Builds Tusi.app into ./build. Usage: ./build.sh [--open]
#
# Architecture is controlled by TUSI_ARCH (default: native, i.e. whatever this Mac is):
#   TUSI_ARCH=arm64      swift build --arch arm64
#   TUSI_ARCH=universal  builds arm64 + x86_64 separately, lipo's them together
set -euo pipefail
cd "$(dirname "$0")"

ARCH_MODE="${TUSI_ARCH:-native}"

# VERSION contains the short version and build number, separated by whitespace.
# Environment variables override it for CI/nightly builds.
DEFAULT_VERSION="1.0.0"
DEFAULT_BUILD_NUMBER="1"
if [[ -f VERSION ]]; then
    read -r DEFAULT_VERSION DEFAULT_BUILD_NUMBER < VERSION
fi
VERSION="${TUSI_VERSION:-${DEFAULT_VERSION:-1.0.0}}"
BUILD_NUMBER="${TUSI_BUILD_NUMBER:-${DEFAULT_BUILD_NUMBER:-1}}"
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "无效版本号: $VERSION" >&2
    exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "无效构建号: $BUILD_NUMBER" >&2
    exit 1
fi

APP="build/Tusi.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Where the binary actually lands varies by toolchain/build-system (classic SPM uses
# .build/<arch>-apple-macosx/release/, the newer Swift Build backend reuses one shared
# .build/out/Products/Release/ for every --arch invocation). --show-bin-path asks the
# toolchain directly instead of guessing, so this works either way — but because a shared
# directory gets overwritten by the next build, each slice must be copied out immediately.
case "$ARCH_MODE" in
    native)
        swift build -c release
        cp "$(swift build -c release --show-bin-path)/Tusi" "$APP/Contents/MacOS/Tusi"
        chmod +x "$APP/Contents/MacOS/Tusi"
        ;;
    arm64)
        swift build -c release --arch arm64
        cp "$(swift build -c release --arch arm64 --show-bin-path)/Tusi" "$APP/Contents/MacOS/Tusi"
        chmod +x "$APP/Contents/MacOS/Tusi"
        ;;
    universal)
        arm64_slice="$(mktemp -t tusi-arm64)"
        x86_64_slice="$(mktemp -t tusi-x86_64)"
        cleanup_slices() {
            rm -f "${arm64_slice:-}" "${x86_64_slice:-}"
        }
        trap cleanup_slices EXIT

        swift build -c release --arch arm64
        cp "$(swift build -c release --arch arm64 --show-bin-path)/Tusi" "$arm64_slice"
        swift build -c release --arch x86_64
        cp "$(swift build -c release --arch x86_64 --show-bin-path)/Tusi" "$x86_64_slice"
        lipo -create "$arm64_slice" "$x86_64_slice" -output "$APP/Contents/MacOS/Tusi"
        chmod +x "$APP/Contents/MacOS/Tusi"
        ;;
    *)
        echo "未知 TUSI_ARCH: $ARCH_MODE（可选 native / arm64 / universal）" >&2
        exit 1
        ;;
esac

cp Resources/Tusi.icns "$APP/Contents/Resources/Tusi.icns"

# Copy .lproj folders straight into the app's own Resources — not SwiftPM's nested
# resource bundle — so Bundle.main (what SwiftUI's Text/.help and NSLocalizedString both
# read by default) finds them without any explicit `bundle:` argument anywhere in the code.
for lproj in Sources/Tusi/Resources/*.lproj; do
    [ -d "$lproj" ] && cp -R "$lproj" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Tusi</string>
    <key>CFBundleDisplayName</key>
    <string>Tusi</string>
    <key>CFBundleIdentifier</key>
    <string>com.tusi.app</string>
    <key>CFBundleExecutable</key>
    <string>Tusi</string>
    <key>CFBundleIconFile</key>
    <string>Tusi</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh-Hans</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh-Hans</string>
        <string>en</string>
    </array>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Sign with a stable identity when one is available, otherwise ad-hoc.
#
# An ad-hoc signature's designated requirement is the binary's cdhash, so it changes on
# every build. The Keychain stores that requirement when you click "Always Allow", which
# means an ad-hoc app re-prompts for the API key after every rebuild. Signing with a real
# identity pins the requirement to the certificate instead, and the authorization sticks.
#
# Anyone building this from a clone just falls through to ad-hoc: no certificate needed,
# and the result works exactly as before.
IDENTITY="${TUSI_SIGN_IDENTITY:-Spotoast Local Dev}"
AVAILABLE_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if grep -F "\"$IDENTITY\"" >/dev/null <<< "$AVAILABLE_IDENTITIES"; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "✓ 已用「${IDENTITY}」签名"
else
    codesign --force --sign - "$APP"
    echo "✓ 已用 ad-hoc 签名（未找到「${IDENTITY}」证书）"
fi

echo "✓ 已生成 $APP"
if [[ "${1:-}" == "--open" ]]; then
    open "$APP"
fi
