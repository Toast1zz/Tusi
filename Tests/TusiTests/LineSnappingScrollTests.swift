import AppKit
import XCTest
@testable import Tusi

@MainActor
final class LineSnappingScrollTests: XCTestCase {
    private func fixture(usingTextKit2: Bool) -> (NSWindow, NSTextView, NSScrollView, LineSnappingScroll.Coordinator) {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 220, height: 60),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 60))
        window.contentView = root
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 21))
        let text = NSTextView(usingTextLayoutManager: usingTextKit2)
        text.frame = NSRect(x: 0, y: 0, width: 200, height: 400)
        text.font = .systemFont(ofSize: 15)
        text.string = "first\nsecond"
        scroll.documentView = text
        root.addSubview(scroll)
        let anchor = NSView(frame: NSRect(x: 5, y: 5, width: 0, height: 0))
        root.addSubview(anchor)
        let coordinator = LineSnappingScroll.Coordinator(step: 21)
        coordinator.growingEditorLimit = 126
        coordinator.attach(near: anchor)
        return (window, text, scroll, coordinator)
    }

    func testGrowingEditorPreservesTextKit2WhileCorrectingScroll() throws {
        let (window, text, scroll, coordinator) = fixture(usingTextKit2: true)
        defer { coordinator.detach(); window.close() }
        let layout = try XCTUnwrap(text.textLayoutManager)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 7))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        XCTAssertTrue(text.textLayoutManager === layout, "Measuring must not switch the editor to TextKit 1")
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 0.5)
    }

    func testCompositionSurvivesBoundsChangesAndLineSnapping() throws {
        for modern in [true, false] {
            let (window, text, scroll, coordinator) = fixture(usingTextKit2: modern)
            defer { coordinator.detach(); window.close() }
            text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
            text.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
            let marked = text.markedRange()
            let selection = text.selectedRange()
            let draft = text.string
            XCTAssertTrue(text.hasMarkedText())
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 7))
            let origin = scroll.contentView.bounds.origin
            XCTAssertGreaterThan(origin.y, 0.5, "Exercise an actual scrolled viewport")
            NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
            XCTAssertTrue(text.hasMarkedText(), "Scrolling must not commit unfinished pinyin")
            XCTAssertEqual(text.markedRange(), marked)
            XCTAssertEqual(text.selectedRange(), selection)
            XCTAssertEqual(text.string, draft)
            XCTAssertEqual(scroll.contentView.bounds.origin, origin, "Leave composition caret tracking to AppKit")
            XCTAssertEqual(text.textLayoutManager != nil, modern)

            text.insertText("中", replacementRange: marked)
            XCTAssertFalse(text.hasMarkedText())
            XCTAssertTrue(text.string.hasSuffix("中"))
            text.setFrameSize(NSSize(width: 200, height: 400))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 7))
            NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 0.5,
                           "Normal short-document correction must resume after committing")
        }
    }
}
