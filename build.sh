#!/bin/bash
# Builds Tusi.app into ./build. Usage: ./build.sh [--open]  |  ./build.sh release
#
# Architecture is controlled by TUSI_ARCH (default: native, i.e. whatever this Mac is):
#   TUSI_ARCH=arm64      swift build --arch arm64
#   TUSI_ARCH=universal  builds arm64 + x86_64 separately, lipo's them together
#   TUSI_ARCH=release    both zips into dist/ (same as the ./build.sh release form)
set -euo pipefail
cd "$(dirname "$0")"

ARCH_MODE="${TUSI_ARCH:-native}"
if [[ "${1:-}" == "release" ]]; then
    ARCH_MODE=release
fi

# -strict-concurrency=complete + -warnings-as-errors: any concurrency hazard
# (data race, non-Sendable capture) fails the build instead of shipping a
# Swift-6 time bomb. Applied to EVERY arch mode — not just native — so the
# release zips users download are gated exactly like the debug loop is.
CONCURRENCY_FLAGS=(-Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors)

# VERSION contains the short version and build number, separated by whitespace.
# Environment variables override it for CI/nightly builds.
DEFAULT_VERSION="1.0.0"
DEFAULT_BUILD_NUMBER="1"
if [[ -f VERSION ]]; then
    # || true: a missing trailing newline makes read return nonzero, which would
    # otherwise abort the script under set -e after silently keeping the old version.
    read -r DEFAULT_VERSION DEFAULT_BUILD_NUMBER < VERSION || true
fi
VERSION="${TUSI_VERSION:-${DEFAULT_VERSION:-1.0.0}}"
BUILD_NUMBER="${TUSI_BUILD_NUMBER:-${DEFAULT_BUILD_NUMBER:-1}}"
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+)*(-[A-Za-z0-9.]+)?$ ]]; then
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
        swift build -c release "${CONCURRENCY_FLAGS[@]}"
        cp "$(swift build -c release --show-bin-path)/Tusi" "$APP/Contents/MacOS/Tusi"
        chmod +x "$APP/Contents/MacOS/Tusi"
        ;;
    arm64)
        swift build -c release "${CONCURRENCY_FLAGS[@]}" --arch arm64
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

        swift build -c release "${CONCURRENCY_FLAGS[@]}" --arch arm64
        cp "$(swift build -c release --arch arm64 --show-bin-path)/Tusi" "$arm64_slice"
        swift build -c release "${CONCURRENCY_FLAGS[@]}" --arch x86_64
        cp "$(swift build -c release --arch x86_64 --show-bin-path)/Tusi" "$x86_64_slice"
        lipo -create "$arm64_slice" "$x86_64_slice" -output "$APP/Contents/MacOS/Tusi"
        chmod +x "$APP/Contents/MacOS/Tusi"
        ;;
    release)
        # Both release zips, packed with ditto (zip -r would sprinkle __MACOSX/ junk
        # through the archive). Each slice is built by recursing into this script with
        # the matching TUSI_ARCH; the last build (arm64) is what build/Tusi.app holds.
        mkdir -p dist
        # The identity has to be passed down explicitly. The recursive calls see
        # TUSI_ARCH=universal/arm64, not "release", so on their own they would pick the
        # local Team-ID identity — and a Development certificate carries the developer's
        # name and email, which `codesign -dvvv` would expose on every published zip.
        # An identity the caller set by hand still wins.
        export TUSI_SIGN_IDENTITY="${TUSI_SIGN_IDENTITY:-Tusi Dev Signing}"
        TUSI_ARCH=universal "$0"
        ditto -c -k --norsrc --keepParent "$APP" "dist/Tusi-universal.zip"
        TUSI_ARCH=arm64 "$0"
        ditto -c -k --norsrc --keepParent "$APP" "dist/Tusi-arm64.zip"
        echo "✓ 已生成 dist/Tusi-arm64.zip 与 dist/Tusi-universal.zip"
        # release 已完成全部打包；显式退出，跳过公共尾部的重复签名/echo。
        exit 0
        ;;
    *)
        echo "未知 TUSI_ARCH: ${ARCH_MODE}（可选 native / arm64 / universal / release）" >&2
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

