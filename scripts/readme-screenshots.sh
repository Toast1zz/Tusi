#!/bin/bash
# Regenerates the README screenshots in docs/screenshots from TUSI_PREVIEW scenarios.
# Each panel is shot over a plain backdrop window so its glass has something to show
# through, and only the panel's own region is captured — never the rest of the screen.
# Run ./build.sh first; the display must be awake (see caffeinate).
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Tusi.app/Contents/MacOS/Tusi
OUT=docs/screenshots
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/winframe.swift" <<'SWIFT'
import CoreGraphics
// Prints "x y w h" (top-left screen coordinates) of the tallest on-screen window of a pid.
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
let frames = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
    .compactMap { $0[kCGWindowBounds as String] as? [String: Double] }
if let b = frames.max(by: { $0["Height"]! < $1["Height"]! }) {
    print(Int(b["X"]!), Int(b["Y"]!), Int(b["Width"]!), Int(b["Height"]!))
}
SWIFT

cat > "$TMP/backdrop.swift" <<'SWIFT'
import AppKit
// Usage: backdrop x y w h r g b — a borderless solid window just below the panel's level.
let a = CommandLine.arguments.dropFirst().map { Double($0)! }
let screenHeight = NSScreen.screens[0].frame.height
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: NSRect(x: a[0], y: screenHeight - a[1] - a[3], width: a[2], height: a[3]),
                      styleMask: .borderless, backing: .buffered, defer: false)
window.level = NSWindow.Level(rawValue: 2)
window.backgroundColor = NSColor(srgbRed: a[4], green: a[5], blue: a[6], alpha: 1)
window.hasShadow = false
window.orderFrontRegardless()
app.run()
SWIFT

swiftc -o "$TMP/winframe" "$TMP/winframe.swift"
swiftc -o "$TMP/backdrop" "$TMP/backdrop.swift"

# shoot <scenario> <file> <light|dark>
shoot() {
    local backdrop
    if [[ "$3" == dark ]]; then
        backdrop="0.13 0.14 0.17"
        TUSI_DARK=1 TUSI_PREVIEW="$1" "$APP" >/dev/null 2>&1 &
    else
        backdrop="0.86 0.88 0.92"
        TUSI_LIGHT=1 TUSI_PREVIEW="$1" "$APP" >/dev/null 2>&1 &
    fi
    local app_pid=$!
    sleep 4
    local x y w h m=40
    read -r x y w h < <("$TMP/winframe" "$app_pid")
    # shellcheck disable=SC2086
    "$TMP/backdrop" $((x - m - 10)) $((y - m - 10)) $((w + 2 * m + 20)) $((h + 2 * m + 20)) $backdrop &
    local backdrop_pid=$!
    sleep 1.5
    screencapture -x -R$((x - m)),$((y - m)),$((w + 2 * m)),$((h + 2 * m)) "$OUT/$2"
    kill "$app_pid" "$backdrop_pid"
    wait "$app_pid" "$backdrop_pid" 2>/dev/null || true
    echo "✓ $OUT/$2"
}

mkdir -p "$OUT"
shoot main translate-light.png light
shoot main translate-dark.png dark
shoot escalated second-opinion.png light
shoot picker target-picker.png light
shoot settings settings-services.png light
