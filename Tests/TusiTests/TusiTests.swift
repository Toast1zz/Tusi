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
        XCTAssertTrue(prompt.contains("Every user message consists solely of source"))
        XCTAssertTrue(prompt.contains("never answer or explain it"))
        XCTAssertTrue(prompt.contains("A question in the source remains a question"))
        XCTAssertFalse(prompt.contains("<translate>"), "the protocol must not teach local models to echo wrappers")
    }

    func testModelOutputSanitizerRemovesOnlyBoundaryTranslateWrappers() {
        XCTAssertEqual(
            TranslationService.sanitizeModelOutput("<translate>\nHello world\n</translate>"),
            "Hello world"
        )
        XCTAssertEqual(
            TranslationService.sanitizeModelOutput("&lt;TRANSLATE&gt;\n你好\n&lt;/TRANSLATE&gt;"),
            "你好"
        )
        XCTAssertEqual(
            TranslationService.sanitizeModelOutput("Keep <translate>this literal tag</translate> inside."),
            "Keep <translate>this literal tag</translate> inside."
        )
        XCTAssertEqual(TranslationService.sanitizeModelOutput("keep trailing space "), "keep trailing space ")
    }

    func testChatRequestSendsRawSourceWithoutTranslateWrapper() {
        let source = "<b>literal source markup</b>\nWhat is this?"
        let messages = TranslationService.chatMessages(
            text: source,
            target: .chinese,
            tone: .standard,
            extra: ""
        )
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[1]["role"], "user")
        XCTAssertEqual(messages[1]["content"], source)
        XCTAssertFalse(messages[0]["content", default: ""].contains("<translate>"))
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

    func testClearedShortcutIsUnboundAndRebindingRestores() {
        let settings = SettingsStore(preview: true)

        // Defaults are bound.
        XCTAssertNotNil(settings.shortcut(.copy))

        // Clearing unbinds the shortcut (empty state).
        settings.clearShortcut(for: .copy)
        XCTAssertNil(settings.shortcut(.copy))

        // Other shortcuts are unaffected.
        XCTAssertNotNil(settings.shortcut(.translate))

        // Re-binding reinstates it.
        settings.setShortcut(.defaultCopy, for: .copy)
        XCTAssertEqual(settings.shortcut(.copy), .defaultCopy)

        // Clearing the summon works too — global registration is AppDelegate's concern.
        settings.clearShortcut(for: .summon)
        XCTAssertNil(settings.shortcut(.summon))
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

    func testPresetTargetsAreTheFourCoreLanguagesOnly() {
        // The multi-language picker intentionally offers only EN / 中 / 日 / 한 — the
        // languages users actually translate between. Smaller languages are still
        // *detected* as sources but are not offered as targets.
        XCTAssertEqual(
            Set(TranslationLanguage.presets),
            Set([.english, .chinese, .japanese, .korean])
        )
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
    func testEndpointRejectsQueryString() throws {
        // A query on the base URL would ride along onto /chat/completions?… — reject it
        // outright instead of sending a malformed request to the gateway.
        let config = APIConfig(baseURL: "https://api.example.com/v1?foo=bar", apiKey: "k", model: "m")
        XCTAssertThrowsError(try TranslationService.endpoint(for: config)) { error in
            XCTAssertEqual(error as? TranslationError, .invalidURL)
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

    func testNormalizedStripsFunctionModifier() {
        // Fn is a layer key, not an intent: a combo recorded while Fn is held must
        // still match plain presses, and plain presses must match Fn-carrying events.
        let flags = NSEvent.ModifierFlags([.command, .function])
        XCTAssertEqual(KeyCombo.normalized(flags).rawValue, NSEvent.ModifierFlags.command.rawValue)
    }

    func testVersionBuildMetadataIsIgnored() {
        // Semver: "+build" metadata never participates in ordering.
        XCTAssertFalse(UpdateChecker.isNewer("1.6.0+build.5", than: "1.6.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.6.0", than: "1.6.0+build.5"))
        XCTAssertTrue(UpdateChecker.isNewer("1.6.1+build.9", than: "1.6.0+build.5"))
        XCTAssertTrue(UpdateChecker.isNewer("1.6.0-beta.1+meta", than: "1.6.0-beta.0"))
    }

    func testEndpointDefaultsHTTPForLoopbackAndHTTPSForRemote() throws {
        // Scheme-less local hosts must default to http (Ollama-style), remote to https.
        let local = APIConfig(baseURL: "localhost:11434/v1", apiKey: "k", model: "m")
        XCTAssertEqual(
            try TranslationService.endpoint(for: local).absoluteString,
            "http://localhost:11434/v1/chat/completions"
        )
        let remote = APIConfig(baseURL: "api.example.com/v1", apiKey: "k", model: "m")
        XCTAssertEqual(
            try TranslationService.endpoint(for: remote).absoluteString,
            "https://api.example.com/v1/chat/completions"
        )
    }

    // MARK: - Local endpoints don't require an API key

    func testLocalEndpointIsUsableWithoutAPIKey() {
        // Loopback servers (Ollama, LM Studio, llama.cpp-server) take no key.
        let local = APIConfig(baseURL: "http://localhost:11434/v1", apiKey: "", model: "model")
        XCTAssertFalse(local.requiresAuth)
        XCTAssertTrue(local.isUsable)

        // The whole 127.0.0.0/8 range is loopback too.
        let loopback = APIConfig(baseURL: "http://127.0.0.2:11434/v1", apiKey: "", model: "model")
        XCTAssertFalse(loopback.requiresAuth)
        XCTAssertTrue(loopback.isUsable)
    }

    func testRemoteEndpointStillRequiresAPIKey() {
        // A remote endpoint without a key is not usable and must require auth.
        let remote = APIConfig(baseURL: "https://api.deepseek.com/v1", apiKey: "", model: "model")
        XCTAssertTrue(remote.requiresAuth)
        XCTAssertFalse(remote.isUsable)
    }

    func testLocalStreamSendsNoAuthorizationHeader() async throws {
        // Local endpoints must not carry a Bearer token (many local servers reject or
        // ignore one they never asked for).
        let sse = """
        data: {"choices":[{"delta":{"content":"你好"}}]}

        data: [DONE]

        """
        var capturedHeader: String? = nil
        MockURLProtocol.handler = { request in
            capturedHeader = request.value(forHTTPHeaderField: "Authorization")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(sse.utf8))
        }
        let mockConfig = URLSessionConfiguration.ephemeral
        mockConfig.protocolClasses = [MockURLProtocol.self]
        TranslationService.sessionOverride = URLSession(configuration: mockConfig)
        defer {
            TranslationService.sessionOverride = nil
            MockURLProtocol.handler = nil
        }

        let local = APIConfig(baseURL: "http://localhost:11434/v1", apiKey: "", model: "model")
        var pieces: [String] = []
        for try await piece in TranslationService.stream(text: "hi", target: .chinese, tone: .standard, extra: "", config: local) {
            pieces.append(piece)
        }
        XCTAssertEqual(pieces, ["你好"])
        XCTAssertNil(capturedHeader, "local endpoint must not send an Authorization header")
    }

    func testLocalTranslationWithoutKeySucceeds() async throws {
        // End-to-end through the engine: a loopback profile with no key must translate
        // (isUsable, no emptyKey thrown, no auth header sent).
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.profiles[0] = APIProfile(baseURL: "http://localhost:11434/v1", apiKey: "", model: "model")
        let engine = TranslationEngine(settings: settings) { _, _, _, _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield("你好")
                continuation.finish()
            }
        }
        engine.input = "hi"
        engine.translate()
        try await waitUntilDone(engine)
        XCTAssertEqual(engine.output, "你好")
    }

    func testTranslateWithoutUsableProfileShowsSetupMessage() {
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        let engine = TranslationEngine(settings: settings)
        engine.input = "hi"
        engine.translate()
        if case .failed(let message) = engine.state {
            XCTAssertTrue(message.contains("还没有配置可用的 API 服务"), message)
        } else {
            XCTFail("expected failed state, got \(engine.state)")
        }
    }

    func testFailoverMessageSkipsUntriedBackup() async throws {
        // Primary yields partial output then dies: backup must NOT be tried (splicing
        // two translations is worse), and the message must not claim it was.
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.profiles[0] = APIProfile(baseURL: "https://example.com/v1", apiKey: "k1", model: "m1")
        settings.profiles[1] = APIProfile(baseURL: "https://example.com/v1", apiKey: "k2", model: "m2")

        var calls = 0
        let engine = TranslationEngine(settings: settings) { _, _, _, _, _ in
            calls += 1
            return AsyncThrowingStream { continuation in
                continuation.yield("partial")
                // The connection dies *after* the partial data landed — the realistic
                // mid-stream failure. (A synchronous yield-then-throw would drop the
                // yielded value; AsyncThrowingStream delivers the error instead.)
                Task {
                    try? await Task.sleep(for: .milliseconds(50))
                    continuation.finish(throwing: TranslationError.http(500, "boom"))
                }
            }
        }
        engine.input = "hi"
        engine.translate()
        try await waitUntilFailed(engine)
        XCTAssertEqual(calls, 1)
        if case .failed(let message) = engine.state {
            XCTAssertFalse(message.contains("备用"), message)
        } else {
            XCTFail("expected failed state")
        }
    }

    func testFailoverMessageMentionsBackupWhenTried() async throws {
        // Primary fails cleanly before any output → backup is tried → both failed.
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.profiles[0] = APIProfile(baseURL: "https://example.com/v1", apiKey: "k1", model: "m1")
        settings.profiles[1] = APIProfile(baseURL: "https://example.com/v1", apiKey: "k2", model: "m2")

        var calls = 0
        let engine = TranslationEngine(settings: settings) { _, _, _, _, _ in
            calls += 1
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: TranslationError.http(500, "boom"))
            }
        }
        engine.input = "hi"
        engine.translate()
        try await waitUntilFailed(engine)
        // Transient 500 is retried once per provider before failing over, so the
        // primary is attempted twice and the backup twice: 4 calls total.
        XCTAssertEqual(calls, 4)
        if case .failed(let message) = engine.state {
            XCTAssertTrue(message.contains("备用"), message)
        } else {
            XCTFail("expected failed state")
        }
    }

    func testTransientFailureRetriesSameProviderOnceThenSucceeds() async throws {
        // A transient 500 on the first attempt must be retried on the same provider;
        // the second attempt succeeds, so no backup is tried and the result is complete.
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.profiles[0] = APIProfile(baseURL: "https://example.com/v1", apiKey: "k1", model: "m1")
        settings.profiles[1] = APIProfile(baseURL: "https://example.com/v1", apiKey: "k2", model: "m2")

        var calls = 0
        let engine = TranslationEngine(settings: settings) { _, _, _, _, _ in
            calls += 1
            return AsyncThrowingStream { continuation in
                if calls == 1 {
                    continuation.finish(throwing: TranslationError.http(500, "boom"))
                } else {
                    continuation.yield("你好")
                    continuation.finish()
                }
            }
        }
        engine.input = "hi"
        engine.translate()
        try await waitUntilDone(engine)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(engine.output, "你好")
        XCTAssertFalse(engine.interrupted)
    }

    func testNonTransientFailureDoesNotRetry() async throws {
        // A 401 (bad auth) is deterministic — retrying would just fail again, so the
        // provider is attempted exactly once.
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.profiles[0] = APIProfile(baseURL: "https://example.com/v1", apiKey: "k1", model: "m1")

        var calls = 0
        let engine = TranslationEngine(settings: settings) { _, _, _, _, _ in
            calls += 1
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: TranslationError.http(401, "bad key"))
            }
        }
        engine.input = "hi"
        engine.translate()
        try await waitUntilFailed(engine)
        XCTAssertEqual(calls, 1)
        if case .failed(let message) = engine.state {
            XCTAssertTrue(message.contains("401"), message)
        } else {
            XCTFail("expected failed state")
        }
    }

    func testMultiLanguageTargetChangeRestartsTranslationWhileTranslating() async throws {
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.profiles[0] = APIProfile(baseURL: "https://example.com/v1", apiKey: "k", model: "m")
        settings.multiLanguageMode = true

        var requestedTargets: [TranslationLanguage] = []
        var continuations: [AsyncThrowingStream<String, Error>.Continuation] = []
        let engine = TranslationEngine(settings: settings) { _, target, _, _, _ in
            requestedTargets.append(target)
            return AsyncThrowingStream { continuation in
                continuations.append(continuation)
            }
        }
        engine.input = "hello world"  // English input → target Chinese
        engine.translate()
        XCTAssertTrue(engine.isTranslating)

        for _ in 0..<100 where requestedTargets.count < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(requestedTargets, [.chinese])

        engine.setTarget(.japanese)
        XCTAssertEqual(engine.target, .japanese)
        XCTAssertTrue(engine.isTranslating)

        for _ in 0..<100 where requestedTargets.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(requestedTargets, [.chinese, .japanese])
        XCTAssertEqual(continuations.count, 2)

        // The old stream is left open to prove that the new request, not its late
        // completion, owns the result shown by the engine.
        continuations[1].yield("日本語")
        continuations[1].finish()
        try await waitUntilDone(engine)
        XCTAssertEqual(engine.output, "日本語")
    }

    func testMultiLanguageTargetSelectableWithEmptyInput() {
        // The language grid in Settings is visible before anything is typed, so choosing
        // a target with an empty input must register — it must not be silently dropped.
        // Regression: setTarget used to return early on empty input, so "日本語" could
        // never be selected until the user typed something; and once empty input was
        // allowed, selecting 中文 was still vetoed because the empty-input source
        // placeholder (Chinese) tripped the "translate X into X" auto-flip.
        let settings = SettingsStore(preview: true)
        settings.multiLanguageMode = true
        let engine = TranslationEngine(settings: settings)
        XCTAssertTrue(engine.input.isEmpty)

        engine.setTarget(.chinese)
        XCTAssertEqual(engine.target, .chinese, "中文 must be selectable with empty input")

        engine.setTarget(.japanese)
        XCTAssertEqual(engine.target, .japanese)

        // In simple (non-multi) mode an explicit target is still ignored.
        settings.multiLanguageMode = false
        engine.setTarget(.english)
        XCTAssertEqual(engine.target, .japanese, "ignored outside multi-language mode")
    }

    func testMultiLanguageTargetStillAutoFlippedWithRealInputForNoop() {
        // With actual input, choosing a target identical to the detected source is
        // still an invalid "translate X into X" and should be corrected to the other
        // side — the empty-input exception must not leak into real translations.
        let settings = SettingsStore(preview: true)
        settings.multiLanguageMode = true
        let engine = TranslationEngine(settings: settings)
        engine.input = "这是中文字符串"   // detected source: Chinese
        XCTAssertEqual(engine.source, .chinese)
        engine.setTarget(.chinese)       // no-op target → should flip away from Chinese
        XCTAssertNotEqual(engine.target, .chinese)
    }

    func testMultiLanguageModeChangeRestartsTranslationWhileTranslating() async throws {
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.profiles[0] = APIProfile(baseURL: "https://example.com/v1", apiKey: "k", model: "m")
        var requestedTargets: [TranslationLanguage] = []
        var continuations: [AsyncThrowingStream<String, Error>.Continuation] = []
        let engine = TranslationEngine(settings: settings) { _, target, _, _, _ in
            requestedTargets.append(target)
            return AsyncThrowingStream { continuation in
                continuations.append(continuation)
            }
        }
        engine.input = "hello world"
        engine.translate()
        XCTAssertTrue(engine.isTranslating)

        for _ in 0..<100 where requestedTargets.count < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(requestedTargets, [.chinese])

        settings.multiLanguageMode = true
        engine.multiLanguageModeDidChange()
        XCTAssertEqual(engine.target, .chinese)
        XCTAssertTrue(engine.isTranslating)

        for _ in 0..<100 where requestedTargets.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(requestedTargets, [.chinese, .chinese])
        XCTAssertEqual(continuations.count, 2)

        continuations[1].yield("中文")
        continuations[1].finish()
        try await waitUntilDone(engine)
        XCTAssertEqual(engine.output, "中文")
    }

    func testHistoryLoadToleratesCorruptRecord() throws {
        let url = TranslationEngine.historyURL(preview: true)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let good = """
        {"id":"00000000-0000-0000-0000-000000000001","input":"a","output":"b","sourceLabel":"中","source":{"displayName":"中文","apiName":"x","symbol":"中"},"target":{"displayName":"English","apiName":"y","symbol":"EN"},"tone":"standard","timestamp":1000}
        """
        // Missing required fields (id/timestamp/tone) — must not sink the good record.
        let bad = "{\"input\":\"broken\"}"
        try "[\(good),\(bad)]".write(to: url, atomically: true, encoding: .utf8)

        let settings = SettingsStore(preview: true)
        let engine = TranslationEngine(settings: settings)
        XCTAssertEqual(engine.history.count, 1)
        XCTAssertEqual(engine.history[0].input, "a")
    }

    func testLongResultIsTruncatedInHistoryButNotInPanel() async throws {
        // Bounds the worst case for the synchronous history write (50 records at the
        // input/output ceilings would be ~10MB of JSON) by capping each field on
        // archive — the current panel's full input/output must be unaffected.
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.profiles[0] = APIProfile(baseURL: "https://example.com/v1", apiKey: "k", model: "m")
        let longInput = String(repeating: "a", count: 5_000)
        let longOutput = String(repeating: "b", count: 5_000)
        let engine = TranslationEngine(settings: settings) { _, _, _, _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield(longOutput)
                continuation.finish()
            }
        }
        engine.input = longInput
        engine.translate()
        try await waitUntilDone(engine)

        XCTAssertEqual(engine.input.count, 5_000, "the panel's own input must not be truncated")
        XCTAssertEqual(engine.output.count, 5_000, "the panel's own output must not be truncated")

        let record = try XCTUnwrap(engine.history.first)
        XCTAssertEqual(record.input.count, 4_000)
        XCTAssertEqual(record.output.count, 4_000)
    }

    func testClearHistoryPersistsEmptyFile() async throws {
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.profiles[0] = APIProfile(baseURL: "https://example.com/v1", apiKey: "k", model: "m")
        let engine = TranslationEngine(settings: settings) { _, _, _, _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield("result")
                continuation.finish()
            }
        }
        engine.input = "hi"
        engine.translate()
        try await waitUntilDone(engine)
        XCTAssertEqual(engine.history.count, 1)

        engine.clearHistory()
        // Synchronous save: the cleared state is already on disk — no detached task
        // can resurrect the old records later.
        let data = try Data(contentsOf: TranslationEngine.historyURL(preview: true))
        let decoded = try JSONDecoder().decode([TranslationEngine.Record].self, from: data)
        XCTAssertTrue(decoded.isEmpty)
    }

    private func waitUntilFailed(_ engine: TranslationEngine) async throws {
        for _ in 0..<100 where !isFailed(engine.state) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(isFailed(engine.state))
    }

    private func isFailed(_ state: TranslationEngine.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private func waitUntilDone(_ engine: TranslationEngine) async throws {
        for _ in 0..<100 where engine.state != .done {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(engine.state, .done)
    }

    // MARK: - Streaming (mock URLSession)

    func testStreamParsesSSEChunksUntilDone() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"你"}}]}

        data: {"choices":[{"delta":{"content":"好"}}]}

        data: [DONE]

        """
        try await withMockSession(sse: sse) {
            let config = APIConfig(baseURL: "https://example.com/v1", apiKey: "k", model: "m")
            var pieces: [String] = []
            for try await piece in TranslationService.stream(text: "hi", target: .chinese, tone: .standard, extra: "", config: config) {
                pieces.append(piece)
            }
            XCTAssertEqual(pieces, ["你", "好"])
        }
    }

    func testStreamWithoutDoneSentinelThrowsTruncated() async throws {
        // A clean close with content but no [DONE] means the connection ended before
        // the result did — a truncated translation must not pass as complete.
        let sse = """
        data: {"choices":[{"delta":{"content":"你"}}]}

        """
        try await withMockSession(sse: sse) {
            let config = APIConfig(baseURL: "https://example.com/v1", apiKey: "k", model: "m")
            do {
                for try await _ in TranslationService.stream(text: "hi", target: .chinese, tone: .standard, extra: "", config: config) {}
                XCTFail("expected truncatedStream error")
            } catch {
                XCTAssertEqual(error as? TranslationError, .truncatedStream)
            }
        }
    }

    func testStreamCompletesOnFinishReasonWithoutDoneSentinel() async throws {
        // Some OpenAI-compatible gateways close the connection cleanly right after the
        // finishing chunk instead of sending [DONE]. A non-null finish_reason must be
        // accepted as completion on its own — this must NOT throw truncatedStream.
        let sse = """
        data: {"choices":[{"delta":{"content":"你"}}]}

        data: {"choices":[{"delta":{"content":"好"},"finish_reason":"stop"}]}

        """
        try await withMockSession(sse: sse) {
            let config = APIConfig(baseURL: "https://example.com/v1", apiKey: "k", model: "m")
            var pieces: [String] = []
            for try await piece in TranslationService.stream(text: "hi", target: .chinese, tone: .standard, extra: "", config: config) {
                pieces.append(piece)
            }
            XCTAssertEqual(pieces, ["你", "好"])
        }
    }

    func testStreamSurfacesHTTPErrorWithParsedMessage() async throws {
        try await withMockSession(sse: #"{"error":{"message":"bad key"}}"#, statusCode: 401) {
            let config = APIConfig(baseURL: "https://example.com/v1", apiKey: "k", model: "m")
            do {
                for try await _ in TranslationService.stream(text: "hi", target: .chinese, tone: .standard, extra: "", config: config) {}
                XCTFail("expected http error")
            } catch {
                XCTAssertEqual(error as? TranslationError, .http(401, "bad key"))
            }
        }
    }

    /// Serves `sse` as the body of a mock HTTP response through a URLProtocol-backed
    /// session, runs `body`, and tears the seam down afterwards.
    private func withMockSession(sse: String, statusCode: Int = 200, hangs: Bool = false, body: () async throws -> Void) async throws {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (response, Data(sse.utf8))
        }
        MockURLProtocol.hangsAfterResponse = hangs
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        TranslationService.sessionOverride = URLSession(configuration: config)
        defer {
            TranslationService.sessionOverride = nil
            MockURLProtocol.handler = nil
            MockURLProtocol.hangsAfterResponse = false
        }
        try await body()
    }

    func testStreamFailsAfterFirstTokenTimeout() async throws {
        // A server that accepts the connection but never delivers body data must be
        // failed by the first-token timeout instead of hanging the UI forever.
        let originalTimeout = TranslationService.firstTokenTimeout
        TranslationService.firstTokenTimeout = 0.2  // shorten so the test is fast
        defer { TranslationService.firstTokenTimeout = originalTimeout }

        try await withMockSession(sse: "data: [DONE]\n\n", hangs: true) {
            let config = APIConfig(baseURL: "https://example.com/v1", apiKey: "k", model: "m")
            do {
                for try await _ in TranslationService.stream(text: "hi", target: .chinese, tone: .standard, extra: "", config: config) {}
                XCTFail("expected first-token timeout error")
            } catch {
                guard case .http(let code, _) = error as? TranslationError else {
                    XCTFail("expected TranslationError.http, got \(error)")
                    return
                }
                XCTAssertEqual(code, 0)
            }
        }
    }

    func testStreamWithImmediateDataIgnoresTimeout() async throws {
        // Data arriving before the deadline must not be dropped or duplicated.
        let originalTimeout = TranslationService.firstTokenTimeout
        TranslationService.firstTokenTimeout = 2.0  // generous so the race never fires
        defer { TranslationService.firstTokenTimeout = originalTimeout }

        let sse = """
        data: {"choices":[{"delta":{"content":"你"}}]}

        data: {"choices":[{"delta":{"content":"好"}}]}

        data: [DONE]

        """
        try await withMockSession(sse: sse) {
            let config = APIConfig(baseURL: "https://example.com/v1", apiKey: "k", model: "m")
            var pieces: [String] = []
            for try await piece in TranslationService.stream(text: "hi", target: .chinese, tone: .standard, extra: "", config: config) {
                pieces.append(piece)
            }
            XCTAssertEqual(pieces, ["你", "好"])
        }
    }

    // MARK: - SmartQuotes edges

    func testSmartQuotesUnmatchedBacktickDoesNotSilenceQuotes() {
        // A stray opening backtick without a closer must not leave the rest of the
        // text in code mode — quotes after it still convert.
        XCTAssertEqual(SmartQuotes.apply(to: "He said \"hi\" `oops"), "He said “hi” `oops")
    }

    func testSmartQuotesPairedBackticksPreserveCode() {
        XCTAssertEqual(
            SmartQuotes.apply(to: "`raw \"quotes\"` and \"real\""),
            "`raw \"quotes\"` and “real”"
        )
    }

    func testSmartQuotesFencedBlockPreservesContentUntilCloser() {
        XCTAssertEqual(
            SmartQuotes.apply(to: "```\n\"raw\"\n```\n\"after\""),
            "```\n\"raw\"\n```\n“after”"
        )
    }

    func testSmartQuotesUnclosedFenceDoesNotSilenceQuotes() {
        // An unclosed ``` block is not code: its quotes still convert rather than
        // everything after it going raw.
        XCTAssertEqual(SmartQuotes.apply(to: "```\n\"raw\"\n"), "```\n“raw”\n")
    }

    func testSmartQuotesApostrophesAndElision() {
        XCTAssertEqual(SmartQuotes.apply(to: "Don't stop"), "Don’t stop")
        XCTAssertEqual(SmartQuotes.apply(to: "the '90s"), "the ’90s")
    }

    // MARK: - Streaming coalescing

    func testStreamingCoalescingDoesNotDropContent() async throws {
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.profiles[0] = APIProfile(baseURL: "https://example.com/v1", apiKey: "k", model: "m")
        let chunks = (0..<40).map { "piece-\($0) " }
        let engine = TranslationEngine(settings: settings) { _, _, _, _, _ in
            AsyncThrowingStream { continuation in
                Task {
                    for chunk in chunks {
                        continuation.yield(chunk)
                        try? await Task.sleep(for: .milliseconds(2))
                    }
                    continuation.finish()
                }
            }
        }
        engine.input = "hi"
        engine.translate()
        try await waitUntilDone(engine)
        XCTAssertEqual(engine.output, chunks.joined())
    }

    func testOverlongOutputIsCappedAndFlagged() async throws {
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.profiles[0] = APIProfile(baseURL: "https://example.com/v1", apiKey: "k", model: "m")
        // 10-char substring × the cap ⇒ far past the ceiling; Character-count must
        // match the engine's own cap logic.
        let big = String(repeating: "很长的一段翻译文本，", count: TranslationEngine.maxOutputCharacters)
        let engine = TranslationEngine(settings: settings) { _, _, _, _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield(big)
                continuation.finish()
            }
        }
        engine.input = "hi"
        engine.translate()
        try await waitUntilDone(engine)
        XCTAssertEqual(engine.state, .done)
        XCTAssertEqual(engine.output.count, TranslationEngine.maxOutputCharacters)
        XCTAssertTrue(engine.outputCapped)
    }

    func testShortOutputIsNotCapped() async throws {
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.profiles[0] = APIProfile(baseURL: "https://example.com/v1", apiKey: "k", model: "m")
        let engine = TranslationEngine(settings: settings) { _, _, _, _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield("你好")
                continuation.finish()
            }
        }
        engine.input = "hi"
        engine.translate()
        try await waitUntilDone(engine)
        XCTAssertEqual(engine.output, "你好")
        XCTAssertFalse(engine.outputCapped)
    }

    func testCompletedTranslationDoesNotExposeEchoedTranslateWrapper() async throws {
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.profiles[0] = APIProfile(baseURL: "https://example.com/v1", apiKey: "k", model: "m")
        let engine = TranslationEngine(settings: settings) { _, _, _, _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield("<translate>\nTranslated text\n</translate>")
                continuation.finish()
            }
        }
        engine.input = "source"
        engine.translate()
        try await waitUntilDone(engine)
        XCTAssertEqual(engine.output, "Translated text")
        XCTAssertEqual(engine.history.first?.output, "Translated text")
    }

    // MARK: - Progressive streaming & single atomic final commit

    func testOutputStreamsProgressivelyThenCommitsCleanFinal() async throws {
        // Chunks are mirrored into `output` as they arrive (real streaming), but the
        // stream finishing still re-derives `output` once more from the full buffer
        // with the punctuation/sanitize pass and length cap applied — the same single
        // atomic "final" commit as before, layered on top of progressive display.
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.profiles[0] = APIProfile(baseURL: "https://example.com/v1", apiKey: "k", model: "m")
        var continuations: [AsyncThrowingStream<String, Error>.Continuation] = []
        let engine = TranslationEngine(settings: settings) { _, _, _, _, _ in
            AsyncThrowingStream { continuation in
                continuations.append(continuation)
            }
        }
        engine.input = "hi"
        engine.translate()

        for _ in 0..<100 where continuations.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        // Deliver half the chunks, spaced past the ~33ms flush interval so each one
        // gets its own throttled publish instead of being coalesced into the first.
        continuations[0].yield("你")
        try await Task.sleep(for: .milliseconds(80))
        continuations[0].yield("好")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(engine.state, .translating)
        XCTAssertEqual(engine.output, "你好", "partial output should be visible while streaming")
        XCTAssertFalse(engine.copied)

        continuations[0].yield("世")
        continuations[0].yield("界")
        continuations[0].finish()
        try await waitUntilDone(engine)
        XCTAssertEqual(engine.state, .done)
        XCTAssertEqual(engine.output, "你好世界")
    }

    func testFailedAttemptClearsStreamedPartialOutput() async throws {
        // A provider that streams some content and then fails must not leave that
        // partial text on screen — a failed attempt reads as "still working" or
        // "failed", never as a silently-kept partial answer.
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.profiles[0] = APIProfile(baseURL: "https://example.com/v1", apiKey: "k", model: "m")
        var continuations: [AsyncThrowingStream<String, Error>.Continuation] = []
        let engine = TranslationEngine(settings: settings) { _, _, _, _, _ in
            AsyncThrowingStream { continuation in
                continuations.append(continuation)
            }
        }
        engine.input = "hi"
        engine.translate()

        for _ in 0..<100 where continuations.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        continuations[0].yield("partial")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(engine.output, "partial")

        continuations[0].finish(throwing: TranslationError.truncatedStream)
        try await waitUntilFailed(engine)
        XCTAssertTrue(engine.output.isEmpty, "a failed attempt must clear streamed partial output")
    }

    func testStopWithBufferedContentShowsPartialOnce() async throws {
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.profiles[0] = APIProfile(baseURL: "https://example.com/v1", apiKey: "k", model: "m")
        var continuations: [AsyncThrowingStream<String, Error>.Continuation] = []
        let engine = TranslationEngine(settings: settings) { _, _, _, _, _ in
            AsyncThrowingStream { continuation in
                continuations.append(continuation)
            }
        }
        engine.input = "hi"
        engine.translate()

        for _ in 0..<100 where continuations.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        continuations[0].yield("partial ")
        try await Task.sleep(for: .milliseconds(80))
        continuations[0].yield("content")
        // Let the throttled flush publish the streamed chunks before stopping.
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(engine.state, .translating)
        XCTAssertEqual(engine.output, "partial content")

        engine.cancelTranslation()
        // The buffered content appears once (re-derived via the same sanitize pass),
        // marked incomplete, and is copyable.
        XCTAssertEqual(engine.output, "partial content")
        XCTAssertEqual(engine.interrupted, true)
        XCTAssertEqual(engine.state, .done)

        engine.copyOutput()
        XCTAssertTrue(engine.copied, "stopped partial content must be copyable")
    }

    func testStopWithNoContentReturnsToIdle() async throws {
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.profiles[0] = APIProfile(baseURL: "https://example.com/v1", apiKey: "k", model: "m")
        var continuations: [AsyncThrowingStream<String, Error>.Continuation] = []
        let engine = TranslationEngine(settings: settings) { _, _, _, _, _ in
            AsyncThrowingStream { continuation in
                continuations.append(continuation)
            }
        }
        engine.input = "hi"
        engine.translate()
        for _ in 0..<100 where continuations.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(engine.state, .translating)

        engine.cancelTranslation()
        XCTAssertEqual(engine.state, .idle)
        XCTAssertTrue(engine.output.isEmpty)
        XCTAssertFalse(engine.interrupted)
    }

    func testChunkThenFailureShowsNoPartialAndSkipsBackup() async throws {
        // A provider that produces a token and then fails must not show the partial
        // result, must not fail over to the backup (two spliced translations are worse),
        // and must land in a failed state.
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.profiles[0] = APIProfile(baseURL: "https://example.com/v1", apiKey: "k1", model: "m1")
        settings.profiles[1] = APIProfile(baseURL: "https://example.com/v1", apiKey: "k2", model: "m2")

        var calls = 0
        let engine = TranslationEngine(settings: settings) { _, _, _, _, _ in
            calls += 1
            return AsyncThrowingStream { continuation in
                continuation.yield("partial")
                Task {
                    try? await Task.sleep(for: .milliseconds(50))
                    continuation.finish(throwing: TranslationError.http(500, "boom"))
                }
            }
        }
        engine.input = "hi"
        engine.translate()
        try await waitUntilFailed(engine)
        XCTAssertEqual(calls, 1, "backup must not be tried after a token landed")
        XCTAssertTrue(engine.output.isEmpty, "partial output must be discarded on failure")
        if case .failed(let message) = engine.state {
            XCTAssertFalse(message.contains("备用"), message)
        } else {
            XCTFail("expected failed state")
        }
    }

    // MARK: - Input cap / keychain recovery / metrics

    func testInputIsCappedAtMaximumLength() {
        let settings = SettingsStore(preview: true)
        let engine = TranslationEngine(settings: settings)
        engine.input = String(repeating: "a", count: TranslationEngine.maxInputCharacters + 500)
        XCTAssertEqual(engine.input.count, TranslationEngine.maxInputCharacters)
        // Direction detection still runs on the truncated text without crashing.
        XCTAssertFalse(engine.sourceLabel.isEmpty)
        XCTAssertFalse(engine.target.symbol.isEmpty)
    }

    func testReloadKeysIfMissingIsSafeNoOpInPreview() {
        let settings = SettingsStore(preview: true)
        let engine = TranslationEngine(settings: settings)
        // Preview mode must never touch the Keychain — this is a pure no-op.
        settings.reloadKeysIfMissing()
        XCTAssertTrue(settings.profiles.allSatisfy { $0.apiKey.isEmpty })
        XCTAssertEqual(engine.state, .idle)
    }

    func testLineMetricsAreDerivedAndSane() {
        let metrics = TranslatorView.measureLineMetrics()
        // 15pt system font + 3pt line spacing: first line ≈19pt, step ≈22pt.
        // Loose bounds only — the point is to catch gross regressions, not pin
        // font metrics that can vary slightly across OS versions.
        XCTAssertGreaterThan(metrics.first, 10)
        XCTAssertGreaterThan(metrics.step, 10)
        XCTAssertLessThan(metrics.first, 40)
        XCTAssertLessThan(metrics.step, 40)
        XCTAssertLessThan(metrics.first, metrics.step)
    }
    // MARK: - UpdateChecker (mock session)

    func testUpdateCheckerFailsOnHTTPError() async throws {
        let checker = UpdateChecker(preview: false, session: Self.mockGitHubSession(statusCode: 500, body: "{}"))
        defer { Self.resetMockGitHubSession() }
        checker.check(manual: true)
        try await Self.waitUntilState(of: checker) { state in
            if case .failed = state { return true }
            return false
        }
    }

    func testUpdateCheckerSurfacesAvailableDownload() async throws {
        let body = #"{"tag_name":"v99.0.0","html_url":"https://github.com/Toast1zz/Tusi/releases/tag/v99.0.0"}"#
        let checker = UpdateChecker(preview: false, session: Self.mockGitHubSession(statusCode: 200, body: body))
        defer { Self.resetMockGitHubSession() }
        checker.check(manual: true)
        try await Self.waitUntilState(of: checker) { state in
            if case .available = state { return true }
            return false
        }
        guard case .available(let version, let url) = checker.state else {
            return XCTFail("expected available state, got \(checker.state)")
        }
        XCTAssertEqual(version, "99.0.0")
        XCTAssertEqual(url.absoluteString, "https://github.com/Toast1zz/Tusi/releases/tag/v99.0.0")
        XCTAssertEqual(checker.pendingUpdate?.version, "99.0.0")
    }

    func testUpdateCheckerReportsUpToDate() async throws {
        // "0.0.0" is not newer than the test bundle's current version ("0"), so the
        // release must not be offered and no update must be pending.
        let body = #"{"tag_name":"0.0.0","html_url":"https://github.com/Toast1zz/Tusi/releases/tag/0.0.0"}"#
        let checker = UpdateChecker(preview: false, session: Self.mockGitHubSession(statusCode: 200, body: body))
        defer { Self.resetMockGitHubSession() }
        checker.check(manual: true)
        try await Self.waitUntilState(of: checker) { $0 == .upToDate }
        XCTAssertNil(checker.pendingUpdate)
    }

    private static func mockGitHubSession(statusCode: Int, body: String) -> URLSession {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static func resetMockGitHubSession() {
        MockURLProtocol.handler = nil
    }

    private static func waitUntilState(
        of checker: UpdateChecker,
        condition: @escaping (UpdateChecker.State) -> Bool,
        timeout: TimeInterval = 2
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(checker.state) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(checker.state))
    }
}

/// Serves canned HTTP responses to URLSession, so TranslationService's SSE parsing
/// runs without a network. Installed as the protocol class of a throwaway session.
final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    /// When true, the protocol sends response headers but never delivers body data nor
    /// finishes — simulating a server that accepted the connection but hangs. Used to
    /// test the first-token timeout.
    static var hangsAfterResponse = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if Self.hangsAfterResponse {
                // Hold the connection open without delivering body data. The
                // URLProtocol must not finish, so `bytes.lines` blocks until the
                // consumer's first-token timeout fires.
                return
            }
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
