import XCTest
@testable import Tusi

@MainActor
final class ServiceDraftTests: XCTestCase {
    private func store(_ defaults: UserDefaults) -> SettingsStore {
        SettingsStore(
            preview: false,
            credentialStorage: CredentialStorage(load: { [:] }, save: { _ in }),
            defaultsOverride: defaults
        )
    }

    private func scratchDefaults() -> UserDefaults {
        let suite = "com.tusi.test.servicedraft.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    // MARK: - Draft

    func testDraftCarriesOnlyEditedFields() {
        let stored = APIProfile(baseURL: "https://a.example/v1", apiKey: "k1", model: "m1")
        var draft = ProfileDraft(stored)
        draft.edited.model = "m2"

        // The store moved under the draft (a picker, a late Keychain read).
        var moved = stored
        moved.apiKey = "k-late"
        moved.baseURL = "https://b.example/v1"

        let resolved = draft.resolved(over: moved)
        XCTAssertEqual(resolved.model, "m2", "the user's edit wins")
        XCTAssertEqual(resolved.apiKey, "k-late", "an untouched field follows the store")
        XCTAssertEqual(resolved.baseURL, "https://b.example/v1")
    }

    func testDraftEditedBackToOriginalIsNotAChange() {
        let stored = APIProfile(baseURL: "https://a.example/v1", apiKey: "k", model: "m")
        var draft = ProfileDraft(stored)
        draft.edited.baseURL = "https://other.example/v1"
        draft.edited.baseURL = stored.baseURL
        XCTAssertEqual(draft.resolved(over: stored), stored)
    }

    // MARK: - Commit and endpoint history

    func testCommitWritesWholeProfileAndRecordsBothEndpoints() {
        let defaults = scratchDefaults()
        let s = store(defaults)
        s.commitProfile(APIProfile(baseURL: "https://a.example/v1", apiKey: "k", model: "m"), at: 0)
        s.commitProfile(APIProfile(baseURL: "https://b.example/v1", apiKey: "k2", model: "m2"), at: 0)

        XCTAssertEqual(s.profiles[0].baseURL, "https://b.example/v1")
        XCTAssertEqual(s.profiles[0].model, "m2")
        XCTAssertEqual(s.endpointHistory, ["https://b.example/v1", "https://a.example/v1"])
        XCTAssertEqual(store(defaults).endpointHistory, s.endpointHistory, "history survives relaunch")
    }

    func testHistoryDeduplicatesSpellingsOfOneEndpoint() {
        let s = store(scratchDefaults())
        s.commitProfile(APIProfile(baseURL: "https://A.example/v1/", apiKey: "k", model: "m"), at: 0)
        s.commitProfile(APIProfile(baseURL: "a.example/v1", apiKey: "k", model: "m"), at: 1)
        XCTAssertEqual(s.endpointHistory, ["a.example/v1"])
    }

    func testHistoryIsBoundedAndSkipsLocalSlot() {
        let s = store(scratchDefaults())
        for n in 0..<(SettingsStore.endpointHistoryLimit + 5) {
            s.commitProfile(APIProfile(baseURL: "https://h\(n).example/v1", apiKey: "k", model: "m"), at: 0)
        }
        XCTAssertEqual(s.endpointHistory.count, SettingsStore.endpointHistoryLimit)
        let before = s.endpointHistory
        s.commitProfile(APIProfile(baseURL: "http://127.0.0.1:8080/v1", model: "local"), at: SettingsStore.localProfileIndex)
        XCTAssertEqual(s.endpointHistory, before)
    }

    func testExistingEndpointsSeedHistoryOnce() {
        let defaults = scratchDefaults()
        defaults.set("https://primary.example/v1", forKey: "baseURL.0")
        defaults.set("https://backup.example/v1", forKey: "baseURL.1")
        let s = store(defaults)
        XCTAssertEqual(s.endpointHistory, ["https://primary.example/v1", "https://backup.example/v1"])
        s.clearEndpointHistory()
        XCTAssertEqual(store(defaults).endpointHistory, [], "a cleared history is not re-seeded")
    }

    // MARK: - Model list

    func testModelsEndpointSitsBesideChatEndpoint() throws {
        func url(_ base: String) throws -> String {
            try TranslationService.modelsEndpoint(for: APIConfig(baseURL: base, apiKey: "k", model: "m")).absoluteString
        }
        XCTAssertEqual(try url("https://api.example.com/v1"), "https://api.example.com/v1/models")
        XCTAssertEqual(try url("https://api.example.com/v1/chat/completions"), "https://api.example.com/v1/models")
        XCTAssertEqual(try url("api.example.com"), "https://api.example.com/models")
        XCTAssertThrowsError(try url("http://api.example.com/v1"), "remote HTTP stays refused")
    }

    func testParseModelListSortsAndDeduplicates() throws {
        let json = #"{"object":"list","data":[{"id":"gpt-4o"},{"id":"deepseek-chat"},{"id":"gpt-4o"},{"id":""}]}"#
        XCTAssertEqual(try TranslationService.parseModelList(Data(json.utf8)), ["deepseek-chat", "gpt-4o"])
        XCTAssertThrowsError(try TranslationService.parseModelList(Data("<html>".utf8)))
    }

    func testParseModelListAcceptsGatewayShapes() throws {
        func parse(_ json: String) throws -> [String] { try TranslationService.parseModelList(Data(json.utf8)) }
        XCTAssertEqual(try parse(#"[{"id":"b"},{"id":"a"}]"#), ["a", "b"])
        XCTAssertEqual(try parse(#"{"models":[{"name":"x"}]}"#), ["x"])
        XCTAssertEqual(try parse(#"{"data":["m1",{"id":7},{"id":"m2"}]}"#), ["m1", "m2"], "a malformed entry drops only itself")
        XCTAssertThrowsError(try parse(#"{"error":"nope"}"#))
    }

    func testListModelsAllowsUnauthenticatedPublicGatewayAndRejectsOversizedResponse() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        TranslationService.sessionOverride = session
        defer {
            TranslationService.sessionOverride = nil
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        MockURLProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let json = #"{"data":[{"id":"gpt-4o"},{"id":"deepseek-chat"}]}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }
        let models = try await TranslationService.listModels(config: APIConfig(baseURL: "https://openrouter.ai/api/v1", apiKey: "", model: ""))
        XCTAssertEqual(models, ["deepseek-chat", "gpt-4o"])

        MockURLProtocol.handler = { request in
            let oversized = Data(repeating: 0x20, count: 2 * 1024 * 1024 + 1)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, oversized)
        }
        do {
            _ = try await TranslationService.listModels(config: APIConfig(baseURL: "https://openrouter.ai/api/v1", apiKey: "", model: ""))
            XCTFail("Expected oversized model list to be rejected")
        } catch {
            XCTAssertEqual(error as? TranslationError, .invalidResponse)
        }
    }
}
