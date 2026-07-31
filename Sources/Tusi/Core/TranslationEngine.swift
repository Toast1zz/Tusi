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
        let sourceLabel: String
        let source: TranslationLanguage
        let target: TranslationLanguage
        let tone: Tone
        let timestamp: Date
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

    /// Transient banner shown at the bottom of the panel, then auto-dismissed.
    /// Whether primary or backup served the request is an implementation detail —
    /// the only thing worth surfacing is the one-time "primary failed" notice.
    enum Toast: Equatable {
        case fellBack
    }
    @Published private(set) var toast: Toast?

    private let settings: SettingsStore
    private let stream: Streamer
    private var translationTask: Task<Void, Never>?
    private var inputRevision: UInt = 0
    private var toastTask: Task<Void, Never>?
    private var copyResetTask: Task<Void, Never>?

    /// Ring buffer of completed translations (newest first).
    @Published private(set) var history: [Record] = []
    private let historyCapacity = 50

    // MARK: - History persistence

    /// History file location. Preview runs (TUSI_PREVIEW / preview settings) get a
    /// scratch directory so tests and screenshot runs never read or clobber the
    /// real history.
    private let historyURL: URL

    // Internal (not private): tests reset the preview scratch history between cases.
    static func historyURL(preview: Bool) -> URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let dir = paths[0].appendingPathComponent(preview ? "com.tusi.preview" : "com.tusi.app", isDirectory: true)
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
                // Find the most recent record where target ≠ current source.
                let lastDifferent = history.first { $0.target != source }?.target
                target = lastDifferent ?? (source == .english ? .chinese : .english)
            }
        } else {
            // Simple CN↔EN mode: Chinese → English, everything else → Chinese.
            target = source == .chinese ? .english : .chinese
        }
    }

    /// Toggles the manual direction override for the current input. Guarded to
    /// simple mode: multi-language mode has no "opposite side" to flip to, and
    /// there is nothing to flip before anything is typed.
    func flipDirection() {
        guard !input.isEmpty, !settings.multiLanguageMode else { return }
        flipped.toggle()
        updateDirection()
    }

    /// Explicit target selection for multi-language mode. The auto-detected source is
    /// left alone; if the chosen target equals the source, `updateDirection` re-picks
    /// (translating into the same language makes no sense).
    func setTarget(_ language: TranslationLanguage) {
        guard settings.multiLanguageMode else { return }
        target = language
        if target == source { updateDirection() }
    }

    // MARK: - Translate

    func translate() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        translationTask?.cancel()
        translationTask = nil
        output = ""
        copied = false
        toast = nil

        let chain = settings.resolvedChain
        guard !chain.isEmpty else {
            state = .failed(TranslationError.emptyKey.localizedDescription)
            return
        }

        state = .translating
        let target = target
        let source = source
        let sourceLabel = sourceLabel
        let tone = settings.tone
        let extra = settings.extraInstruction
        let requestRevision = inputRevision

        translationTask = Task { [weak self] in
            guard let self else { return }
            var lastError: Error?

            for (position, link) in chain.enumerated() {
                do {
                    for try await piece in stream(text, target, tone, extra, link.config) {
                        guard !Task.isCancelled, self.inputRevision == requestRevision else { return }
                        self.output += piece
                    }
                    guard !Task.isCancelled, self.inputRevision == requestRevision else { return }

                    // A successful HTTP response with no usable content is still a
                    // failed attempt and should be eligible for backup failover.
                    guard !self.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        self.output = ""
                        lastError = TranslationError.emptyResponse
                        guard position < chain.count - 1 else { break }
                        continue
                    }

                    // Normalize punctuation once the full text is in — the conversion
                    // needs to see the character after a quote to place it.
                    self.output = SmartQuotes.apply(to: self.output)
                    self.state = .done
                    self.pushHistory(input: text, output: self.output, source: source, sourceLabel: sourceLabel, target: target, tone: tone)
                    if self.settings.autoCopy, !self.output.isEmpty {
                        self.copyToPasteboard()
                        self.flashCopied(auto: true)
                    }
                    // A backup that quietly saved the day still deserves a heads-up
                    // that the primary is down; otherwise stay silent.
                    if position > 0 {
                        self.flashToast(.fellBack)
                    }
                    return
                } catch is CancellationError {
                    return  // Cancelled by a newer request or by the user.
                } catch let urlError as URLError where urlError.code == .cancelled {
                    return
                } catch {
                    guard !Task.isCancelled, self.inputRevision == requestRevision else { return }
                    lastError = error
                    // Only fall back before any token landed — retrying mid-stream
                    // would splice two different translations together.
                    if self.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       position < chain.count - 1 {
                        self.output = ""
                        continue
                    }
                    break
                }
            }

            guard !Task.isCancelled, self.inputRevision == requestRevision else { return }
            // Partial output is not presented as a complete translation and must not
            // remain available through the copy button after a failed stream.
            self.output = ""
            let message = lastError?.localizedDescription ?? L("翻译失败")
            self.state = .failed(chain.count > 1 ? String(format: L("主用和备用都失败了 · %@"), message) : message)
        }
    }

    func cancelTranslation() {
        translationTask?.cancel()
        translationTask = nil
        state = output.isEmpty ? .idle : .done
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
        copied = false
        toast = nil
        state = .idle
    }

    /// Fills the panel with sample content for visual inspection (TUSI_PREVIEW).
    func debugPreview(input: String, output: String, toast: Toast? = nil) {
        self.input = input
        self.output = output
        self.state = .done
        self.toast = toast
    }

    // MARK: - Clipboard

    private func copyToPasteboard() {
        guard !output.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(output, forType: .string)
    }

    private func flashToast(_ kind: Toast) {
        toast = kind
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(kind == .fellBack ? 2.4 : 1.6))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func copyOutput() {
        guard !output.isEmpty else { return }
        copyToPasteboard()
        flashCopied()
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
        let record = Record(
            id: UUID(),
            input: input,
            output: output,
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
        state = .done
    }

    /// Clears all translation history.
    func clearHistory() {
        history = []
        saveHistory()
    }

    // MARK: - File persistence

    private func saveHistory() {
        let records = history
        let url = historyURL
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(records) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadHistory() {
        let url = historyURL
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Record].self, from: data)
        else { return }
        history = decoded
    }

}
