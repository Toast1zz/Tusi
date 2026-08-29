import AppKit
import Combine
import Foundation

@MainActor
final class TranslationEngine: ObservableObject {
    enum State: Equatable {
        case idle
        case translating
        case done
        case failed(String)
    }

    struct Record: Identifiable, Equatable, Codable {
        let id: UUID
        let input: String
        let output: String
        /// History stores a bounded snapshot rather than the full panel text. These
        /// flags keep restored entries honest instead of presenting an archive excerpt
        /// as a complete translation.
        let inputTruncated: Bool
        let outputTruncated: Bool
        let sourceLabel: String
        let source: TranslationLanguage
        let target: TranslationLanguage
        let tone: Tone
        let timestamp: Date

        init(
            id: UUID,
            input: String,
            output: String,
            inputTruncated: Bool = false,
            outputTruncated: Bool = false,
            sourceLabel: String,
            source: TranslationLanguage,
            target: TranslationLanguage,
            tone: Tone,
            timestamp: Date
        ) {
            self.id = id
            self.input = input
            self.output = output
            self.inputTruncated = inputTruncated
            self.outputTruncated = outputTruncated
            self.sourceLabel = sourceLabel
            self.source = source
            self.target = target
            self.tone = tone
            self.timestamp = timestamp
        }

        var isTruncated: Bool { inputTruncated || outputTruncated }

        private enum CodingKeys: String, CodingKey {
            case id, input, output, inputTruncated, outputTruncated, sourceLabel, source, target, tone, timestamp
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            input = try container.decode(String.self, forKey: .input)
            output = try container.decode(String.self, forKey: .output)
            inputTruncated = try container.decodeIfPresent(Bool.self, forKey: .inputTruncated) ?? false
            outputTruncated = try container.decodeIfPresent(Bool.self, forKey: .outputTruncated) ?? false
            sourceLabel = try container.decode(String.self, forKey: .sourceLabel)
            source = try container.decode(TranslationLanguage.self, forKey: .source)
            target = try container.decode(TranslationLanguage.self, forKey: .target)
            tone = try container.decode(Tone.self, forKey: .tone)
            timestamp = try container.decode(Date.self, forKey: .timestamp)
        }
    }

    typealias Streamer = (
        _ text: String,
        _ target: TranslationLanguage,
        _ tone: Tone,
        _ extra: String,
        _ config: APIConfig
    ) -> AsyncThrowingStream<String, Error>

    @Published var input = "" {
        didSet {
            guard input != oldValue else { return }
            if input.count > Self.maxInputCharacters {
                inputWasTruncated = true
                // The re-entrant didSet (truncated value) does the real work below while
                // this guard keeps the persistent notice from being cleared immediately.
                isApplyingInputCap = true
                input = String(input.prefix(Self.maxInputCharacters))
                isApplyingInputCap = false
                flashToast(.truncatedInput)
                return
            }
            if !isApplyingInputCap {
                inputWasTruncated = false
            }
            // A manual direction flip is scoped to the input it was set on: any edit
            // drops it, so a stale override can never leak into the next query.
            flipped = false
            updateDirection()
            // Any edit makes the previous result stale. Clearing it also cancels a
            // request for the old text, while the revision check below protects against
            // a final network callback that races with that cancellation.
            inputRevision &+= 1
            clearResult()
        }
    }
    @Published private(set) var output = ""
    @Published private(set) var state: State = .idle
    @Published private(set) var target: TranslationLanguage = .english
    @Published private(set) var source: TranslationLanguage = .chinese
    @Published private(set) var sourceLabel = "中"
    /// Manual direction override: the user tapped the direction chip because the
    /// auto-detected side was wrong. Simple CN↔EN mode only, where the correct
    /// direction is exactly the opposite of the detected one.
    @Published private(set) var flipped = false
    /// Drives the copy button's confirmation. Auto-copy sets it too, so the button is the
    /// single place that reports a copy — no extra chrome competing for the bottom bar.
    @Published private(set) var copied = false

    /// True when the user stopped a stream with partial output already on screen. The
    /// half-finished text is kept (stopping is a deliberate act), but it must not read as
    /// a complete translation — the result view marks it as such.
    @Published private(set) var interrupted = false

    /// True when a finished result was truncated to `maxOutputCharacters`. Comes from
    /// overlong model output (a chatty run that never terminates cleanly), not from the
    /// user — like `interrupted` it keeps the text but flags it as incomplete, and it
    /// suppresses the auto-copy and the success sound.
    @Published private(set) var outputCapped = false

    /// True after a paste or edit exceeded the input ceiling. Unlike the transient Toast,
    /// this remains beside the editor until the user changes the text again.
    @Published private(set) var inputWasTruncated = false

    /// A restored history snapshot may be smaller than the original translation. It
    /// stays copyable, but the result view must make that archival truncation visible.
    @Published private(set) var restoredFromTruncatedHistory = false

    /// What kind of failure `state == .failed` is describing. The message alone can't
    /// tell the error box whether the useful button is "retry" or "open settings" —
    /// retrying a request that has no configured endpoint just fails again in front of
    /// the user. Nil whenever the panel isn't in a failed state.
    @Published private(set) var failureKind: FailureKind?

    /// True when a finished result isn't written in the language it was asked for —
    /// the signature of a model that answered the source text instead of translating it.
    /// Like `outputCapped` the text is kept and shown (the check is a heuristic, and
    /// discarding a possibly-good translation would be worse), but it is flagged and it
    /// suppresses auto-copy and the success sound: silently putting a wrong-language
    /// result on the pasteboard is the actual harm.
    @Published private(set) var outputLanguageMismatch = false

