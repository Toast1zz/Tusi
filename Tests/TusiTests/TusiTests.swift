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
