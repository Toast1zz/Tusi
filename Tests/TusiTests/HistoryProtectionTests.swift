import AppKit
import XCTest
@testable import Tusi

@MainActor
final class HistoryProtectionTests: XCTestCase {
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
    func testUnknownHistoryMustNotBeOverwrittenAfterReadFailure() async throws {
        var writes = 0
        let storage = TranslationStorage(read: { url in
            if url.lastPathComponent == "history.json" { throw CocoaError(.fileReadNoPermission) }
            return nil
        }, write: { _, url in if url.lastPathComponent == "history.json" { writes += 1 } })
        let e = TranslationEngine(settings: settings(), storage: storage, clipboard: .init(write: { _ in true }), stream: { _, _, _, _, _ in
            AsyncThrowingStream { $0.yield("Hello"); $0.finish() }
        })
        XCTAssertNotNil(e.persistenceError)
        e.input = "你好"
        e.translate()
        try await settle { e.state == .done }
        XCTAssertEqual(writes, 0, "unknown pre-existing history must be recovered or preserved before replacing it")
        XCTAssertNotNil(e.persistenceError, "new write does not recover unseen history")
    }
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testMalformedHistoryMustBeReportedAndQuarantined() throws {
        let directory = try temporaryDirectory()
        let original = directory.appendingPathComponent("history.json")
        let bytes = Data("{broken".utf8)
        try bytes.write(to: original)
        let storage = TranslationStorage(read: { try TranslationStorage.disk.read(directory.appendingPathComponent($0.lastPathComponent)) }, write: { try TranslationStorage.disk.write($0, directory.appendingPathComponent($1.lastPathComponent)) }, move: { try FileManager.default.moveItem(at: directory.appendingPathComponent($0.lastPathComponent), to: directory.appendingPathComponent($1.lastPathComponent)) })
        let e = TranslationEngine(settings: settings(), storage: storage)
        XCTAssertNotNil(e.persistenceError)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let quarantined = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("history.corrupt-") })
        XCTAssertEqual(try Data(contentsOf: quarantined), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        e.clearHistory()
        XCTAssertNil(e.persistenceError)
        XCTAssertEqual(try Data(contentsOf: original), Data("[]".utf8))
    }

    func testFailedQuarantineBlocksWritesUntilExplicitClear() {
        var writes = 0
        let storage = TranslationStorage(read: { _ in Data("{broken".utf8) }, write: { _, _ in writes += 1 }, move: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        let e = TranslationEngine(settings: settings(), storage: storage)
        XCTAssertNotNil(e.persistenceError)
        e.pruneExpiredHistory()
        XCTAssertEqual(writes, 0)
        e.clearHistory()
        XCTAssertEqual(writes, 1)
        XCTAssertNil(e.persistenceError)
    }

    func testDisablingHistoryAuthorizesDeletionAfterReadFailure() {
        var deletions = 0
        let s = settings()
        let storage = TranslationStorage(read: { _ in throw CocoaError(.fileReadNoPermission) }, write: { data, _ in
            XCTAssertNil(data)
            deletions += 1
        })
        let e = TranslationEngine(settings: s, storage: storage)
        s.saveHistoryEnabled = false
        e.historyPreferenceChanged()
        XCTAssertEqual(deletions, 1)
        XCTAssertNil(e.persistenceError)
    }

    func testMissingDiskFileReturnsNilAndAllowsHistorySave() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("history.json")
        XCTAssertNil(try TranslationStorage.disk.read(url))
        let storage = TranslationStorage(read: { try TranslationStorage.disk.read(directory.appendingPathComponent($0.lastPathComponent)) }, write: { try TranslationStorage.disk.write($0, directory.appendingPathComponent($1.lastPathComponent)) }, move: { try FileManager.default.moveItem(at: directory.appendingPathComponent($0.lastPathComponent), to: directory.appendingPathComponent($1.lastPathComponent)) })
        let e = TranslationEngine(settings: settings(), storage: storage)
        XCTAssertNil(e.persistenceError)
        e.clearHistory()
        XCTAssertEqual(try Data(contentsOf: url), Data("[]".utf8))
    }

    func testLossyHistoryKeepsGoodRecordsWithoutQuarantine() throws {
        let good = TranslationEngine.Record(id: UUID(), input: "good", output: "output", sourceLabel: "中", source: .chinese, target: .english, tone: .standard, timestamp: Date())
        let record = String(decoding: try JSONEncoder().encode(good), as: UTF8.self)
        let seed = Data("[\(record),{\"input\":\"broken\"}]".utf8)
        let storage = TranslationStorage(read: { _ in seed }, write: { _, _ in XCTFail("Unexpected write") })
        let e = TranslationEngine(settings: settings(), storage: storage)
        XCTAssertEqual(e.history.map(\.input), ["good"])
        XCTAssertNil(e.persistenceError)
    }
}