    /// Transient banner shown at the bottom of the panel, then auto-dismissed.
    /// Whether primary or backup served the request is an implementation detail —
    /// the only thing worth surfacing is the one-time "primary failed" notice.
    enum Toast: Equatable {
        case fellBack
        case truncatedInput
        case copyFailed
        /// Race for fastest (SettingsStore.raceFastestEnabled) picked a winner —
        /// carries the winning provider's display host so the one-time notice can
        /// name it, e.g. "api.deepseek.com 更快".
        case raceWon(String)
    }
    @Published private(set) var toast: Toast?

    private let settings: SettingsStore
    private let stream: Streamer
    private var translationTask: Task<Void, Never>?
    private var inputRevision: UInt = 0
    private var toastTask: Task<Void, Never>?
    private var copyResetTask: Task<Void, Never>?
    private var isApplyingInputCap = false

    /// Unpublished accumulation of the in-flight provider's chunks. It is NOT @Published
    /// and never touches the UI: parts only surface once a request commits atomically
    /// (normal completion), or when the user deliberately stops a stream that already
    /// produced content. Keeping it out of `output` is what lets local and online models
    /// behave the same — the display commits once regardless of how fast or in how many
    /// pieces the provider delivers tokens. Reset at the start of every request and every
    /// provider attempt.
    private var pendingOutput = ""
    /// Set as soon as the in-flight buffer reaches the hard output ceiling. This is
    /// separate from `outputCapped`: the latter describes the published result, while
    /// this flag protects the unpublished buffer before a stream has finished.
    private var pendingOutputCapped = false

    /// Ring buffer of completed translations (newest first).
    @Published private(set) var history: [Record] = []
    private let historyCapacity = 50

    /// Per-field cap applied only when archiving into `history` — the panel's own
    /// input/output for the current translation are never touched. Bounds the worst
    /// case for the synchronous history write: without this, 50 records at the input/
    /// output ceilings (32k + 64k each) could reach ~10MB of JSON, and `saveHistory`
    /// encodes and writes on the main thread by design (see its doc comment).
    private static let historyFieldCharacterLimit = 4_000

    /// Hard ceiling for the input box. Pasted documents longer than this are
    /// truncated at the boundary. This bounds the request body and the stored
    /// history records (each record holds the full input).
    static let maxInputCharacters = 32_000

    /// Hard ceiling for a completed result (applied after the stream ends). A model
    /// that rambles far past the input size is cut here — the panel and the history
    /// file never hold an unbounded string, and the synchronous main-thread history
    /// write stays small. Cutting is honest: the result is flagged `outputCapped`.
    static let maxOutputCharacters = 64_000

    // MARK: - History persistence

    /// History file location. Preview runs (TUSI_PREVIEW / preview settings) get a
    /// scratch directory so tests and screenshot runs never read or clobber the
    /// real history.
    private let historyURL: URL

    // Internal (not private): tests reset the preview scratch history between cases.
    static func historyURL(preview: Bool) -> URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        // FileManager guarantees at least one application-support URL in practice; a
        // degraded environment still gets a writable scratch location instead of a crash.
        let dir = (paths.first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(preview ? "com.tusi.preview" : "com.tusi.app", isDirectory: true)
        return dir.appendingPathComponent("history.json")
    }

    init(
        settings: SettingsStore,
        stream: @escaping Streamer = { text, target, tone, extra, config in
            TranslationService.stream(
                text: text,
                target: target,
                tone: tone,
                extra: extra,
                config: config
            )
        }
    ) {
        self.settings = settings
        self.stream = stream
        self.historyURL = Self.historyURL(preview: settings.isPreview)
        loadHistory()
    }

    var isTranslating: Bool { state == .translating }

    /// Model shown in the bottom bar: always the primary slot's model.
    var activeModel: String {
        let idx = settings.primaryIndex
        guard settings.profiles.indices.contains(idx) else { return L("未配置模型") }
        let model = settings.profiles[idx].model.trimmingCharacters(in: .whitespaces)
        return model.isEmpty ? L("未配置模型") : model
    }

    var hasResultSection: Bool {
        state != .idle || !output.isEmpty
    }

    /// A translation ran to completion and its input is still sitting in the box.
    var hasFinishedTranslation: Bool {
        state == .done && !output.isEmpty && !input.isEmpty
    }

    // MARK: - Direction

    /// Updates the detected source language and the target, respecting the
    /// multi-language mode.
    private func updateDirection() {
        let (detected, label) = LanguageDetector.detect(input)
        if flipped {
            // Manual override: the user says the detector picked the wrong side.
            source = detected == .chinese ? .english : .chinese
            sourceLabel = source == .chinese ? "中" : "EN"
            target = source == .chinese ? .english : .chinese
            return
        }
        source = detected
        sourceLabel = label
        if settings.multiLanguageMode {
            // In multi-language mode the user picks the target explicitly.
            // If the stored target equals the source, flip it to the most
            // recent distinct target, or fall back to the other side.
            if target == source {
                // Find the most recent record where target ≠ current source and is still
                // offered in the picker — older builds may have recorded targets (e.g.
                // French) that are no longer in the presets list.
                let lastDifferent = history.first {
                    $0.target != source && TranslationLanguage.presets.contains($0.target)
                }?.target
                target = lastDifferent ?? (source == .english ? .chinese : .english)
            }
        } else {
            // Simple CN↔EN mode: Chinese → English, everything else → Chinese.
            target = source == .chinese ? .english : .chinese
        }
    }

