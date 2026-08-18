import AppKit
import XCTest
@testable import Tusi

/// Tests for the sound integration: a single completion cue (`success`, uisfx "scifi"
/// pack) played when a translation result has fully arrived. Everything else is
/// deliberately silent.
@MainActor
final class SoundTests: XCTestCase {
    private let player = SoundPlayer.shared

    override func setUp() {
        super.setUp()
        player.enabled = true
        player.volume = 0.7
        player.debugResetPlayedFlag()
        // Wipe the preview scratch suite so sound preferences never leak between tests.
        UserDefaults.standard.removePersistentDomain(forName: "com.tusi.preview.scratch")
    }

    // MARK: - Success cue timing

    func testSuccessfulTranslationPlaysSuccessAfterResultArrives() async throws {
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.profiles[0] = APIProfile(baseURL: "https://example.com/v1", apiKey: "k", model: "m")

        // A slow stream: the cue must not play until the stream actually finishes.
        let engine = TranslationEngine(settings: settings) { _, _, _, _, _ in
            AsyncThrowingStream { continuation in
                Task {
                    try? await Task.sleep(for: .milliseconds(50))
                    continuation.yield("你好")
                    continuation.finish()
                }
            }
        }
        engine.input = "hello"
        engine.translate()

        // Immediately after start, nothing should have played yet.
        XCTAssertFalse(player.hasPlayedSuccess)
        try await waitUntil { engine.state == .done }
        XCTAssertEqual(engine.output, "你好")
        XCTAssertTrue(player.hasPlayedSuccess)
    }

    func testFailedTranslationPlaysNoSound() async throws {
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.profiles[0] = APIProfile(baseURL: "https://example.com/v1", apiKey: "k", model: "m")
        let engine = TranslationEngine(settings: settings) { _, _, _, _, _ in
            AsyncThrowingStream { continuation in
                continuation.finish(throwing: TranslationError.http(500, "boom"))
            }
        }
        engine.input = "hello"
        engine.translate()
        try await waitUntil {
            if case .failed = engine.state { return true }
            return false
        }
        XCTAssertFalse(player.hasPlayedSuccess)
    }

    func testCancelledTranslationPlaysNoSound() async throws {
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.profiles[0] = APIProfile(baseURL: "https://example.com/v1", apiKey: "k", model: "m")
        let engine = TranslationEngine(settings: settings) { _, _, _, _, _ in
            AsyncThrowingStream { continuation in
                _ = continuation  // never finishes
            }
        }
        engine.input = "hello"
        engine.translate()
        XCTAssertTrue(engine.isTranslating)
        engine.cancelTranslation()
        XCTAssertFalse(player.hasPlayedSuccess)
    }

    // MARK: - Preference

    func testSoundPreferencePersistsAndRestores() {
        // Preview stores wipe their own suite on init, so the persistence round-trip
        // must go through the real UserDefaults.standard. Save the current values and
        // restore them afterwards so the test never clobbers a real user's prefs.
        let defaults = UserDefaults.standard
        let savedEnabled = defaults.object(forKey: "soundEnabled")
        let savedVolume = defaults.object(forKey: "soundVolume")
        defer {
            if let savedEnabled {
                defaults.set(savedEnabled, forKey: "soundEnabled")
            } else {
                defaults.removeObject(forKey: "soundEnabled")
            }
            if let savedVolume {
                defaults.set(savedVolume, forKey: "soundVolume")
            } else {
                defaults.removeObject(forKey: "soundVolume")
            }
        }

        defaults.set(false, forKey: "soundEnabled")
        defaults.set(0.4, forKey: "soundVolume")

        let settings = SettingsStore(preview: false)
        XCTAssertFalse(settings.soundEnabled)
        XCTAssertEqual(settings.soundVolume, 0.4, accuracy: 0.001)
        // The shared player picked up the restored preference too.
        XCTAssertFalse(player.enabled)
        XCTAssertEqual(player.volume, 0.4, accuracy: 0.001)
    }

    func testEnabledDefaultsTrueAndVolumeDefaults07() {
        let settings = SettingsStore(preview: true)
        XCTAssertTrue(settings.soundEnabled)
        XCTAssertEqual(settings.soundVolume, 0.7, accuracy: 0.001)
    }

    func testDisablingPreventsSuccessCue() async throws {
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.soundEnabled = false
        settings.profiles[0] = APIProfile(baseURL: "https://example.com/v1", apiKey: "k", model: "m")
        let engine = TranslationEngine(settings: settings) { _, _, _, _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield("你好")
                continuation.finish()
            }
        }
        engine.input = "hello"
        engine.translate()
        try await waitUntil { engine.state == .done }
        XCTAssertEqual(engine.output, "你好")
        XCTAssertFalse(player.hasPlayedSuccess)
    }

    func testPreviewPlaysEvenWhenSoundDisabled() {
        let settings = SettingsStore(preview: true)
        settings.soundEnabled = false
        XCTAssertFalse(settings.soundEnabled)

        // The 试听 button must still play the cue so the user can judge it before
        // enabling — it bypasses the enabled flag.
        _ = player.previewSuccess()
        XCTAssertTrue(player.hasPreviewed)
        XCTAssertFalse(player.hasPlayedSuccess)
    }

    // MARK: - Helpers

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }
}
