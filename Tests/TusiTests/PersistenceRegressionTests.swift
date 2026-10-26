import AppKit
import XCTest
@testable import Tusi

@MainActor
final class PersistenceRegressionTests: XCTestCase {
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
    func testHistoryDeleteFailureMustSurviveSuccessfulDraftWrite() {
        let s = settings()
        let storage = TranslationStorage(read: { _ in nil }, write: { _, url in
            if url.lastPathComponent == "history.json" { throw CocoaError(.fileWriteNoPermission) }
        })
        let e = TranslationEngine(settings: s, draftPersistenceEnabled: true, storage: storage)
        s.saveHistoryEnabled = false
        e.historyPreferenceChanged()
        XCTAssertNotNil(e.persistenceError)
        e.input = "new draft"
        e.flushPendingDraftSave()
        XCTAssertNotNil(e.persistenceError, "an unrelated successful draft write must not hide failed history deletion")
    }
    func testHealthyDraftWriteMustNotHideHistoryReadFailure() {
        let storage = TranslationStorage(read: { url in
            if url.lastPathComponent == "history.json" { throw CocoaError(.fileReadNoPermission) }
            return nil
        }, write: { _, _ in })
        let e = TranslationEngine(settings: settings(), draftPersistenceEnabled: true, storage: storage)
        XCTAssertNotNil(e.persistenceError)
        e.input = "a new draft"
        e.flushPendingDraftSave()
        XCTAssertNotNil(e.persistenceError, "history read failure remains unresolved")
    }
    func testHistorySuccessMustNotHideDraftWriteFailure() {
        let storage = TranslationStorage(read: { _ in nil }, write: { _, url in
            if url.lastPathComponent == "draft.txt" { throw CocoaError(.fileWriteNoPermission) }
        })
        let e = TranslationEngine(settings: settings(), draftPersistenceEnabled: true, storage: storage)
        e.input = "new draft"
        e.flushPendingDraftSave()
        XCTAssertNotNil(e.persistenceError)
        e.clearHistory()
        XCTAssertNotNil(e.persistenceError)
    }

    func testHistoryDeletionRetriesAndClearsOnlyItsOwnError() {
        var failDeletion = true
        var attempts = 0
        let s = settings()
        let storage = TranslationStorage(read: { _ in nil }, write: { data, url in
            guard url.lastPathComponent == "history.json", data == nil else { return }
            attempts += 1
            if failDeletion { throw CocoaError(.fileWriteNoPermission) }
        })
        let e = TranslationEngine(settings: s, storage: storage)
        s.saveHistoryEnabled = false
        e.historyPreferenceChanged()
        XCTAssertEqual(attempts, 1)
        XCTAssertNotNil(e.persistenceError)
        failDeletion = false
        e.clearHistory()
        XCTAssertEqual(attempts, 2)
        XCTAssertNil(e.persistenceError)
    }

    func testReadFailureUsesReadErrorCopy() {
        let storage = TranslationStorage(read: { _ in throw CocoaError(.fileReadNoPermission) }, write: { _, _ in })
        let e = TranslationEngine(settings: settings(), storage: storage)
        XCTAssertEqual(e.persistenceError, L("本机读取失败，请检查磁盘空间或文件权限"))
    }
}
