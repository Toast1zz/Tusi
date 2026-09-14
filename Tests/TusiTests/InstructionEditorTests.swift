import AppKit
import SwiftUI
import XCTest
@testable import Tusi

@MainActor
final class InstructionEditorTests: XCTestCase {
    func testHeightIncludesWrappingTrailingNewlineAndCap() {
        let short = InstructionEditor.height(for: "One", width: 400)
        let three = InstructionEditor.height(for: "One\nTwo\n", width: 400)
        XCTAssertGreaterThan(three, short)
        XCTAssertGreaterThan(InstructionEditor.height(for: String(repeating: "中文", count: 30), width: 180), short)
        XCTAssertEqual(InstructionEditor.height(for: String(repeating: "line\n", count: 30), width: 400), short * 3)
    }

    func testSettingsEditorAcceptsNewlinesGrowsWindowAndScrollsAtCap() async throws {
        let settings = SettingsStore(preview: true)
        settings.extraInstruction = "Keep names"
        let state = PanelState()
        state.showSettings = true
        state.settingsSection = .translation
        let engine = TranslationEngine(settings: settings, storage: TranslationStorage(read: { _ in nil }, write: { _, _ in }))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 470, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = RootView(onHeightChange: { height in
            var frame = window.frame
            frame.origin.y = frame.maxY - height
            frame.size.height = height
            window.setFrame(frame, display: true)
        }).environmentObject(settings).environmentObject(state).environmentObject(engine)
            .environmentObject(UpdateChecker(preview: true))
            .environment(\.colorScheme, .light)
            .background(Color.white)
        let host = NSHostingView(rootView: root)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        window.alphaValue = 0
        window.orderBack(nil)
        defer { window.close() }
        func settle() async throws {
            for _ in 0..<25 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func findEditor(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.isEditable { return text }
            return view.subviews.compactMap(findEditor).first
        }
        func snapshot(_ name: String) throws {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/tmp/tusi-instruction-\(name).png"))
        }
        try await settle()
        let editor = try XCTUnwrap(findEditor(host))
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        let layout = try XCTUnwrap(editor.textLayoutManager)
        window.makeFirstResponder(editor)
        let initial = window.frame.height
        try snapshot("short")
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertNewline(nil)
        editor.insertText("Keep formatting", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.insertNewline(nil)
        try await settle()
        XCTAssertEqual(settings.extraInstruction, "Keep names\nKeep formatting\n")
        XCTAssertGreaterThan(window.frame.height, initial + 5)
        XCTAssertTrue(state.showSettings)
        XCTAssertEqual(engine.state, .idle)
        XCTAssertTrue(editor.textLayoutManager === layout)
        try snapshot("multiline")

        editor.insertText(String(repeating: "More instructions\n", count: 20),
                          replacementRange: NSRange(location: NSNotFound, length: 0))
        try await settle()
        let capped = scroll.frame.height
        XCTAssertLessThanOrEqual(window.frame.height, SettingsView.maximumHeight(availableHeight: state.availableHeight))
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0)
        try snapshot("long")
        editor.insertText(String(repeating: "More\n", count: 20),
                          replacementRange: NSRange(location: NSNotFound, length: 0))
        try await settle()
        XCTAssertEqual(scroll.frame.height, capped, accuracy: 1)

        editor.insertText("Short", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await settle()
        XCTAssertEqual(window.frame.height, initial, accuracy: 1)
        editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        try await settle()
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertTrue(editor.textLayoutManager === layout)
    }
}
