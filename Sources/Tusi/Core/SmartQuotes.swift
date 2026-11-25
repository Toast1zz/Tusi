import Foundation

/// Converts straight ASCII quotes into typographic ones.
///
/// The system prompt already asks for typographic punctuation, but cheap models comply
/// unevenly, so the result is normalized here too — a deterministic pass is the only way
/// to actually guarantee it. Text inside code spans and fenced blocks is left byte-exact:
/// curly quotes there would break the code the translation is trying to preserve.
enum SmartQuotes {
    /// A contiguous run of backticks, located up front so unpaired runs can be told
    /// apart from genuine code delimiters.
    private struct BacktickRun {
        let start: Int
        let end: Int
        let length: Int
    }

    static func apply(to text: String) -> String {
        guard text.contains("\"") || text.contains("'") else { return text }

        let characters = Array(text)
        let codeFlags = matchedCodeFlags(in: characters)
        var result = ""
        result.reserveCapacity(characters.count)

        var doubleIsOpen = false
        var singleIsOpen = false
        var previous: Character?
        var index = 0

        while index < characters.count {
            let character = characters[index]

            // Backtick runs and the text between a matched pair are passed through
            // byte-exact — curly quotes there would break the code being preserved.
            // A run whose partner never appears (a stray ` from a half-finished
            // markdown edit) is NOT code: leaving it unpaired keeps one orphan
            // backtick from disabling quote conversion for the rest of the text.
            if codeFlags[index] {
                if character == "`" {
                    var end = index
                    while end < characters.count, characters[end] == "`" { end += 1 }
                    result.append(contentsOf: characters[index..<end])
                    previous = "`"
                    index = end
                    continue
                }
                result.append(character)
                previous = character
                index += 1
                continue
            }

            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
            switch character {
            case "\"":
                let opening = !doubleIsOpen
                doubleIsOpen = opening
                let emitted: Character = opening ? "\u{201C}" : "\u{201D}"
                result.append(emitted)
                previous = emitted
            case "'":
                let prevIsLatin = previous.map(isLatinWordChar) ?? false
                let nextIsLatin = next.map(isLatinWordChar) ?? false
                let emitted: Character
                // Keep intraword apostrophes (don’t, it’s, O’Neill) and unpaired leading/trailing
                // apostrophes (the ’90s, teams’) out of quote pairing state.
                if prevIsLatin && nextIsLatin {
                    emitted = "\u{2019}"
                } else if !singleIsOpen, let next, next.isNumber, !prevIsLatin,
                          !hasClosingSingleQuoteForToken(in: characters, codeFlags: codeFlags, from: index + 1) {
                    emitted = "\u{2019}"
                } else if !singleIsOpen, prevIsLatin, !(next.map(isCJK) ?? false) {
                    emitted = "\u{2019}"
                } else {
                    let opening = !singleIsOpen
                    singleIsOpen = opening
                    emitted = opening ? "\u{2018}" : "\u{2019}"
                }
                result.append(emitted)
                previous = emitted
            default:
                result.append(character)
                previous = character
                // Reset quote parity across blank lines so an unclosed quote never
                // inverts later paragraphs.
                if character.isNewline,
                   isFollowedByBlankLine(in: characters, codeFlags: codeFlags, after: index) {
                    doubleIsOpen = false
                    singleIsOpen = false
                }
            }
            index += 1
        }
        return result
    }

    /// Fence contents stay protected through the closing line or the end of input.
    /// Inline backtick pairs are matched only within lines outside fences.
    private static func matchedCodeFlags(in characters: [Character]) -> [Bool] {
        var flags = [Bool](repeating: false, count: characters.count)
        var fence: (character: Character, length: Int)?
        var start = 0
        while start < characters.count {
            var end = start
            while end < characters.count, !characters[end].isNewline { end += 1 }
            let next = end < characters.count ? end + 1 : end
            var marker = start
            while marker < end, characters[marker] == " ", marker - start < 4 { marker += 1 }
            var runEnd = marker
            if marker - start <= 3, marker < end,
               characters[marker] == "`" || characters[marker] == "~" {
                while runEnd < end, characters[runEnd] == characters[marker] { runEnd += 1 }
            }
            let length = runEnd - marker
            if let current = fence {
                for position in start..<next { flags[position] = true }
                if length >= current.length, characters[marker] == current.character,
                   characters[runEnd..<end].allSatisfy({ $0.isWhitespace }) {
                    fence = nil
                }
            } else if length >= 3, characters[marker] == "~" || !characters[runEnd..<end].contains("`") {
                fence = (characters[marker], length)
                for position in start..<next { flags[position] = true }
            } else {
                var runs: [BacktickRun] = []
                var index = start
                while index < end {
                    if characters[index] == "`" {
                        var finish = index + 1
                        while finish < end, characters[finish] == "`" { finish += 1 }
                        runs.append(BacktickRun(start: index, end: finish, length: finish - index))
                        index = finish
                    } else {
                        index += 1
                    }
                }
                index = 0
                while index < runs.count {
                    let opening = runs[index]
                    if let closing = runs[(index + 1)...].firstIndex(where: { $0.length == opening.length }) {
                        for position in opening.start..<runs[closing].end { flags[position] = true }
                        index = closing + 1
                    } else {
                        index += 1
                    }
                }
            }
            start = next
        }
        return flags
    }

    private static func isLatinWordChar(_ character: Character) -> Bool {
        (character.isLetter || character.isNumber) && !isCJK(character)
    }

    private static func hasClosingSingleQuoteForToken(
        in characters: [Character],
        codeFlags: [Bool],
        from start: Int
    ) -> Bool {
        var cursor = start
        while cursor < characters.count, !codeFlags[cursor], isLatinWordChar(characters[cursor]) {
            cursor += 1
        }
        return cursor < characters.count && !codeFlags[cursor] && characters[cursor] == "'"
    }

    private static func isFollowedByBlankLine(
        in characters: [Character],
        codeFlags: [Bool],
        after newlineIndex: Int
    ) -> Bool {
        var cursor = newlineIndex + 1
        while cursor < characters.count, !codeFlags[cursor],
              characters[cursor] == " " || characters[cursor] == "\t" {
            cursor += 1
        }
        return cursor < characters.count && !codeFlags[cursor] && characters[cursor].isNewline
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x303F,    // CJK punctuation: 。，、：；「」
             0x3040...0x30FF,    // Kana
             0x3400...0x4DBF,    // Han extension A
             0x4E00...0x9FFF,    // Han
             0xAC00...0xD7AF,    // Hangul
             0xF900...0xFAFF,    // Han compatibility
             0xFF00...0xFFEF:    // Fullwidth forms: ！？（）
            return true
        default:
            return false
        }
    }
}
