import Foundation

/// User-facing compatibility preference. Automatic protocol negotiation is the normal
/// path; plain text is the escape hatch for gateways that only implement the basic
/// OpenAI-compatible content stream.
enum TranslationProtocolPreference: String, Codable, CaseIterable, Hashable, Sendable {
    case automatic
    case plainText
}

/// Internal wire format used to ask a provider for one translation payload. These cases
/// are deliberately not exposed as four settings: capability probing chooses among them.
enum TranslationOutputProtocol: String, Codable, Equatable, CaseIterable, Sendable {
    case strictJSONSchema
    case forcedToolCall
    case jsonObject
    case plainText

    var statusLabel: String {
        switch self {
        case .strictJSONSchema: return L("结构化输出")
        case .forcedToolCall: return L("工具输出")
        case .jsonObject: return L("JSON 兼容")
        case .plainText: return L("纯文本兼容")
        }
    }

    var promptSuffix: String {
        switch self {
        case .strictJSONSchema, .jsonObject:
            return """
            Place only the final translation in the JSON field "translation". Do not put \
            labels, explanations, notes, or surrounding quotation marks inside that field.
            """
        case .forcedToolCall:
            return """
            Call submit_translation exactly once. Put only the final translation in its \
            translation argument. Do not emit a normal assistant answer.
            """
        case .plainText:
            return ""
        }
    }

    /// Top-level Chat Completions fields added for this protocol. Kept separate from the
    /// common request body so tests can prove that plain-text compatibility stays clean.
    var requestAdditions: [String: Any] {
        switch self {
        case .strictJSONSchema:
            return [
                "response_format": [
                    "type": "json_schema",
                    "json_schema": [
                        "name": "translation_result",
                        "strict": true,
                        "schema": Self.translationSchema(),
                    ],
                ],
            ]
        case .forcedToolCall:
            return [
                "tools": [[
                    "type": "function",
                    "function": [
                        "name": "submit_translation",
                        "description": "Submit only the final translation in the requested target language.",
                        "strict": true,
                        "parameters": Self.translationSchema(),
                    ],
                ]],
                "tool_choice": [
                    "type": "function",
                    "function": ["name": "submit_translation"],
                ],
                "parallel_tool_calls": false,
            ]
        case .jsonObject:
            return ["response_format": ["type": "json_object"]]
        case .plainText:
            return [:]
        }
    }

    private static func translationSchema() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "translation": [
                    "type": "string",
                    "description": "Only the final translation in the requested target language.",
                ],
            ],
            "required": ["translation"],
            "additionalProperties": false,
        ]
    }
}

enum TranslationStructuredOutputError: LocalizedError, Equatable {
    case invalidEnvelope
    case emptyTranslation
    case outputTooLarge
    case multipleToolCalls
    case wrongToolName
    case modelRefusal

    var errorDescription: String? {
        switch self {
        case .emptyTranslation:
            return L("模型没有返回内容")
        case .modelRefusal:
            return L("模型拒绝返回译文，请改写原文或切换服务")
        case .invalidEnvelope, .outputTooLarge, .multipleToolCalls, .wrongToolName:
            return L("模型没有返回可用译文，请重试或切换服务")
        }
    }
}

enum TranslationEnvelopeDecoder {
    static let maxRawBytes = 512 * 1024

    static func decode(_ raw: String) throws -> String {
        guard raw.utf8.count <= maxRawBytes else {
            throw TranslationStructuredOutputError.outputTooLarge
        }
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == Set(["translation"]),
              let translation = dictionary["translation"] as? String
        else {
            throw TranslationStructuredOutputError.invalidEnvelope
        }
        guard !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationStructuredOutputError.emptyTranslation
        }
        return translation
    }
}

struct TranslationToolCallFragment: Equatable {
    var index: Int
    var id: String?
    var name: String?
    var arguments: String?
}

struct DecodedTranslationPayload: Equatable {
    var translation: String
    var discardedAssistantContent: Bool
}

struct TranslationToolCallAccumulator {
    private var index: Int?
    private var id: String?
    private var name: String?
    private var arguments = ""
    private var sawArguments = false
    private(set) var discardedAssistantContent = false

    mutating func noteAssistantContent(_ content: String?) {
        if let content, !content.isEmpty {
            discardedAssistantContent = true
        }
    }

    mutating func append(_ fragment: TranslationToolCallFragment) throws {
        if let index, index != fragment.index {
            throw TranslationStructuredOutputError.multipleToolCalls
        }
        index = fragment.index

        if let fragmentID = fragment.id, !fragmentID.isEmpty {
            if let id, id != fragmentID {
                throw TranslationStructuredOutputError.multipleToolCalls
            }
            id = fragmentID
        }
        if let fragmentName = fragment.name, !fragmentName.isEmpty {
            if let name, name != fragmentName {
                let combined = name + fragmentName
                guard "submit_translation".hasPrefix(combined) else {
                    throw TranslationStructuredOutputError.wrongToolName
                }
                self.name = combined
            } else {
                name = fragmentName
            }
        }
        if let fragmentArguments = fragment.arguments {
            sawArguments = true
            arguments += fragmentArguments
            guard arguments.utf8.count <= TranslationEnvelopeDecoder.maxRawBytes else {
                throw TranslationStructuredOutputError.outputTooLarge
            }
        }
    }

    func finalize() throws -> DecodedTranslationPayload {
        guard index != nil, name == "submit_translation", sawArguments else {
            throw name == nil || name == "submit_translation"
                ? TranslationStructuredOutputError.invalidEnvelope
                : TranslationStructuredOutputError.wrongToolName
        }
        return DecodedTranslationPayload(
            translation: try TranslationEnvelopeDecoder.decode(arguments),
            discardedAssistantContent: discardedAssistantContent
        )
    }
}
