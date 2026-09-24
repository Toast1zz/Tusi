import Foundation
import XCTest
@testable import Tusi

@MainActor
final class JevToneTests: XCTestCase {
    private func settings() -> SettingsStore {
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.soundEnabled = false
        settings.tone = .automatic
        settings.jevAPIKey = "test-key"
        settings.profiles[0] = APIProfile(baseURL: "https://example.com/v1", apiKey: "fake", model: "test")
        return settings
    }

    private func waitUntilDone(_ engine: TranslationEngine) async throws {
        for _ in 0..<200 {
            if engine.state == .done { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Translation did not complete")
    }

    func testJevChoiceRequestAndAmbiguousFallback() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.typesafe.ai/v1/systemone")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            var bodyData = request.httpBody ?? Data()
            if bodyData.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = stream.read(&buffer, maxLength: buffer.count)
                stream.close()
                if count > 0 { bodyData = Data(buffer.prefix(count)) }
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, "jev-latest")
            XCTAssertEqual(body["state"] as? String, "Hello")
            let questions = body["questions"] as! [String: [String: Any]]
            XCTAssertEqual(questions["tone"]?["type"] as? String, "choice")
            let criteria = questions["tone"]?["criteria"] as! [String: String]
            XCTAssertEqual(Set(criteria.keys), Set(["casual", "standard", "formal"]))
            let data = Data("""
                {"answers":{"tone":{"type":"choice","choice":"formal","probabilities":{"formal":0.82,"standard":0.13,"casual":0.05},"confidence":0.8}}}
                """.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let selected = try await JevToneService.classify(text: "Hello", key: "test-key", session: session)
        XCTAssertEqual(selected, .formal)

        MockURLProtocol.handler = { request in
            let data = Data("""
                {"answers":{"tone":{"type":"choice","choice":"casual","probabilities":{"casual":0.55,"standard":0.44,"formal":0.01}}}}
                """.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let ambiguous = try await JevToneService.classify(text: "Hello", key: "test-key", session: session)
        XCTAssertEqual(ambiguous, .standard)
    }

    func testConnectionUsesSyntheticTextAndReportsInvalidKey() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }
        MockURLProtocol.handler = { request in
            var bodyData = request.httpBody ?? Data()
            if bodyData.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = stream.read(&buffer, maxLength: buffer.count)
                stream.close()
                if count > 0 { bodyData = Data(buffer.prefix(count)) }
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            XCTAssertEqual(body["state"] as? String, "Please review the attached document.")
            let data = Data("""
                {"answers":{"tone":{"type":"choice","choice":"formal","probabilities":{"formal":0.9,"standard":0.1,"casual":0}}}}
                """.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let latency = try await JevToneService.testConnection(key: "test-key", session: session)
        XCTAssertGreaterThanOrEqual(latency, 0)

        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        do {
            _ = try await JevToneService.testConnection(key: "bad-key", session: session)
            XCTFail("Unauthorized key should fail the connection test")
        } catch {
            XCTAssertEqual(error.localizedDescription, L("Jev API Key 无效或无权限"))
        }
    }

    func testAutoToneIsFrozenForTranslationAndHistory() async throws {
        let settings = settings()
        var tones: [Tone] = []
        let engine = TranslationEngine(settings: settings, stream: { _, _, tone, _, _ in
            tones.append(tone)
            return AsyncThrowingStream { continuation in
                continuation.yield("Please review the proposal.")
                continuation.finish()
            }
        }, toneClassifier: { text, key in
            XCTAssertEqual(text, "请审阅这份方案。")
            XCTAssertEqual(key, "test-key")
            return .formal
        })
        engine.input = "请审阅这份方案。"
        engine.translate()
        try await waitUntilDone(engine)
        XCTAssertEqual(tones, [.formal])
        XCTAssertEqual(engine.resolvedTone, .formal)
        XCTAssertEqual(engine.history.first?.tone, .formal)
        XCTAssertEqual(settings.tone, .automatic)
    }

    func testClassifierFailureFallsBackAndOldDecisionCannotStartTranslation() async throws {
        let settings = settings()
        var inputs: [String] = []
        let engine = TranslationEngine(settings: settings, stream: { text, _, tone, _, _ in
            inputs.append(text)
            XCTAssertEqual(tone, .standard)
            return AsyncThrowingStream { continuation in
                continuation.yield("Current translation")
                continuation.finish()
            }
        }, toneClassifier: { text, _ in
            if text == "旧文本" {
                try? await Task.sleep(for: .milliseconds(80))
                return .formal
            }
            throw URLError(.timedOut)
        })
        engine.input = "旧文本"
        engine.translate()
        engine.input = "新文本"
        engine.translate()
        try await waitUntilDone(engine)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(inputs, ["新文本"])
        XCTAssertEqual(engine.resolvedTone, .standard)
        XCTAssertNotNil(engine.toneDecisionNote)
        XCTAssertEqual(engine.history.first?.tone, .standard)
    }
}
