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
            scheduleDraftSave()
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

    /// A finished translation together with which slot produced it.
    ///
    /// Provenance used to be announced by a floating toast that covered the input for
    /// a couple of seconds and then took the information with it. It is not an event —
    /// it is a property of the result, it stays true for as long as the result is on
    /// screen, and it is what makes two versions of the same translation tellable
    /// apart. So it lives on the result instead.
    struct ResultVersion: Equatable {
        var text: String
        var slot: Int
        var tier: TranslationTier
        var languageMismatch: Bool
        var capped: Bool
        /// True when this version was produced only after the slot ahead of it in the
        /// same stage failed — the one thing the old "已用备用翻译" toast said that the
        /// slot name alone does not.
        var afterFailover: Bool
    }

    /// Every finished answer to the current input, oldest tier first. At most one per
    /// tier: a local answer and the online answer that superseded it. One entry is the
    /// ordinary case and shows as a plain provenance label; two entries turn that label
    /// into a switch between them.
    @Published private(set) var versions: [ResultVersion] = []

    /// Which entry of `versions` is on screen — and therefore, by the app's one
    /// clipboard rule, which one auto-copy has put on the pasteboard.
    @Published private(set) var shownVersion = 0

    /// Set briefly when writing to the pasteboard failed. Reported by the copy button
    /// itself, in the same place the success confirmation appears, rather than by a
    /// banner over the text the user was reading.
    @Published private(set) var copyFailed = false

    /// Why an escalation could not produce a second opinion. Shown as a quiet line
    /// under the result that is still perfectly good, never as an error box replacing
    /// it: the user asked an optional question and did not get an answer, which is not
    /// the same as their translation failing.
    @Published private(set) var escalationFailure: String?

    private let settings: SettingsStore
    private let stream: Streamer
    private var translationTask: Task<Void, Never>?
    private var inputRevision: UInt = 0
    private var copyResetTask: Task<Void, Never>?
    private var draftSaveTask: Task<Void, Never>?
    private var pendingDraftInput: String?
    private var isApplyingInputCap = false
    private var isRestoringDraft = false

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
    private let draftURL: URL
    private let draftPersistenceEnabled: Bool

    // Internal (not private): tests reset the preview scratch history between cases.
    static func historyURL(preview: Bool) -> URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        // FileManager guarantees at least one application-support URL in practice; a
        // degraded environment still gets a writable scratch location instead of a crash.
        let dir = (paths.first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(preview ? "com.tusi.preview" : "com.tusi.app", isDirectory: true)
        return dir.appendingPathComponent("history.json")
    }

    // Internal for tests. Drafts share the same isolated preview directory as history.
    static func draftURL(preview: Bool) -> URL {
        historyURL(preview: preview)
            .deletingLastPathComponent()
            .appendingPathComponent("draft.txt")
    }

    init(
        settings: SettingsStore,
        draftPersistenceEnabled: Bool? = nil,
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
        self.draftURL = Self.draftURL(preview: settings.isPreview)
        self.draftPersistenceEnabled = draftPersistenceEnabled ?? !settings.isPreview
        loadHistory()
        loadDraft()
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
        copyResetTask?.cancel()
        copyResetTask = nil
        output = ""
        resetPendingOutput()
        versions.removeAll()
        shownVersion = 0
        request = nil
        currentStageIndex = 0
        escalating = false
        escalationFailure = nil
        copied = false
        copyFailed = false
        interrupted = false
        outputCapped = false
        outputLanguageMismatch = false
        restoredFromTruncatedHistory = false
        failureKind = nil
    }

    /// Everything one translation needs, captured when ⏎ was pressed.
    ///
    /// Escalation runs a later stage of the *same* request minutes later, so the route
    /// and the tone are frozen here rather than read from settings a second time: a
    /// preference the user changed in between must not silently apply to half of one
    /// result pair.
    private struct RequestContext {
        var text: String
        var source: TranslationLanguage
        var sourceLabel: String
        var target: TranslationLanguage
        var tone: Tone
        var extra: String
        var revision: UInt
        var route: TranslationRoute
    }

    private var request: RequestContext?
    /// Which stage of `request.route` produced what is on screen. Escalation asks for
    /// the next stage above this one; failover already happened inside it.
    private var currentStageIndex = 0

    /// True while a higher tier is being asked for an answer the user already has a
    /// version of. Deliberately not `state == .translating`: the result on screen stays
    /// readable and copyable throughout, because it is still the current answer until a
    /// better one actually arrives.
    @Published private(set) var escalating = false

    /// Whether asking a better model is available right now. False at the top tier —
    /// offering "try a better one" that re-rolls the same model would be a lie.
    var canEscalate: Bool {
        guard state == .done, !escalating, !versions.isEmpty, let request else { return false }
        return request.route.hasHigherTier(after: currentStageIndex)
    }

    /// The label of the tier escalation would reach, for the hint that offers it.
    var escalationTargetLabel: String? {
        guard canEscalate, let request,
              let next = request.route.nextHigherStage(after: currentStageIndex),
              let slot = next.stage.slots.first
        else { return nil }
        return next.stage.slots.count > 1 ? L("在线") : settings.label(for: slot)
    }

    /// What ⏎ means right now.
    ///
    /// The user's own instinct was a double-press: one for the cheap model, two for the
    /// good one. This keeps that gesture and drops the timing window — the second press
    /// only means "better one" *after* a result is on screen, which is the only moment
    /// anyone can tell whether they need it. So a fast double-tap on a typo costs
    /// nothing, and there is no 300ms window every ordinary ⏎ has to wait out.
    func submit() {
        if canEscalate {
            escalate()
            return
        }
        // Nothing left to ask for: this text already has an answer from the best tier
        // configured. Re-running would restart the route at its start — swapping a
        // careful online answer back for the local one the user escalated away from —
        // and bill for the privilege. An edit, a tone change, or the retry button in a
        // failed state are the ways forward from here.
        guard !(state == .done && !versions.isEmpty), !escalating else { return }
        translate()
    }

    func translate() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        resetForNewRequest()

        let route = settings.route
        guard !route.isEmpty else {
            // Nothing usable anywhere: every slot is empty or half-filled.
            failureKind = .notConfigured
            state = .failed(L("还没有配置可用的翻译服务，请先在设置中填写"))
            return
        }

        let context = RequestContext(
            text: text,
            source: source,
            sourceLabel: sourceLabel,
            target: target,
            tone: settings.tone,
            extra: settings.extraInstruction,
            revision: inputRevision,
            route: route
        )
        request = context
        currentStageIndex = 0
        state = .translating

        translationTask = Task { [weak self] in
            await self?.runRoute(context, from: 0)
        }
    }

    /// Asks the next tier up for its own answer, keeping the current one.
    ///
    /// This is the same machine as failover — advance a stage, run it, commit — with a
    /// different trigger and one different rule: the answer already on screen is kept
    /// rather than discarded, because it is not a failure, it is just the one the user
    /// wants a second opinion on.
    func escalate() {
        guard canEscalate,
              let context = request,
              let next = context.route.nextHigherStage(after: currentStageIndex)
        else { return }
        translationTask?.cancel()
        escalating = true
        translationTask = Task { [weak self] in
            await self?.runRoute(context, from: next.index)
        }
    }

    /// Walks the route from `startIndex`, stopping at the first stage that produces a
    /// usable answer. A stage that fails outright advances to the next one — which is
    /// failover when the next stage is the same tier's other slot, and automatic
    /// escalation when it is the tier above. They were three separate branches of this
    /// function; they are one loop now because they only ever differed in the trigger.
    private func runRoute(_ context: RequestContext, from startIndex: Int) async {
        var lastError: Error?
        var sawEmptyResponse = false
        var attemptedTiers: Set<TranslationTier> = []
        var attemptedSlotCount = 0
        var index = startIndex

        while let stage = context.route.stage(at: index) {
            attemptedTiers.insert(stage.tier)
            attemptedSlotCount += stage.slots.count
            let outcome = await runStage(stage, context: context)
            switch outcome {
            case .cancelled:
                escalating = false
                return
            case .succeeded:
                currentStageIndex = index
                escalating = false
                // A result that is not in the language that was asked for is not a
                // matter of taste — that tier demonstrably failed at the job. If a
                // better one exists, go there without being asked, keeping the
                // suspicious answer as the version the user can switch back to.
                guard let committed = versions.last,
                      committed.languageMismatch,
                      let next = context.route.nextHigherStage(after: index)
                else { return }
                Log.translation.notice("auto-escalating after wrong-language result at tier \(stage.tier.rawValue, privacy: .public)")
                escalating = true
                index = next.index
                continue
            case .emptyResponse:
                sawEmptyResponse = true
                lastError = lastError ?? TranslationError.emptyResponse
            case .failed(let error):
                lastError = lastError ?? error
            }
            index += 1
        }

        guard !Task.isCancelled, self.inputRevision == context.revision else {
            escalating = false
            return
        }
        escalating = false

        // An escalation that fails leaves the answer the user already had exactly where
        // it was. Replacing a perfectly good local translation with an error box because
        // the *optional* second opinion did not arrive would be the app punishing the
        // user for asking.
        if !versions.isEmpty {
            escalationFailure = (lastError ?? TranslationError.emptyResponse).localizedDescription
            return
        }

        // Partial output is not presented as a complete translation and must not remain
        // available through the copy button after a failed stream.
        self.output = ""
        let message = lastError?.localizedDescription
            ?? (sawEmptyResponse ? TranslationError.emptyResponse.localizedDescription : L("翻译失败"))
        self.failureKind = lastError.map(FailureKind.classify) ?? .unknown
        self.state = .failed(Self.failureMessage(
            message,
            tiers: attemptedTiers,
            slotCount: attemptedSlotCount
        ))
    }

    /// Names what was actually tried, never more. Claiming the backup failed when a
    /// mid-stream primary failure deliberately skipped it (two spliced translations are
    /// worse than one failed one) misleads about which provider is down.
    static func failureMessage(_ message: String, tiers: Set<TranslationTier>, slotCount: Int) -> String {
        if tiers.count > 1 {
            return String(format: L("本地和在线都失败了 · %@"), message)
        }
        if slotCount > 1 {
            return String(format: L("两套在线服务都失败了 · %@"), message)
        }
        return message
    }

    /// Runs one stage under its own strategy and commits on success.
    private func runStage(_ stage: RouteStage, context: RequestContext) async -> StreamOutcome {
        switch stage.strategy {
        case .single:
            guard let slot = stage.slots.first else { return .emptyResponse }
            return await consumeWithRetry(
                slot: slot, stage: stage, afterFailover: false, context: context
            )

        case .failover:
            var lastError: Error?
            var sawEmptyResponse = false
            for (position, slot) in stage.slots.enumerated() {
                let isLast = position == stage.slots.count - 1
                let outcome = await consumeWithRetry(
                    slot: slot, stage: stage, afterFailover: position > 0, context: context
                )
                switch outcome {
                case .cancelled, .succeeded:
                    return outcome
                case .emptyResponse:
                    resetPendingOutput()
                    sawEmptyResponse = true
                    lastError = lastError ?? TranslationError.emptyResponse
                    if isLast { break }
                case .failed(let error):
                    lastError = lastError ?? error
                    // Only fall back before any token landed — retrying mid-stream would
                    // splice two different translations together. If partial output has
                    // buffered (even though it is unpublished), the failure is final for
                    // this stage; the buffer is discarded.
                    let clean = pendingOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    resetPendingOutput()
                    if !clean || isLast { return .failed(error) }
                }
            }
            if let lastError, !sawEmptyResponse { return .failed(lastError) }
            return sawEmptyResponse ? .emptyResponse : .failed(lastError ?? TranslationError.emptyResponse)

        case .concurrent:
            return await raceStage(stage, context: context)
        }
    }

    // MARK: - Stream plumbing

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
    /// effects (version list, history, auto-copy, success sound). Returns false when
    /// there was no usable content (a "successful" response that said nothing is a
    /// failed attempt). Shared by every stage strategy — all of them need the exact
    /// same "is this actually usable" and "publish exactly once" semantics.
    @discardableResult
    private func commitPendingOutput(
        context: RequestContext,
        slot: Int,
        tier: TranslationTier,
        afterFailover: Bool
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
        // Overlong output is cut at the cap here (after the stream ends): the panel and
        // history never hold an unbounded string. A capped result is honest about being
        // partial — flagged, not silent — and behaves like a stop: no auto-copy, no
        // success sound (a run that had to be cut is not a clean completion).
        let wasCapped = bufferWasCapped || finalOutput.count > Self.maxOutputCharacters
        if wasCapped {
            finalOutput = String(finalOutput.prefix(Self.maxOutputCharacters))
        }
        // A result in the wrong language means the model answered the source text
        // instead of translating it. The text is still published — the check is a
        // heuristic and throwing away a possibly-good translation would cost more than
        // it saves — but it is flagged, and like a capped run it is not treated as a
        // clean completion: no auto-copy, no success sound.
        let wrongLanguage = LanguageDetector.looksLikeWrongLanguage(finalOutput, target: context.target)

        let version = ResultVersion(
            text: finalOutput,
            slot: slot,
            tier: tier,
            languageMismatch: wrongLanguage,
            capped: wasCapped,
            afterFailover: afterFailover
        )
        // At most one version per tier: escalating twice to the same tier replaces that
        // tier's answer rather than growing a stack the provenance switch cannot show.
        let supersedes: Bool
        if let existing = versions.firstIndex(where: { $0.tier == tier }) {
            versions[existing] = version
            shownVersion = existing
            supersedes = versions.count > 1
        } else {
            versions.append(version)
            versions.sort { $0.tier < $1.tier }
            shownVersion = versions.firstIndex(where: { $0.tier == tier }) ?? 0
            supersedes = versions.count > 1
        }

        escalationFailure = nil
        self.restoredFromTruncatedHistory = false
        self.failureKind = nil
        self.state = .done
        // Publishes `output` and, when auto-copy is on, puts exactly what is now on
        // screen on the pasteboard — the app's one clipboard rule.
        applyShownVersion(playingSound: true)
        // An escalation answers the same question again; it updates that question's
        // history entry instead of filing a second one beside it.
        self.pushHistory(
            input: context.text,
            output: finalOutput,
            source: context.source,
            sourceLabel: context.sourceLabel,
            target: context.target,
            tone: context.tone,
            replacingNewest: supersedes
        )
        return true
    }

    /// Consumes one provider's stream and commits the result on success. Transient
    /// failures (TCP reset, 5xx, timeout) get one quick retry on the same provider —
    /// cheaper than failing over, and often the hiccup is one-off. Returns the outcome
    /// for the caller's stage-advance decision; `self.output` is already committed on
    /// `.succeeded`.
    private func consumeWithRetry(
        slot: Int,
        stage: RouteStage,
        afterFailover: Bool,
        context: RequestContext
    ) async -> StreamOutcome {
        let config = settings.config(for: slot)
        // Each distinct attempt (and retry) starts with an empty buffer so a backup (or
        // a retry) commits only its own tokens — two models' output is never spliced.
        resetPendingOutput()
        let first = await consumeStream(
            stream(context.text, context.target, context.tone, context.extra, config),
            requestRevision: context.revision
        )
        switch first {
        case .completed:
            return commitPendingOutput(
                context: context, slot: slot, tier: stage.tier, afterFailover: afterFailover
            ) ? .succeeded : .emptyResponse
        case .cancelled:
            return .cancelled
        case .failed(let error):
            // Only retry before any token landed — retrying mid-stream would splice two
            // different translations together. Because output is unpublished until the
            // end, the "any token landed" test reads the buffer, not the UI. The buffer
            // is left intact here for the caller's stage-advance decision to see.
            guard pendingOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failed(error)
            }
            guard Self.isTransient(error) else { return .failed(error) }

            resetPendingOutput()
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, self.inputRevision == context.revision else { return .cancelled }
            let retry = await consumeStream(
                stream(context.text, context.target, context.tone, context.extra, config),
                requestRevision: context.revision
            )
            switch retry {
            case .completed:
                return commitPendingOutput(
                    context: context, slot: slot, tier: stage.tier, afterFailover: afterFailover
                ) ? .succeeded : .emptyResponse
            case .cancelled:
                return .cancelled
            case .failed(let retryError):
                return .failed(retryError)
            }
        }
    }

    /// Retry only transient failures (TCP reset, 5xx, timeout) — deterministic errors
    /// like bad auth or quota would just fail again in front of the user.
    private static func isTransient(_ error: Error) -> Bool {
        if let translationError = error as? TranslationError {
            return translationError.isTransient
        }
        if let urlError = error as? URLError {
            return [
                .timedOut,
                .networkConnectionLost,
                .cannotFindHost,
                .cannotConnectToHost,
                .dnsLookupFailed,
                .notConnectedToInternet,
            ].contains(urlError.code)
        }
        return false
    }

    /// Consumes one provider's SSE stream into `pendingOutput`. Content is never
    /// published to `output` here — the caller decides when to commit (once, on success
    /// or a user stop). Chunks accumulate in the buffer as they arrive, so a fast local
    /// server can deliver hundreds of tokens with no UI churn at all. Partial content is
    /// left in `pendingOutput` on failure so the caller's retry/advance logic can see
    /// whether any token landed.
    private func consumeStream(
        _ stream: AsyncThrowingStream<String, Error>,
        requestRevision: UInt
    ) async -> StreamConsumeOutcome {
        do {
            for try await piece in stream {
                guard !Task.isCancelled, self.inputRevision == requestRevision else { return .cancelled }
                if appendPendingOutput(piece) {
                    // The stream has reached the output ceiling. Committing now keeps the
                    // user-facing result bounded even if the producer keeps sending
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

    // MARK: - Concurrent stage

    /// Outcome of one concurrent leg. Mirrors `StreamConsumeOutcome`, but carries its own
    /// local buffer instead of writing into the shared `pendingOutput`: the legs run
    /// concurrently, and only the winner's content should ever become the committed
    /// buffer. `cancelTranslation()` reading `pendingOutput` mid-stage therefore just
    /// sees "" and reports "no content" — a manual stop abandons every leg rather than
    /// guessing which one's partial text to show, which is fine because this stage only
    /// ever runs before a winner exists.
    private enum LegOutcome {
        case completed(String, capped: Bool)
        case failed(Error)
        case cancelled
    }

    /// A candidate must contain real output and plausibly match the requested language
    /// before it can cancel the other provider. Wrong-language content remains a
    /// fallback candidate so the cautious warning behavior is preserved when neither
    /// provider produces a clean translation.
    private enum CandidateQuality {
        case empty
        case wrongLanguage
        case usable
    }

    private func candidateQuality(_ buffer: String, target: TranslationLanguage) -> CandidateQuality {
        let cleaned = TranslationService.sanitizeModelOutput(buffer)
        guard !cleaned.isEmpty else { return .empty }
        return LanguageDetector.looksLikeWrongLanguage(cleaned, target: target)
            ? .wrongLanguage
            : .usable
    }

    private func consumeLeg(
        _ stream: AsyncThrowingStream<String, Error>,
        requestRevision: UInt
    ) async -> LegOutcome {
        var buffer = ""
        do {
            for try await piece in stream {
                guard !Task.isCancelled, self.inputRevision == requestRevision else { return .cancelled }
                let remaining = Self.maxOutputCharacters - buffer.count
                if remaining <= 0 {
                    return .completed(buffer, capped: true)
                }
                if piece.count <= remaining {
                    buffer += piece
                } else {
                    buffer += String(piece.prefix(remaining))
                    return .completed(buffer, capped: true)
                }
            }
            guard !Task.isCancelled, self.inputRevision == requestRevision else { return .cancelled }
            return .completed(buffer, capped: false)
        } catch is CancellationError {
            return .cancelled
        } catch let urlError as URLError where urlError.code == .cancelled {
            return .cancelled
        } catch {
            guard !Task.isCancelled, self.inputRevision == requestRevision else { return .cancelled }
            return .failed(error)
        }
    }

    /// Fires every slot in the stage at once and commits whichever finishes first with
    /// usable content; the still-running losers are cancelled the moment a winner is
    /// chosen. `SettingsStore.concurrentAvailable` is what guarantees no loopback slot
    /// is in here — its near-zero network latency would win every time regardless of
    /// whether its answer is any good.
    ///
    /// Deliberately no retry: a leg that fails just loses. Retrying it would only delay
    /// a result the other leg may already be able to provide; if the other leg also
    /// fails, both errors were tried anyway, exactly as a sequential stage would.
    private func raceStage(_ stage: RouteStage, context: RequestContext) async -> StreamOutcome {
        resetPendingOutput()
        // Built here, on the main actor, and only captured (not called) inside the child
        // tasks below: `stream` itself is a non-Sendable closure property, so invoking it
        // from inside `addTask` would need to hop back to the main actor anyway —
        // starting the streams up front makes that hop happen once, up front.
        let legs = stage.slots.map { slot in
            (slot, self.stream(context.text, context.target, context.tone, context.extra, settings.config(for: slot)))
        }
        return await withTaskGroup(of: (Int, LegOutcome).self) { group -> StreamOutcome in
            for (slot, stream) in legs {
                group.addTask {
                    (slot, await self.consumeLeg(stream, requestRevision: context.revision))
                }
            }

            var firstError: Error?
            var firstWrongLanguage: (slot: Int, buffer: String, capped: Bool)?
            var sawEmptyResponse = false
            while let (slot, outcome) = await group.next() {
                switch outcome {
                case .completed(let buffer, let capped):
                    switch self.candidateQuality(buffer, target: context.target) {
                    case .empty:
                        // An empty completion is not a winner. The other provider may
                        // still finish with a usable translation, so keep waiting.
                        sawEmptyResponse = true
                    case .wrongLanguage:
                        // Keep the first suspicious answer only as a last resort. It must
                        // not cancel a provider that may still return the requested
                        // language.
                        if firstWrongLanguage == nil {
                            firstWrongLanguage = (slot, buffer, capped)
                        }
                        let host = self.settings.config(for: slot).displayHost
                        Log.translation.notice("concurrent candidate missed target language (slot \(slot, privacy: .public), host \(host, privacy: .public)); waiting for other provider")
                    case .usable:
                        self.pendingOutput = buffer
                        self.pendingOutputCapped = capped
                        if self.commitPendingOutput(
                            context: context, slot: slot, tier: stage.tier, afterFailover: false
                        ) {
                            let host = self.settings.config(for: slot).displayHost
                            Log.translation.info("concurrent winner selected (slot \(slot, privacy: .public), host \(host, privacy: .public), target-language result)")
                            group.cancelAll()
                            return .succeeded
                        }
                        // Sanitization was already checked above, so this is defensive:
                        // if the commit boundary rejects it, continue waiting.
                        sawEmptyResponse = true
                    }
                case .cancelled:
                    // A global cancellation (user stop, newer input) — the other legs
                    // will see the same signal on their own next check regardless.
                    group.cancelAll()
                    return .cancelled
                case .failed(let error):
                    firstError = firstError ?? error
                    // Keep waiting: the other leg is still running and may still win.
                }
            }
            if let fallback = firstWrongLanguage {
                self.pendingOutput = fallback.buffer
                self.pendingOutputCapped = fallback.capped
                if self.commitPendingOutput(
                    context: context, slot: fallback.slot, tier: stage.tier, afterFailover: false
                ) {
                    let host = self.settings.config(for: fallback.slot).displayHost
                    Log.translation.notice("concurrent stage exhausted without a target-language result; preserving warned fallback (slot \(fallback.slot, privacy: .public), host \(host, privacy: .public))")
                    return .succeeded
                }
            }
            if let firstError {
                return .failed(firstError)
            }
            return sawEmptyResponse ? .emptyResponse : .failed(TranslationError.emptyResponse)
        }
    }

    func cancelTranslation() {
        translationTask?.cancel()
        translationTask = nil

        // Stopping an escalation abandons the second opinion, nothing else. The answer
        // on screen is a finished translation that was already committed — replacing it
        // with the half-arrived online one would punish the user for changing their mind.
        if escalating {
            escalating = false
            resetPendingOutput()
            applyShownVersion(playingSound: false)
            state = .done
            return
        }

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
        copyResetTask?.cancel()
        copyResetTask = nil
        output = ""
        resetPendingOutput()
        versions.removeAll()
        shownVersion = 0
        request = nil
        currentStageIndex = 0
        escalating = false
        escalationFailure = nil
        copied = false
        copyFailed = false
        interrupted = false
        outputCapped = false
        outputLanguageMismatch = false
        restoredFromTruncatedHistory = false
        failureKind = nil
        state = .idle
    }

    /// Fills the panel with sample content for visual inspection (TUSI_PREVIEW).
    func debugPreview(input: String, output: String, versions: [ResultVersion] = []) {
        self.input = input
        self.output = output
        self.state = .done
        self.versions = versions
        self.shownVersion = max(0, versions.count - 1)
        // Build the same request context a real translation would leave behind, so the
        // preview exercises the actual `canEscalate` predicate rather than a stand-in.
        let route = settings.route
        self.request = RequestContext(
            text: input, source: source, sourceLabel: sourceLabel, target: target,
            tone: settings.tone, extra: settings.extraInstruction,
            revision: inputRevision, route: route
        )
        self.currentStageIndex = versions.last.flatMap { last in
            route.stages.firstIndex { $0.tier == last.tier }
        } ?? 0
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

    func copyOutput() {
        guard !output.isEmpty else { return }
        if copyToPasteboard() {
            flashCopied()
        } else {
            flashCopyFailed()
        }
    }

    /// The copy button reports its own failure, in its own place. A banner floating over
    /// the translation to say the translation was not copied is the app covering the
    /// thing it is talking about.
    private func flashCopyFailed() {
        copied = false
        copyFailed = true
        copyResetTask?.cancel()
        copyResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.0))
            guard !Task.isCancelled else { return }
            self?.copyFailed = false
        }
    }

    // MARK: - Result versions

    /// Shows the answer from another tier. The pasteboard follows: whatever is on
    /// screen is what auto-copy has put there, which is the single rule that keeps two
    /// versions of one translation from being ambiguous about which one you just
    /// pasted.
    func showVersion(_ index: Int) {
        guard versions.indices.contains(index), index != shownVersion else { return }
        shownVersion = index
        applyShownVersion(playingSound: false)
    }

    /// Publishes `versions[shownVersion]` as the visible result and, when auto-copy is
    /// on and the result is clean, onto the pasteboard.
    private func applyShownVersion(playingSound: Bool) {
        guard versions.indices.contains(shownVersion) else { return }
        let version = versions[shownVersion]
        // Publish exactly once. The view deliberately keeps showing the skeleton until
        // `state` becomes `.done`, so text and the copy button enter together.
        output = version.text
        outputCapped = version.capped
        outputLanguageMismatch = version.languageMismatch
        interrupted = false
        // A capped or wrong-language result is not a clean completion: silently putting
        // it on the pasteboard is the actual harm the flag exists to prevent.
        let clean = !version.capped && !version.languageMismatch
        if clean, settings.autoCopy, !output.isEmpty {
            if copyToPasteboard() {
                flashCopied(auto: true)
            } else {
                flashCopyFailed()
            }
        }
        if clean, playingSound {
            SoundPlayer.shared.playSuccess()
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
    ///
    /// `replacingNewest` is set by an escalation: it answered the question the newest
    /// record already answers, so it updates that record instead of filing a second
    /// entry beside it. Without this, every second opinion would leave history holding
    /// the same input twice.
    private func pushHistory(input: String, output: String, source: TranslationLanguage, sourceLabel: String, target: TranslationLanguage, tone: Tone, replacingNewest: Bool = false) {
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
        if replacingNewest, !history.isEmpty {
            history = Array(([record] + history.dropFirst()).prefix(historyCapacity))
        } else {
            history = Array(([record] + history).prefix(historyCapacity))
        }
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

    private func scheduleDraftSave() {
        guard draftPersistenceEnabled, !isRestoringDraft else { return }
        pendingDraftInput = input
        draftSaveTask?.cancel()
        let draft = input
        draftSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.saveDraft(draft)
        }
    }

    private func saveDraft(_ draft: String) {
        do {
            if draft.isEmpty {
                if FileManager.default.fileExists(atPath: draftURL.path) {
                    try FileManager.default.removeItem(at: draftURL)
                }
            } else {
                try FileManager.default.createDirectory(
                    at: draftURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(draft.utf8).write(to: draftURL, options: .atomic)
            }
            pendingDraftInput = nil
        } catch {
            Log.app.error("draft write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadDraft() {
        guard draftPersistenceEnabled,
              let data = try? Data(contentsOf: draftURL),
              let draft = String(data: data, encoding: .utf8),
              !draft.isEmpty else { return }
        isRestoringDraft = true
        input = String(draft.prefix(Self.maxInputCharacters))
        isRestoringDraft = false
    }

    /// Guarantees the latest editor contents land before a normal app termination.
    func flushPendingDraftSave() {
        guard draftPersistenceEnabled else { return }
        draftSaveTask?.cancel()
        draftSaveTask = nil
        if let pendingDraftInput {
            saveDraft(pendingDraftInput)
        }
    }

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
