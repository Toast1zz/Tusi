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
                for page in ["translator", "hold", "settings", "local", "advanced", "translation", "general", "shortcuts"] {
                    let settings = SettingsStore(preview: true)
                    settings.autoCopy = false
                    settings.soundEnabled = false
                    settings.profiles[0] = APIProfile(baseURL: "https://example.com/v1", apiKey: "test-key", model: "translation-model", providerOrder: "provider-a")
                    settings.profiles[1] = settings.profiles[0]
                    settings.profiles[2] = APIProfile(baseURL: "http://localhost:11434/v1", model: "local-model")
                    let engine = TranslationEngine(settings: settings, storage: TranslationStorage(read: { _ in nil }, write: { _, _ in }))
                    let sampleOutput = String(repeating: "A complete translation with several lines of text.\n", count: 30)
                    engine.debugPreview(input: String(repeating: "这是布局测试。\n", count: 12), output: sampleOutput,
                                        versions: [.init(text: sampleOutput, slot: 0, tier: .online,
                                                         languageMismatch: false, capped: false, afterFailover: false,
                                                         host: "opencode.ai", model: "mimo-v2.5")])
                    let state = PanelState()
                    state.panelWidth = width
                    state.availableHeight = 520
                    state.showSettings = page != "translator" && page != "hold"
                    if page == "hold" { state.returnHoldProgress = 0.5 }
                    state.showShortcuts = page == "shortcuts"
                    if page == "local" { state.settingsProfileIndex = SettingsStore.localProfileIndex }
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
                    if ["settings", "local", "advanced", "translation", "general"].contains(page) {
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
        var heightReports: [CGFloat] = []
        let root = RootView(onHeightChange: { measured = $0; heightReports.append($0) }, onContentMinWidthChange: { _ in })
            .environmentObject(settings).environmentObject(state).environmentObject(engine)
            .environmentObject(UpdateChecker(preview: true))
            .transaction { $0.animation = nil }
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 480), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        var firstServiceHeight: CGFloat?
        for section in [SettingsSection.services, .translation, .general, .translation, .general, .services] {
            heightReports.removeAll()
            state.settingsSection = section
            for _ in 0..<6 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(40))
            }
            XCTAssertGreaterThan(measured, 180)
            XCTAssertLessThanOrEqual(measured, SettingsView.maximumHeight(availableHeight: 480) + 1)
            if section == .general { XCTAssertLessThan(measured, 400) }


            if section == .services {
                if let firstServiceHeight { XCTAssertEqual(measured, firstServiceHeight, accuracy: 1) }
                else { firstServiceHeight = measured }
            }
        }
    }
    func testNaturalSettingsTransitionKeepsHeaderAnchoredAndAnimatesWindowMonotonically() async throws {
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.profiles[0] = APIProfile(baseURL: "https://opencode.ai/v1", apiKey: "fake", model: "mimo-v2.5")
        settings.profiles[1] = APIProfile(baseURL: "https://api.deepseek.com/v1", apiKey: "fake", model: "deepseek-flash")
        settings.profiles[2] = APIProfile(baseURL: "http://localhost:8080/v1", model: "local-model")
        let state = PanelState()
        state.showSettings = true
        state.settingsSection = .translation
        state.availableHeight = 600
        let engine = TranslationEngine(settings: settings, storage: TranslationStorage(read: { _ in nil }, write: { _, _ in }))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 470, height: 440),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var animated = false
        var destination: CGFloat = 0
        let root = RootView(onHeightChange: { height in
            guard abs(destination - height) > 0.5 else { return }
            destination = height
            var frame = window.frame
            frame.origin.y = frame.maxY - height
            frame.size.height = height
            if animated { PanelController.animateResize(window, to: frame) }
            else { window.setFrame(frame, display: true) }
        }, onContentMinWidthChange: { _ in })
            .environmentObject(settings).environmentObject(state).environmentObject(engine)
            .environmentObject(UpdateChecker(preview: true))
            .frame(maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, .light)
            .background(Color.white)
        let host = NSHostingView(rootView: root)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        window.alphaValue = 0
        window.orderBack(nil)
        defer { window.close() }
        for _ in 0..<15 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        func findCategory(_ view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl { return control }
            return view.subviews.compactMap(findCategory).first
        }
        let control = try XCTUnwrap(findCategory(host))
        func headerScreenTop() -> CGFloat {
            window.convertToScreen(control.convert(control.bounds, to: nil)).maxY
        }
        var trace = "section,frame,height,windowTop,headerTop\n"
        for section in [SettingsSection.general, .translation, .services, .general] {
            let startHeight = window.frame.height
            let top = window.frame.maxY
            let headerTop = headerScreenTop()
            animated = true
            state.settingsSection = section
            var heights: [CGFloat] = []
            for index in 0..<35 {
                try await Task.sleep(for: .milliseconds(16))
                host.layoutSubtreeIfNeeded()
                let height = window.frame.height
                heights.append(height)
                if [0, 6, 20].contains(index), let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/tusi-transition-\(section.rawValue)-\(index).png"))
                }
                XCTAssertEqual(window.frame.maxY, top, accuracy: 1)
                XCTAssertEqual(headerScreenTop(), headerTop, accuracy: 1, "Category controls must not jump")
                trace += "\(section.rawValue),\(index),\(height),\(window.frame.maxY),\(headerScreenTop())\n"
            }
            let endHeight = window.frame.height
            XCTAssertGreaterThan(abs(startHeight - endHeight), 20, "Pages must retain distinct natural heights")
            XCTAssertEqual(endHeight, destination, accuracy: 1)
            let intermediate = heights.filter { abs($0 - startHeight) > 1 && abs($0 - endHeight) > 1 }
            XCTAssertGreaterThan(intermediate.count, 2, "Window must animate, not snap")
            let direction: CGFloat = endHeight > startHeight ? 1 : -1
            for pair in zip(heights, heights.dropFirst()) {
                XCTAssertGreaterThanOrEqual((pair.1 - pair.0) * direction, -1, "Height must not reverse during transition")
            }
        }
        try trace.write(toFile: "/tmp/tusi-settings-native-transition.csv", atomically: true, encoding: .utf8)
    }

    func testInputLineResizeSharesWindowFramesAndKeepsFirstLineAnchored() async throws {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        print("INPUT_TRANSITION reduceMotion=\(reduceMotion)")
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.soundEnabled = false
        let state = PanelState()
        let engine = TranslationEngine(settings: settings, storage: TranslationStorage(read: { _ in nil }, write: { _, _ in }))
        engine.input = "投资人"
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 470, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var directReports = 0
        let root = RootView(onHeightChange: { height in
            var frame = window.frame
            frame.origin.y = frame.maxY - ceil(height)
            frame.size.height = ceil(height)
            if state.inputResizeInProgress { directReports += 1 }
            window.setFrame(frame, display: true)
        }, onContentMinWidthChange: { _ in })
            .environmentObject(settings).environmentObject(state).environmentObject(engine)
            .environmentObject(UpdateChecker(preview: true))
            .frame(maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, .light)
            .background(Color.white)
        let host = NSHostingView(rootView: root)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        window.alphaValue = 0
        window.orderBack(nil)
        defer { window.close() }
        for _ in 0..<15 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(15))
        }
        func findEditor(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.isEditable { return text }
            return view.subviews.compactMap(findEditor).first
        }
        let editor = try XCTUnwrap(findEditor(host))
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        window.makeFirstResponder(editor)
        let oneLineHeight = window.frame.height
        let top = window.frame.maxY
        let inputTop = window.convertToScreen(editor.convert(editor.bounds, to: nil)).maxY
        let chromeGap = window.convertToScreen(scroll.convert(scroll.bounds, to: nil)).minY - window.frame.minY
        var trace = "direction,frame,height,windowTop,inputTop,scrollY\n"
        for growing in [true, false] {
            let start = window.frame.height
            directReports = 0
            if growing {
                editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
                editor.insertNewline(nil)
            } else {
                editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
                editor.deleteBackward(nil)
            }
            var heights: [CGFloat] = []
            for index in 0..<30 {
                try await Task.sleep(for: .milliseconds(8))
                host.layoutSubtreeIfNeeded()
                let height = window.frame.height
                heights.append(height)
                let currentInputTop = window.convertToScreen(editor.convert(editor.bounds, to: nil)).maxY
                XCTAssertEqual(window.frame.maxY, top, accuracy: 1)
                let gap = window.convertToScreen(scroll.convert(scroll.bounds, to: nil)).minY - window.frame.minY
                XCTAssertEqual(gap, chromeGap, accuracy: 1, "Input bottom and window bottom must move together")
                XCTAssertEqual(currentInputTop, inputTop, accuracy: 1, "First input line must stay anchored")
                XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 1, "Caret reveal must not scroll the first line away")
                trace += "\(growing),\(index),\(height),\(window.frame.maxY),\(currentInputTop),\(scroll.contentView.bounds.origin.y)\n"
            }
            let end = window.frame.height
            XCTAssertEqual(end, oneLineHeight + (growing ? TranslatorView.measureEditorLineMetrics().step : 0), accuracy: 1)
            if !reduceMotion {
                XCTAssertGreaterThan(directReports, 2, "The window must receive intermediate layout frames")
                XCTAssertGreaterThan(Set(heights).count, 2)
            }
            let direction: CGFloat = growing ? 1 : -1
            for pair in zip([start] + heights, heights) {
                XCTAssertGreaterThanOrEqual((pair.1 - pair.0) * direction, -1, "Input resize must not reverse")
            }
        }
        // The guard applies only to documents that grow within the input cap.
        editor.insertText(String(repeating: "\nlong input", count: 12), replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 1, "Long drafts must still scroll to the caret")
        try trace.write(toFile: "/tmp/tusi-input-line-transition.csv", atomically: true, encoding: .utf8)
    }

    func testCompactWidthStaysStableForShortDraftAndExpandsOnceForLongContent() async throws {
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.soundEnabled = false
        let state = PanelState()
        state.panelWidth = Theme.compactPanelMinWidth
        let engine = TranslationEngine(settings: settings, storage: TranslationStorage(read: { _ in nil }, write: { _, _ in }))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: state.panelWidth, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var widths: [CGFloat] = []
        let root = RootView(onHeightChange: { height in
            var frame = window.frame
            frame.origin.y = frame.maxY - ceil(height)
            frame.size.height = ceil(height)
            window.setFrame(frame, display: true)
        }, onContentMinWidthChange: { controls in
            let target = PanelController.resolvedWidth(saved: settings.panelWidth, controls: controls, compact: state.usesCompactWidth)
            if abs(target - state.panelWidth) > 0.5 { widths.append(target) }
            state.panelWidth = target
            var frame = window.frame
            let center = frame.midX
            frame.size.width = target
            frame.origin.x = center - target / 2
            window.setFrame(frame, display: true)
        })
            .environmentObject(settings).environmentObject(state).environmentObject(engine)
            .environmentObject(UpdateChecker(preview: true))
            .frame(maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, .light)
            .background(Color.white)
        let host = NSHostingView(rootView: root)
        window.contentView = host
        defer { window.close() }
        func settle() async throws {
            for _ in 0..<20 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(15))
            }
        }
        func snapshot(_ name: String) throws {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/tusi-compact-\(name).png"))
        }
        try await settle()
        let compact = state.panelWidth
        print("COMPACT_WIDTH empty=\(compact) height=\(window.frame.height)")
        XCTAssertLessThan(compact, Theme.panelMinWidth)
        XCTAssertLessThan(window.frame.height, 100)
        try snapshot("empty")
        widths.removeAll()
        for text in ["投", "投资", "投资人"] {
            engine.input = text
            try await settle()
            XCTAssertEqual(state.panelWidth, compact, accuracy: 0.5)
        }
        XCTAssertTrue(widths.isEmpty, "Typing a short draft must not widen the window")
        engine.debugPreview(input: "投资人", output: "Investor")
        try await settle()
        XCTAssertEqual(state.panelWidth, compact, accuracy: 0.5)
        try snapshot("short-result")
        engine.input = String(repeating: "这是一段需要更多阅读空间的长文本。", count: 15)
        try await settle()
        XCTAssertTrue(state.expandedDraftWidth)
        XCTAssertGreaterThanOrEqual(state.panelWidth, Theme.panelMinWidth)
        let expanded = state.panelWidth
        engine.input = "投资人"
        try await settle()
        XCTAssertEqual(state.panelWidth, expanded, accuracy: 0.5, "Deleting near a wrapping boundary must not oscillate width")
        engine.input = ""
        try await settle()
        XCTAssertEqual(state.panelWidth, compact, accuracy: 0.5)
        state.showSettings = true
        try await settle()
        XCTAssertGreaterThanOrEqual(state.panelWidth, Theme.panelMinWidth)
        state.showSettings = false
        try await settle()
        XCTAssertEqual(state.panelWidth, compact, accuracy: 0.5)
    }

    func testFirstAndRepeatedClearUseOneMonotonicWindowTransition() async throws {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        print("CLEAR_TRANSITION reduceMotion=\(reduceMotion)")
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.soundEnabled = false
        let state = PanelState()
        let engine = TranslationEngine(settings: settings, storage: TranslationStorage(read: { _ in nil }, write: { _, _ in }))
        let source = String(repeating: "This is a long source line that fills the editor.\n", count: 8)
        let output = String(repeating: "This is the completed translation.\n", count: 5)
        engine.debugPreview(input: source, output: output)
        let app = NSApplication.shared
        let existing = Set(app.windows.map(ObjectIdentifier.init))
        let controller = PanelController(engine: engine, settings: settings, panelState: state,
                                         updateChecker: UpdateChecker(preview: true), statusItem: nil)
        let window = try XCTUnwrap(app.windows.first { !existing.contains(ObjectIdentifier($0)) && $0 is FloatingPanel })
        window.alphaValue = 0
        window.orderBack(nil)
        defer { controller.hide() }
        func settle() async throws {
            for _ in 0..<50 {
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await settle()
        var trace = "pass,sample,width,height,top,centerX\n"
        var endpoints: [NSSize] = []
        for pass in 0..<2 {
            if pass > 0 {
                engine.debugPreview(input: source, output: output)
                try await settle()
            }
            let start = window.frame
            engine.input = ""
            var frames: [NSRect] = [start]
            for sample in 0..<50 {
                try await Task.sleep(for: .milliseconds(8))
                window.contentView?.layoutSubtreeIfNeeded()
                let frame = window.frame
                frames.append(frame)
                trace += "\(pass),\(sample),\(frame.width),\(frame.height),\(frame.maxY),\(frame.midX)\n"
                XCTAssertEqual(frame.maxY, start.maxY, accuracy: 1)
                XCTAssertEqual(frame.midX, start.midX, accuracy: 1)
            }
            let end = window.frame
            endpoints.append(end.size)
            XCTAssertLessThan(end.width, start.width)
            XCTAssertLessThan(end.height, 100)
            XCTAssertFalse(state.inputResizeInProgress)
            for (previous, next) in zip(frames, frames.dropFirst()) {
                XCTAssertLessThanOrEqual(next.width, previous.width + 1, "Clearing must not shrink then widen")
                XCTAssertLessThanOrEqual(next.height, previous.height + 1, "Clearing must not reverse height")
                if !reduceMotion {
                    XCTAssertLessThanOrEqual(previous.height - next.height, (start.height - end.height) * 0.4,
                                             "Clearing must not snap off the result before shrinking the input")
                }
            }
            let intermediate = frames.filter { $0.height < start.height - 1 && $0.height > end.height + 1 }
            if !reduceMotion { XCTAssertGreaterThan(intermediate.count, 2) }
        }
        XCTAssertEqual(endpoints[0].width, endpoints[1].width, accuracy: 1)
        XCTAssertEqual(endpoints[0].height, endpoints[1].height, accuracy: 1)
        try trace.write(toFile: "/tmp/tusi-first-repeated-clear.csv", atomically: true, encoding: .utf8)
    }

}
