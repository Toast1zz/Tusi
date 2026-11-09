import Foundation
import XCTest

/// The shipped app has only what `build.sh` copies from `Sources/Tusi/Resources/*.lproj`.
/// Without a zh-Hans table, macOS treats `en` as the only available localization and
/// can show English UI (and English date formats) on a Chinese system.
final class LocalizationCatalogTests: XCTestCase {
    func testChineseTableCoversEnglishKeysWithIdentityValues() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Tusi/Resources")
        let english = try Self.entries(in: resources.appendingPathComponent("en.lproj/Localizable.strings"))
        let chinese = try Self.entries(in: resources.appendingPathComponent("zh-Hans.lproj/Localizable.strings"))
        XCTAssertFalse(english.isEmpty)
        XCTAssertEqual(
            Set(chinese.keys), Set(english.keys),
            "zh-Hans.lproj must contain every key shipped in en.lproj"
        )
        let mismatched = chinese.filter { $0.key != $0.value }.map(\.key).sorted()
        XCTAssertTrue(mismatched.isEmpty, "zh-Hans values must equal their keys: \(mismatched)")
    }

    private static func entries(in url: URL) throws -> [String: String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"^"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)";\s*$"#, options: [.anchorsMatchLines])
        let range = NSRange(text.startIndex..., in: text)
        var result: [String: String] = [:]
        pattern.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match,
                  let keyRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text) else { return }
            result[String(text[keyRange])] = String(text[valueRange])
        }
        return result
    }
}
