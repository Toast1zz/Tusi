import Foundation

enum JevToneError: LocalizedError {
    case http(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .http(401), .http(403): return L("Jev API Key 无效或无权限")
        case .http(429): return L("Jev 请求过于频繁，请稍后重试")
        case .http(let status): return String(format: L("Jev 服务返回错误（%d）"), status)
        case .invalidResponse: return L("Jev 返回了无效的判断结果")
        }
    }
}

enum JevToneService {
    private static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

    private struct Request: Encodable {
        let model = "jev-latest"
        let state: String
        let questions: [String: Question]
    }

    private struct Question: Encodable {
        let type = "choice"
        let instructions = "Choose the best register for translating this source text. Choose standard when context is unclear. Judge the intended use, not just punctuation or vocabulary."
        let criteria = [
            "casual": "Personal chat, informal messages, or conversational social posts.",
            "standard": "Neutral writing, mixed or unclear context, and short ambiguous text.",
            "formal": "Business correspondence, official notices, professional documents, or clearly formal writing."
        ]
    }

    private struct Response: Decodable {
        let answers: [String: Answer]
    }

    private struct Answer: Decodable {
        let choice: String
        let probabilities: [String: Double]
    }

    static func testConnection(key: String, session: URLSession = .shared) async throws -> Int {
        let start = ProcessInfo.processInfo.systemUptime
        _ = try await evaluate(text: "Please review the attached document.", key: key, session: session)
        return Int((ProcessInfo.processInfo.systemUptime - start) * 1_000)
    }

    static func classify(text: String, key: String, session: URLSession = .shared) async throws -> Tone {
        let answer = try await evaluate(text: text, key: key, session: session)
        guard let tone = Tone(rawValue: answer.choice), tone != .automatic,
              let probability = answer.probabilities[answer.choice], probability >= 0.7,
              probability - (answer.probabilities.filter { $0.key != answer.choice }.values.max() ?? 0) >= 0.2
        else { return .standard }
        return tone
    }

    private static func evaluate(text: String, key: String, session: URLSession) async throws -> Answer {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(
            state: text,
            questions: ["tone": Question()]
        ))

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw JevToneError.invalidResponse }
        guard response.statusCode == 200 else { throw JevToneError.http(response.statusCode) }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw JevToneError.invalidResponse
        }
        let answer = decoded.answers["tone"]
        guard let answer,
              let tone = Tone(rawValue: answer.choice), tone != .automatic,
              let probability = answer.probabilities[answer.choice], (0...1).contains(probability)
        else { throw JevToneError.invalidResponse }
        return answer
    }
}
