import Foundation
import XCTest
@testable import Tusi

@MainActor
final class OpenCodeSessionTests: XCTestCase {
    private let config = APIConfig(baseURL: "https://opencode.ai/zen/go/v1", apiKey: "fake", model: "mimo-v2.5")
    private let missingSession = "Request is missing x-opencode-session and cannot be routed efficiently."

    func testHeaderIsRestrictedToOpenCodeAndUsesExplicitIdentity() throws {
        let id = UUID()
        let request = try TranslationService.makeRequest(config: config, body: [:], sessionID: id)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-session"), id.uuidString)
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Tusi/") == true)
        XCTAssertEqual(request.url?.absoluteString, "https://opencode.ai/zen/go/v1/chat/completions")
        for host in ["example.com", "opencode.ai.example.com", "localhost"] {
            var other = config
            other.baseURL = "https://\(host)/v1"
            let otherRequest = try TranslationService.makeRequest(config: other, body: [:], sessionID: id)
            XCTAssertNil(otherRequest.value(forHTTPHeaderField: "x-opencode-session"))
        }
    }

    private func withMock(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data),
                          body: () async throws -> Void) async throws {
        let suite = "com.tusi.tests.opencode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        TranslationService.sessionOverride = session
        TranslationService.protocolRegistryOverride = TranslationProtocolRegistry(defaults: defaults, storageKey: "capabilities")
        MockURLProtocol.handler = handler
        defer {
            session.invalidateAndCancel()
            TranslationService.sessionOverride = nil
            TranslationService.protocolRegistryOverride = nil
            MockURLProtocol.handler = nil
            defaults.removePersistentDomain(forName: suite)
        }
        try await body()
    }

    func testConnectionProbePreservesSessionAcrossProtocolFallbackAndRotatesForNextProbe() async throws {
        var ids: [String] = []
        try await withMock({ request in
            ids.append(try XCTUnwrap(request.value(forHTTPHeaderField: "x-opencode-session")))
            let first = ids.count == 1
            let response = HTTPURLResponse(url: request.url!, statusCode: first ? 400 : 200, httpVersion: nil, headerFields: nil)!
            let payload = first ? #"{"error":{"message":"unsupported response_format"}}"#
                : "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"},\"finish_reason\":\"stop\"}]}\n\n"
            return (response, Data(payload.utf8))
        }) {
            _ = try await TranslationService.testConnection(config: config)
            _ = try await TranslationService.testConnection(config: config)
        }
        XCTAssertEqual(ids.count, 3)
        guard ids.count == 3 else { return }
        XCTAssertEqual(ids[0], ids[1])
        XCTAssertNotEqual(ids[1], ids[2])
    }

    func testMissingSessionIsNotRetriedAsOutputProtocolFailure() async throws {
        var count = 0
        let payload = try JSONSerialization.data(withJSONObject: ["error": ["message": missingSession]])
        try await withMock({ request in
            count += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, payload)
        }) {
            do {
                _ = try await TranslationService.testConnection(config: config)
                XCTFail("Expected provider rejection")
            } catch {
                XCTAssertEqual(error as? TranslationError, .http(400, missingSession))
            }
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(TranslationService.httpFailureReason(status: 400, message: missingSession), "missing_opencode_session")
        XCTAssertEqual(TranslationService.httpFailureReason(status: 400, message: "private source or key"), "provider_rejected_request")
    }

    func testEngineKeepsSessionAcrossTransportRetryAndRotatesForNewTranslation() async throws {
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.soundEnabled = false
        settings.profiles[0] = APIProfile(baseURL: config.baseURL, apiKey: "fake", model: config.model,
                                          outputProtocolPreference: .plainText)
        var ids: [UUID?] = []
        let engine = TranslationEngine(settings: settings, stream: { _, _, _, _, _ in
            ids.append(TranslationService.sessionID)
            let fail = ids.count == 1
            return AsyncThrowingStream { continuation in
                if fail { continuation.finish(throwing: URLError(.networkConnectionLost)) }
                else { continuation.yield("Hello"); continuation.finish() }
            }
        })
        engine.input = "你好"
        engine.translate()
        for _ in 0..<200 {
            if ids.count >= 2, !engine.isTranslating { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        engine.input = "您好"
        engine.translate()
        for _ in 0..<200 {
            if ids.count >= 3, !engine.isTranslating { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(ids.count, 3)
        guard ids.count == 3 else { return }
        XCTAssertNotNil(ids[0])
        XCTAssertEqual(ids[0], ids[1])
        XCTAssertNotEqual(ids[1], ids[2])
    }
}