# Bundle the sound pack (uisfx "scifi" mp3s) so Bundle.main can resolve
# "Sounds/scifi/<cue>.mp3" at runtime.
cp -R Resources/Sounds "$APP/Contents/Resources/"

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
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF


# The app's bundle identifier, which is also the Keychain service name the API keys
# are stored under (see Core/Keychain.swift).
BUNDLE_ID="com.tusi.app"

# --- Keychain authorization ----------------------------------------------------
#
# Signing with a stable identity is necessary but NOT sufficient to stop the app
# being re-authorized after every install, and the comment that used to sit here
# claimed otherwise for months. Two independent mechanisms guard a login-keychain
# item, and they behave differently:
#
#   1. The ACL's trusted-application list. For a signed app this matches by
#      designated requirement, so a rebuild signed with the same certificate is
#      still recognised. This is what the stable identity buys, and it works.
#
#   2. The partition ID list (macOS 10.12+), which overrides (1). Its entries take
#      the form `teamid:<TEAM>` for an app signed by an identity that carries a Team
#      ID, and `cdhash:<hash>` when there is none. A Team ID is stable across
#      rebuilds; a cdhash changes with every build.
#
# That is the whole story, and it is why an ordinary Xcode-signed app never shows this
# behavior. A self-signed certificate has no Team ID (`TeamIdentifier=not set`), so
# macOS falls back to pinning the exact binary — and every click of 「始终允许」 only
# appends that one build's cdhash. Tusi's item had accumulated eleven of them.
#
# Verified directly: the same probe signed with a self-signed identity gets
# `cdhash:…` and is denied after a rebuild; signed with an identity carrying a Team ID
# it gets `teamid:…` and is granted after a rebuild. Nothing else changed.
#
# So local builds sign with a Team-ID-carrying identity (see below), and an item that
# still holds a stale cdhash list is repointed once via `./build.sh keychain-unpin`.
keychain_partition_hint() {
    local acl
    acl="$(security find-generic-password -s "$BUNDLE_ID" -a apiKeys 2>/dev/null || true)"
    [[ -z "$acl" ]] && return 0
    local team
    team="$(codesign -dvvv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    [[ -z "$team" || "$team" == "not set" ]] && return 0
    cat <<HINT
ℹ 如果启动时又被要求授权 API Key，运行一次（需要输入登录钥匙串密码）：
    ./build.sh keychain-unpin
  这会把记录的 partition 固定到 teamid:${team}，之后重新构建不再触发授权。
HINT
}

# Sign with a stable identity when one is available, otherwise ad-hoc.
#
# Release archives are packed with ditto --norsrc (see the `ditto` calls in the
# release case): macOS stamps filesystem metadata (com.apple.provenance,
# com.apple.macl) on freshly created files, and those attributes are system-managed
# — xattr -d/-c silently no-ops on them. ditto would otherwise archive them as
# AppleDouble entries, and zip tools that can't restore forks would leave stray ._*
# files behind, making the extracted bundle fail strict signature verification.
# Omitting the metadata at archive time keeps every extraction clean instead.
#
# An ad-hoc signature's designated requirement is the binary's cdhash, so it changes on
# every build. Signing with a real identity pins the requirement to the certificate
# instead, which is what lets the ACL's trusted-application check survive a rebuild.
# That check is only half the story — see the partition-ID note above for the other
# half, which is what actually decides whether the app gets re-authorized.
#
# Anyone building this from a clone just falls through to ad-hoc: no certificate needed,
# and the result works exactly as before.
#
# The default identity is Tusi's own signing certificate (a self-signed cert in the
# dedicated tusi-dev.keychain-db). find-identity without -v is used for the presence
# check on purpose: -v filters to *trusted* identities, which would hide a perfectly
# usable self-signed certificate and silently fall back to ad-hoc.
#
# The identity resolves through the default keychain search list — normally the login
# keychain, which macOS unlocks automatically at login, so builds never ask for a
# keychain password. The dedicated-keychain override below is kept for machines that
# keep the identity in its own keychain:
#   TUSI_SIGN_KEYCHAIN=~/Library/Keychains/tusi-dev.keychain-db \
#   TUSI_SIGN_KEYCHAIN_PW_FILE=~/.dsh/tusi-signing.pw ./build.sh
# Local builds prefer an identity that carries a Team ID, because that is what decides
# whether macOS re-authorizes the Keychain item after every install (see the partition-ID
# note above). Release archives deliberately do NOT use it: a Development certificate
# embeds the developer's name and email in the binary, and `codesign -dvvv` on a published
# zip would hand that to anyone who downloads it. Release keeps the anonymous self-signed
# identity, and its users type the API key once into a build they keep.
# (The `release` mode never reaches here: it recurses per architecture and exits. It
# pins TUSI_SIGN_IDENTITY to the anonymous identity before recursing — see that branch.)
if [[ -n "${TUSI_SIGN_IDENTITY:-}" ]]; then
    IDENTITY="$TUSI_SIGN_IDENTITY"
