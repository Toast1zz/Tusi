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
        let englishURL = resources.appendingPathComponent("en.lproj/Localizable.strings")
        let chineseURL = resources.appendingPathComponent("zh-Hans.lproj/Localizable.strings")
        let english = try Self.entries(in: englishURL)
        let chinese = try Self.entries(in: chineseURL)
        XCTAssertFalse(english.values.isEmpty)
        XCTAssertTrue(english.duplicates.isEmpty, "Duplicate keys in en.lproj/Localizable.strings: \(english.duplicates)")
        XCTAssertTrue(chinese.duplicates.isEmpty, "Duplicate keys in zh-Hans.lproj/Localizable.strings: \(chinese.duplicates)")
        XCTAssertEqual(
            Set(chinese.values.keys), Set(english.values.keys),
            "zh-Hans.lproj must contain every key shipped in en.lproj"
        )
        let mismatched = chinese.values.filter { $0.key != $0.value }.map(\.key).sorted()
        XCTAssertTrue(mismatched.isEmpty, "zh-Hans values must equal their keys: \(mismatched)")

        for (label, url, parsed) in [("en", englishURL, english.values), ("zh-Hans", chineseURL, chinese.values)] {
            let plist = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: url),
                options: [],
                format: nil
            ) as? [String: String]
            let dict = try XCTUnwrap(plist, "\(label) Localizable.strings must parse as [String: String]")
            XCTAssertEqual(Set(dict.keys), Set(parsed.keys), "\(label) PropertyList key count must match scanner")
        }
    }

    private static func entries(in url: URL) throws -> (values: [String: String], duplicates: [String]) {
        let text = try String(contentsOf: url, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"^"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)";\s*$"#, options: [.anchorsMatchLines])
        let range = NSRange(text.startIndex..., in: text)
        var result: [String: String] = [:]
        var duplicates: [String] = []
        pattern.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match,
                  let keyRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text) else { return }
            let key = String(text[keyRange])
            if result[key] != nil {
                duplicates.append(key)
            }
            result[key] = String(text[valueRange])
        }
        return (result, duplicates)
    }
}
