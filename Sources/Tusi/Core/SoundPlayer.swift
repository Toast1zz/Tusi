import AVFoundation
import Foundation

/// Minimal sound engine for Tusi: a single completion cue that plays when a
/// translation result has fully arrived. All other interactions are deliberately
/// silent — the user asked for sound only on the finished result.
///
/// Audio asset is the `success` cue from the `uisfx` npm package (CC0-licensed),
/// `scifi` pack, copied to `Resources/Sounds/scifi/success.mp3`.
@MainActor
final class SoundPlayer {
    static let pack = "scifi"

    /// The one cue the product uses. Validated against the uisfx catalog.
    enum Cue: String {
        case success
    }

    static let shared = SoundPlayer()

    #if DEBUG
    /// Test-only flag: whether the success cue has been played since the last reset.
    /// Lets tests assert cue timing without an audio device.
    private(set) var hasPlayedSuccess = false

    /// Test-only flag: whether the preview cue has been requested since the last reset.
    private(set) var hasPreviewed = false

    /// Test-only reset of the observation flags.
    func debugResetPlayedFlag() {
        hasPlayedSuccess = false
        hasPreviewed = false
    }
    #endif

    /// Whether the completion cue may play. Mirrors the user's "翻译成功音效" preference.
    var enabled: Bool = true {
        didSet {
            guard enabled != oldValue else { return }
            if !enabled {
                // Mute is immediate: silence anything still playing.
                current?.stop()
                current = nil
            }
        }
    }

    /// The audio currently playing, if any. Only one completion cue can be audible at
    /// a time; a new play retriggers it.
    private var current: Handle?
    private var cached: AVAudioPlayer?

    /// Plays the translation-complete cue. Returns nil when sound is disabled or the
    /// asset is missing — callers treat nil as "nothing played", never as a failure.
    @discardableResult
    func playSuccess() -> Handle? {
        guard enabled else { return nil }
        #if DEBUG
        // Record the decision to play regardless of whether the asset loads (tests run
        // without the app bundle, so the load fails there but the intent is what we
        // assert). The enabled guard above means a disabled player never records.
        hasPlayedSuccess = true
        #endif
        guard let audio = audioPlayer() else { return nil }
        current?.stop()
        let handle = Handle(player: audio)
        handle.onCompletion = { [weak self, weak handle] in
            guard let self, let handle, self.current === handle else { return }
            self.current = nil
        }
        configure(audio)
        guard audio.play() else { return nil }
        current = handle
        return handle
    }

    /// Preview helper for the Settings "试听" button: plays the completion cue even
    /// when sound is disabled, so the user can judge the sound before enabling it.
    @discardableResult
    func previewSuccess() -> Handle? {
        #if DEBUG
        hasPreviewed = true
        #endif
        guard let audio = audioPlayer() else { return nil }
        current?.stop()
        let handle = Handle(player: audio)
        handle.onCompletion = { [weak self, weak handle] in
            guard let self, let handle, self.current === handle else { return }
            self.current = nil
        }
        configure(audio)
        guard audio.play() else { return nil }
        current = handle
        return handle
    }

    /// Stops anything playing and releases the cached player (final teardown).
    func destroy() {
        current?.stop()
        current = nil
        cached = nil
    }

    private func configure(_ audio: AVAudioPlayer) {
        audio.currentTime = 0
        audio.numberOfLoops = 0
    }

    private func audioPlayer() -> AVAudioPlayer? {
        if let cached { return cached }
        guard let url = Bundle.main.url(
            forResource: Cue.success.rawValue,
            withExtension: "mp3",
            subdirectory: "Sounds/\(Self.pack)"
        ) else {
            Log.sound.error("completion cue asset missing: Sounds/\(Self.pack)/\(Cue.success.rawValue).mp3")
            return nil
        }
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            Log.sound.error("could not create AVAudioPlayer for completion cue")
            return nil
        }
        player.prepareToPlay()
        cached = player
        return player
    }

    /// Retained handle for the playing cue. Holds the AVAudioPlayer and its delegate;
    /// `stop()` silences it immediately.
    final class Handle: NSObject, AVAudioPlayerDelegate {
        fileprivate let player: AVAudioPlayer
        fileprivate var onCompletion: (() -> Void)?

        fileprivate init(player: AVAudioPlayer) {
            self.player = player
            super.init()
            player.delegate = self
        }

        func stop() {
            player.stop()
        }

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            DispatchQueue.main.async { [weak self] in
                self?.onCompletion?()
            }
        }
    }
}
