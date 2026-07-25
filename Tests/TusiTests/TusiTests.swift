import AppKit
import XCTest
@testable import Tusi

@MainActor
final class TusiTests: XCTestCase {
    func testLanguageDirectionHandlesMixedChineseAndLatin() {
        XCTAssertEqual(LanguageDetector.detect("这个 PR 需要 rebase 一下").target, .english)
        XCTAssertEqual(LanguageDetector.detect("This PR needs a rebase").target, .chinese)
    }

    func testSmartQuotesLeaveCodeSpansUntouched() {
        let input = "He said \"hello\" and `\"raw\"`."
        XCTAssertEqual(SmartQuotes.apply(to: input), "He said “hello” and `\"raw\"`.")
    }

    func testKeyComboTreatsKeypadReturnAsReturn() {
        let combo = ShortcutAction.translate.defaultCombo
        let eventFlags = NSEvent.ModifierFlags(arrayLiteral: .numericPad)
        XCTAssertTrue(
            combo.matches(
                NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: eventFlags,
                    timestamp: 0,
                    windowNumber: 0,
                    context: nil,
                    characters: "\r",
                    charactersIgnoringModifiers: "\r",
                    isARepeat: false,
                    keyCode: 76
                )!
            )
        )
    }

    func testVersionComparisonUsesSemanticOrdering() {
        XCTAssertTrue(UpdateChecker.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.2", than: "1.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.1.9", than: "1.2"))
    }

    func testEndpointNormalizesBaseAndRejectsRemoteHTTP() throws {
        let config = APIConfig(
            baseURL: "https://api.example.com/v1/chat/completions/",
            apiKey: "key",
            model: "model"
        )
        XCTAssertEqual(
            try TranslationService.endpoint(for: config).absoluteString,
            "https://api.example.com/v1/chat/completions"
        )

        let local = APIConfig(baseURL: "http://127.0.0.1:11434/v1", apiKey: "key", model: "model")
        XCTAssertEqual(
            try TranslationService.endpoint(for: local).absoluteString,
            "http://127.0.0.1:11434/v1/chat/completions"
        )

        let remoteHTTP = APIConfig(baseURL: "http://api.example.com/v1", apiKey: "key", model: "model")
        XCTAssertThrowsError(try TranslationService.endpoint(for: remoteHTTP)) { error in
            XCTAssertEqual(error as? TranslationError, .insecureURL)
        }
    }
    func testCompletedTranslationIsRecordedAndRestorable() async throws {
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.profiles[0] = APIProfile(
            baseURL: "https://example.com/v1",
            apiKey: "test-key",
            model: "test-model"
        )

        var responses = ["First result", "Second result"]
        let engine = TranslationEngine(settings: settings) { _, _, _, _, _ in
            let response = responses.removeFirst()
            return AsyncThrowingStream { continuation in
                continuation.yield(response)
                continuation.finish()
            }
        }

        engine.input = "First input"
        engine.translate()
        try await waitUntilDone(engine)

        XCTAssertEqual(engine.history.count, 1)
        XCTAssertEqual(engine.history[0].input, "First input")
        XCTAssertEqual(engine.history[0].output, "First result")

        engine.input = "Second input"
        engine.translate()
        try await waitUntilDone(engine)

        XCTAssertEqual(engine.history.map(\.input), ["Second input", "First input"])
        let older = engine.history[1]
        engine.restoreHistory(older)
        XCTAssertEqual(engine.input, "First input")
        XCTAssertEqual(engine.output, "First result")
        XCTAssertEqual(engine.state, .done)

        engine.clearHistory()
        XCTAssertTrue(engine.history.isEmpty)
    }

    private func waitUntilDone(_ engine: TranslationEngine) async throws {
        for _ in 0..<100 where engine.state != .done {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(engine.state, .done)
    }
}
