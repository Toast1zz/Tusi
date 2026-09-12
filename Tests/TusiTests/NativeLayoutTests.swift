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
                    let root = RootView(onHeightChange: { measured = $0 })
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
        let root = RootView(onHeightChange: { measured = $0; heightReports.append($0) })
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
        let window = FloatingPanel(contentRect: NSRect(x: 100, y: 100, width: 470, height: 440),
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
        })
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
        })
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
        window.setFrameOrigin(NSPoint(x: 200, y: 200))
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
            XCTAssertEqual(end.width, start.width, accuracy: 1, "Clearing must preserve the reading width")
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

    func testSettledAuditRepairsStaleHeightWithoutAnotherPreference() async throws {
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.soundEnabled = false
        let state = PanelState()
        let engine = TranslationEngine(settings: settings, storage: TranslationStorage(read: { _ in nil }, write: { _, _ in }))
        engine.input = "First line\nSecond line\nThird line"
        let app = NSApplication.shared
        let existing = Set(app.windows.map(ObjectIdentifier.init))
        let controller = PanelController(engine: engine, settings: settings, panelState: state,
                                         updateChecker: UpdateChecker(preview: true), statusItem: nil)
        let window = try XCTUnwrap(app.windows.first { !existing.contains(ObjectIdentifier($0)) && $0 is FloatingPanel })
        window.setFrameOrigin(NSPoint(x: 200, y: 200))
        window.alphaValue = 0
        window.orderBack(nil)
        defer { controller.hide() }
        func settle() async throws {
            for _ in 0..<100 {
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await settle()
        let natural = window.frame
        // Reproduce the incident: the last report still describes the removed result,
        // while the actual view has already shrunk. No new geometry is required.
        controller.setContentHeight(natural.height + 163)
        try await settle()
        XCTAssertEqual(window.frame.height, natural.height, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, natural.maxY, accuracy: 1)
        XCTAssertEqual(window.frame.width, natural.width, accuracy: 1)

        // Editing without changing the line count must also trigger reconciliation.
        var stale = window.frame
        stale.origin.y -= 100
        stale.size.height += 100
        window.setFrame(stale, display: true)
        engine.input = "First edit\nSecond line\nThird line"
        try await settle()
        XCTAssertEqual(window.frame.height, natural.height, accuracy: 1)

        // A new result arriving during shrink confirmation must invalidate the old
        // measurement, and its full height must survive the follow-up audits.
        controller.setContentHeight(natural.height + 163)
        try await Task.sleep(for: .milliseconds(370))
        engine.debugPreview(input: engine.input, output: String(repeating: "A completed result line.\n", count: 8))
        try await settle()
        let resultHeight = window.frame.height
        XCTAssertGreaterThan(resultHeight, natural.height + 100)
        try await settle()
        XCTAssertEqual(window.frame.height, resultHeight, accuracy: 1)
    }

    func testDirectInputResizeCancelsPreviousWindowAnimation() async throws {
        let window = FloatingPanel(contentRect: NSRect(x: 200, y: 200, width: 470, height: 307),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        let top = window.frame.maxY
        PanelController.animateResize(window, to: NSRect(x: 200, y: top - 188, width: 470, height: 188))
        try await Task.sleep(for: .milliseconds(25))
        // Mirrors rapid deletion: input interpolation takes over the result-removal
        // animation, then stops producing height reports at its final one-line size.
        for height in stride(from: 180.0, through: 83.0, by: -1) {
            window.setFrame(NSRect(x: 200, y: top - height, width: 470, height: height), display: true)
            try await Task.sleep(for: .milliseconds(2))
            XCTAssertEqual(window.frame.height, height, accuracy: 1)
            XCTAssertEqual(window.frame.maxY, top, accuracy: 1)
        }
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(8))
            XCTAssertEqual(window.frame.height, 83, accuracy: 1, "Old animation must not restore the 188pt destination")
        }
    }

    func testRapidDeletionFromCompletedResultDoesNotWaitForFitAudit() async throws {
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.soundEnabled = false
        let state = PanelState()
        let engine = TranslationEngine(settings: settings, storage: TranslationStorage(read: { _ in nil }, write: { _, _ in }))
        engine.debugPreview(input: String(repeating: "Long source line\n", count: 8),
                            output: String(repeating: "Translated line\n", count: 5))
        let app = NSApplication.shared
        let existing = Set(app.windows.map(ObjectIdentifier.init))
        let controller = PanelController(engine: engine, settings: settings, panelState: state,
                                         updateChecker: UpdateChecker(preview: true), statusItem: nil)
        let window = try XCTUnwrap(app.windows.first { !existing.contains(ObjectIdentifier($0)) && $0 is FloatingPanel })
        window.setFrameOrigin(NSPoint(x: 200, y: 200))
        window.alphaValue = 0
        window.orderBack(nil)
        defer { controller.hide() }
        try await Task.sleep(for: .milliseconds(700))
        let top = window.frame.maxY
        engine.input = "One line remains"
        for sample in 0..<60 {
            try await Task.sleep(for: .milliseconds(8))
            window.contentView?.layoutSubtreeIfNeeded()
            // Continue same-height edits to debounce the fallback audit. The direct
            // resize must settle independently of that delayed safety check.
            if sample % 5 == 0 { engine.input += "a" }
            if sample >= 25 {
                XCTAssertLessThan(window.frame.height, 100, "Input resize must settle before the fallback audit")
                XCTAssertEqual(window.frame.maxY, top, accuracy: 1)
            }
        }
    }

    func testEmptyHistoryCompactsAndUndoRestoresListHeight() async throws {
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.soundEnabled = false
        let record = TranslationEngine.Record(id: UUID(), input: "测试", output: "Test", sourceLabel: "中",
                                              source: .chinese, target: .english, tone: .standard, timestamp: Date())
        let data = try JSONEncoder().encode([record])
        let engine = TranslationEngine(settings: settings, storage: TranslationStorage(
            read: { $0.lastPathComponent == "history.json" ? data : nil }, write: { _, _ in }))
        XCTAssertEqual(engine.history.count, 1)
        let state = PanelState()
        state.showHistory = true
        let app = NSApplication.shared
        let existing = Set(app.windows.map(ObjectIdentifier.init))
        let controller = PanelController(engine: engine, settings: settings, panelState: state,
                                         updateChecker: UpdateChecker(preview: true), statusItem: nil)
        let window = try XCTUnwrap(app.windows.first { !existing.contains(ObjectIdentifier($0)) && $0 is FloatingPanel })
        window.setFrameOrigin(NSPoint(x: 200, y: 200))
        window.alphaValue = 0
        window.orderBack(nil)
        defer { controller.hide() }
        try await Task.sleep(for: .milliseconds(650))
        let populated = window.frame
        engine.deleteHistory(record.id)
        var heights: [CGFloat] = []
        for _ in 0..<70 {
            try await Task.sleep(for: .milliseconds(8))
            window.contentView?.layoutSubtreeIfNeeded()
            heights.append(window.frame.height)
            XCTAssertEqual(window.frame.maxY, populated.maxY, accuracy: 1)
        }
        XCTAssertTrue(engine.canUndoHistoryDeletion)
        XCTAssertLessThan(window.frame.height, 140, "Empty history should contain only its header")
        XCTAssertLessThan(window.frame.height, populated.height - 15)
        for (a, b) in zip(heights, heights.dropFirst()) {
            XCTAssertLessThanOrEqual(b, a + 1, "Deleting the last record must not reverse the shrink")
        }
        let material = try XCTUnwrap(window.contentView as? NSVisualEffectView)
        let mask = try XCTUnwrap(material.maskImage)
        let representation = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(mask.tiffRepresentation)))
        XCTAssertEqual(try XCTUnwrap(representation.colorAt(x: 0, y: 0)).alphaComponent, 0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(representation.colorAt(x: representation.pixelsWide / 2, y: representation.pixelsHigh / 2)).alphaComponent, 1, accuracy: 0.01)
        let view = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/tusi-empty-history-compact.png"))
        engine.undoHistoryDeletion()
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(engine.history.count, 1)
        XCTAssertEqual(window.frame.height, populated.height, accuracy: 1)
    }

    func testHistoryToggleKeepsToolbarGlyphsOnSameRow() async throws {
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.soundEnabled = false
        let engine = TranslationEngine(settings: settings, storage: TranslationStorage(read: { _ in nil }, write: { _, _ in }))
        let state = PanelState()
        state.showHistory = true
        let app = NSApplication.shared
        let existing = Set(app.windows.map(ObjectIdentifier.init))
        let controller = PanelController(engine: engine, settings: settings, panelState: state,
                                         updateChecker: UpdateChecker(preview: true), statusItem: nil)
        let window = try XCTUnwrap(app.windows.first { !existing.contains(ObjectIdentifier($0)) && $0 is FloatingPanel })
        window.setFrameOrigin(NSPoint(x: 200, y: 200))
        window.alphaValue = 0
        window.appearance = NSAppearance(named: .aqua)
        window.orderBack(nil)
        defer { controller.hide() }
        try await Task.sleep(for: .milliseconds(600))
        let view = try XCTUnwrap(window.contentView)
        let width = window.frame.width
        for expanded in [false, true, false] {
            // History sits just left of settings at the bar's trailing end: 16pt margin,
            // the 26pt settings button, an 8pt gap, then history's 26pt — centred 63pt in.
            let point = NSPoint(x: width - 63, y: 23)
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1))
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: window.windowNumber, context: nil,
                eventNumber: 2, clickCount: 1, pressure: 0))
            window.sendEvent(down)
            window.sendEvent(up)
            XCTAssertEqual(state.showHistory, expanded, "Mouse click must invoke the history button")
            for sample in 0..<30 {
                try await Task.sleep(for: .milliseconds(8))
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
                // Only the bottom bar's own 36pt (26pt controls, 10pt margin): the input
                // placeholder and the history list sit above the same columns, and while the
                // window catches up a history row is revealed right against the bar's top.
                let band = max(0, bitmap.pixelsHigh - Int(36 * scale))..<bitmap.pixelsHigh
                func glyphY(_ start: CGFloat, _ end: CGFloat) -> CGFloat? {
                    var total: CGFloat = 0
                    var count: CGFloat = 0
                    for x in Int(start * scale)..<Int(end * scale) {
                        for y in band {
                            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.8,
                                  min(c.redComponent, c.greenComponent, c.blueComponent) < 0.65 else { continue }
                            total += CGFloat(y) / scale
                            count += 1
                        }
                    }
                    return count > 0 ? total / count : nil
                }
                let clock = try XCTUnwrap(glyphY(width - 70, width - 56), "History glyph must remain visible")
                let chip = try XCTUnwrap(glyphY(20, 60), "Direction chip must remain visible")
                XCTAssertEqual(clock, chip, accuracy: 3, "History icon must travel with the rest of the bar")
                if [1, 5, 10].contains(sample) {
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/tusi-history-toggle-\(expanded)-\(sample).png"))
                }
            }
        }
    }

    /// A click on a segment selects it, once, and does not drag the panel. (XCTest's
    /// synthetic `leftMouseDragged` events do not drive SwiftUI drag gestures — no
    /// hardware button is down — so the drag itself is covered by the release rule below
    /// and by hand.)
    /// Opening and closing history from a typed, untranslated input — the state it was
    /// reported to jitter in. Before the content was clipped above a bar that rides the
    /// window edge, the input jumped 43pt up and back on opening and the bar slid out of
    /// the window. Traced frame by frame: window height and top, the input's top edge, and
    /// the bar's trailing glyph's distance from the window bottom.
    func testHistoryToggleKeepsInputAndBarStill() async throws {
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.soundEnabled = false
        let now = Date()
        let records = (0..<3).map { index in
            TranslationEngine.Record(id: UUID(), input: "第\(index)条原文，用来测试历史的展开和收起。",
                                     output: index == 2 ? String(repeating: "A longer translation that wraps onto a second line. ", count: 2) : "A short translation.",
                                     sourceLabel: "中", source: .chinese, target: .english, tone: .standard,
                                     timestamp: index == 2 ? now.addingTimeInterval(-90_000) : now)
        }
        let data = try JSONEncoder().encode(records)
        let engine = TranslationEngine(settings: settings, storage: TranslationStorage(
            read: { $0.lastPathComponent == "history.json" ? data : nil }, write: { _, _ in }))
        engine.input = "下周周会上我将分享我们黑五和圣诞的具体战略，届时将和各位讨论任务分配责任人等情况。"
        let state = PanelState()
        let app = NSApplication.shared
        let existing = Set(app.windows.map(ObjectIdentifier.init))
        let controller = PanelController(engine: engine, settings: settings, panelState: state,
                                         updateChecker: UpdateChecker(preview: true), statusItem: nil)
        let window = try XCTUnwrap(app.windows.first { !existing.contains(ObjectIdentifier($0)) && $0 is FloatingPanel })
        window.setFrameOrigin(NSPoint(x: 200, y: 200))
        window.alphaValue = 0
        window.appearance = NSAppearance(named: .aqua)
        window.orderBack(nil)
        defer { controller.hide() }
        try await Task.sleep(for: .milliseconds(700))
        let view = try XCTUnwrap(window.contentView)
        func findEditor(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.isEditable { return text }
            return view.subviews.compactMap(findEditor).first
        }
        let editor = try XCTUnwrap(findEditor(view))
        var trace = "pass,sample,ms,height,top,editorTopFromWindowTop,clockFromBottom\n"
        var maxEditorShift: CGFloat = 0
        var maxClockShift: CGFloat = 0
        var reversals = 0
        var editorMoves = 0
        var barMoves = 0
        for (pass, expanded) in [true, false, true, false].enumerated() {
            let started = ProcessInfo.processInfo.systemUptime
            state.showHistory = expanded
            var previousHeight = window.frame.height
            var direction: CGFloat = 0
            var firstEditor: CGFloat?
            var firstClock: CGFloat?
            for sample in 0..<45 {
                try await Task.sleep(for: .milliseconds(8))
                view.layoutSubtreeIfNeeded()
                let frame = window.frame
                let editorTop = frame.maxY - window.convertToScreen(editor.convert(editor.bounds, to: nil)).maxY
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
                var total: CGFloat = 0, count: CGFloat = 0
                for x in Int((view.bounds.width - 40) * scale)..<Int((view.bounds.width - 16) * scale) {
                    // The bar's own 36pt only: the end of the history list sits just above it.
                    for y in max(0, bitmap.pixelsHigh - Int(36 * scale))..<bitmap.pixelsHigh {
                        guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.8,
                              min(c.redComponent, c.greenComponent, c.blueComponent) < 0.65 else { continue }
                        total += CGFloat(y) / scale; count += 1
                    }
                }
                let clockFromBottom = count > 0 ? view.bounds.height - total / count : -1
                let delta = frame.height - previousHeight
                if abs(delta) > 0.5 {
                    let d: CGFloat = delta > 0 ? 1 : -1
                    if direction != 0 && d != direction { reversals += 1 }
                    direction = d
                }
                previousHeight = frame.height
                if let firstEditor { maxEditorShift = max(maxEditorShift, abs(editorTop - firstEditor)) }
                if let firstEditor, abs(editorTop - firstEditor) > 1 { editorMoves += 1 }
                if firstEditor == nil { firstEditor = editorTop }
                if clockFromBottom > 0 {
                    if let firstClock { maxClockShift = max(maxClockShift, abs(clockFromBottom - firstClock)) }
                    if let firstClock, abs(clockFromBottom - firstClock) > 1.5 { barMoves += 1 }
                    if firstClock == nil { firstClock = clockFromBottom }
                }
                let ms = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                trace += "\(pass),\(sample),\(ms),\(frame.height),\(frame.maxY),\(editorTop),\(clockFromBottom)\n"
            }
        }
        try trace.write(toFile: "/tmp/tusi-history-toggle-trace.csv", atomically: true, encoding: .utf8)
        print("HISTORY_TRACE reversals=\(reversals) editorMoves=\(editorMoves) barMoves=\(barMoves) maxEditorShift=\(maxEditorShift) maxClockShift=\(maxClockShift)")
        XCTAssertEqual(reversals, 0, "The window height must not reverse")
        XCTAssertLessThanOrEqual(maxEditorShift, 1, "The input must not move while history opens or closes")
        XCTAssertLessThanOrEqual(maxClockShift, 2, "The bottom bar must ride the window's bottom edge")
    }

    /// Renders the panel's characteristic states for visual review: a result with two
    /// versions while pinned, and history spanning two days.
    func testShowcaseStatesRender() async throws {
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let records = [
            TranslationEngine.Record(id: UUID(), input: "或许你每天可以填一下这份表格，为了 Mitchelle。",
                                     output: "Perhaps you could fill out this form every day, for Mitchelle.",
                                     sourceLabel: "中", source: .chinese, target: .english, tone: .standard, timestamp: now),
            TranslationEngine.Record(id: UUID(), input: "真的吗，你们的回答好官方。",
                                     output: "Really? Your answers sound so official.",
                                     sourceLabel: "中", source: .chinese, target: .english, tone: .casual, timestamp: now.addingTimeInterval(-600)),
            TranslationEngine.Record(id: UUID(), input: "得益于全新的架构，这次更新带来了显著的性能提升。",
                                     output: "Thanks to the brand-new architecture, this update delivers a significant performance boost.",
                                     sourceLabel: "中", source: .chinese, target: .english, tone: .formal, timestamp: yesterday),
        ]
        let data = try JSONEncoder().encode(records)
        for dark in [false, true] {
            for scene in ["result", "history"] {
                let settings = SettingsStore(preview: true)
                settings.autoCopy = false
                settings.soundEnabled = false
                settings.profiles[0] = APIProfile(baseURL: "https://api.deepseek.com", apiKey: "k", model: "deepseek-chat")
                settings.profiles[2] = APIProfile(baseURL: "http://127.0.0.1:11434/v1", model: "qwen2.5:7b")
                let engine = TranslationEngine(settings: settings, storage: TranslationStorage(
                    read: { $0.lastPathComponent == "history.json" ? data : nil }, write: { _, _ in }))
                let state = PanelState()
                state.panelWidth = 470
                state.availableHeight = 760
                if scene == "result" {
                    state.pinned = true
                    let local = TranslationEngine.ResultVersion(
                        text: "Maybe you could fill in this form every day, for Mitchelle.",
                        slot: SettingsStore.localProfileIndex, tier: .local,
                        languageMismatch: false, capped: false, afterFailover: false)
                    let online = TranslationEngine.ResultVersion(
                        text: "Perhaps you could fill out this form every day, for Mitchelle.",
                        slot: 0, tier: .online, languageMismatch: false, capped: false, afterFailover: false,
                        host: "api.deepseek.com", model: "deepseek-chat")
                    engine.debugPreview(input: "或许你每天可以填一下这份表格，为了 Mitchelle。",
                                        output: online.text, versions: [local, online])
                } else {
                    state.showHistory = true
                }
                let root = RootView(onHeightChange: { _ in })
                    .environmentObject(settings).environmentObject(engine).environmentObject(state)
                    .environmentObject(UpdateChecker(preview: true))
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .transaction { $0.animation = nil }
                    .background(dark ? Color(white: 0.16) : Color(white: 0.96))
                let host = NSHostingView(rootView: root)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 400),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                host.frame = window.contentLayoutRect
                for _ in 0..<4 {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(40))
                }
                let size = host.fittingSize
                window.setContentSize(NSSize(width: 470, height: size.height))
                host.frame = NSRect(x: 0, y: 0, width: 470, height: size.height)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(40))
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(png.count, 1000)
                try png.write(to: URL(fileURLWithPath: "/tmp/tusi-showcase-\(scene)-\(dark ? "dark" : "light").png"))
                window.close()
            }
        }
    }

    func testProgrammaticPanelMovesDoNotPin() async throws {
        let settings = SettingsStore(preview: true)
        let engine = TranslationEngine(settings: settings, storage: TranslationStorage(read: { _ in nil }, write: { _, _ in }))
        engine.debugPreview(input: "第一行", output: String(repeating: "A line of translation.\n", count: 6))
        let state = PanelState()
        let app = NSApplication.shared
        let existing = Set(app.windows.map(ObjectIdentifier.init))
        let controller = PanelController(engine: engine, settings: settings, panelState: state,
                                         updateChecker: UpdateChecker(preview: true), statusItem: nil)
        let window = try XCTUnwrap(app.windows.first { !existing.contains(ObjectIdentifier($0)) && $0 is FloatingPanel })
        window.alphaValue = 0
        window.orderBack(nil)
        defer { controller.hide() }
        window.setFrameOrigin(NSPoint(x: 240, y: 260))
        engine.input = ""
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(state.pinned, "Only a hand drag pins the panel")
    }

}