else
    TEAM_IDENTITY="$(security find-identity -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
    IDENTITY="${TEAM_IDENTITY:-Tusi Dev Signing}"
fi

if [[ -n "${TUSI_SIGN_KEYCHAIN:-}" && -f "${TUSI_SIGN_KEYCHAIN_PW_FILE:-}" ]]; then
    security unlock-keychain -p "$(cat "$TUSI_SIGN_KEYCHAIN_PW_FILE")" "$TUSI_SIGN_KEYCHAIN" >/dev/null 2>&1 || true
fi

AVAILABLE_IDENTITIES="$(security find-identity -p codesigning 2>/dev/null || true)"
if grep -F "\"$IDENTITY\"" >/dev/null <<< "$AVAILABLE_IDENTITIES"; then
    # Identity exists but signing fails (e.g. the keychain is locked): fail loudly
    # instead of installing an ad-hoc build that would re-trigger the Keychain prompt.
    codesign --force --sign "$IDENTITY" "$APP" || {
        echo "✗ 签名失败：身份「${IDENTITY}」存在但无法使用（钥匙串是否已解锁？）" >&2
        exit 1
    }
    codesign --verify --deep --strict "$APP"
    echo "✓ 已用「${IDENTITY}」签名并验证"
else
    codesign --force --sign - "$APP"
    echo "✓ 已用 ad-hoc 签名（未找到「${IDENTITY}」证书）"
fi

echo "✓ 已生成 $APP"
INSTALLED=0
DO_OPEN=0
for arg in "$@"; do
    case "$arg" in
        --open)
            DO_OPEN=1
            ;;
        install)
            # 调试循环：装到 /Applications。
            rm -rf /Applications/Tusi.app
            cp -R "$APP" /Applications/Tusi.app
            INSTALLED=1
            echo "✓ 已安装到 /Applications/Tusi.app"
            keychain_partition_hint
            ;;
        keychain-unpin)
            # Repoints the item's partition list at the Team ID the app is now signed
            # with. An empty list (-S "") does NOT mean "unrestricted" — it writes one
            # empty string, which matches nothing, so the prompt comes back and appends
            # yet another cdhash. The value has to be a partition macOS can actually
            # match, and teamid: is the only one that is stable across rebuilds.
            TEAM="$(codesign -dvvv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
            if [[ -z "$TEAM" || "$TEAM" == "not set" ]]; then
                echo "✗ 当前签名身份没有 Team ID，partition 只能按 cdhash 记录，无法固定。" >&2
                echo "  用带 Team 的证书重新构建后再运行（见 build.sh 的签名身份选择）。" >&2
                exit 1
            fi
            echo "把 API Key 记录的 partition 固定到 teamid:${TEAM}（需要输入登录钥匙串密码）："
            security set-generic-password-partition-list \
                -S "teamid:$TEAM" -s "$BUNDLE_ID" -a apiKeys \
                "$HOME/Library/Keychains/login.keychain-db"
            ;;
    esac
done
if [[ "$DO_OPEN" == "1" ]]; then
    if [[ "$INSTALLED" == "1" ]]; then
        open /Applications/Tusi.app
    else
        open "$APP"
    fi
fi
