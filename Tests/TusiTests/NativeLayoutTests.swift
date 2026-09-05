import AppKit
import SwiftUI
import XCTest
@testable import Tusi

@MainActor
final class NativeLayoutTests: XCTestCase {
    func testCompactNativeSurfacesRenderWithinHeightBudget() async throws {
        for width: CGFloat in [470, 700] {
            for dark in [false, true] {
                for page in ["translator", "settings", "shortcuts"] {
                    let settings = SettingsStore(preview: true)
                    settings.autoCopy = false
                    settings.soundEnabled = false
                    let engine = TranslationEngine(settings: settings, storage: TranslationStorage(read: { _ in nil }, write: { _, _ in }))
                    engine.debugPreview(input: String(repeating: "这是布局测试。\n", count: 12), output: String(repeating: "A complete translation with several lines of text.\n", count: 30))
                    let state = PanelState()
                    state.panelWidth = width
                    state.availableHeight = 520
                    state.showSettings = page != "translator"
                    state.showShortcuts = page == "shortcuts"
                    var measured: CGFloat = 0
                    let root = RootView(onHeightChange: { measured = $0 }, onContentMinWidthChange: { _ in })
                        .environmentObject(settings).environmentObject(engine).environmentObject(state)
                        .environmentObject(UpdateChecker(preview: true))
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .transaction { $0.animation = nil }
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(dark ? Color.black : Color.white)
                    let rect = NSRect(x: 0, y: 0, width: width, height: 520)
                    let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let host = NSHostingView(rootView: root)
                    host.frame = rect
                    window.contentView = host
                    for _ in 0..<3 {
                        host.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(30))
                    }
                    XCTAssertGreaterThan(measured, 0)
                    if page == "translator" { XCTAssertLessThanOrEqual(measured, 520) }
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    XCTAssertGreaterThan(data.count, 1000)
                    let path = "/tmp/tusi-layout-\(page)-\(Int(width))-\(dark ? "dark" : "light").png"
                    try data.write(to: URL(fileURLWithPath: path))
                    window.close()
                }
            }
        }
    }
}
