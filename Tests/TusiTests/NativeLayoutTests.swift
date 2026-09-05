import AppKit
import SwiftUI
import XCTest
@testable import Tusi

@MainActor
final class NativeLayoutTests: XCTestCase {
    func testSettingsCategoryUsesNativeCapsuleTabsAndTargetAction() async throws {
        var selection = SettingsSection.services
        let size: ControlSize
        if #available(macOS 26.0, *) { size = .extraLarge } else { size = .large }
        let picker = SettingsCategoryPicker(selection: Binding(get: { selection }, set: { selection = $0 }))
            .controlSize(size)
        let host = NSHostingView(rootView: picker)
        host.frame = NSRect(x: 0, y: 0, width: 440, height: 30)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        func findControl(_ view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl { return control }
            return view.subviews.compactMap(findControl).first
        }
        let control = try XCTUnwrap(findControl(host))
        if #available(macOS 26.0, *) { XCTAssertEqual(control.controlSize, .extraLarge) }
        else { XCTAssertEqual(control.controlSize, .large) }
        XCTAssertGreaterThan(control.intrinsicContentSize.height, 24)
        if #available(macOS 26.0, *) { XCTAssertEqual(control.borderShape, .capsule) }
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) { XCTAssertEqual(control.role, .tabs) }
        #endif
        XCTAssertEqual(control.selectedSegment, 0)
        XCTAssertTrue(control.acceptsFirstResponder)
        control.selectedSegment = 2
        XCTAssertTrue(control.sendAction(control.action, to: control.target))
        XCTAssertEqual(selection, .general)
    }

    func testCompactNativeSurfacesRenderWithinHeightBudget() async throws {
        for width: CGFloat in [470, 700] {
            for dark in [false, true] {
                for page in ["translator", "settings", "advanced", "translation", "general", "shortcuts"] {
                    let settings = SettingsStore(preview: true)
                    settings.autoCopy = false
                    settings.soundEnabled = false
                    settings.profiles[0] = APIProfile(baseURL: "https://example.com/v1", apiKey: "test-key", model: "translation-model", providerOrder: "provider-a")
                    settings.profiles[1] = settings.profiles[0]
                    settings.profiles[2] = APIProfile(baseURL: "http://localhost:11434/v1", model: "local-model")
                    let engine = TranslationEngine(settings: settings, storage: TranslationStorage(read: { _ in nil }, write: { _, _ in }))
                    engine.debugPreview(input: String(repeating: "这是布局测试。\n", count: 12), output: String(repeating: "A complete translation with several lines of text.\n", count: 30))
                    let state = PanelState()
                    state.panelWidth = width
                    state.availableHeight = 520
                    state.showSettings = page != "translator"
                    state.showShortcuts = page == "shortcuts"
                    if page == "translation" { state.settingsSection = .translation }
                    if page == "general" { state.settingsSection = .general }
                    if page == "advanced" { state.settingsAdvancedProfiles = [0] }
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
                    if ["settings", "advanced", "translation", "general"].contains(page) {
                        XCTAssertGreaterThan(measured, 240)
                        XCTAssertLessThanOrEqual(measured, SettingsView.maximumHeight(availableHeight: 520) + 1)
                        print("SETTINGS_LAYOUT \(page) width=\(width) height=\(measured)")
                    }
                    window.setContentSize(NSSize(width: width, height: min(max(measured, 60), 520)))
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(30))
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

    func testSettingsSectionChangesKeepHeaderAndHeightBounded() async throws {
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        let state = PanelState()
        state.showSettings = true
        state.availableHeight = 480
        let engine = TranslationEngine(settings: settings, storage: TranslationStorage(read: { _ in nil }, write: { _, _ in }))
        var measured: CGFloat = 0
        let root = RootView(onHeightChange: { measured = $0 }, onContentMinWidthChange: { _ in })
            .environmentObject(settings).environmentObject(state).environmentObject(engine)
            .environmentObject(UpdateChecker(preview: true))
            .transaction { $0.animation = nil }
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 480), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        var firstServiceHeight: CGFloat?
        for section in [SettingsSection.services, .translation, .general, .services] {
            state.settingsSection = section
            for _ in 0..<4 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(40))
            }
            XCTAssertGreaterThan(measured, 180)
            XCTAssertLessThanOrEqual(measured, SettingsView.maximumHeight(availableHeight: 480) + 1)
            if section == .services {
                if let firstServiceHeight { XCTAssertEqual(measured, firstServiceHeight, accuracy: 1) }
                else { firstServiceHeight = measured }
            }
        }
    }
}