    /// Toggles the manual direction override for the current input. Guarded to
    /// simple mode: multi-language mode has no "opposite side" to flip to, and
    /// there is nothing to flip before anything is typed. A direction flip remains
    /// deliberately unavailable while translating because it is a separate,
    /// compact bottom-bar control; use the explicit target picker to restart an
    /// in-flight translation in multi-language mode.
    func flipDirection() {
        guard !input.isEmpty, !settings.multiLanguageMode, !isTranslating else { return }
        flipped.toggle()
        updateDirection()
    }

    /// Explicit target selection for multi-language mode. The auto-detected source is
    /// left alone; if the chosen target equals the source, `updateDirection` re-picks
    /// (translating into the same language makes no sense). If a translation is in
    /// flight, `translate()` cancels that request and starts the same input again with
    /// the newly selected target.
    ///
    /// The target may be chosen with an empty input: the language grid in Settings is
    /// visible before anything is typed, so a click must register even with no text —
    /// the chosen target just hasn't kicked off a translation yet.
    func setTarget(_ language: TranslationLanguage) {
        guard settings.multiLanguageMode else { return }
        let previousTarget = target
        target = language
        // Avoid a no-op "translate X into X" — but only when there is real input to
        // translate. With an empty input the detected source is just a placeholder
        // (usually Chinese), so it must not veto the user's explicit target choice:
        // let them select 中文 even before typing anything.
        if target == source, !input.isEmpty { updateDirection() }
        guard target != previousTarget else { return }
        if isTranslating { translate() }
    }

    /// Applies a change made to the mode flag. The setting is already updated by the
    /// time this is called, so direction calculation reads the new mode. Restarting a
    /// live request is important here: otherwise the request's captured target and the
    /// picker UI can disagree until the next translation.
    func multiLanguageModeDidChange() {
        updateDirection()
        if isTranslating { translate() }
    }

    // MARK: - Panel language picker

    /// The panel's inline picker chose「自动」: back to simple auto-detected CN↔EN.
    /// Owns the mode flag so the picker has a single call per pill and the
    /// mode-change restart semantics can't be forgotten at a call site.
    func selectAutoTarget() {
        guard settings.multiLanguageMode else { return }
        settings.multiLanguageMode = false
        multiLanguageModeDidChange()
    }

    /// The panel's inline picker chose an explicit target language. Entering
    /// multi-language mode implicitly — picking a concrete target IS the mode,
    /// there is no separate switch anymore.
    func selectExplicitTarget(_ language: TranslationLanguage) {
        if !settings.multiLanguageMode {
            settings.multiLanguageMode = true
            // No multiLanguageModeDidChange() here: setTarget below re-derives the
            // direction and restarts an in-flight request itself — calling both would
            // restart twice, the first time against a stale target.
        }
        setTarget(language)
    }

    // MARK: - Translate

    /// Cancels any in-flight request and clears everything a fresh attempt must not
    /// inherit (stale output, toasts, copy confirmation). Shared by both branches of
    /// `translate()` below — they only differ in which provider(s) they talk to.
    private func resetForNewRequest() {
        translationTask?.cancel()
        translationTask = nil
        toastTask?.cancel()
        toastTask = nil
        copyResetTask?.cancel()
        copyResetTask = nil
        output = ""
        resetPendingOutput()
        copied = false
        toast = nil
        interrupted = false
        outputCapped = false
        outputLanguageMismatch = false
        restoredFromTruncatedHistory = false
        failureKind = nil
    }

    /// Whether the dedicated local-model slot is filled in enough to use — read by
    /// Settings to gate the "translate with this model" toggle.
    var localModelAvailable: Bool {
        settings.profiles[SettingsStore.localProfileIndex].isUsable
    }

    func translate() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        resetForNewRequest()

        let target = target
        let source = source
        let sourceLabel = sourceLabel
        let tone = settings.tone
        let extra = settings.extraInstruction
        let requestRevision = inputRevision

        // The local-model slot is a standing mode switch (flipped in Settings), not a
        // per-request choice — when it's on, this slot is the ONLY thing translate()
        // talks to: no primary/backup, no race, no failover. See
        // `SettingsStore.localProfileIndex` and `SettingsStore.useLocalModel`.
        if settings.useLocalModel {
            guard localModelAvailable else {
                failureKind = .localModelNotConfigured
                state = .failed(L("本地模型尚未配置，请先在设置中填写"))
                return
            }
            state = .translating
            let link = (index: SettingsStore.localProfileIndex, config: settings.profiles[SettingsStore.localProfileIndex].config)
            translationTask = Task { [weak self] in
                guard let self else { return }
                let outcome = await self.consumeWithRetry(
                    link: link, text: text, target: target, source: source, sourceLabel: sourceLabel,
                    tone: tone, extra: extra, requestRevision: requestRevision
                )
                switch outcome {
                case .cancelled, .succeeded:
                    return
                case .emptyResponse:
                    guard !Task.isCancelled, self.inputRevision == requestRevision else { return }
                    self.output = ""
                    self.failureKind = .classify(TranslationError.emptyResponse)
                    self.state = .failed(TranslationError.emptyResponse.localizedDescription)
                case .failed(let error):
                    guard !Task.isCancelled, self.inputRevision == requestRevision else { return }
                    self.output = ""
                    self.failureKind = .classify(error)
                    self.state = .failed(error.localizedDescription)
                }
            }
            return
        }

