import Foundation
import NaturalLanguage

/// A translation language pair component. Codable for history persistence,
/// Hashable for SwiftUI selection.
struct TranslationLanguage: Codable, Equatable, Hashable {
    var displayName: String
    var apiName: String
    var symbol: String

    static let english = TranslationLanguage(
        displayName: "English",
        apiName: "natural, idiomatic English",
        symbol: "EN"
    )
    static let chinese = TranslationLanguage(
        displayName: "中文",
        apiName: "natural, idiomatic Simplified Chinese (简体中文)",
        symbol: "中"
    )
    static let japanese = TranslationLanguage(
        displayName: "日本語",
        apiName: "natural, idiomatic Japanese",
        symbol: "日"
    )
    static let korean = TranslationLanguage(
        displayName: "한국어",
        apiName: "natural, idiomatic Korean",
        symbol: "한"
    )
    static let french = TranslationLanguage(
        displayName: "Français",
        apiName: "natural, idiomatic French",
        symbol: "FR"
    )
    static let german = TranslationLanguage(
        displayName: "Deutsch",
        apiName: "natural, idiomatic German",
        symbol: "DE"
    )
    static let spanish = TranslationLanguage(
        displayName: "Español",
        apiName: "natural, idiomatic Spanish",
        symbol: "ES"
    )
    static let portuguese = TranslationLanguage(
        displayName: "Português",
        apiName: "natural, idiomatic Portuguese",
        symbol: "PT"
    )
    static let italian = TranslationLanguage(
        displayName: "Italiano",
        apiName: "natural, idiomatic Italian",
        symbol: "IT"
    )
    static let russian = TranslationLanguage(
        displayName: "Русский",
        apiName: "natural, idiomatic Russian",
        symbol: "RU"
    )
    static let arabic = TranslationLanguage(
        displayName: "العربية",
        apiName: "natural, idiomatic Arabic",
        symbol: "AR"
    )
    static let hindi = TranslationLanguage(
        displayName: "हिन्दी",
        apiName: "natural, idiomatic Hindi",
        symbol: "HI"
    )
    static let vietnamese = TranslationLanguage(
        displayName: "Tiếng Việt",
        apiName: "natural, idiomatic Vietnamese",
        symbol: "VI"
    )
    static let thai = TranslationLanguage(
        displayName: "ไทย",
        apiName: "natural, idiomatic Thai",
        symbol: "TH"
    )
    static let indonesian = TranslationLanguage(
        displayName: "Bahasa Indonesia",
        apiName: "natural, idiomatic Indonesian",
        symbol: "ID"
    )
    static let turkish = TranslationLanguage(
        displayName: "Türkçe",
        apiName: "natural, idiomatic Turkish",
        symbol: "TR"
    )
    static let dutch = TranslationLanguage(
        displayName: "Nederlands",
        apiName: "natural, idiomatic Dutch",
        symbol: "NL"
    )

    /// All preset languages, used for the language picker in multi-language mode.
    static let presets: [TranslationLanguage] = [
        .english, .chinese, .japanese, .korean,
        .french, .german, .spanish, .portuguese,
        .italian, .russian, .arabic, .hindi,
        .vietnamese, .thai, .indonesian, .turkish, .dutch
    ]
    /// Fallback for NLLanguage values not in the presets list.
    static func fromNLLanguage(_ nl: NLLanguage) -> TranslationLanguage {
        let display = shortDisplayName(for: nl)
        let raw = nl.rawValue
        return TranslationLanguage(
            displayName: display,
            apiName: "natural, idiomatic \(display)",
            symbol: raw.prefix(2).uppercased()
        )
    }

    private static func shortDisplayName(for language: NLLanguage) -> String {
        let locale = Locale(identifier: "en")
        return locale.localizedString(forLanguageCode: language.rawValue) ?? language.rawValue
    }
}

