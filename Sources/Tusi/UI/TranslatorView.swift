import AppKit
import SwiftUI

private struct ResultHeightKey: PreferenceKey {
    // `let`, not `var`: the protocol only needs a getter, and a mutable static is a
    // data-race error under the Swift 6 language mode.
    static let defaultValue: CGFloat = 20
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct TranslatorView: View {
    @EnvironmentObject private var engine: TranslationEngine
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var panelState: PanelState

    @FocusState private var inputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presentedInputHeight: CGFloat?
    @State private var inputResizeGeneration = UUID()
    @State private var resultHeight: CGFloat = 20
    /// Whether the result viewport sits at its bottom edge. Streaming auto-scrolls
    /// only when the user is already there — reading an earlier part of a long
    /// result must not be yanked back to the tail on every chunk.
    @State private var isAtBottom = true

    // Line geometry for the 15pt content font with lineSpacing 3, measured with the
    // same AppKit machinery the input height uses — derived, not hardcoded, so a
    // change to the font or spacing (including larger system fonts) stays correct.
    // Measured empirically: the first line is 19pt and every line after adds 22pt.
    private let firstLineHeight: CGFloat
    private let lineStep: CGFloat
    /// The same two numbers for the *input editor*, which does not lay text out the way
    /// `Text` does. See `measureEditorLineMetrics`.
    private let editorFirstLineHeight: CGFloat
    private let editorLineStep: CGFloat
    init() {
        let metrics = Self.measureLineMetrics()
        firstLineHeight = metrics.first
        lineStep = metrics.step
        let editorMetrics = Self.measureEditorLineMetrics()
        editorFirstLineHeight = editorMetrics.first
        editorLineStep = editorMetrics.step
    }
    private func height(lines: Int) -> CGFloat { firstLineHeight + CGFloat(lines - 1) * lineStep }

    /// Measures a single line's height for a given system font size — the same
    /// `boundingRect` technique `measureLineMetrics()` uses for the content font,
    /// generalized to the smaller fonts `HistoryRecordRow` uses for its label and
    /// footer lines.
    private static func measureSingleLineHeight(fontSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize)
        let text = NSAttributedString(string: "A", attributes: [.font: font])
        let rect = text.boundingRect(
            with: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        )
        return ceil(rect.height)
    }

    /// How many lines `text` takes in a `Text` at the content font and `width` — the same
    /// `boundingRect` layout `measureLineMetrics()` uses, so it agrees with what `Text` draws.
    static func contentLineCount(_ text: String, width: CGFloat, firstLineHeight: CGFloat, lineStep: CGFloat) -> Int {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        let attributed = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [
            .font: NSFont.systemFont(ofSize: 15), .paragraphStyle: style,
        ])
        let height = ceil(attributed.boundingRect(
            with: NSSize(width: max(width, 1), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        ).height)
        return max(1, Int(((height - firstLineHeight) / max(lineStep, 1)).rounded()) + 1)
    }

    /// One `HistoryRecordRow`'s height: the source line, the translation at its real line
    /// count (capped at the row's two), and the row's padding. Measured per record, so a
    /// history of one-line answers is not sized as if every answer took two lines.
    private func historyRowHeight(for record: TranslationEngine.Record) -> CGFloat {
        let width = panelState.panelWidth - 32 - 10  // panel margins, row padding
        let lines = min(2, Self.contentLineCount(record.output, width: width,
                                                 firstLineHeight: firstLineHeight, lineStep: lineStep))
        return Self.metaLineHeight + Self.historyRowSpacing + height(lines: lines)
            + Self.historyRowVerticalPadding * 2
    }

    /// Internal for tests: asserts the derived metrics stay sane.
    static func measureLineMetrics() -> (first: CGFloat, step: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        let font = NSFont.systemFont(ofSize: 15)
        let one = NSAttributedString(string: "A", attributes: [.font: font, .paragraphStyle: style])
        let two = NSAttributedString(string: "A\nA", attributes: [.font: font, .paragraphStyle: style])
        let h1 = one.boundingRect(
            with: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        ).height
        let h2 = two.boundingRect(
            with: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        ).height
        return (ceil(h1), ceil(h2 - h1))
    }

    /// Line metrics for the *input editor*, measured with the machinery `TextEditor`
    /// actually lays out with.
    ///
    /// `Text` and `TextEditor` do not agree, and the difference is not noise. Measured on
    /// this font (system 15, `lineSpacing(3)`), against a live view of each:
    ///
    ///     lines   Text (and boundingRect)   TextEditor (and NSLayoutManager)
    ///         1                        19                                 18
    ///         6                       129                                123
    ///        14                       305                                291
    ///
    /// `measureLineMetrics()` above measures the first column and is exactly right for
    /// the result, which is a `Text`. Using it for the input made the six-line cap 129pt
    /// tall when six editor lines are 123pt — the extra 6pt showed the top of a seventh
    /// line, a row of clipped glyph tops sitting above the text. It also made every
    /// scrolled position land mid-line: the top edge of the viewport fell 8pt into a row
    /// rather than on a boundary.
    ///
    /// With the editor's own numbers the alignment stops being something to arrange and
    /// becomes arithmetic. Content is `first + step × (lines − 1)`, the viewport is
    /// `first + step × 5`, and their difference — the scroll offset when the editor sits
    /// at the end of the text, which is where it sits after a paste — is a whole multiple
    /// of `step`. No half line, for any text.
    static func measureEditorLineMetrics() -> (first: CGFloat, step: CGFloat) {
        let one = editorTextHeight("A", width: 200)
        let two = editorTextHeight("A\nA", width: 200)
        return (one, two - one)
    }