        let chain = settings.resolvedChain
        guard !chain.isEmpty else {
            // Nothing usable: all profiles are empty or half-filled. "API Key" alone
            // would be wrong when the model or base URL is what's missing.
            failureKind = .notConfigured
            state = .failed(L("还没有配置可用的 API 服务，请先在设置中填写"))
            return
        }

        state = .translating

        translationTask = Task { [weak self] in
            guard let self else { return }
            var lastError: Error?
            var triedBackup = false

            // Racing replaces the sequential attempt loop entirely, but only when both
            // slots are genuinely comparable: two usable, non-loopback endpoints. A
            // loopback slot (near-zero network latency) would trivially win every race
            // regardless of answer quality, so its presence just falls through to the
            // ordinary primary→backup behavior below, unaffected by this setting.
            if self.settings.raceFastestEnabled,
               chain.count == 2,
               chain[0].config.requiresAuth,
               chain[1].config.requiresAuth {
                let (outcome, winnerIndex) = await self.raceForFastest(
                    linkA: chain[0], linkB: chain[1], text: text, target: target, source: source,
                    sourceLabel: sourceLabel, tone: tone, extra: extra, requestRevision: requestRevision
                )
                switch outcome {
                case .cancelled:
                    return
                case .succeeded:
                    // Quiet, one-time, non-blocking: names who answered first without
                    // demanding attention — same rhythm as the existing fallback toast.
                    // The short slot label ("deepseek"), not the full host, so the
                    // toast stays a glance rather than a sentence.
                    if self.settings.raceToastEnabled, let winnerIndex {
                        self.flashToast(.raceWon(self.settings.label(for: winnerIndex)))
                    }
                    return
                case .emptyResponse:
                    self.output = ""
                    lastError = TranslationError.emptyResponse
                case .failed(let error):
                    lastError = error
                }
                guard !Task.isCancelled, self.inputRevision == requestRevision else { return }
                self.output = ""
                let message = lastError?.localizedDescription ?? L("翻译失败")
                self.failureKind = lastError.map(FailureKind.classify) ?? .unknown
                self.state = .failed(String(format: L("两个供应商都失败了 · %@"), message))
                return
            }

            attemptLoop: for (position, link) in chain.enumerated() {
                if position > 0 { triedBackup = true }
                // Consume the stream, retrying once on the same provider for transient
                // failures (TCP reset, 5xx, timeout) before failing over.
                let outcome = await consumeWithRetry(
                    link: link, text: text, target: target, source: source, sourceLabel: sourceLabel,
                    tone: tone, extra: extra, requestRevision: requestRevision
                )
                switch outcome {
                case .cancelled:
                    return  // Cancelled by a newer request or by the user.
                case .succeeded:
                    // A backup that quietly saved the day still deserves a heads-up
                    // that the primary is down; otherwise stay silent.
                    if position > 0 {
                        self.flashToast(.fellBack)
                    }
                    return
                case .emptyResponse:
                    self.output = ""
                    self.resetPendingOutput()
                    lastError = TranslationError.emptyResponse
                    if position < chain.count - 1 { continue attemptLoop }
                    break attemptLoop
                case .failed(let error):
                    lastError = error
                    // Only fall back before any token landed — retrying mid-stream
                    // would splice two different translations together. If partial
                    // output has buffered (even though it's unpublished), the failure
                    // is final for this attempt; the buffer is discarded.
                    if self.pendingOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       position < chain.count - 1 {
                        self.resetPendingOutput()
                        continue attemptLoop
                    }
                    self.resetPendingOutput()
                    break attemptLoop
                }
            }

            guard !Task.isCancelled, self.inputRevision == requestRevision else { return }
            // Partial output is not presented as a complete translation and must not
            // remain available through the copy button after a failed stream.
            self.output = ""
            let message = lastError?.localizedDescription ?? L("翻译失败")
            self.failureKind = lastError.map(FailureKind.classify) ?? .unknown
            // Only claim the backup failed when it was actually tried: a mid-stream
            // failure on the primary deliberately skips failover (two spliced
            // translations are worse than one failed one), and saying otherwise
            // misleads about which provider is down.
            if triedBackup {
                self.state = .failed(String(format: L("主用和备用都失败了 · %@"), message))
            } else if chain.count > 1 {
                self.state = .failed(String(format: L("主用连接失败 · %@"), message))
            } else {
                self.state = .failed(message)
            }
        }
    }

    /// One provider attempt's outcome as seen by the caller (after retry handling).
    private enum StreamOutcome {
        case succeeded
        case emptyResponse
        case failed(Error)
        case cancelled
    }

    /// Raw outcome of a single `consumeStream` call, before retry/failover decisions.
    private enum StreamConsumeOutcome {
        case completed(capped: Bool)
        case failed(Error)
        case cancelled
    }

    /// Commits whatever is currently in `pendingOutput` as the finished result:
    /// punctuation pass, length cap, then one atomic publish plus its completion side
    /// effects (history, auto-copy, success sound). Returns false when there was no
    /// usable content (a "successful" response that said nothing is a failed attempt).
    /// Shared by the sequential attempt path and the race path — both need the exact
    /// same "is this actually usable" and "publish exactly once" semantics.
    private func commitPendingOutput(
        text: String,
        source: TranslationLanguage,
        sourceLabel: String,
        target: TranslationLanguage,
        tone: Tone
    ) -> Bool {
        let raw = pendingOutput
        let bufferWasCapped = pendingOutputCapped
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            resetPendingOutput()
            return false
        }
        let cleaned = TranslationService.sanitizeModelOutput(raw)
        resetPendingOutput()
        guard !cleaned.isEmpty else { return false }
        var finalOutput = SmartQuotes.apply(to: cleaned)
        // Overlong output is cut at the cap here (after the stream ends): the
        // panel and history never hold an unbounded string. A capped result is
        // honest about being partial — flagged, not silent — and behaves like a
        // stop: no auto-copy, no success sound (a run that had to be cut is not
        // a clean completion).
        let wasCapped = bufferWasCapped || finalOutput.count > Self.maxOutputCharacters
        if wasCapped {
            finalOutput = String(finalOutput.prefix(Self.maxOutputCharacters))
        }
        // A result in the wrong language means the model answered the source text
        // instead of translating it. The text is still published — the check is a
        // heuristic and throwing away a possibly-good translation would cost more than
        // it saves — but it is flagged, and like a capped run it is not treated as a
        // clean completion: no auto-copy, no success sound.
        let wrongLanguage = LanguageDetector.looksLikeWrongLanguage(finalOutput, target: target)
        let cleanCompletion = !wasCapped && !wrongLanguage
        // Publish exactly once. The view deliberately keeps showing the skeleton
        // until `state` becomes `.done`, so text and the copy button enter together.
        self.output = finalOutput
        self.outputCapped = wasCapped
        self.outputLanguageMismatch = wrongLanguage
        self.restoredFromTruncatedHistory = false
        self.failureKind = nil
        self.state = .done
        self.pushHistory(input: text, output: self.output, source: source, sourceLabel: sourceLabel, target: target, tone: tone)
        if cleanCompletion, self.settings.autoCopy, !self.output.isEmpty {
            if self.copyToPasteboard() {
                self.flashCopied(auto: true)
            } else {
                self.flashToast(.copyFailed)
            }
        }
        if cleanCompletion {
            SoundPlayer.shared.playSuccess()
        }
        return true
    }

    /// Consumes one provider's stream and commits the result on success. Transient
    /// failures (TCP reset, 5xx, timeout) get one quick retry on the same provider —
    /// cheaper than failing over, and often the hiccup is one-off. Returns the
    /// outcome for the caller's failover decision; `self.output` is already committed
    /// on `.succeeded`.
    private func consumeWithRetry(
        link: (index: Int, config: APIConfig),
        text: String,
        target: TranslationLanguage,
        source: TranslationLanguage,
        sourceLabel: String,
        tone: Tone,
        extra: String,
        requestRevision: UInt
    ) async -> StreamOutcome {
        // Each distinct attempt (and retry) starts with an empty buffer so a backup (or
        // a retry) commits only its own tokens — two models' output is never spliced.
        resetPendingOutput()
        let first = await consumeStream(stream(text, target, tone, extra, link.config), requestRevision: requestRevision)
        switch first {
        case .completed:
            return commitPendingOutput(text: text, source: source, sourceLabel: sourceLabel, target: target, tone: tone) ? .succeeded : .emptyResponse
        case .cancelled:
            return .cancelled
        case .failed(let error):
            // Only retry before any token landed — retrying mid-stream would splice two
            // different translations together. Because output is unpublished until the
            // end, the "any token landed" test reads the buffer, not the UI. The buffer
            // is left intact here for the caller's failover decision to see; it clears it.
            guard pendingOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failed(error)
            }
            // Retry only transient failures (TCP reset, 5xx, timeout) — deterministic
            // errors like bad auth or quota would just fail again.
            let transient: Bool
            if let translationError = error as? TranslationError {
                transient = translationError.isTransient
            } else if let urlError = error as? URLError {
                transient = [
                    .timedOut,
                    .networkConnectionLost,
                    .cannotFindHost,
                    .cannotConnectToHost,
                    .dnsLookupFailed,
                    .notConnectedToInternet,
                ].contains(urlError.code)
            } else {
                transient = false
            }
            guard transient else { return .failed(error) }

            resetPendingOutput()
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, self.inputRevision == requestRevision else { return .cancelled }
            let retry = await consumeStream(stream(text, target, tone, extra, link.config), requestRevision: requestRevision)
            switch retry {
            case .completed:
                return commitPendingOutput(text: text, source: source, sourceLabel: sourceLabel, target: target, tone: tone) ? .succeeded : .emptyResponse
            case .cancelled:
                return .cancelled
            case .failed(let retryError):
                return .failed(retryError)
            }
        }
    }

    /// Consumes one provider's SSE stream into `pendingOutput`. Content is never
    /// published to `output` here — the caller decides when to commit (once, on success
    /// or a user stop). Chunks accumulate in the buffer as they arrive, so a fast local
    /// server can deliver hundreds of tokens with no UI churn at all. Partial content is
    /// left in `pendingOutput` on failure so the caller's retry/failover logic can see
    /// whether any token landed.
    private func consumeStream(
        _ stream: AsyncThrowingStream<String, Error>,
        requestRevision: UInt
    ) async -> StreamConsumeOutcome {
        do {
            for try await piece in stream {
                guard !Task.isCancelled, self.inputRevision == requestRevision else { return .cancelled }
                if appendPendingOutput(piece) {
                    // The stream has reached the output ceiling. Committing now keeps
                    // the user-facing result bounded even if the producer keeps sending
                    // tokens; the stream's termination hook cancels its producer.
                    return .completed(capped: true)
                }
            }
            guard !Task.isCancelled, self.inputRevision == requestRevision else { return .cancelled }
            return .completed(capped: false)
        } catch is CancellationError {
            return .cancelled
        } catch let urlError as URLError where urlError.code == .cancelled {
            return .cancelled
        } catch {
            guard !Task.isCancelled, self.inputRevision == requestRevision else { return .cancelled }
            // Content stays in `pendingOutput` so the caller can decide whether this
            // counts as a mid-stream failure (a token already landed) or one to retry/
            // fail over cleanly.
            return .failed(error)
        }
    }

    /// Clears the unpublished accumulator and its cap marker together. Keeping these
    /// operations coupled prevents a capped attempt from making the next retry look
    /// capped even though it starts with a fresh buffer.
    private func resetPendingOutput() {
        pendingOutput.removeAll(keepingCapacity: true)
        pendingOutputCapped = false
    }

    /// Appends one streamed piece without ever allowing the in-flight buffer to exceed
    /// the same ceiling applied to the published result. Returns true exactly when this
    /// append reaches the ceiling, allowing the caller to commit a bounded partial result
    /// immediately instead of waiting for a producer that may never finish.
    @discardableResult
    private func appendPendingOutput(_ piece: String) -> Bool {
        guard !piece.isEmpty, !pendingOutputCapped else { return pendingOutputCapped }
        let remaining = Self.maxOutputCharacters - pendingOutput.count
        guard remaining > 0 else {
            pendingOutputCapped = true
            return true
        }
        if piece.count <= remaining {
            pendingOutput.append(contentsOf: piece)
            if pendingOutput.count == Self.maxOutputCharacters {
                pendingOutputCapped = true
                return true
            }
            return false
        }
        pendingOutput.append(contentsOf: piece.prefix(remaining))
        pendingOutputCapped = true
        return true
    }

    // MARK: - Race for fastest

    /// Outcome of one race leg. Mirrors `StreamConsumeOutcome`, but carries its own
    /// local buffer instead of writing into the shared `pendingOutput`: two legs run
    /// concurrently, and only the winner's content should ever become the committed
    /// buffer. `cancelTranslation()` reading `pendingOutput` mid-race therefore just
    /// sees "" and reports "no content" — a manual stop during a race abandons both
    /// legs rather than guessing which one's partial text to show, which is fine
    /// because a race only ever runs before a winner exists.
    private enum RaceLegOutcome {
        case completed(String, capped: Bool)
        case failed(Error)
        case cancelled
    }

    private func consumeRaceLeg(
        _ stream: AsyncThrowingStream<String, Error>,
        requestRevision: UInt
    ) async -> RaceLegOutcome {
        var buffer = ""
        var capped = false
        do {
            for try await piece in stream {
                guard !Task.isCancelled, self.inputRevision == requestRevision else { return .cancelled }
                guard !capped else { continue }
                let remaining = Self.maxOutputCharacters - buffer.count
                if remaining <= 0 {
                    capped = true
                    return .completed(buffer, capped: true)
                }
                if piece.count <= remaining {
                    buffer += piece
                } else {
                    buffer += String(piece.prefix(remaining))
                    capped = true
                    return .completed(buffer, capped: true)
                }
            }
            guard !Task.isCancelled, self.inputRevision == requestRevision else { return .cancelled }
            return .completed(buffer, capped: capped)
        } catch is CancellationError {
            return .cancelled
        } catch let urlError as URLError where urlError.code == .cancelled {
            return .cancelled
        } catch {
            guard !Task.isCancelled, self.inputRevision == requestRevision else { return .cancelled }
            return .failed(error)
        }
    }

    /// Fires `linkA` and `linkB` concurrently and commits whichever finishes first with
    /// usable content; the still-running loser is cancelled the moment a winner is
    /// chosen. Callers must only reach this with two non-loopback links — see
    /// `SettingsStore.raceFastestEnabled`'s doc comment for why loopback is excluded.
    ///
    /// Deliberately no retry: a leg that fails just loses the race. Retrying it would
    /// only delay a result the other leg may already be able to provide; if the other
    /// leg also fails, both errors were tried anyway, exactly as a sequential two-slot
    /// attempt would.
    /// Result of `raceForFastest`: the outcome, plus (only on `.succeeded`) which
    /// slot index actually won — used to look up its short label (via
    /// `SettingsStore.label(for:)`) for the one-time race-result toast.
    private func raceForFastest(
        linkA: (index: Int, config: APIConfig),
        linkB: (index: Int, config: APIConfig),
        text: String,
        target: TranslationLanguage,
        source: TranslationLanguage,
        sourceLabel: String,
        tone: Tone,
        extra: String,
        requestRevision: UInt
    ) async -> (outcome: StreamOutcome, winnerIndex: Int?) {
        resetPendingOutput()
        // Built here, on the main actor, and only captured (not called) inside the
        // child tasks below: `stream` itself is a non-Sendable closure property, so
        // invoking it from inside `addTask` would need to hop back to the main actor
        // anyway — starting both streams up front makes that hop happen once, up
        // front, instead of racing to acquire it twice.
        let streamA = self.stream(text, target, tone, extra, linkA.config)
        let streamB = self.stream(text, target, tone, extra, linkB.config)
        return await withTaskGroup(of: (Int, RaceLegOutcome).self) { group -> (StreamOutcome, Int?) in
            group.addTask {
                (linkA.index, await self.consumeRaceLeg(streamA, requestRevision: requestRevision))
            }
            group.addTask {
                (linkB.index, await self.consumeRaceLeg(streamB, requestRevision: requestRevision))
            }

            var firstError: Error?
            var sawEmptyResponse = false
            while let (index, outcome) = await group.next() {
                switch outcome {
                case .completed(let buffer, let capped):
                    self.pendingOutput = buffer
                    self.pendingOutputCapped = capped
                    let usable = self.commitPendingOutput(text: text, source: source, sourceLabel: sourceLabel, target: target, tone: tone)
                    if usable {
                        group.cancelAll()
                        return (.succeeded, index)
                    }
                    // An empty completion is not a winner. The other provider may still
                    // finish with a usable translation, so keep racing until it does.
                    sawEmptyResponse = true
                case .cancelled:
                    // A global cancellation (user stop, newer input) — the other leg
                    // will see the same signal on its own next check regardless.
                    group.cancelAll()
                    return (.cancelled, nil)
                case .failed(let error):
                    firstError = firstError ?? error
                    // Keep waiting: the other leg is still racing and may still win.
                }
            }
            if let firstError {
                return (.failed(firstError), nil)
            }
            return (sawEmptyResponse ? .emptyResponse : .failed(TranslationError.emptyResponse), nil)
        }
    }

    func cancelTranslation() {
        translationTask?.cancel()
        translationTask = nil
        outputCapped = false
        outputLanguageMismatch = false
        restoredFromTruncatedHistory = false
        failureKind = nil
        // Whether anything buffered decides if this stop leaves partial content behind.
        // During a translation `output` is empty by design; the buffer holds everything
        // the provider already delivered.
        let hadContent = !pendingOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !hadContent {
            resetPendingOutput()
            interrupted = false
            state = .idle
        } else {
            // Stopping is deliberate: the partial text stays visible and copyable, but it
            // gets the same punctuation pass a finished result does, and the view marks
            // it as incomplete so it can't be mistaken for a complete translation.
            let cleaned = TranslationService.sanitizeModelOutput(pendingOutput)
            guard !cleaned.isEmpty else {
                resetPendingOutput()
                interrupted = false
                state = .idle
                return
            }
            var partial = SmartQuotes.apply(to: cleaned)
            let wasCapped = pendingOutputCapped || partial.count > Self.maxOutputCharacters
            if wasCapped {
                partial = String(partial.prefix(Self.maxOutputCharacters))
            }
            output = partial
            resetPendingOutput()
            interrupted = true
            outputCapped = wasCapped
            state = .done
        }
    }

    private func clearResult() {
        guard state != .idle || !output.isEmpty || translationTask != nil else { return }
        translationTask?.cancel()
        translationTask = nil
        toastTask?.cancel()
        toastTask = nil
        copyResetTask?.cancel()
        copyResetTask = nil
        output = ""
        resetPendingOutput()
        copied = false
        toast = nil
        interrupted = false
        outputCapped = false
        outputLanguageMismatch = false
        restoredFromTruncatedHistory = false
        failureKind = nil
        state = .idle
    }

    /// Fills the panel with sample content for visual inspection (TUSI_PREVIEW).
    func debugPreview(input: String, output: String, toast: Toast? = nil) {
        self.input = input
        self.output = output
        self.state = .done
        self.toast = toast
        self.interrupted = false
        self.outputCapped = false
        // Run the real check rather than forcing false: a preview scenario that supplies
        // wrong-language sample text then exercises the actual detection, not just the
        // banner. `input` is assigned first, so `target` is already resolved here.
        self.outputLanguageMismatch = LanguageDetector.looksLikeWrongLanguage(output, target: target)
        self.restoredFromTruncatedHistory = false
        self.failureKind = nil
    }

    /// Puts the panel into a mid-translation state for visual inspection: a non-empty
    /// input with an empty (unpublished) output and `.translating`. Skip the audible cue.
    func debugPreviewTranslating(input: String) {
        resetPendingOutput()
        self.input = input
        self.output = ""
        self.interrupted = false
        self.outputCapped = false
        self.outputLanguageMismatch = false
        self.restoredFromTruncatedHistory = false
        self.failureKind = nil
        self.copied = false
        self.state = .translating
    }

    // MARK: - Diagnostics

    /// Builds the de-identified state receipt offered next to a failure. Reads the
    /// engine's own view of the request (target, failure) and the settings' hosts —
    /// never the key, the source text or the result. See `Diagnostics` for the rules.
    func diagnosticsReport() -> String {
        func host(_ index: Int) -> String {
            settings.profiles.indices.contains(index) ? settings.profiles[index].config.displayHost : ""
        }
        let failureMessage: String?
        if case .failed(let message) = state { failureMessage = message } else { failureMessage = nil }
        let report = Diagnostics.Report(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            primaryHost: host(settings.primaryIndex),
            primaryModel: settings.profiles.indices.contains(settings.primaryIndex)
                ? settings.profiles[settings.primaryIndex].model.trimmingCharacters(in: .whitespaces)
                : "",
            backupHost: host(settings.fallbackIndex),
            localHost: host(SettingsStore.localProfileIndex),
            usingLocalModel: settings.useLocalModel,
            raceEnabled: settings.raceFastestEnabled,
            multiLanguageMode: settings.multiLanguageMode,
            target: target.apiName,
            failure: failureMessage,
            failureKind: failureKind
        )
        return Diagnostics.text(for: report)
    }

    /// Copies the receipt above. Separate from `copyOutput` because it must work when
    /// there is no output at all — a failed translation is exactly when it is needed.
    /// It reuses `flashCopied`/`copyFailed` on purpose: "something was copied" has one
    /// confirmation in this app, and inventing a second one for a support action would
    /// add UI for the rarest path in the panel.
    func copyDiagnostics() {
        let text = diagnosticsReport()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(text, forType: .string) {
            flashCopied()
        } else {
            flashToast(.copyFailed)
        }
    }

    // MARK: - Clipboard

    private func copyToPasteboard() -> Bool {
        guard !output.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        let didWrite = pasteboard.setString(output, forType: .string)
        if !didWrite, let previousString {
            // Restore the prior text when AppKit rejects the new write, so a failed
            // copy never destroys the user's existing string clipboard.
            pasteboard.setString(previousString, forType: .string)
        }
        return didWrite
    }

    private func flashToast(_ kind: Toast) {
        toast = kind
        toastTask?.cancel()
        let duration: Double
        switch kind {
        case .fellBack: duration = 2.4
        case .truncatedInput: duration = 2.0
        case .copyFailed: duration = 2.0
        case .raceWon: duration = 2.2
        }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func copyOutput() {
        guard !output.isEmpty else { return }
        if copyToPasteboard() {
            flashCopied()
        } else {
            copied = false
            flashToast(.copyFailed)
        }
    }

    /// Morphs the copy button into a check for a beat. Auto-copy holds it a little longer:
    /// nobody clicked, so it has to survive being noticed rather than confirming a click.
    private func flashCopied(auto: Bool = false) {
        copied = true
        copyResetTask?.cancel()
        copyResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(auto ? 2.2 : 1.6))
            guard !Task.isCancelled else { return }
            self?.copied = false
        }
    }

    // MARK: - History persistence

    /// Appends one completed request to the bounded, newest-first history.
    private func pushHistory(input: String, output: String, source: TranslationLanguage, sourceLabel: String, target: TranslationLanguage, tone: Tone) {
        let inputTruncated = input.count > Self.historyFieldCharacterLimit
        let outputTruncated = output.count > Self.historyFieldCharacterLimit
        let record = Record(
            id: UUID(),
            input: String(input.prefix(Self.historyFieldCharacterLimit)),
            output: String(output.prefix(Self.historyFieldCharacterLimit)),
            inputTruncated: inputTruncated,
            outputTruncated: outputTruncated,
            sourceLabel: sourceLabel,
            source: source,
            target: target,
            tone: tone,
            timestamp: Date()
        )
        // Publish the bounded snapshot as one atomic observable change.
        history = Array(([record] + history).prefix(historyCapacity))
        saveHistory()
    }

    /// Restores a history record into the input/output area. The user is going back
    /// to an earlier point and should start a fresh conversation turn.
    func restoreHistory(_ record: Record) {
        input = record.input
        output = record.output
        sourceLabel = record.sourceLabel
        source = record.source
        target = record.target
        interrupted = false
        outputCapped = false
        // A restored snapshot is archived text, not a fresh model response: judging it
        // again would only re-litigate a translation the user already accepted.
        outputLanguageMismatch = false
        restoredFromTruncatedHistory = record.isTruncated
        failureKind = nil
        state = .done
    }

    /// Clears all translation history.
    func clearHistory() {
        history = []
        saveHistory()
    }

    // MARK: - File persistence

    /// Serializes the bounded history snapshot. Written synchronously on the main
    /// actor: the file is tiny (≤50 records, sub-millisecond), and a synchronous
    /// write is what makes saves strictly ordered and guaranteed to land before
    /// termination. The previous detached writes could finish out of order — an
    /// older snapshot overwriting a newer one, or a cleared history resurrecting
    /// itself — and could be cut off by app exit.
    private func saveHistory() {
        let records = history
        let url = historyURL
        guard let data = try? JSONEncoder().encode(records) else {
            // Encoding a bounded `[Record]` basically never fails, but when it does,
            // silently dropping the write would lose the user's history with no trail.
            Log.app.error("history encode failed for \(records.count) records")
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.app.error("history write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadHistory() {
        let url = historyURL
        guard let data = try? Data(contentsOf: url) else { return }
        if let decoded = try? JSONDecoder().decode([Record].self, from: data) {
            history = normalizeLoadedHistory(decoded)
            return
        }
        // A single corrupt record (schema drift, truncated entry) must not cost the
        // user the whole history: decode per-record, keep the good ones.
        let lossy = try? JSONDecoder().decode([LossyRecord].self, from: data)
        history = normalizeLoadedHistory(lossy?.compactMap(\.record) ?? [])
    }

    /// Old builds or manually edited files can exceed the in-memory guarantees that
    /// `pushHistory` applies before saving. Normalize after every decode so one large
    /// history file cannot make the next synchronous save unbounded again.
    private func normalizeLoadedHistory(_ records: [Record]) -> [Record] {
        records.prefix(historyCapacity).map { record in
            let inputTruncated = record.input.count > Self.historyFieldCharacterLimit
            let outputTruncated = record.output.count > Self.historyFieldCharacterLimit
            return Record(
                id: record.id,
                input: String(record.input.prefix(Self.historyFieldCharacterLimit)),
                output: String(record.output.prefix(Self.historyFieldCharacterLimit)),
                inputTruncated: record.inputTruncated || inputTruncated,
                outputTruncated: record.outputTruncated || outputTruncated,
                sourceLabel: record.sourceLabel,
                source: record.source,
                target: record.target,
                tone: record.tone,
                timestamp: record.timestamp
            )
        }
    }

    /// Wrapper that tolerates individual corrupt entries during history load.
    private struct LossyRecord: Decodable {
        let record: Record?
        init(from decoder: Decoder) throws {
            record = try? Record(from: decoder)
        }
    }

}
