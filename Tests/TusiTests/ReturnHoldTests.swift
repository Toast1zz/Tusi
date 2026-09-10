import AppKit
import XCTest
@testable import Tusi

final class ReturnHoldTests: XCTestCase {
    func testShortPressSubmitsOnReleaseWithoutRetranslation() {
        var hold = ReturnHold()
        hold.begin(keyCode: 36, now: 10)
        XCTAssertFalse(hold.fireIfReady(now: 11.49))
        XCTAssertTrue(hold.release(keyCode: 36))
        XCTAssertNil(hold.keyCode)
        XCTAssertFalse(hold.fireIfReady(now: 20))
    }

    func testLongPressFiresExactlyOnceAndReleaseDoesNotSubmitAgain() {
        var hold = ReturnHold()
        hold.begin(keyCode: 36, now: 10)
        XCTAssertEqual(hold.progress(now: 10.75), 0.5)
        XCTAssertTrue(hold.fireIfReady(now: 11.5))
        hold.begin(keyCode: 36, now: 12)
        XCTAssertFalse(hold.fireIfReady(now: 20))
        XCTAssertFalse(hold.release(keyCode: 36))
        hold.begin(keyCode: 36, now: 21)
        XCTAssertTrue(hold.fireIfReady(now: 22.5))
    }

    func testCancellationLatchesUntilMatchingKeyUp() {
        var hold = ReturnHold()
        hold.begin(keyCode: 76, now: 10)
        hold.cancel()
        XCTAssertFalse(hold.fireIfReady(now: 20))
        XCTAssertFalse(hold.release(keyCode: 36))
        XCTAssertEqual(hold.keyCode, 76)
        XCTAssertFalse(hold.release(keyCode: 76))
        XCTAssertNil(hold.keyCode)
    }

    func testOnlyUnmodifiedMainOrKeypadReturnQualify() {
        XCTAssertTrue(KeyCombo(keyCode: 36, modifiers: 0, display: "").isPlainReturn)
        XCTAssertTrue(KeyCombo(keyCode: 76, modifiers: NSEvent.ModifierFlags.numericPad.rawValue, display: "").isPlainReturn)
        XCTAssertFalse(KeyCombo(keyCode: 36, modifiers: NSEvent.ModifierFlags.command.rawValue, display: "").isPlainReturn)
        XCTAssertFalse(KeyCombo(keyCode: 36, modifiers: NSEvent.ModifierFlags.shift.rawValue, display: "").isPlainReturn)
        XCTAssertFalse(KeyCombo(keyCode: 49, modifiers: 0, display: "").isPlainReturn)
    }
}
