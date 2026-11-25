import Foundation
import XCTest
@testable import Tusi

private final class FixMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class AuditFixes20261125Tests: IsolatedPersistenceTestCase {
    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    // AUD-01: CRLF (\r\n) SSE [DONE] frames succeed
    func testCRLF_SSEStreamCompletesCleanly() async throws {
        let session = makeMockSession()
        TranslationService.sessionOverride = session
        defer {
            TranslationService.sessionOverride = nil
            FixMockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        let payload =
            "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\r\n\r\n" +
            "data: [DONE]\r\n\r\n"
        FixMockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data(payload.utf8))
        }

        let config = APIConfig(
            baseURL: "https://api.example.com/v1",
            apiKey: "sk-fix-test",
            model: "gpt-4o-mini",
            outputProtocolPreference: .plainText
        )

        var chunks: [String] = []
        for try await chunk in TranslationService.stream(
            text: "你好",
            target: .english,
            tone: .standard,
            extra: "",
            config: config,
            outputProtocol: .plainText
        ) {
            chunks.append(chunk)
        }
        XCTAssertEqual(chunks.joined(), "Hello")
    }

    // AUD-02: Typing in extraInstruction does not auto-retranslate on every pause;
    // leaving settings or submitting applies it once.
    func testExtraInstructionDoesNotRetranslateDuringTypingAndAppliesOnReturn() async throws {
        let settings = isolatedSettings()
        settings.profiles[0] = APIProfile(baseURL: "https://api.example.com/v1", apiKey: "sk", model: "m")
        settings.autoCopy = true
        var calls: [String] = []
        var writes: [String] = []
        let engine = TranslationEngine(
            settings: settings,
            storage: testStorage,
            clipboard: TranslationClipboard { text in writes.append(text); return true },
            stream: { _, _, _, extra, _ in
                calls.append(extra)
                return AsyncThrowingStream { c in
                    c.yield("T[\(extra)]")
                    c.finish()
                }
            }
        )

        engine.input = "你好"
        engine.translate()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(calls, [""])
        XCTAssertEqual(writes, ["T[]"])

        settings.extraInstruction = "a"
        try await Task.sleep(for: .milliseconds(50))
        settings.extraInstruction = "ab"
        try await Task.sleep(for: .milliseconds(50))
        settings.extraInstruction = "abc"
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(calls, [""])
        XCTAssertEqual(writes, ["T[]"])

        engine.retranslateIfConfigurationChanged()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(calls, ["", "abc"])
        XCTAssertEqual(writes, ["T[]", "T[abc]"])
    }

    // AUD-03: SmartQuotes handles CJK single quotes, nested quotes, dashes, ellipsis, and blank-line resets
    func testSmartQuotesAuditEdgeCasesAndParagraphReset() {
        let cases: [(String, String)] = [
            ("请点击 'Save' 并点击'确认'", "请点击 ‘Save’ 并点击‘确认’"),
            ("He said \"'Hello'\"", "He said “‘Hello’”"),
            ("他说\"'API'设置和'SDK'配置\"", "他说“‘API’设置和‘SDK’配置”"),
            ("前缀 \"non-\" 表示\"非\"", "前缀 “non-” 表示“非”"),
            ("\"Wait—\" she said.", "“Wait—” she said."),
            ("他犹豫了一下……\"OK\"，然后点了\"确认\"", "他犹豫了一下……“OK”，然后点了“确认”"),
            ("She asked \"'Don't stop'\"", "She asked “‘Don’t stop’”"),
            ("It costs '90' credits in the '90s", "It costs ‘90’ credits in the ’90s"),
            ("Unclosed \"quote\n\n\"Fresh\"", "Unclosed “quote\n\n“Fresh”")
        ]
        for (input, expected) in cases {
            XCTAssertEqual(SmartQuotes.apply(to: input), expected, "Input: \(input)")
        }
    }

    // AUD-04 & AUD-05: Synchronous commit flushes immediately, revisions increment on repeated failures/saves,
    // and reverting Jev/slot keys clears pending queue.
    func testKeychainCommitSyncAndRevertClearsPendingQueue() throws {
        var backing: [Int: String] = [SettingsStore.jevKeyIndex: "old-jev"]
        var failSave = true
        let settings = isolatedSettings(credentialStorage: CredentialStorage(
            load: { backing },
            save: { snapshot in
                if failSave { throw KeychainError.operationFailed(errSecAuthFailed) }
                backing = snapshot
            }
        ))

        let initialFailRev = settings.keychainFailureRevision
        let initialSaveRev = settings.keychainSaveRevision

        settings.commitJevAPIKey("bad-jev")
        XCTAssertNotNil(settings.keychainError)
        XCTAssertEqual(settings.keychainFailureRevision, initialFailRev &+ 1)
        XCTAssertEqual(settings.keychainSaveRevision, initialSaveRev)

        // Repeated identical failure still increments keychainFailureRevision
        settings.commitJevAPIKey("still-bad")
        XCTAssertEqual(settings.keychainFailureRevision, initialFailRev &+ 2)

        // Reverting back to loaded key cancels stale pending overwrite
        settings.jevAPIKey = "old-jev"
        failSave = false
        settings.retryLoadKeys()
        XCTAssertEqual(backing[SettingsStore.jevKeyIndex], "old-jev")
        XCTAssertNil(settings.keychainError)

        // Successful commit increments keychainSaveRevision synchronously
        let revBeforeSuccess = settings.keychainSaveRevision
        settings.commitJevAPIKey("new-jev")
        XCTAssertEqual(settings.keychainSaveRevision, revBeforeSuccess &+ 1)
        XCTAssertEqual(backing[SettingsStore.jevKeyIndex], "new-jev")
    }

    // AUD-06: ProfileDraft.acceptStoreModel and LocalModelManager.readSelection preserve custom local baseURL
    func testProfileDraftAndLocalModelSelectionPreserveCustomEndpoint() async throws {
        var stored = APIProfile(baseURL: "http://127.0.0.1:8080/v1", model: "A.gguf", outputProtocolPreference: .plainText)
        var draft = ProfileDraft(stored)
        draft.edited.baseURL = "http://127.0.0.1:9090/v1"
        draft.edited.outputProtocolPreference = .automatic

        draft.acceptStoreModel("B.gguf")
        stored.model = "B.gguf"

        let resolved = draft.resolved(over: stored)
        XCTAssertEqual(resolved.model, "B.gguf")
        XCTAssertEqual(resolved.baseURL, "http://127.0.0.1:9090/v1")
        XCTAssertEqual(resolved.outputProtocolPreference, .automatic)

        // Verify LocalModelManager.refresh preserves customized non-empty local baseURL & protocol
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try Data("GGUF".utf8).write(to: directory.appendingPathComponent("C.gguf"))
        let plist = directory.appendingPathComponent("service.plist")
        let plistObj: [String: Any] = [
            "Label": "com.tusi.llamaserver",
            "ProgramArguments": ["/bin/llama-server", "--host", "127.0.0.1", "--port", "8080",
                                 "-m", directory.appendingPathComponent("C.gguf").path]
        ]
        try PropertyListSerialization.data(fromPropertyList: plistObj, format: .xml, options: 0).write(to: plist)

        actor MockRuntime: LocalModelRuntime {
            func run(_ arguments: [String]) async throws -> (code: Int32, output: String) { (0, "") }
            func activeModel() async throws -> String { "C.gguf" }
            func isProcessRunning(_ pid: Int32) async -> Bool { false }
        }
        let service = LocalModelService(plistURL: plist, runtime: MockRuntime())
        let suite = "com.tusi.test.localmodel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let manager = LocalModelManager(service: service)
        let settings = SettingsStore(
            preview: false,
            credentialStorage: CredentialStorage(load: { [:] }, save: { _ in }),
            defaultsOverride: defaults
        )
        settings.profiles[SettingsStore.localProfileIndex] = resolved
        manager.prepareAtLaunch(settings: settings)
        for _ in 0..<100 where manager.isSwitching {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(settings.profiles[SettingsStore.localProfileIndex].model, "C.gguf")
        XCTAssertEqual(settings.profiles[SettingsStore.localProfileIndex].baseURL, "http://127.0.0.1:9090/v1")
        XCTAssertEqual(settings.profiles[SettingsStore.localProfileIndex].outputProtocolPreference, .automatic)
    }

    // AUD-07: Cancel escalation doesn't auto-copy twice, and restoreHistory doesn't mutate global tone
    func testCancelEscalationDoesNotAutoCopyAndRestoreHistoryPreservesGlobalTone() async throws {
        let settings = isolatedSettings()
        settings.setLocalModelEnabled(true)
        settings.setLocalModelReady(true)
        settings.routeStart = .local
        settings.profiles[SettingsStore.localProfileIndex] = APIProfile(baseURL: "http://127.0.0.1:8080/v1", model: "local.gguf")
        settings.profiles[0] = APIProfile(baseURL: "https://api.example.com/v1", apiKey: "sk", model: "online")
        settings.autoCopy = true
        settings.saveHistoryEnabled = true
        settings.tone = .casual

        var writes: [String] = []
        var streamedModels: [String] = []
        let engine = TranslationEngine(
            settings: settings,
            storage: testStorage,
            clipboard: TranslationClipboard { text in writes.append(text); return true },
            stream: { _, _, _, _, config in
                streamedModels.append(config.model)
                if config.model == "local.gguf" {
                    return AsyncThrowingStream { c in c.yield("Local answer"); c.finish() }
                }
                return AsyncThrowingStream { c in
                    Task {
                        try? await Task.sleep(for: .seconds(5))
                        c.finish()
                    }
                }
            }
        )

        engine.input = "你好"
        engine.translate()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(writes, ["Local answer"])

        engine.escalate()
        try await Task.sleep(for: .milliseconds(30))
        engine.cancelTranslation()
        XCTAssertEqual(writes, ["Local answer"])

        let record = try XCTUnwrap(engine.history.first)
        settings.tone = .formal
        engine.restoreHistory(record)
        XCTAssertEqual(settings.tone, .formal)

        // Switching tone away from the restored record's tone triggers a fresh translation
        settings.tone = .standard
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(streamedModels.count, 3)
    }

    // AUD-08: SemVer build metadata with hyphens and HTTPS->HTTP downgrade rejection
    func testSemVerHyphenBuildMetadataAndHTTPSDowngradeBlock() {
        XCTAssertFalse(UpdateChecker.isNewer("1.21.0", than: "1.21.0+2026-11-23"))
        XCTAssertFalse(UpdateChecker.isNewer("1.21.0+2026-11-23", than: "1.21.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.21.1+2026-11-25", than: "1.21.0+2026-11-23"))

        var orig = URLRequest(url: URL(string: "https://api.example.com/v1/chat/completions")!)
        orig.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        let downgrade = URLRequest(url: URL(string: "http://api.example.com/v1/chat/completions")!)
        XCTAssertNil(TranslationService.redirectedRequest(original: orig, redirected: downgrade))

        let crossHostDowngrade = URLRequest(url: URL(string: "http://other.example/redirect")!)
        XCTAssertNil(TranslationService.redirectedRequest(original: orig, redirected: crossHostDowngrade))
    }

    // AUD-13 & AUD-14: History reload timestamp ordering, endpointIdentity ports, JevToneService sessionOverride
    func testRetryLoadHistoryChronologicalOrderEndpointPortAndJevOverride() async throws {
        var storedData: Data?
        let storage = TranslationStorage(read: { _ in storedData }, write: { data, _ in storedData = data })
        let settings = isolatedSettings()
        settings.saveHistoryEnabled = true
        let engine = TranslationEngine(settings: settings, storage: storage)

        let older = TranslationEngine.Record(
            id: UUID(), input: "old", output: "旧", sourceLabel: "EN",
            source: .english, target: .chinese, tone: .standard,
            timestamp: Date(timeIntervalSince1970: 100)
        )
        let newer = TranslationEngine.Record(
            id: UUID(), input: "new", output: "新", sourceLabel: "EN",
            source: .english, target: .chinese, tone: .standard,
            timestamp: Date(timeIntervalSince1970: 200)
        )
        storedData = try JSONEncoder().encode([newer])
        engine.retryLoadHistory()
        XCTAssertEqual(engine.history.map(\.id), [newer.id])

        // Merge with another disk record newer than an in-memory record
        let middle = TranslationEngine.Record(
            id: UUID(), input: "mid", output: "中", sourceLabel: "EN",
            source: .english, target: .chinese, tone: .standard,
            timestamp: Date(timeIntervalSince1970: 150)
        )
        storedData = try JSONEncoder().encode([newer, older])
        // Simulate in-memory record via fresh engine loaded with middle
        var diskA: Data? = try JSONEncoder().encode([middle])
        let sA = TranslationStorage(read: { _ in diskA }, write: { data, _ in diskA = data })
        let engineA = TranslationEngine(settings: settings, storage: sA)
        diskA = try JSONEncoder().encode([newer, older])
        engineA.retryLoadHistory()
        XCTAssertEqual(engineA.history.map(\.input), ["new", "mid", "old"])

        // Default port stripping
        XCTAssertEqual(
            SettingsStore.endpointIdentity("https://API.Example.com:443/v1/"),
            SettingsStore.endpointIdentity("api.example.com/v1")
        )
        XCTAssertEqual(
            SettingsStore.endpointIdentity("http://localhost:80/v1/"),
            SettingsStore.endpointIdentity("http://localhost/v1")
        )

        // JevToneService.sessionOverride
        let session = makeMockSession()
        JevToneService.sessionOverride = session
        defer {
            JevToneService.sessionOverride = nil
            FixMockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }
        FixMockURLProtocol.handler = { req in
            let json = #"{"answers":{"tone":{"choice":"formal","probabilities":{"formal":0.95,"standard":0.05}}}}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }
        let tone = try await JevToneService.classify(text: "Please sign the attached contract.", key: "jev-test")
        XCTAssertEqual(tone, .formal)
    }

    // AUD-15: Clause-length pure Simplified Chinese flagged for .japanese target while Kanji place names stay allowed
    func testJapaneseWrongLanguageFlagsClauseLengthChineseButAllowsKanjiNouns() {
        let pureChinese = "这是一个完全使用简体中文书写的翻译结果，用于测试目标语言为日语时是否能够识别出错误语言。"
        XCTAssertTrue(LanguageDetector.looksLikeWrongLanguage(pureChinese, target: .japanese))
        XCTAssertFalse(LanguageDetector.looksLikeWrongLanguage("東京都渋谷区神南一丁目", target: .japanese))
    }
}
