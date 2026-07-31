import AppKit
import XCTest
@testable import Tusi

@MainActor
final class TusiTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Preview-mode engines share one scratch history file (com.tusi.preview);
        // reset it so no test case reads another case's records.
        try? FileManager.default.removeItem(at: TranslationEngine.historyURL(preview: true))
    }

    func testLanguageDirectionHandlesMixedChineseAndLatin() {
        XCTAssertEqual(LanguageDetector.detect("这个 PR 需要 rebase 一下").source, .chinese)
        XCTAssertEqual(LanguageDetector.detect("This PR needs a rebase").source, .english)
    }

    func testSystemPromptEnforcesTranslationOverAnswering() {
        let prompt = TranslationService.systemPrompt(for: .chinese, tone: .standard)
        // The chat channel defaults to answering user questions; the prompt must
        // explicitly override that or a mixed query gets explained instead of translated.
        XCTAssertTrue(prompt.contains("text between the <translate> markers"))
        XCTAssertTrue(prompt.contains("never answer or explain it"))
        XCTAssertTrue(prompt.contains("A question in the source remains a question"))
    }

    func testStatusItemDoubleClickTogglesOnlyOnce() {
        func event(clickCount: Int) -> NSEvent {
            NSEvent.mouseEvent(
                with: .leftMouseUp, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: clickCount, pressure: 0
            )!
        }
        // First click of a double-click toggles; the second must not (it would flash
        // the panel and trigger the activation hand-back to the previous app).
        XCTAssertTrue(AppDelegate.shouldTogglePanel(for: event(clickCount: 1)))
        XCTAssertFalse(AppDelegate.shouldTogglePanel(for: event(clickCount: 2)))
        XCTAssertFalse(AppDelegate.shouldTogglePanel(for: event(clickCount: 3)))
    }

    func testManualDirectionFlipOverridesDetection() {
        let settings = SettingsStore(preview: true)
        let engine = TranslationEngine(settings: settings)

        // 4 Han characters outweigh the 2 Latin words, so auto-detection says Chinese.
        engine.input = "sequential thinking 什么意思"
        XCTAssertEqual(engine.source, .chinese)
        XCTAssertEqual(engine.target, .english)
        XCTAssertFalse(engine.flipped)

        engine.flipDirection()
        XCTAssertTrue(engine.flipped)
        XCTAssertEqual(engine.source, .english)
        XCTAssertEqual(engine.target, .chinese)

        // Tapping again returns to the detected direction.
        engine.flipDirection()
        XCTAssertFalse(engine.flipped)
        XCTAssertEqual(engine.source, .chinese)
        XCTAssertEqual(engine.target, .english)

        // Any input change drops the manual choice.
        engine.flipDirection()
        XCTAssertTrue(engine.flipped)
        engine.input = "This PR needs a rebase"
        XCTAssertFalse(engine.flipped)
        XCTAssertEqual(engine.source, .english)
        XCTAssertEqual(engine.target, .chinese)
    }

    func testDirectionFlipIsNoOpWithoutInputOrInMultiLanguageMode() {
        let settings = SettingsStore(preview: true)
        let engine = TranslationEngine(settings: settings)

        engine.flipDirection()  // nothing typed yet
        XCTAssertFalse(engine.flipped)

        settings.multiLanguageMode = true
        engine.input = "sequential thinking 什么意思"
        engine.flipDirection()  // explicit target rules in multi-language mode
        XCTAssertFalse(engine.flipped)
        XCTAssertEqual(engine.source, .chinese)
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

    func testVersionComparisonHandlesPrereleases() {
        // A release beats its own prerelease.
        XCTAssertTrue(UpdateChecker.isNewer("1.6.0", than: "1.6.0-beta.1"))
        XCTAssertFalse(UpdateChecker.isNewer("1.6.0-beta.1", than: "1.6.0"))
        // Prerelease segments compare numerically, then lexically.
        XCTAssertTrue(UpdateChecker.isNewer("1.6.0-beta.2", than: "1.6.0-beta.1"))
        XCTAssertTrue(UpdateChecker.isNewer("1.6.0-beta.10", than: "1.6.0-beta.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.6.0-alpha.9", than: "1.6.0-beta.1"))
        // A prerelease of a newer minor beats the current release.
        XCTAssertTrue(UpdateChecker.isNewer("v1.7.0-beta.1", than: "1.6.0"))
    }

    func testSetTargetOnlyWorksInMultiLanguageMode() {
        let settings = SettingsStore(preview: true)
        let engine = TranslationEngine(settings: settings)

        engine.input = "hello world"
        engine.setTarget(.japanese)  // simple mode: explicit targets are ignored
        XCTAssertEqual(engine.target, .chinese)

        settings.multiLanguageMode = true
        engine.setTarget(.japanese)
        XCTAssertEqual(engine.target, .japanese)
    }

    func testConversationContextOrderIsUserThenAssistant() async throws {
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.contextTurns = 1
        settings.profiles[0] = APIProfile(
            baseURL: "https://example.com/v1",
            apiKey: "test-key",
            model: "test-model"
        )

        var captured: [[TranslationEngine.ContextMessage]] = []
        let engine = TranslationEngine(settings: settings) { _, _, _, _, _, context in
            captured.append(context)
            return AsyncThrowingStream { continuation in
                continuation.yield("译文")
                continuation.finish()
            }
        }

        engine.input = "第一句"
        engine.translate()
        try await waitUntilDone(engine)
        engine.input = "第二句"
        engine.translate()
        try await waitUntilDone(engine)

        XCTAssertEqual(captured.count, 2)
        // The second request carries the first turn as context, newest-first:
        // the user message must precede the assistant reply.
        XCTAssertEqual(captured[1].map(\.role), ["user", "assistant"])
        XCTAssertEqual(captured[1].map(\.content), ["第一句", "译文"])
    }

    func testLoopback127RangeAllowsHTTP() throws {
        let config = APIConfig(baseURL: "http://127.0.0.2:11434/v1", apiKey: "key", model: "model")
        XCTAssertEqual(
            try TranslationService.endpoint(for: config).absoluteString,
            "http://127.0.0.2:11434/v1/chat/completions"
        )

        let remote = APIConfig(baseURL: "http://10.0.0.1/v1", apiKey: "key", model: "model")
        XCTAssertThrowsError(try TranslationService.endpoint(for: remote)) { error in
            XCTAssertEqual(error as? TranslationError, .insecureURL)
        }
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
        let engine = TranslationEngine(settings: settings) { _, _, _, _, _, _ in
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