/// Register the translation should land in. Kept to three because the choice has to be
/// made in one glance from the bottom bar — more options would turn it into a form.
/// Declaration order is the on-screen order: the three read as one spectrum from loose
/// to buttoned-up, with 标准 sitting between them.
enum Tone: String, CaseIterable, Identifiable, Codable {
    case casual
    case standard
    case formal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return L("标准")
        case .formal: return L("正式")
        case .casual: return L("口语")
        }
    }

    var help: String {
        switch self {
        case .standard: return L("忠实自然，适合大多数场合")
        case .formal: return L("书面、专业，适合邮件、文档")
        case .casual: return L("轻松口语，适合聊天、社交")
        }
    }

    var promptInstruction: String {
        switch self {
        case .standard:
            return "Use a neutral register that faithfully matches the source's own tone."
        case .formal:
            return "Use a polished, professional register suitable for business email and documentation. Prefer complete sentences and precise vocabulary; avoid slang and contractions."
        case .casual:
            return "Use a relaxed, conversational register suitable for chat and social posts. Contractions and everyday word choices are welcome; avoid stiff or bureaucratic phrasing."
        }
    }
}

enum LanguageDetector {
    private static let recognizer: NLLanguageRecognizer = {
        // NLLanguageRecognizer is designed for reuse — create once, reset() between uses.
        NLLanguageRecognizer()
    }()

    /// Detects the source language of the input text. In simple (CN↔EN) mode the
    /// caller derives the target from the source; in multi-language mode the caller
    /// uses the user's selected target. Returns the detected source language plus a
    /// short display label.
    ///
    /// The decision is script-based rather than NLLanguageRecognizer's dominant-language
    /// guess for the CN-vs-not-CN question. The recognizer reads "这个 PR 需要 rebase 一下"
    /// as Spanish and "支持主用 API 和 fallback" as English, because a few Latin tokens
    /// outweigh the Han characters in its probabilities. Script analysis doesn't have that
    /// problem.
    static func detect(_ text: String) -> (source: TranslationLanguage, sourceLabel: String) {
        let sample = String(text.prefix(400)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty else { return (.chinese, "中") }

        // Kana and Hangul are decisive: those scripts are never Chinese, even though
        // Japanese mixes in Han characters (kanji).
        if sample.unicodeScalars.contains(where: isKana) { return (.japanese, "日") }
        if sample.unicodeScalars.contains(where: isHangul) { return (.korean, "한") }

        // Weigh Han characters against Latin words: one Han character carries roughly
        // one word of meaning, so this compares like with like for mixed-script text.
        // Ties fall to "not Chinese" — "I love 中国" reads as English with a loanword.
        let hanCount = sample.unicodeScalars.filter(isHan).count
        if hanCount > 0, hanCount > latinWordCount(in: sample) {
            return (.chinese, "中")
        }

        recognizer.reset()
        recognizer.processString(sample)
        guard let language = recognizer.dominantLanguage else { return (.chinese, "文") }
        let detected = TranslationLanguage.fromNLLanguage(language)
        return (detected, shortLabel(for: language))
    }

    // MARK: - Script tests

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2E80...0x2EFF,       // CJK radicals
             0x3000...0x303F,       // CJK punctuation
             0x3400...0x4DBF,       // CJK Unified Extension A
             0x4E00...0x9FFF,       // CJK Unified
             0xF900...0xFAFF,       // CJK Compatibility
             0x20000...0x2FFFF:     // CJK Extension B–F
            return true
        default:
            return false
        }
    }

    private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x309F,       // Hiragana
             0x30A0...0x30FF:       // Katakana
            return true
        default:
            return false
        }
    }

    private static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0xAC00...0xD7AF:       // Hangul syllables
            return true
        default:
            return false
        }
    }

    private static func latinWordCount(in text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            let isLatinLetter = (0x41...0x5A).contains(scalar.value)
                || (0x61...0x7A).contains(scalar.value)
                || (0xC0...0x24F).contains(scalar.value)  // Latin-1 supplement + extended
            if isLatinLetter {
                if !inWord { count += 1; inWord = true }
            } else {
                inWord = false
            }
        }
        return count
    }

    private static func shortLabel(for language: NLLanguage) -> String {
        switch language {
        case .english: return "EN"
        case .japanese: return "日"
        case .korean: return "한"
        case .french: return "FR"
        case .german: return "DE"
        case .spanish: return "ES"
        case .portuguese: return "PT"
        case .italian: return "IT"
        case .russian: return "RU"
        case .vietnamese: return "VI"
        case .thai: return "TH"
        case .arabic: return "AR"
        case .hindi: return "HI"
        case .indonesian: return "ID"
        case .turkish: return "TR"
        case .dutch: return "NL"
        default:
            return language.rawValue.prefix(2).uppercased()
        }
    }
}
