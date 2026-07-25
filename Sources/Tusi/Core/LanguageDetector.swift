import Foundation
import NaturalLanguage

enum TargetLanguage {
    case english
    case chinese

    var promptName: String {
        switch self {
        case .english: return "natural, idiomatic English"
        case .chinese: return "natural, idiomatic Simplified Chinese (简体中文)"
        }
    }
}

/// Register the translation should land in. Kept to three because the choice has to be
/// made in one glance from the bottom bar — more options would turn it into a form.
/// Declaration order is the on-screen order: the three read as one spectrum from loose
/// to buttoned-up, with 标准 sitting between them.
enum Tone: String, CaseIterable, Identifiable {
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

    /// Decides the translation direction: Chinese input → English, anything else → Chinese.
    /// Returns the target language plus a short label for the detected source language.
    ///
    /// The decision is script-based rather than NLLanguageRecognizer's dominant-language
    /// guess. The question here is binary ("is this Chinese?"), and the recognizer answers
    /// a harder question badly on mixed text — it reads "这个 PR 需要 rebase 一下" as
    /// Spanish and "支持主用 API 和 fallback" as English, because a few Latin tokens
    /// outweigh the Han characters in its probabilities.
    static func detect(_ text: String) -> (target: TargetLanguage, sourceLabel: String) {
        let sample = String(text.prefix(400)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty else { return (.english, "中") }

        // Kana and Hangul are decisive: those scripts are never Chinese, even though
        // Japanese mixes in Han characters (kanji).
        if sample.unicodeScalars.contains(where: isKana) { return (.chinese, "日") }
        if sample.unicodeScalars.contains(where: isHangul) { return (.chinese, "한") }

        // Weigh Han characters against Latin words: one Han character carries roughly
        // one word of meaning, so this compares like with like for mixed-script text.
        // Ties fall to "not Chinese" — "I love 中国" reads as English with a loanword.
        let hanCount = sample.unicodeScalars.filter(isHan).count
        if hanCount > 0, hanCount > latinWordCount(in: sample) {
            return (.english, "中")
        }

        recognizer.reset()
        recognizer.processString(sample)
        guard let language = recognizer.dominantLanguage else { return (.chinese, "文A") }
        return (.chinese, shortLabel(for: language))
    }

    // MARK: - Script tests

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF,    // CJK Unified Ideographs
             0x3400...0x4DBF,    // Extension A
             0xF900...0xFAFF,    // Compatibility Ideographs
             0x20000...0x2A6DF:  // Extension B
            return true
        default:
            return false
        }
    }

    private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x309F,  // Hiragana
             0x30A0...0x30FF,  // Katakana
             0x31F0...0x31FF:  // Katakana phonetic extensions
            return true
        default:
            return false
        }
    }

    private static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0xAC00...0xD7AF,  // Hangul syllables
             0x1100...0x11FF,  // Jamo
             0x3130...0x318F:  // Compatibility jamo
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
