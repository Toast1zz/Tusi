import Foundation
import XCTest
@testable import Tusi

class IsolatedPersistenceTestCase: XCTestCase {
    @MainActor private lazy var persistenceDirectory: URL = {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tusi-test-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }()

    @MainActor var testHistoryURL: URL { persistenceDirectory.appendingPathComponent("history.json") }
    @MainActor var testDraftURL: URL { persistenceDirectory.appendingPathComponent("draft.txt") }

    @MainActor var testStorage: TranslationStorage {
        let directory = persistenceDirectory
        return TranslationStorage(
            read: { try TranslationStorage.disk.read(directory.appendingPathComponent($0.lastPathComponent)) },
            write: { try TranslationStorage.disk.write($0, directory.appendingPathComponent($1.lastPathComponent)) },
            move: { try FileManager.default.moveItem(at: directory.appendingPathComponent($0.lastPathComponent),
                                                   to: directory.appendingPathComponent($1.lastPathComponent)) }
        )
    }

    @MainActor func isolatedSettings(credentialStorage: CredentialStorage? = nil) -> SettingsStore {
        let suite = "com.tusi.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return SettingsStore(preview: true, credentialStorage: credentialStorage, defaultsOverride: defaults)
    }
}