    /// Lays `text` out exactly as the input editor's NSTextView does and returns the
    /// height it occupies. `width` is the text width, so the container's own fragment
    /// padding is zeroed — `editorTextWidth` has already subtracted it.
    static func editorTextHeight(_ text: String, width: CGFloat) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        let storage = NSTextStorage(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 15),
            .paragraphStyle: style,
        ])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height)
    }

    /// Whether the result is taller than the viewport it was given, and therefore has
    /// content the panel cannot show at once.
    private var resultOverflows: Bool { resultHeight + textLineGap > maxResultHeight }

    /// Fades the final line rather than cutting it flat. One line of gradient — enough to
    /// read as "continues", not so much that the text looks dimmed.
    private var fadeOutBottom: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 1 - (lineStep / max(maxResultHeight, 1))),
                .init(color: .black.opacity(0.12), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// The `Text` grid's trailing gap, the counterpart of `editorLineGap` for the result.
    private var textLineGap: CGFloat { lineStep - firstLineHeight }

    /// The line spacing that the last line does not get.
    ///
    /// TextKit puts `lineSpacing` *between* fragments, so a run of lines measures
    /// 21, 21, …, 18: every line carries its 3pt of spacing except the last, whose
    /// fragment stops at the glyph box. Sizing the editor to that measurement puts the
    /// bottom line flush against the clip edge with nothing to spare — no descender room,
    /// no room for the caret — which reads as the line being shaved off. Adding the gap
    /// back means the editor is always sized to whole cells of the line grid rather than
    /// to where the ink happens to stop.
    private var editorLineGap: CGFloat { editorLineStep - editorFirstLineHeight }

    // Caps expressed as whole lines so a clamped view never cuts a line in half — the panel
    // grows to fit short content, and long content scrolls inside a whole-line viewport.
    // Each cap is measured with the metrics of the view it caps: the input is a TextEditor,
    // the result is a Text, and they lay text out differently.
    //
    // Whole grid cells, gap included — not `first + n × step`, which is the same lines
    // with the last one's spacing shaved off.
    //
    // The two caps are not the same number because they are not the same job. The input
    // is a draft the user already knows the contents of, and six lines of it is context;
    // the result is the thing they came for, and a translation that stops mid-sentence
    // reads as damage no matter how correct the arithmetic above it is. The result's cap
    // is therefore as tall as the panel can be without taking over the screen, and exists
    // only to keep the window inside `clampedPanelHeight` — not as an editorial decision
    // about how much translation is worth showing.
    private var maxInputHeight: CGFloat {
        let lines = min(6, max(2, floor((panelState.availableHeight - 240) / (2 * editorLineStep))))
        return lines * editorLineStep
    }

    /// One grid cell for empty or single-line input; measurement adds rows only
    /// when text wraps or the user inserts a newline.
    private var minInputHeight: CGFloat { editorLineStep }
    private struct InputResizeTarget: Equatable {
        let height: CGFloat
        let animated: Bool
    }
    private var inputResizeTarget: InputResizeTarget {
        InputResizeTarget(height: min(max(inputHeight, minInputHeight), maxInputHeight),
                          animated: !engine.input.isEmpty && !reduceMotion && !engine.hasResultSection && !panelState.showHistory)
    }
    private var maxResultHeight: CGFloat {
        let budget = panelState.availableHeight - min(inputHeight, maxInputHeight) - 240
            - (panelState.showLanguagePicker ? 40 : 0)
        return max(2, min(24, floor(budget / lineStep))) * lineStep
    }

    private var editorTextWidth: CGFloat { panelState.panelWidth - 32 - 10 }

    /// Measures the input's natural height with the editor's own layout manager, so the
    /// frame it sets is the height the text actually occupies — see
    /// `measureEditorLineMetrics` for why `boundingRect` is not that height.
    ///
    /// Memoized by (text, width): the body re-evaluates on every streamed chunk, but
    /// the input text does not change while the result streams — re-measuring it
    /// hundreds of times per translation is pure waste. The cache is bounded (widths
    /// come from the clamped 470–700 range, so entries are few).
    private struct InputMeasureKey: Hashable {
        let text: String
        let width: CGFloat
    }
    // @MainActor: only ever touched from `body`/view computed properties, which SwiftUI
    // already runs on the main actor — explicit here so it reads the same as the rest of
    // this project's Swift 6 concurrency annotations instead of looking like an oversight.
    @MainActor private static var inputMeasureCache: [InputMeasureKey: CGFloat] = [:]
    private static let inputMeasureCacheLimit = 64

    private var inputHeight: CGFloat {
        let key = InputMeasureKey(text: engine.input, width: editorTextWidth)
        if let cached = Self.inputMeasureCache[key] { return cached }
        var text = engine.input.isEmpty ? " " : engine.input
        // A trailing newline has no line fragment of its own until something follows it;
        // without this the editor scrolls a line the measurement does not know about.
        if text.hasSuffix("\n") { text += " " }
        let height = Self.editorTextHeight(text, width: editorTextWidth) + editorLineGap
        Self.inputMeasureCache[key] = height
        if Self.inputMeasureCache.count > Self.inputMeasureCacheLimit {
            Self.inputMeasureCache.removeAll()
        }
        return height
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The content above the bar reports the height it wants, then gets only what
            // the window has, anchored at the top and clipped at the bottom. The bar below
            // it therefore rides the window's bottom edge exactly: while the window is
            // still catching up with a taller layout, the new content is revealed above the
            // bar instead of pushing the bar out of the window; while it is catching up
            // with a shorter one, the bar travels up with the edge instead of jumping
            // ahead of it. Both heights report through the same summed key, in the same
            // pass, so the window still receives one destination.
            panelContent
                .padding(.bottom, panelState.showLanguagePicker ? 8 : (engine.hasResultSection || panelState.showHistory ? 12 : 10))
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: PanelHeightKey.self, value: proxy.size.height)
                    }
                )
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                .clipped()

            bottomBar
                // Move the toolbar as one geometry group. A button's own transaction can
                // otherwise place its label on a different timeline from its siblings.
                .geometryGroup()
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: PanelHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        // Every one of these is declared here, at the top of the page, rather than
        // wrapped around the mutation that causes it: a value can be changed from the
        // bottom bar, a keyboard shortcut, or the panel controller, and only a
        // declaration covers all three. History shares `.layout` with everything else
        // now — it had its own slightly longer token purely to mask the window lag that
        // no longer exists.
        .motion(.layout, value: resultPhase)
        // The provenance row arriving, and the switch appearing beside it when a second
        // version lands, both change the panel's height — same clock as everything else.
        .motion(.layout, value: engine.versions)
        .motion(.layout, value: engine.escalating)
        .motion(.layout, value: engine.escalationFailure)
        .motion(.layout, value: panelState.showHistory)
        .motion(.layout, value: panelState.showLanguagePicker)
        .onReceive(NotificationCenter.default.publisher(for: .tusiFocusInput)) { notification in
            // Every panel show reposts this; a picker left open last time must not
            // greet the next invocation already expanded.
            panelState.showLanguagePicker = false
            let selectAll = notification.object as? Bool == true
            inputFocused = true
            guard selectAll else { return }
            Task { @MainActor in
                await Task.yield()
                (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
            }
        }
        // The picker is a transient choice row; a page change (history/settings) is a
        // context switch that should fold it away rather than leave it hanging.
        .onChange(of: panelState.showHistory) { _, _ in panelState.showLanguagePicker = false }
        .onChange(of: panelState.showSettings) { _, _ in panelState.showLanguagePicker = false }
    }

    /// Everything above the bottom bar: the input, the result or history, and the
    /// target-language row.
    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputArea
                .padding(.top, 16)
                .padding(.horizontal, 16)

            if panelState.showHistory || engine.hasResultSection {
                SoftDivider()
                    .padding(.horizontal, 16)
                    .padding(.top, 14)

                // History is a disclosure in the same place as the result, not a new
                // page. Keep both states top-anchored, animate only the viewport height,
                // and crossfade them so no content flies in or out.
                ZStack(alignment: .topLeading) {
                    if panelState.showHistory {
                        historyList
                            .transition(.opacity)
                    } else if engine.hasResultSection {
                        resultArea
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                    }
                }
                // History gets an explicit viewport; the result deliberately gets none.
                //
                // The result section used to measure itself into a `@State` that then
                // set this frame — one more `preference → @State → frame → preference`
                // hop on the way to the window. SwiftUI does not promise to redeliver a
                // preference for the layout its own state write caused, and when that
                // second delivery went missing the window stayed sized for the *previous*
                // result: the panel kept the height it had while the text underneath it
                // grew past the bottom edge, taking the bottom bar with it. Traced live —
                // `result section 238.0` arrived and the `content` that should have
                // followed never did. Letting the result's natural height reach the VStack
                // directly puts it in the same layout pass as the measurement, so there is
                // no second delivery left to lose.
                .frame(height: panelState.showHistory ? historyViewportHeight : nil, alignment: .top)
                .clipped()
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }

            // Inline target picker: expands ABOVE the bottom bar (never a popover — a
            // popup makes the panel resign key and trip the click-outside auto-hide,
            // which is also why the tone picker is inline).
            //
            // A `Disclosure`, not an `if` + `.move(edge: .bottom)`: the row's arrival is
            // the panel getting taller, and a vertical slide on top of that says the same
            // thing twice while leaving the stack's own height to change in one step.
            Disclosure(isExpanded: panelState.showLanguagePicker) {
                languagePickerRow
                    .padding(.horizontal, 16)
                    .padding(.top, engine.hasResultSection || panelState.showHistory ? 12 : 10)
            }
        }
    }

    // MARK: - Input

    private var inputArea: some View {
        let height = inputHeight
        return VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                if engine.input.isEmpty {
                    Text(settings.commandLabel(L("输入中文或任意语言"), action: .translate))
                        .font(Theme.contentFont)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $engine.input)
                    .font(Theme.contentFont)
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(height <= maxInputHeight)
                    // Keep long drafts scrollable without exposing the system scroller.
                    // On macOS it can render as an opaque gutter against this clear editor.
                    .scrollIndicators(.never)
                    .focused($inputFocused)
                    // The trailing gap again, this time for the *scrolled* state, where a
                    // taller frame cannot help: scrolled to the end of the text the last
                    // pixel of the content is the last pixel of the viewport, so the
                    // bottom line sits flush against the clip edge with nothing to spare.
                    // A bottom safe-area inset extends the scrollable range instead, which
                    // both keeps 3pt under the last line and — because the extra range is
                    // exactly the gap the grid is missing — lands the top edge of the
                    // viewport on a line boundary rather than partway into a row.
                    // Measured against a live editor: without it, scrolled to the end, the
                    // top line is cut by 15pt and the bottom line by all of its spacing.
                    //
                    // Bottom edge only. A top inset would push the first line down 3pt and
                    // leave the placeholder, which is a sibling and has no safe area,
                    // sitting above the text it stands in for.
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Color.clear.frame(height: editorLineGap)
                    }
                    // The two positions the app scrolls to itself — the top, and the end
                    // of the text — land on the grid by construction. A trackpad does not:
                    // it leaves the view wherever the flick stopped, which is why the top
                    // and bottom rows were cut through the glyphs at some scroll positions
                    // and not others.
                    .snapsScrollToLines(step: editorLineStep, growingEditorLimit: maxInputHeight)
                    // Clearing is one whole-panel transition, not an editor row edit.
                    .frame(height: engine.input.isEmpty ? inputResizeTarget.height : (presentedInputHeight ?? inputResizeTarget.height))
            }

            if engine.inputWasTruncated {
                Label(
                    String(format: L("输入已截断，最多保留 %d 字"), TranslationEngine.maxInputCharacters),
                    systemImage: "scissors"
                )
                .font(Theme.meta)
                .foregroundStyle(.secondary)
                .transition(.opacity)
            } else if engine.input.count >= Self.inputCountdownThreshold {
                // A count only appears near the ceiling. Showing one from the first
                // character would put a number under an empty box for every short
                // sentence — which is every normal use — to warn about a limit almost
                // nobody reaches. Arriving late is the point: it is a warning, not a
                // meter, and it gives the user a chance to split the text *before* the
                // paste that loses its tail.
                Text(String(
                    format: L("还可以输入 %d 字"),
                    max(0, TranslationEngine.maxInputCharacters - engine.input.count)
                ))
                .font(Theme.meta)
                .foregroundStyle(.tertiary)
                .transition(.opacity)
            }
        }
        // Keyed to *which* notice is showing, not to the input itself. The editor grows
        // and shrinks on every keystroke and must never animate — that would put the text
        // behind the caret. A notice appearing or disappearing is a different event: it
        // adds a line to the panel, so it rides the same clock the window does.
        .motion(.layout, value: inputNotice)
        .task(id: inputResizeTarget) {
            let target = inputResizeTarget
            let generation = UUID()
            inputResizeGeneration = generation
            defer {
                if inputResizeGeneration == generation { panelState.inputResizeInProgress = false }
            }
            guard let start = presentedInputHeight, abs(start - target.height) > 0.5,
                  target.animated else {
                presentedInputHeight = target.height
                return
            }
            panelState.inputResizeInProgress = true
            let started = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                presentedInputHeight = Theme.inputResizeHeight(from: start, to: target.height, elapsed: elapsed)
                if elapsed >= Theme.inputResizeDuration * Theme.animationScale { break }
                do { try await Task.sleep(for: .milliseconds(8)) } catch { return }
            }
            // Keep direct window following enabled until the final layout report
            // has crossed the SwiftUI/AppKit boundary.
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    /// The one notice, if any, under the input box.
    private enum InputNotice: Equatable {
        case none
        case truncated
        case remainingCount
    }

    private var inputNotice: InputNotice {
        if engine.inputWasTruncated { return .truncated }
        if engine.input.count >= Self.inputCountdownThreshold { return .remainingCount }
        return .none
    }

    // MARK: - Result

    /// The one button that can move a failed state forward. A missing configuration is
    /// fixed in Settings, not by asking the same endpoint again; a dropped connection is
    /// the opposite. `FailureKind` carries which case this is.
    private var failureActionLabel: String {
        switch engine.failureKind {
        case .notConfigured, .credentials, .configuration: return L("打开设置")
        case .transient, .unknown, .none: return L("重试")
        }
    }

    private func performFailureAction() {
        switch engine.failureKind {
        case .notConfigured, .credentials, .configuration:
            panelState.settingsSection = .services
            panelState.showSettings = true
        case .transient, .unknown, .none:
            engine.translate()
        }
    }

    /// What kind of thing the result box currently holds. One value rather than the two
    /// it is derived from (`hasResultSection` and `engine.state`), because they change
    /// together the moment a translation starts or lands — and two `.motion` scopes both
    /// claiming that moment is precisely the "one action, several overlapping timelines"
    /// this system exists to prevent. Note what is *not* in here: `engine.output`. It
    /// grows while a translation streams, and nothing in the panel animates during a
    /// stream — the window mirrors those heights directly, which is what keeps the text
    /// from lagging the tokens.
    private enum ResultPhase: Equatable {
        case none
        case waiting
        case failed
        case text
    }

    private var resultPhase: ResultPhase {
        guard engine.hasResultSection else { return .none }
        switch engine.state {
        case .translating: return .waiting
        case .failed: return .failed
        default: return .text
        }
    }

    @ViewBuilder
    private var resultArea: some View {
        // `.transition(.opacity)` on each branch, driven by `.motion(.layout, value:
        // resultPhase)` at the top of `body`. Without them the skeleton is replaced by
        // the finished text in a single frame while the box around it is still easing
        // its height — the last hard cut in the panel, and the most visible one, since
        // it lands exactly where the user is looking.
        switch engine.state {
        case .failed(let message):
            ErrorBox(
                message: message,
                primaryLabel: failureActionLabel,
                primaryAction: performFailureAction
            )
            .transition(.opacity)
        case .translating:
            VStack(alignment: .leading, spacing: 8) {
                StreamingPlaceholder()
                    .padding(.vertical, 2)
                // The copy capsule's slot, held by the stop control while the answer is
                // on its way, so the footer keeps its shape when the text lands.
                HStack {
                    Spacer(minLength: 8)
                    StopButton { engine.cancelTranslation() }
                }
            }
            .transition(.opacity)
        default:
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.vertical) {
                    Text(engine.output)
                        .font(Theme.contentFont)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        // Matches TextEditor's default 5pt NSTextView line-fragment
                        // inset (see the input placeholder's identical padding and
                        // editorTextWidth's -10 above) so the result text's left
                        // edge lines up with the input's, instead of sitting 5pt
                        // further left.
                        .padding(.leading, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            GeometryReader { geometry in
                                Color.clear.preference(key: ResultHeightKey.self, value: geometry.size.height)
                            }
                        )
                }
                // The last holdout of the three scrollers in this panel, and the
                // only one still asking for an automatic indicator: macOS reserves an
                // opaque white gutter for it when the system is drawing legacy
                // scrollers (a mouse is attached), which against this transparent
                // panel is a white bar down the side of the translation. The input
                // editor and the history list already answer this the same way, for
                // the same reason. Trackpad, wheel and keyboard scrolling are
                // untouched; only the indicator goes.
                .scrollIndicators(.never)
                // Same trailing gap as the input, on the `Text` grid: a result long
                // enough to scroll is read by scrolling to its end, which is precisely
                // the state that puts the last line against the clip edge.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: textLineGap)
                }
                // Same treatment on the `Text` grid: a result long enough to scroll is
                // read by scrolling, and a hand-scrolled result has the same problem.
                .snapsScrollToLines(step: lineStep)
                .frame(height: min(max(resultHeight + textLineGap, 20), maxResultHeight))
                // A translation longer than the panel can be has to say so, or it
                // reads as one that simply stops mid-sentence — which is exactly how
                // it read once the system scroller (an opaque white gutter against
                // this panel) was taken away. The last line fades instead: it says
                // "there is more" in the panel's own vocabulary, costs no width, and
                // goes away the moment the text is fully scrolled.
                .mask(resultOverflows && !isAtBottom ? AnyView(fadeOutBottom) : AnyView(Rectangle()))
                .trackBottomEdge($isAtBottom)
                .onPreferenceChange(ResultHeightKey.self) { height in
                    HeightTrace.log("result text \(height)")
                    resultHeight = height
                }

                if let escalationFailure = engine.escalationFailure {
                    notice(String(format: L("没能取到在线结果 · %@"), escalationFailure), systemImage: "cloud.slash")
                }
                if engine.outputLanguageMismatch {
                    notice(L("结果语言与目标不符，建议重试"), systemImage: "exclamationmark.triangle")
                } else if engine.interrupted {
                    notice(L("已停止，结果不完整"), systemImage: "stop.circle")
                } else if engine.outputCapped {
                    notice(L("结果过长，已截断，仅保留开头部分"), systemImage: "scissors")
                } else if engine.restoredFromTruncatedHistory {
                    notice(L("历史仅保留部分内容"), systemImage: "scissors")
                }

                resultFooter
            }
        }
    }

    /// A remark about the text above it. Secondary ink, not orange: none of these ask
    /// the user to fix anything, and the retry they might want is in the footer.
    private func notice(_ text: String, systemImage: String) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.tertiary)
        }
        .font(Theme.meta)
        .foregroundStyle(.secondary)
        .padding(.leading, Self.resultNoticeInset)
        .transition(.opacity)
    }

    /// Everything about the answer on screen, on the line under it: where it came from
    /// and the other version on the left, copy on the right.
    private var resultFooter: some View {
        HStack(spacing: 10) {
            if let shown = shownVersion {
                ResultProvenance(
                    label: versionLabel(shown),
                    afterFailover: shown.afterFailover,
                    detail: slotTooltip(shown.slot)
                )
                .layoutPriority(-1)
            }

            if engine.escalating {
                // The result stays readable and copyable while this runs: it is still
                // the current answer until a better one lands.
                HStack(spacing: 5) {
                    Text("在线重译中…")
                        .foregroundStyle(.tertiary)
                    Button {
                        engine.cancelTranslation()
                    } label: {
                        Image(systemName: "stop.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("停止"))
                    .accessibilityLabel(L("停止"))
                }
                .font(Theme.meta)
                .transition(.opacity)
            } else if let other = otherVersion {
                Button {
                    engine.showVersion(other.index)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left.arrow.right")
                        Text(versionLabel(other.version))
                            .lineLimit(1)
                    }
                    .font(Theme.meta)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(format: L("显示 %@ 的翻译"), versionLabel(other.version)))
                .transition(.opacity)
            } else if engine.canEscalate {
                Button {
                    engine.escalate()
                } label: {
                    Text(settings.commandLabel(L("换在线重译"), action: .translate))
                        .font(Theme.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help(engine.escalationTargetLabel.map {
                    String(format: L("用 %@ 再翻一次，两个结果都会留着"), $0)
                } ?? L("请求在线版本，两个结果都会留着"))
                .transition(.opacity)
            }

            if engine.canRetryResult {
                Button(L("重试")) { engine.translate() }
                    .buttonStyle(.plain)
                    .font(Theme.metaMedium)
                    .foregroundStyle(Theme.accent)
            }

            Spacer(minLength: 8)

            if !engine.output.isEmpty {
                CopyButton(
                    copied: engine.copied,
                    failed: engine.copyFailed,
                    shortcutHint: settings.shortcut(.copy)?.display
                ) {
                    engine.copyOutput()
                }
                .overlay(alignment: .bottom) {
                    if let progress = panelState.returnHoldProgress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .controlSize(.mini)
                            .padding(.horizontal, 8)
                            .offset(y: 4)
                            .accessibilityLabel(L("重新翻译确认进度"))
                            .allowsHitTesting(false)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.leading, Self.resultNoticeInset)
    }

    // MARK: - Bottom bar

    // MARK: - History

    private struct HistoryDay: Identifiable {
        let id: Date
        let title: String
        let detail: String
        var records: [TranslationEngine.Record]
    }

    /// History grouped by calendar day, newest first. The day says when, so the rows
    /// don't each have to.
    private var historyDays: [HistoryDay] {
        let calendar = Calendar.current
        var days: [HistoryDay] = []
        for record in engine.history {
            let day = calendar.startOfDay(for: record.timestamp)
            if days.last?.id == day {
                days[days.count - 1].records.append(record)
            } else {
                days.append(HistoryDay(id: day, title: Self.dayTitle(day, calendar: calendar),
                                       detail: Self.dayDetail(day, calendar: calendar), records: [record]))
            }
        }
        return days
    }

    /// 今天, 昨天, then a short date in the interface language (with the year only when
    /// it is not this year).
    static func dayTitle(_ day: Date, calendar: Calendar = .current, now: Date = Date()) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return L("今天") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return L("昨天")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "zh-Hans")
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate(
            calendar.isDate(day, equalTo: now, toGranularity: .year) ? "MMMd" : "yMMMd"
        )
        return formatter.string(from: day)
    }

    /// The other half of a day header: the date and weekday for 今天/昨天, the weekday
    /// alone once the title is already a date.
    static func dayDetail(_ day: Date, calendar: Calendar = .current, now: Date = Date()) -> String {
        let named = calendar.isDate(day, inSameDayAs: now)
            || calendar.date(byAdding: .day, value: -1, to: now).map { calendar.isDate(day, inSameDayAs: $0) } == true
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "zh-Hans")
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate(named ? "MMMdEEE" : "EEE")
        return formatter.string(from: day)
    }

    private static let historyRowSpacing: CGFloat = 3
    private static let historyRowVerticalPadding: CGFloat = 6
    /// Between days: wide enough that a day reads as one group, and its header clearly
    /// belongs to the rows under it rather than the ones above.
    private static let dayGap: CGFloat = 22
    private static let dayHeaderGap: CGFloat = 4
    private static let historyFooterGap: CGFloat = 10
    private static let metaLineHeight = measureSingleLineHeight(fontSize: 11)

    /// Sized to the list's content up to a cap, so a short history doesn't sit in an
    /// empty viewport and a long one scrolls.
    private var historyViewportHeight: CGFloat? {
        guard !engine.history.isEmpty else { return nil }
        let days = CGFloat(historyDays.count)
        let meta = Self.metaLineHeight
        let rows = engine.history.reduce(0) { $0 + historyRowHeight(for: $1) }
        let headers = days * (meta + Self.dayHeaderGap) + max(days - 1, 0) * Self.dayGap
        // The footer sits inside this height but outside the scroll view, so a long
        // history scrolls above it and the footer stays in view.
        let footer = Self.historyFooterGap + meta
        return max(60, min(320, panelState.availableHeight - min(inputHeight, maxInputHeight) - 140,
                           rows + headers + footer))
    }

    private var historyList: some View {
        let days = historyDays
        return VStack(alignment: .leading, spacing: 0) {
            if days.isEmpty {
                // After a deletion the footer's undo already says the list is empty.
                if !engine.canUndoHistoryDeletion {
                    Text("还没有翻译记录")
                        .font(Theme.meta)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, Self.resultNoticeInset)
                }
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(days) { day in
                            // The day as a full-width row — its name on the left, the date
                            // on the right — so the boundary between days is drawn by the
                            // header itself and the space above it, not by a rule.
                            HStack(spacing: 8) {
                                Text(day.title)
                                    .font(Theme.metaMedium)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                Text(day.detail)
                                    .font(Theme.meta)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, Self.resultNoticeInset)
                            .padding(.top, day.id == days.first?.id ? 0 : Self.dayGap)
                            .padding(.bottom, Self.dayHeaderGap)
                            ForEach(day.records) { record in
                                HistoryRecordRow(record: record) {
                                    engine.restoreHistory(record)
                                    panelState.showHistory = false
                                }
                                .contextMenu {
                                    Button(role: .destructive) { engine.deleteHistory(record.id) } label: {
                                        Label(L("删除"), systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }

            if !days.isEmpty || engine.canUndoHistoryDeletion {
                historyFooter
                    .padding(.top, days.isEmpty ? 0 : Self.historyFooterGap)
            }
        }
        .frame(height: historyViewportHeight, alignment: .top)
    }

    /// One row under the list that never scrolls away: how much history keeps on the
    /// left, the commands on the right. Undo appears on the right too — beside Clear
    /// History after a single deletion, and in its very place once everything is cleared —
    /// so the way back is where the click just was. It stays until history is left.
    private var historyFooter: some View {
        HStack(spacing: 12) {
            Text(engine.history.isEmpty
                 ? L("历史已清空")
                 : String(format: L("只保留最近 %d 条"), TranslationEngine.historyCapacity))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            if engine.canUndoHistoryDeletion {
                Button(L("撤销")) { engine.undoHistoryDeletion() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            if !engine.history.isEmpty {
                Button(L("清空历史")) { engine.clearHistory() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .font(Theme.meta)
        .padding(.horizontal, Self.resultNoticeInset)
        .motion(.state, value: engine.canUndoHistoryDeletion)
    }

    // MARK: - Language picker

    /// One row of capsules: 「自动」(simple CN↔EN) plus each preset target, and (in auto
    /// mode) 「互换」. Selecting a language pill IS the mode decision — no separate
    /// multi-language switch exists anymore.
    ///
    /// Wrapped in a horizontal ScrollView rather than a bare HStack: an HStack that runs
    /// out of room silently crushes its `Text` children down to a bare "…" with zero
    /// characters showing instead of erroring — that's happened for real in this exact
    /// row once already. Scrolling degrades instead of destroying legibility, and costs
    /// nothing at any width where everything already fits.
    private var languagePickerRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            languagePickerPills
        }
    }

    private var languagePickerPills: some View {
        HStack(spacing: 6) {
            LanguagePill(
                label: L("自动"),
                selected: !settings.multiLanguageMode,
                icon: "sparkles"
            ) {
                engine.selectAutoTarget()
                closePicker()
            }

            ForEach(TranslationLanguage.presets, id: \.self) { language in
                LanguagePill(
                    label: language.displayName,
                    selected: settings.multiLanguageMode && engine.target == language
                ) {
                    engine.selectExplicitTarget(language)
                    closePicker()
                }
            }

            Spacer(minLength: 4)

            if !settings.multiLanguageMode {
                LanguagePill(
                    label: L("互换"),
                    selected: engine.flipped,
                    icon: "arrow.left.arrow.right"
                ) {
                    engine.flipDirection()
                    closePicker()
                }
                // flipDirection is a guarded no-op in exactly these cases; disabling
                // keeps the pill honest instead of silently swallowing the click.
                .disabled(engine.input.isEmpty || engine.isTranslating)
                .opacity(engine.input.isEmpty || engine.isTranslating ? 0.4 : 1)
                .help(L("切换翻译方向"))
            }
        }
    }

    private func closePicker() {
        panelState.showLanguagePicker = false
    }

    /// Where the remaining-characters count starts appearing: close enough to the
    /// ceiling that it is information, far enough that a normal paste never sees it.
    private static let inputCountdownThreshold = TranslationEngine.maxInputCharacters - 4_000

    /// TextEditor's default NSTextView line-fragment inset. The input editor gets it for
    /// free, the result text adds it back by hand, and so does everything printed under
    /// the result — otherwise the provenance label and the notices start 5pt to the left
    /// of the two blocks of text they are talking about.
    private static let resultNoticeInset: CGFloat = 5

    /// Names the slot a finished result came from. Host and model, not base URL: the
    /// label should say which machine answered, not reprint a configuration line.
    private func slotTooltip(_ slot: Int) -> String {
        guard settings.profiles.indices.contains(slot) else { return settings.label(for: slot) }
        let profile = settings.profiles[slot]
        let model = profile.model.trimmingCharacters(in: .whitespaces)
        let host = profile.config.displayHost
        let detail = [model, host].filter { !$0.isEmpty }.joined(separator: " · ")
        return detail.isEmpty ? settings.label(for: slot) : detail
    }

    private var shownVersion: TranslationEngine.ResultVersion? {
        engine.versions.indices.contains(engine.shownVersion)
            ? engine.versions[engine.shownVersion]
            : nil
    }

    /// The answer that is not on screen. There are at most two — one per tier — so
    /// "the other one" is always a single, well-defined thing, which is exactly why a
    /// swap link says more with less than a two-segment picker did.
    private var otherVersion: (index: Int, version: TranslationEngine.ResultVersion)? {
        guard engine.versions.count > 1 else { return nil }
        let index = engine.shownVersion == 0 ? 1 : 0
        guard engine.versions.indices.contains(index) else { return nil }
        return (index, engine.versions[index])
    }

    /// A version's name: the tier for the local slot (its host is an IP nobody reads as
    /// a name), the provider's short brand for an online one.
    private func versionLabel(_ version: TranslationEngine.ResultVersion) -> String {
        version.tier == .local ? L("本地") : (version.host.isEmpty ? L("在线") : SettingsStore.shortHostName(version.host))
    }

    // MARK: - Bottom bar

    /// Translation parameters on the left; the panel's own controls on the right — the pin,
    /// a window toggle, set a little apart from history and settings, which change what
    /// the panel shows. Nothing here changes with the state of a translation, so the row
    /// never moves. Every control lives here, so the reading area above keeps equal
    /// margins on both sides.
    private var bottomBar: some View {
        HStack(spacing: 8) {
            DirectionChip(
                sourceLabel: engine.sourceLabel,
                target: engine.target,
                isActive: !engine.input.isEmpty,
                isFlipped: engine.flipped,
                isExpanded: panelState.showLanguagePicker,
                onTap: {
                    panelState.showLanguagePicker.toggle()
                }
            )

            ToneSelector(tone: $settings.tone)

            Spacer(minLength: 4)

            BarIconButton(
                systemName: "pin",
                activeSystemName: "pin.fill",
                isActive: panelState.pinned,
                help: panelState.pinned ? "取消固定" : "固定面板（点击外部不关闭）",
                // The pin glyph is 14pt tall next to 13pt circles (clock/gearshape) at the
                // same 12pt font size; nudge it down 0.5pt so its optical centre aligns.
                glyphOffset: 0.5
            ) {
                panelState.pinned.toggle()
            }
            // A wider gap than the 8pt between history and settings: a different kind of
            // control, grouped by space rather than by a divider.
            .padding(.trailing, 6)

            BarIconButton(
                systemName: "clock",
                activeSystemName: "clock.fill",
                isActive: panelState.showHistory,
                help: settings.commandLabel(panelState.showHistory ? L("关闭历史") : L("翻译历史"), action: .history)
            ) {
                panelState.showHistory.toggle()
            }

            BarIconButton(systemName: "gearshape", help: "设置 (⌘,)") {
                panelState.showSettings = true
            }
        }
    }

}

private struct HistoryRecordRow: View {
    let record: TranslationEngine.Record
    let action: () -> Void

    @State private var hovering = false

    private var tooltip: String {
        var value = record.timestamp.formatted(date: .abbreviated, time: .shortened)
            + "\n\n\(record.input)\n\n\(record.output)"
        if record.isTruncated {
            value += "\n\n" + L("历史仅保留部分内容")
        }
        return value
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(record.input)
                        .font(Theme.meta)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if record.isTruncated {
                        Image(systemName: "scissors")
                            .font(Theme.meta)
                            .foregroundStyle(.tertiary)
                            .help(L("历史仅保留部分内容"))
                    }
                }
                Text(record.output)
                    .font(Theme.contentFont)
                    .lineSpacing(3)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 6)
            // No card at rest: the text and the space around it are the row.
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusStandard, style: .continuous)
                    .fill(hovering ? Theme.fillQuiet : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusStandard, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(.micro, value: hovering)
        .help(tooltip)
    }
}

private extension View {
    /// Keeps a "user is at the bottom of the scroll view" flag current. macOS 15+
    /// exposes ScrollGeometry for this; macOS 14 has no way to read a SwiftUI
    /// ScrollView's offset, so the flag simply stays at its initial value there
    /// (true — streaming keeps auto-following, the pre-existing behavior).
    @ViewBuilder
    func trackBottomEdge(_ isAtBottom: Binding<Bool>) -> some View {
        if #available(macOS 15.0, *) {
            onScrollGeometryChange(for: CGFloat.self) { geometry in
                // Distance from the bottom edge of the content, in points.
                max(0, geometry.contentSize.height - geometry.containerSize.height - geometry.contentOffset.y)
            } action: { _, distanceToBottom in
                isAtBottom.wrappedValue = distanceToBottom < 4
            }
        } else {
            self
        }
    }
}
