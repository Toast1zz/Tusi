import AppKit
import XCTest
@testable import Tusi

@MainActor
final class TranslationRegressionTests: XCTestCase {
    func settings() -> SettingsStore {
        let suite = "com.tusi.test.regression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let s = SettingsStore(preview: true, defaultsOverride: defaults)
        s.soundEnabled = false
        s.autoCopy = true
        s.profiles[0] = APIProfile(baseURL: "https://example.invalid/v1", apiKey: "fake", model: "fake")
        return s
    }
    var memory: TranslationStorage { TranslationStorage(read: { _ in nil }, write: { _, _ in }) }
    func settle(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<100 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("condition timed out")
    }
    func testOversizedPasteMustInvalidateOldResultAndUpdateDirection() {
        let e = TranslationEngine(settings: settings(), storage: memory, clipboard: .init(write: { _ in true }))
        e.debugPreview(input: "你好", output: "Hello")
        e.input = String(repeating: "English text. ", count: 3000)
        XCTAssertEqual(e.input.count, 32_000)
        XCTAssertTrue(e.inputWasTruncated)
        XCTAssertEqual(e.target, .chinese, "new English source must update direction")
        XCTAssertEqual(e.state, .idle, "old result must be invalidated")
        XCTAssertTrue(e.output.isEmpty, "old output must not remain under new source")
    }

    func testOversizedPasteMustNotCommitOldRequestOrCopyIt() async throws {
        var producer: AsyncThrowingStream<String, Error>.Continuation?
        var copied: [String] = []
        let e = TranslationEngine(settings: settings(), storage: memory, clipboard: .init(write: { copied.append($0); return true }), stream: { _, _, _, _, _ in
            AsyncThrowingStream { producer = $0 }
        })
        e.input = "你好"
        e.translate()
        try await settle { producer != nil }
        e.input = String(repeating: "English text. ", count: 3000)
        producer?.yield("Hello from the OLD request")
        producer?.finish()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(e.output.isEmpty, "old network response must not commit")
        XCTAssertTrue(copied.isEmpty, "old translation must not auto-copy")
        XCTAssertTrue(e.history.isEmpty, "old response must not archive as current")
    }

    func testOversizedPasteMustPersistLatestDraft() {
        var written: String?
        let storage = TranslationStorage(read: { _ in nil }, write: { data, url in if url.lastPathComponent == "draft.txt" { written = data.map { String(decoding: $0, as: UTF8.self) } } })
        let e = TranslationEngine(settings: settings(), draftPersistenceEnabled: true, storage: storage)
        e.input = "old draft"
        e.flushPendingDraftSave()
        e.input = String(repeating: "x", count: 32_001)
        e.flushPendingDraftSave()
        XCTAssertEqual(written?.count, 32_000, "latest capped draft must replace the old draft")
    }

    func testCodeBlockCorruptionReachesAutoCopy() async throws {
        var copied: [String] = []
        let code = "~~~python\nprint(\"hello\")\n~~~"
        let e = TranslationEngine(settings: settings(), storage: memory, clipboard: .init(write: { copied.append($0); return true }), stream: { _, _, _, _, _ in
            AsyncThrowingStream { $0.yield(code); $0.finish() }
        })
        e.input = "显示以下代码"
        e.translate()
        try await settle { e.state == .done }
        XCTAssertEqual(e.output, code, "code must stay byte-exact at commit")
        XCTAssertEqual(copied, [code], "auto-copy must preserve code")
    }

    func testTildeFenceMustKeepCodeByteExact() {
        let code = "~~~python\nprint(\"hello\")\n~~~"
        XCTAssertEqual(SmartQuotes.apply(to: code), code)
    }

    func testBacktickInsideFenceMustNotDisableCodeProtection() {
        let code = "```python\n# literal ` character\nprint(\"hello\")\n```"
        XCTAssertEqual(SmartQuotes.apply(to: code), code)
    }
    func testFenceLengthsIndentationAndUnclosedBlocksPreserveCode() {
        let samples = [
            "````python\n```\nprint(\"hello\")\n````",
            "   ~~~python\nprint(\"hello\")\n   ~~~~  ",
            "```python\nprint(\"hello\")",
            "~~~python\n```\nprint(\"hello\")\n~~~",
            "````python\n```\nx = \"y\"\n````",
            "`\"x\"`",
            "``a ` \"x\"``",
        ]
        for sample in samples { XCTAssertEqual(SmartQuotes.apply(to: sample), sample) }
        XCTAssertEqual(SmartQuotes.apply(to: "    ~~~\n\"prose\""), "    ~~~\n“prose”")
        XCTAssertEqual(SmartQuotes.apply(to: "`orphan\n\"prose\"\n`"), "`orphan\n“prose”\n`")
    }
}
