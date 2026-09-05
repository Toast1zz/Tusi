import AppKit
import Combine
import XCTest
@testable import Tusi

@MainActor
final class AuditRegressionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        try? FileManager.default.removeItem(at: TranslationEngine.historyURL(preview: true))
    }

    private func settings(local: Bool = false) -> SettingsStore {
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.soundEnabled = false
        settings.profiles[0] = APIProfile(baseURL: "https://example.com/v1", apiKey: "fake", model: "online", outputProtocolPreference: .plainText)
        if local {
            settings.routeStart = .local
            settings.profiles[2] = APIProfile(baseURL: "http://localhost:11434/v1", model: "local")
        }
        return settings
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Timed out waiting for state")
    }

    private func event(_ object: [String: Any]) throws -> String {
        "data: " + String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n\n"
    }

    private func content(_ text: String) throws -> String {
        try event(["choices": [["delta": ["content": text]]]])
    }

    private func finish(_ reason: String) throws -> String {
        try event(["choices": [["finish_reason": reason]]])
    }

    private var usage: [String: Any] {
        ["choices": [], "usage": ["prompt_tokens": 5, "completion_tokens": 2, "total_tokens": 7]]
    }

    private func withStream(_ sse: String, body: () async throws -> Void) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        TranslationService.sessionOverride = session
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(sse.utf8))
        }
        defer {
            TranslationService.sessionOverride = nil
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }
        try await body()
    }

    private func collect(_ outputProtocol: TranslationOutputProtocol = .plainText) async throws -> String {
        var result = ""
        for try await piece in TranslationService.stream(
            text: "source", target: .english, tone: .standard, extra: "",
            config: APIConfig(baseURL: "https://example.com/v1", apiKey: "fake", model: "m"),
            outputProtocol: outputProtocol
        ) { result += piece }
        return result
    }

    func testUsageTrailerAndHeartbeatPreserveCompleteTranslation() async throws {
        for outputProtocol in [TranslationOutputProtocol.plainText, .strictJSONSchema, .jsonObject] {
            let text = outputProtocol == .plainText ? "Hello" : "{\"translation\":\"Hello\"}"
            let sse = try ": heartbeat\n\n" + content(text) + finish("stop") + event(usage) + "data: [DONE]\n\n"
            try await withStream(sse) {
                let result = try await collect(outputProtocol)
                XCTAssertEqual(result, "Hello")
            }
        }
    }

    func testUsageTrailerDoesNotCompleteUnfinishedStream() async throws {
        let sse = try content("Hello") + event(usage)
        try await withStream(sse) {
            do { _ = try await collect(); XCTFail("Usage is not a finish event") }
            catch { XCTAssertEqual(error as? TranslationError, .truncatedStream) }
        }
    }

    func testForcedToolCompletionAcceptsUsageTrailer() async throws {
        let tool: [String: Any] = ["index": 0, "id": "call-1", "type": "function",
            "function": ["name": "submit_translation", "arguments": "{\"translation\":\"Hello\"}"]]
        let sse = try event(["choices": [["delta": ["tool_calls": [tool]]]]])
            + finish("tool_calls") + event(usage) + "data: [DONE]\n\n"
        try await withStream(sse) {
            let result = try await collect(.forcedToolCall)
            XCTAssertEqual(result, "Hello")
        }
    }

    func testMalformedStreamDoesNotCommitPartialResult() async throws {
        let sse = try content("Partial translation") + "data: {broken}\n\n" + finish("stop") + "data: [DONE]\n\n"
        try await withStream(sse) {
            let engine = TranslationEngine(settings: settings())
            engine.input = "source"
            engine.translate()
            try await wait { if case .failed = engine.state { return true }; return false }
            XCTAssertTrue(engine.output.isEmpty)
            XCTAssertTrue(engine.history.isEmpty)
            XCTAssertTrue(engine.versions.isEmpty)
        }
    }

    func testMalformedEventsCannotHideBehindValidChunks() async throws {
        let invalid = [
            "data: {broken-json}\n\n",
            try event(["choices": []]),
            try event(["choices": [], "usage": [:]]),
            try event(["unexpected": true]),
            try event(["choices": [[:]]]),
        ]
        for event in invalid {
            let sse = try content("Hello") + event + finish("stop") + "data: [DONE]\n\n"
            try await withStream(sse) {
                do { _ = try await collect(); XCTFail("Invalid event accepted") }
                catch { XCTAssertEqual(error as? TranslationError, .invalidResponse) }
            }
        }
    }

    func testStreamErrorAfterContentIsSurfaced() async throws {
        let sse = try content("Hello") + event(["error": ["message": "upstream failed"]]) + "data: [DONE]\n\n"
        try await withStream(sse) {
            do { _ = try await collect(); XCTFail("Service error accepted") }
            catch { XCTAssertEqual(error as? TranslationError, .http(0, "upstream failed")) }
        }
    }

    func testLengthTerminationNeverCommitsResultOrHistory() async throws {
        let sse = try content("Partial translation") + finish("length") + "data: [DONE]\n\n"
        try await withStream(sse) {
            let engine = TranslationEngine(settings: settings())
            engine.input = "source"
            engine.translate()
            try await wait { if case .failed = engine.state { return true }; return false }
            XCTAssertTrue(engine.output.isEmpty)
            XCTAssertTrue(engine.versions.isEmpty)
            XCTAssertTrue(engine.history.isEmpty)
        }
    }

    func testStructuredLengthAndContentFilterAreNotSuccessfulEnvelopes() async throws {
        for reason in ["length", "content_filter"] {
            let sse = try content("{\"translation\":\"Hello\"}") + finish(reason) + "data: [DONE]\n\n"
            try await withStream(sse) {
                do { _ = try await collect(.strictJSONSchema); XCTFail("Abnormal finish accepted") }
                catch {
                    if reason == "length" { XCTAssertEqual((error as? PartialTranslationFailure)?.underlying as? TranslationError, .truncatedStream) }
                    else { XCTAssertEqual(error as? TranslationStructuredOutputError, .modelRefusal) }
                }
            }
        }
    }

    func testLocalOnlyRouteIgnoresUnavailableOnlinePreference() {
        let settings = SettingsStore(preview: true)
        settings.profiles[2] = APIProfile(baseURL: "http://localhost:11434/v1", model: "local")
        XCTAssertTrue(settings.isConfigured)
        XCTAssertEqual(settings.route.stages.first?.slots, [2])
        settings.profiles[0] = APIProfile(baseURL: "https://example.com/v1", apiKey: "fake", model: "online")
        XCTAssertEqual(settings.route.stages.first?.slots, [0])
        settings.profiles[0] = APIProfile()
        XCTAssertEqual(settings.route.stages.first?.slots, [2])
    }

    func testChangingFinishedTargetStartsNewRequestBeforeEscalating() async throws {
        var requests: [(TranslationLanguage, String)] = []
        let engine = TranslationEngine(settings: settings(local: true)) { _, target, _, _, config in
            requests.append((target, config.model))
            return AsyncThrowingStream { c in
                c.yield(target == .japanese ? "こんにちは。" : "Hello.")
                c.finish()
            }
        }
        engine.input = "你好"
        engine.submit()
        try await wait { engine.state == .done }
        engine.selectExplicitTarget(.japanese)
        XCTAssertTrue(engine.output.isEmpty)
        try await wait { engine.state == .done }
        engine.submit()
        try await wait { !engine.escalating }
        XCTAssertEqual(requests.map(\.0), [.english, .japanese, .japanese])
        XCTAssertEqual(requests.map(\.1), ["local", "local", "online"])
        XCTAssertEqual(engine.output, "こんにちは。")
        engine.selectAutoTarget()
        try await wait { engine.state == .done }
        XCTAssertEqual(requests.last?.0, .english)
    }

    func testRestoreSameInputCancelsInFlightEscalationAndClearsVersions() async throws {
        var online: AsyncThrowingStream<String, Error>.Continuation?
        let engine = TranslationEngine(settings: settings(local: true)) { _, _, _, _, config in
            AsyncThrowingStream { c in
                if config.model == "local" { c.yield("Local."); c.finish() }
                else { online = c }
            }
        }
        engine.input = "你好"
        engine.submit()
        try await wait { engine.state == .done }
        let record = try XCTUnwrap(engine.history.first)
        engine.escalate()
        try await wait { online != nil }
        engine.restoreHistory(record)
        online?.yield("Stale online.")
        online?.finish()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(engine.output, record.output)
        XCTAssertEqual(engine.versions, record.versions)
        XCTAssertFalse(engine.canEscalate)
        XCTAssertFalse(engine.escalating)
    }

    func testExplicitTargetAfterManualFlipRestoresDetectedSource() async throws {
        var targets: [TranslationLanguage] = []
        let engine = TranslationEngine(settings: settings()) { _, target, _, _, _ in
            targets.append(target)
            return AsyncThrowingStream { c in c.yield("OK."); c.finish() }
        }
        engine.input = "你好"
        engine.flipDirection()
        engine.translate()
        try await wait { engine.state == .done }
        engine.selectExplicitTarget(.japanese)
        try await wait { engine.state == .done }
        XCTAssertFalse(engine.flipped)
        XCTAssertEqual(engine.source, .chinese)
        XCTAssertEqual(engine.sourceLabel, "中")
        XCTAssertEqual(targets, [.chinese, .japanese])
        XCTAssertEqual(engine.history.first?.source, .chinese)
    }

    func testTargetChangeDuringEscalationIgnoresLateOldOnlineResult() async throws {
        var oldOnline: AsyncThrowingStream<String, Error>.Continuation?
        var targets: [TranslationLanguage] = []
        let engine = TranslationEngine(settings: settings(local: true)) { _, target, _, _, config in
            targets.append(target)
            return AsyncThrowingStream { c in
                if config.model == "online" { oldOnline = c }
                else { c.yield(target == .japanese ? "こんにちは。" : "Hello."); c.finish() }
            }
        }
        engine.input = "你好"
        engine.submit()
        try await wait { engine.state == .done }
        engine.escalate()
        try await wait { oldOnline != nil }
        engine.selectExplicitTarget(.japanese)
        oldOnline?.yield("Stale English.")
        oldOnline?.finish()
        try await wait { engine.state == .done && !engine.escalating }
        XCTAssertEqual(targets, [.english, .english, .japanese])
        XCTAssertEqual(engine.output, "こんにちは。")
        XCTAssertEqual(engine.versions.count, 1)
        XCTAssertEqual(engine.history.first?.target, .japanese)
    }

    func testCappedOnlineResultCanRetryWithoutEditingInput() async throws {
        var calls = 0
        let engine = TranslationEngine(settings: settings()) { _, _, _, _, _ in
            calls += 1
            return AsyncThrowingStream { c in
                c.yield(calls == 1 ? String(repeating: "x", count: TranslationEngine.maxOutputCharacters + 1) : "Hello.")
                c.finish()
            }
        }
        engine.input = "你好"
        engine.submit()
        try await wait { engine.state == .done }
        XCTAssertTrue(engine.outputCapped)
        XCTAssertTrue(engine.canRetryResult)
        engine.submit()
        try await wait { engine.state == .done }
        XCTAssertEqual(calls, 2)
        XCTAssertFalse(engine.outputCapped)
        XCTAssertEqual(engine.output, "Hello.")
    }

    func testWrongLanguageOnlineResultCanBeRetried() async throws {
        var calls = 0
        let engine = TranslationEngine(settings: settings()) { _, _, _, _, _ in
            calls += 1
            return AsyncThrowingStream { c in
                c.yield(calls == 1 ? "这段中文没有被翻译成英文。" : "Hello.")
                c.finish()
            }
        }
        engine.input = "你好"
        engine.submit()
        try await wait { engine.state == .done }
        XCTAssertTrue(engine.canRetryResult)
        engine.submit()
        try await wait { engine.state == .done }
        XCTAssertEqual(calls, 2)
        XCTAssertFalse(engine.canRetryResult)
        engine.submit()
        XCTAssertEqual(calls, 2)
    }

    func testFailureDescriptionCountsOnlyRequestedSlots() async throws {
        let settings = settings()
        settings.profiles[1] = settings.profiles[0]
        var calls = 0
        let engine = TranslationEngine(settings: settings) { _, _, _, _, _ in
            calls += 1
            return AsyncThrowingStream { c in
                c.yield("partial")
                c.finish(throwing: TranslationError.truncatedStream)
            }
        }
        engine.input = "source"
        engine.translate()
        try await wait { if case .failed = engine.state { return true }; return false }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(engine.state, .failed(TranslationError.truncatedStream.localizedDescription))
    }

    func testSummonSubscriptionUsesPublishedValuesForRebindAndClear() {
        let settings = settings()
        var values: [KeyCombo?] = []
        let subscription = Publishers.CombineLatest(settings.$shortcuts, settings.$disabledShortcuts)
            .map { SettingsStore.shortcut(.summon, shortcuts: $0, disabled: $1) }
            .removeDuplicates().dropFirst()
            .sink { values.append($0) }
        let combo = KeyCombo(keyCode: 12, modifiers: NSEvent.ModifierFlags.option.rawValue, display: "Option-Q")
        settings.setShortcut(combo, for: .summon)
        XCTAssertEqual(values.last!, combo)
        settings.clearShortcut(for: .summon)
        XCTAssertNil(values.last!)
        settings.setShortcut(combo, for: .summon)
        XCTAssertEqual(values.last!, combo)
        withExtendedLifetime(subscription) {}
    }

    func testCancelConnectionTestResetsStateAndInvalidatesGeneration() {
        let task = Task<Void, Never> { }
        var tasks = [0: task]
        var states: [Int: SettingsView.TestState] = [0: .testing, 1: .failure("previous")]
        var generations = [0: 3]
        SettingsView.cancelConnectionTests(tasks: &tasks, states: &states, generations: &generations)
        XCTAssertTrue(task.isCancelled)
        XCTAssertTrue(tasks.isEmpty)
        XCTAssertEqual(states[0], .idle)
        XCTAssertEqual(states[1], .failure("previous"))
        XCTAssertEqual(generations[0], 4)
    }

    private final class Credentials {
        var keys = [0: "old-primary", 1: "old-backup"]
        var failLoad = false
        var failSave = false
        var writes = 0
        var storage: CredentialStorage {
            CredentialStorage(load: {
                if self.failLoad { throw KeychainError.readFailed(errSecInteractionNotAllowed) }
                return self.keys
            }, save: {
                if self.failSave { throw KeychainError.operationFailed(errSecInteractionNotAllowed) }
                self.writes += 1
                self.keys = $0
            })
        }
    }

    func testHistoryKeepsVersionsAndOriginalProviderAfterConfigChanges() async throws {
        var files: [URL: Data] = [:]
        let storage = TranslationStorage(read: { files[$0] }, write: { files[$1] = $0 })
        let settings = settings(local: true)
        var models: [String] = []
        let engine = TranslationEngine(settings: settings, storage: storage) { _, _, _, _, config in
            models.append(config.model)
            return AsyncThrowingStream { c in c.yield(config.model == "local" ? "Local." : "Online."); c.finish() }
        }
        engine.input = "你好"
        engine.submit()
        try await wait { engine.state == .done }
        settings.profiles[0].model = "changed-after-request"
        engine.escalate()
        try await wait { !engine.escalating }
        XCTAssertEqual(models, ["local", "online"])
        XCTAssertEqual(engine.versions.last?.model, "online")
        let restored = TranslationEngine(settings: settings, storage: storage)
        let record = try XCTUnwrap(restored.history.first)
        XCTAssertEqual(record.versions.count, 2)
        restored.restoreHistory(record)
        restored.showVersion(0)
        XCTAssertEqual(restored.output, "Local.")
        restored.showVersion(1)
        XCTAssertEqual(restored.output, "Online.")
        XCTAssertEqual(restored.versions.last?.host, "example.com")
        XCTAssertFalse(restored.canEscalate)
    }

    func testHistoryDeleteUndoAndPrivacySwitchRemoveDiskData() async throws {
        var files: [URL: Data] = [:]
        let settings = settings()
        let storage = TranslationStorage(read: { files[$0] }, write: { files[$1] = $0 })
        let engine = TranslationEngine(settings: settings, storage: storage) { _, _, _, _, _ in
            AsyncThrowingStream { c in c.yield("Hello."); c.finish() }
        }
        engine.input = "你好"
        engine.translate()
        try await wait { engine.state == .done }
        let record = try XCTUnwrap(engine.history.first)
        engine.deleteHistory(record.id)
        XCTAssertTrue(engine.history.isEmpty)
        engine.undoHistoryDeletion()
        XCTAssertEqual(engine.history.first, record)
        engine.clearHistory()
        engine.undoHistoryDeletion()
        XCTAssertEqual(engine.history.count, 1)
        settings.saveHistoryEnabled = false
        engine.historyPreferenceChanged()
        XCTAssertNil(files[TranslationEngine.historyURL(preview: true)])
        XCTAssertFalse(engine.canUndoHistoryDeletion)
        engine.input = "再见"
        engine.translate()
        try await wait { engine.state == .done }
        XCTAssertTrue(engine.history.isEmpty)
    }

    func testDraftOptOutClearsStorageAndClipboardFailureIsVisible() async throws {
        var files: [URL: Data] = [:]
        var copied: [String] = []
        let settings = settings()
        settings.autoCopy = true
        let storage = TranslationStorage(read: { files[$0] }, write: { files[$1] = $0 })
        let board = TranslationClipboard(write: { copied.append($0); return false })
        let engine = TranslationEngine(settings: settings, draftPersistenceEnabled: true, storage: storage, clipboard: board) { _, _, _, _, _ in
            AsyncThrowingStream { c in c.yield("Hello."); c.finish() }
        }
        engine.input = "你好"
        engine.flushPendingDraftSave()
        XCTAssertNotNil(files[TranslationEngine.draftURL(preview: true)])
        settings.saveDraftEnabled = false
        engine.draftPreferenceChanged()
        XCTAssertNil(files[TranslationEngine.draftURL(preview: true)])
        engine.translate()
        try await wait { engine.state == .done }
        XCTAssertEqual(copied, ["Hello."])
        XCTAssertTrue(engine.copyFailed)
        engine.clearDraft()
        XCTAssertTrue(engine.input.isEmpty)
    }

    func testStorageFailuresAreExposedWithoutDestroyingCurrentResult() async throws {
        let storage = TranslationStorage(read: { _ in nil }, write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        let engine = TranslationEngine(settings: settings(), storage: storage) { _, _, _, _, _ in
            AsyncThrowingStream { c in c.yield("Hello."); c.finish() }
        }
        engine.input = "你好"
        engine.translate()
        try await wait { engine.state == .done }
        XCTAssertNotNil(engine.persistenceError)
        XCTAssertEqual(engine.output, "Hello.")
    }

    func testAdditionalInstructionStartsFreshRequestWithNewIdentity() async throws {
        let settings = settings()
        var extras: [String] = []
        let engine = TranslationEngine(settings: settings) { _, _, _, extra, _ in
            extras.append(extra)
            return AsyncThrowingStream { c in c.yield("Hello."); c.finish() }
        }
        engine.input = "你好"
        engine.translate()
        try await wait { engine.state == .done }
        settings.extraInstruction = "Keep product names"
        engine.submit()
        try await wait { engine.state == .done }
        XCTAssertEqual(extras, ["", "Keep product names"])
        XCTAssertEqual(engine.history.count, 2)
    }

    func testRestoringDefaultShortcutRejectsCollision() {
        let settings = settings()
        settings.setShortcut(.defaultCopy, for: .translate)
        settings.clearShortcut(for: .copy)
        XCTAssertNotNil(settings.restoreShortcut(.copy))
        XCTAssertNil(settings.shortcut(.copy))
        XCTAssertEqual(settings.shortcut(.translate), .defaultCopy)
        XCTAssertFalse(settings.commandLabel("Translate", action: .translate).contains("Return"))
    }

    func testProviderOrderIsPartOfProtocolCacheIdentity() {
        var first = APIConfig(baseURL: "https://openrouter.ai/api/v1", apiKey: "fake", model: "m", providerOrder: "a,b")
        let original = TranslationProtocolRegistry.fingerprint(for: first)
        first.providerOrder = "b,a"
        XCTAssertNotEqual(original, TranslationProtocolRegistry.fingerprint(for: first))
        first.providerOrder = "a, b"
        XCTAssertEqual(original, TranslationProtocolRegistry.fingerprint(for: first))
    }

    func testByteLimitsHandleOneEnormousGrapheme() async throws {
        let giant = "a" + String(repeating: "\u{0301}", count: TranslationEngine.maxOutputBytes)
        XCTAssertEqual(giant.count, 1)
        let engine = TranslationEngine(settings: settings()) { _, _, _, _, _ in
            AsyncThrowingStream { c in c.yield(giant); c.finish() }
        }
        engine.input = giant
        XCTAssertLessThanOrEqual(engine.input.utf8.count, TranslationEngine.maxInputBytes)
        XCTAssertTrue(engine.inputWasTruncated)
        engine.translate()
        try await wait { engine.state == .done }
        XCTAssertLessThanOrEqual(engine.output.utf8.count, TranslationEngine.maxOutputBytes)
        XCTAssertTrue(engine.outputCapped)
    }

    func testStructuredPartialFailureDoesNotRetryOrContactBackup() async throws {
        let settings = settings()
        settings.profiles[0].outputProtocolPreference = .automatic
        settings.profiles[1] = settings.profiles[0]
        var count = 0
        let engine = TranslationEngine(settings: settings) { _, _, _, _, _ in
            count += 1
            return AsyncThrowingStream { c in
                c.finish(throwing: PartialTranslationFailure(underlying: TranslationError.truncatedStream))
            }
        }
        engine.input = "你好"
        engine.translate()
        try await wait { if case .failed = engine.state { return true }; return false }
        XCTAssertEqual(count, 1)
        XCTAssertTrue(engine.output.isEmpty)
    }

    func testUnknownKeysArePreservedWhenOnlyOneSlotIsEdited() {
        let credentials = Credentials()
        credentials.failLoad = true
        let settings = SettingsStore(preview: true, credentialStorage: credentials.storage)
        settings.profiles[0].apiKey = "new-primary"
        settings.flushPendingSaves()
        XCTAssertEqual(credentials.writes, 0)
        XCTAssertNotNil(settings.keychainError)
        credentials.failLoad = false
        settings.retryLoadKeys()
        XCTAssertEqual(credentials.keys, [0: "new-primary", 1: "old-backup"])
        XCTAssertEqual(settings.profiles[1].apiKey, "old-backup")
        XCTAssertNil(settings.keychainError)
    }

    func testExplicitKeyCanReplaceKnownCorruptCredentialData() {
        var saved: [Int: String]?
        let storage = CredentialStorage(load: { throw KeychainError.invalidData }, save: { saved = $0 })
        let settings = SettingsStore(preview: true, credentialStorage: storage)
        XCTAssertNotNil(settings.keychainError)
        settings.profiles[0].apiKey = "replacement"
        settings.flushPendingSaves()
        XCTAssertEqual(saved, [0: "replacement"])
        XCTAssertNil(settings.keychainError)
    }

    func testRapidCredentialEditsMergeWithoutLosingUntouchedSlot() {
        let credentials = Credentials()
        credentials.keys[2] = "untouched"
        let settings = SettingsStore(preview: true, credentialStorage: credentials.storage)
        settings.profiles[0].apiKey = "first-edit"
        settings.profiles[1].apiKey = "new-backup"
        settings.profiles[0].apiKey = "last-edit"
        settings.flushPendingSaves()
        XCTAssertEqual(credentials.keys, [0: "last-edit", 1: "new-backup", 2: "untouched"])
        XCTAssertEqual(credentials.writes, 1)
    }

    func testSaveRetryDoesNotClearFailureWithoutSavingAndHonorsDeletion() {
        let credentials = Credentials()
        let settings = SettingsStore(preview: true, credentialStorage: credentials.storage)
        credentials.failSave = true
        settings.profiles[0].apiKey = "new-primary"
        settings.profiles[1].apiKey = ""
        settings.flushPendingSaves()
        settings.retryLoadKeys()
        XCTAssertNotNil(settings.keychainError)
        XCTAssertEqual(credentials.keys[1], "old-backup")
        credentials.failSave = false
        settings.retryLoadKeys()
        XCTAssertEqual(credentials.keys, [0: "new-primary"])
        XCTAssertEqual(settings.profiles[1].apiKey, "")
        XCTAssertNil(settings.keychainError)
    }

    func testUnlockRecoversRemoteKeysWithWorkingLocalRoute() {
        let credentials = Credentials()
        credentials.failLoad = true
        let settings = SettingsStore(preview: true, credentialStorage: credentials.storage)
        settings.profiles[0].baseURL = "https://example.com/v1"
        settings.profiles[0].model = "online"
        settings.profiles[2] = APIProfile(baseURL: "http://localhost:11434/v1", model: "local")
        XCTAssertTrue(settings.isConfigured)
        credentials.failLoad = false
        settings.reloadKeysIfMissing()
        XCTAssertEqual(settings.profiles[0].apiKey, "old-primary")
        XCTAssertNil(settings.keychainError)
        XCTAssertEqual(credentials.writes, 0, "Loading keys must not schedule an unnecessary save")
        settings.flushPendingSaves()
        XCTAssertEqual(credentials.writes, 0)
    }
}
