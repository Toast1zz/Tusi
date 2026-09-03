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
    /// Exact height of one `HistoryRecordRow`, measured (not guessed) from the same
    /// AppKit metrics as the other line-height math below — see `measureHistoryRowHeight`.
    private let historyRowHeight: CGFloat
    init() {
        let metrics = Self.measureLineMetrics()
        firstLineHeight = metrics.first
        lineStep = metrics.step
        let editorMetrics = Self.measureEditorLineMetrics()
        editorFirstLineHeight = editorMetrics.first
        editorLineStep = editorMetrics.step
        historyRowHeight = Self.measureHistoryRowHeight(firstLineHeight: metrics.first, lineStep: metrics.step)
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

    /// Derives `HistoryRecordRow`'s exact height from its actual layout (Theme.footnote
    /// title line + Theme.contentFont 2-line output + Theme.caption footer line, VStack
    /// spacing 5, vertical padding 7) instead of a hardcoded estimate. CJK and Latin text
    /// measure to different line heights, and this project has already been burned once
    /// by a font-size change silently clipping a hardcoded row height.
    private static func measureHistoryRowHeight(firstLineHeight: CGFloat, lineStep: CGFloat) -> CGFloat {
        let titleLineHeight = measureSingleLineHeight(fontSize: 11)  // Theme.footnote
        let footerLineHeight = measureSingleLineHeight(fontSize: 10)  // Theme.caption
        let outputTwoLineHeight = firstLineHeight + lineStep  // Theme.contentFont, lineLimit(2)
        let interLineSpacing: CGFloat = 5 * 2  // VStack(spacing: 5) between the 3 stacked lines
        let verticalPadding: CGFloat = 7 * 2
        return titleLineHeight + outputTwoLineHeight + footerLineHeight + interLineSpacing + verticalPadding
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
    // Six and fourteen whole grid cells, gap included — not `first + n × step`, which is
    // the same lines with the last one's spacing shaved off.
    private var maxInputHeight: CGFloat { 6 * editorLineStep }
    private var maxResultHeight: CGFloat { 14 * lineStep }

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
            // the same constraint ToneSelector documents).
            //
            // A `Disclosure`, not an `if` + `.move(edge: .bottom)`: the row's arrival is
            // the panel getting taller, and a vertical slide on top of that says the same
            // thing twice while leaving the stack's own height to change in one step.
            Disclosure(isExpanded: panelState.showLanguagePicker) {
                languagePickerRow
                    .padding(.horizontal, 16)
                    .padding(.top, engine.hasResultSection || panelState.showHistory ? 12 : 10)
            }

            // Horizontal padding matches inputArea/resultArea/SoftDivider above (16, not
            // 12) so the copy button's right edge lines up with the clear button's and
            // with the input/result text's own right margin — one consistent margin for
            // the whole panel instead of the bottom row sitting 4pt closer to the edge.
            bottomBar
                .padding(.horizontal, 16)
                .padding(.top, panelState.showLanguagePicker ? 8 : (engine.hasResultSection || panelState.showHistory ? 12 : 10))
                .padding(.bottom, 10)
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
        // Switching tone is a request to see the text in that tone, so re-run it —
        // but only when there's already a result the change would apply to.
        .onChange(of: settings.tone) { _, _ in
            guard engine.hasResultSection, !engine.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            engine.translate()
        }
    }

    // MARK: - Input

    private var inputArea: some View {
        let height = inputHeight
        return VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                if engine.input.isEmpty {
                    Text("输入中文或任意语言，⏎ 翻译")
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
                    .frame(height: min(max(height, 24), maxInputHeight))
            }

            if engine.inputWasTruncated {
                Label(
                    String(format: L("输入已截断，最多保留 %d 字"), TranslationEngine.maxInputCharacters),
                    systemImage: "scissors"
                )
                .font(Theme.caption)
                .foregroundStyle(.orange)
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
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
                .transition(.opacity)
            }
        }
        // Keyed to *which* notice is showing, not to the input itself. The editor grows
        // and shrinks on every keystroke and must never animate — that would put the text
        // behind the caret. A notice appearing or disappearing is a different event: it
        // adds a line to the panel, so it rides the same clock the window does.
        .motion(.layout, value: inputNotice)
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
            StreamingPlaceholder()
                .padding(.vertical, 2)
                .transition(.opacity)
        default:
            VStack(alignment: .leading, spacing: 8) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        // The scroll anchor rides on the text itself — a separate spacer
                        // child would add implicit VStack spacing and clip the top.
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
                            .id("end")
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
                    // enough to scroll is auto-scrolled to its tail on every chunk, which
                    // is precisely the state that puts the last line against the clip edge.
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Color.clear.frame(height: textLineGap)
                    }
                    .frame(height: min(max(resultHeight + textLineGap, 20), maxResultHeight))
                    .trackBottomEdge($isAtBottom)
                    .onPreferenceChange(ResultHeightKey.self) { height in
                        HeightTrace.log("result text \(height)")
                        resultHeight = height
                    }
                    .onChange(of: engine.output) { _, _ in
                        if engine.isTranslating, isAtBottom {
                            proxy.scrollTo("end", anchor: .bottom)
                        }
                    }
                }

                // Where this came from, and the offer of a better one — under the
                // result, in the flow, covering nothing. This row is what the "who was
                // faster" and "used the backup" toasts turned into: the same facts,
                // stated for as long as they are true instead of for 2.2 seconds on top
                // of the text.
                //
                // Everything from here down carries the result text's own 5pt leading
                // inset (see `resultNoticeInset`), so the provenance label, the notices
                // and the translation all begin on one vertical line — and on the same
                // line as the input above them, which shares that inset because it comes
                // from TextEditor's NSTextView line-fragment padding.
                if !engine.versions.isEmpty || engine.escalating {
                    HStack(spacing: 8) {
                        if let shown = shownVersion {
                            ResultProvenance(
                                label: versionLabel(shown),
                                isLocal: shown.tier == .local,
                                afterFailover: shown.afterFailover
                            )
                            .help(slotTooltip(shown.slot))
                        }

                        Spacer(minLength: 4)

                        if engine.escalating {
                            // The result stays readable and copyable while this runs: it
                            // is still the current answer until a better one lands.
                            HStack(spacing: 5) {
                                Text("在线重译中…")
                                    .font(Theme.caption)
                                    .foregroundStyle(.tertiary)
                                Button {
                                    engine.cancelTranslation()
                                } label: {
                                    Image(systemName: "stop.circle")
                                        .font(Theme.bodySmall)
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                                .help(L("停止"))
                                .accessibilityLabel(L("停止"))
                            }
                            .transition(.opacity)
                        } else if let other = otherVersion {
                            // Free, instant and reversible: the other answer is already
                            // in hand. Swapping it in place is also what makes the
                            // difference legible — side by side, in a panel this narrow,
                            // both columns would be too cramped to read.
                            Button {
                                engine.showVersion(other.index)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.left.arrow.right")
                                        .font(Theme.caption2)
                                    Text(versionLabel(other.version))
                                        .font(Theme.caption)
                                        .lineLimit(1)
                                }
                                .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(String(format: L("显示 %@ 的翻译"), versionLabel(other.version)))
                            .transition(.opacity)
                        } else if engine.canEscalate {
                            // The whole feature in one line, at the only moment it is
                            // useful: after you have read the answer and know whether it
                            // was enough. The tier, not the provider — which slot answers
                            // depends on the online strategy, and the label under the next
                            // result will name it anyway.
                            Button {
                                engine.escalate()
                            } label: {
                                Text("⏎ 换在线重译")
                                    .font(Theme.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .help(engine.escalationTargetLabel.map {
                                String(format: L("用 %@ 再翻一次，两个结果都会留着"), $0)
                            } ?? L("用更强的模型再翻一次，两个结果都会留着"))
                            .transition(.opacity)
                        }
                    }
                    .padding(.leading, Self.resultNoticeInset)
                    .transition(.opacity)
                }

                // An escalation that came back empty-handed says so quietly. The
                // translation above it is untouched and still perfectly usable — this
                // is a second opinion that did not arrive, not a failure of the result.
                if let escalationFailure = engine.escalationFailure {
                    Label(String(format: L("没能取到在线结果 · %@"), escalationFailure), systemImage: "cloud.slash")
                        .font(Theme.footnoteMedium)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, Self.resultNoticeInset)
                        .transition(.opacity)
                }

                // A user-stopped stream keeps its partial text, but it must not pass for
                // a complete translation — say so right under the result.
                // `.fixedSize(horizontal: false, vertical: true)` on every notice: the
                // panel is a fixed width (RootView pins it to `panelWidth`), so a notice
                // that insists on one long line pushes the whole content block wider than
                // the window and gets it centre-clipped on both edges — input text on the
                // left, the copy button on the right. Longer localisations must wrap.
                if engine.outputLanguageMismatch {
                    // Checked first: a result in the wrong language is wrong outright,
                    // which matters more than how it ended.
                    Label(L("结果语言与目标不符，建议重试"), systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.footnoteMedium)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, Self.resultNoticeInset)
                        .transition(.opacity)
                } else if engine.interrupted {
                    Label(L("已停止，结果不完整"), systemImage: "stop.circle.fill")
                        .font(Theme.footnoteMedium)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, Self.resultNoticeInset)
                        .transition(.opacity)
                } else if engine.outputCapped {
                    // Same honesty for an overlong result cut at the length cap.
                    Label(L("结果过长，已截断，仅保留开头部分"), systemImage: "scissors")
                        .font(Theme.footnoteMedium)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, Self.resultNoticeInset)
                        .transition(.opacity)
                } else if engine.restoredFromTruncatedHistory {
                    Label(L("历史仅保留部分内容"), systemImage: "scissors")
                        .font(Theme.footnoteMedium)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, Self.resultNoticeInset)
                        .transition(.opacity)
                }
            }
        }
    }

    // MARK: - Bottom bar

    // MARK: - History
    private var historyViewportHeight: CGFloat {
        guard !engine.history.isEmpty else { return 112 }
        let rowSpacing: CGFloat = 4  // LazyVStack(spacing: 4) between rows
        return min(320, 28 + CGFloat(engine.history.count) * (historyRowHeight + rowSpacing))
    }
    private var historyList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("翻译历史")
                    .font(Theme.footnoteSemibold)
                    .foregroundStyle(.secondary)
                Text("\(engine.history.count)")
                    .font(Theme.caption2Rounded)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.fillQuiet))
                Spacer(minLength: 4)
                if !engine.history.isEmpty {
                    Button("清空历史") {
                        engine.clearHistory()
                    }
                    .buttonStyle(.plain)
                    .font(Theme.caption2Medium)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.bottom, 9)

            if engine.history.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(Theme.emptyState)
                    Text("翻译历史为空")
                        .font(Theme.bodySmall)
                }
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 4) {
                        ForEach(engine.history) { record in
                            HistoryRecordRow(
                                record: record,
                                relativeTime: relativeTime(record.timestamp)
                            ) {
                                engine.restoreHistory(record)
                                panelState.showHistory = false
                            }
                        }
                    }
                }
                // macOS 27 can reserve an opaque white gutter for an automatic
                // scroller inside this transparent panel. Hide only the indicator;
                // trackpad, wheel and keyboard scrolling remain unchanged.
                .scrollIndicators(.never)
            }
        }
        .frame(height: historyViewportHeight)
    }


    private func relativeTime(_ date: Date) -> String {
        let interval = -date.timeIntervalSinceNow
        switch interval {
        case ..<60: return L("刚刚")
        case ..<3600: return String(format: L("%d 分钟前"), Int(interval / 60))
        case ..<86400: return String(format: L("%d 小时前"), Int(interval / 3600))
        default: return String(format: L("%d 天前"), Int(interval / 86400))
        }
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

    /// The side margin every row in `body` uses. Named here because the bottom bar's
    /// width measurement has to add it back to report a panel width.
    private static let contentHorizontalInset: CGFloat = 16

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
        version.tier == .local ? L("本地") : settings.label(for: version.slot)
    }

    private var bottomBar: some View {
        // Every control in this row is `.fixedSize(horizontal: true)`, so the row has one
        // natural width and no way to give. In English that width ("Casual/Standard/
        // Formal", "Copy ⇧⌘C") exceeds the 470pt minimum panel, and because RootView pins
        // the content to `panelWidth` the whole column gets centre-clipped — the input
        // text loses characters on the left and the copy button loses its shortcut on the
        // right. Shed the keyboard hint instead of overflowing; it is the one piece here
        // that is pure redundancy (the same shortcut still works, and it's in Settings).
        ViewThatFits(in: .horizontal) {
            bottomBarRow(showsCopyShortcut: true)
            bottomBarRow(showsCopyShortcut: false)
        }
        // Report the width this row actually needs so the panel can widen to fit it,
        // instead of the row being squeezed against a fixed panel width. Measured from an
        // invisible unconstrained copy — the visible row is already inside the fixed frame
        // and would only ever report the width it was given.
        //
        // `measuring: true` pins the copy to the row's widest configuration (the copy
        // button, with its shortcut hint). Measuring the live row instead would report a
        // different width per state — stop button, translate button, copy button — and the
        // window would jump sideways every time a translation started or finished.
        .background(
            bottomBarRow(showsCopyShortcut: true, measuring: true)
                .fixedSize(horizontal: true, vertical: true)
                // The reported number is a *panel* width, so it has to include the side
                // margins the body puts around this row — measuring the row alone would
                // size the window 32pt too narrow and the row would still be squeezed.
                .padding(.horizontal, Self.contentHorizontalInset)
                .hidden()
                .allowsHitTesting(false)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: PanelContentWidthKey.self, value: proxy.size.width)
                    }
                )
        )
    }

    /// Which controls the bottom bar is currently showing. See the `.motion` call at the
    /// bottom of `bottomBarRow` for why this is one value rather than three.
    private struct BarConfiguration: Equatable {
        let hasOutput: Bool
        let isTranslating: Bool
    }

    private var barConfiguration: BarConfiguration {
        BarConfiguration(
            hasOutput: !engine.output.isEmpty,
            isTranslating: engine.isTranslating
        )
    }

    private func bottomBarRow(showsCopyShortcut: Bool, measuring: Bool = false) -> some View {
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

            // Tone occupies the slot the model name used to: it's an action, the model
            // is static trivia that settings already shows. It stays in the tooltip.
            ToneSelector(tone: $settings.tone)
                .help(String(format: L("翻译文风 · 当前模型：%@"), engine.activeModel))

            Spacer(minLength: 4)

            if measuring {
                // Nothing here: the measuring copy carries the copy button below, which is
                // wider than either the stop or the translate control it would replace.
                EmptyView()
            } else if engine.isTranslating {
                // No spinner: the shimmering result placeholder already says "working".
                BarIconButton(systemName: "stop.fill", help: "停止") {
                    engine.cancelTranslation()
                }
                .transition(.opacity)
            } else if !engine.input.isEmpty && engine.output.isEmpty {
                let hasInput = !engine.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button {
                    engine.submit()
                } label: {
                    Text("⏎ 翻译")
                        .font(Theme.footnoteMedium)
                        .lineLimit(1)
                        // minWidth, not a hard width: the slot stays stable at the Chinese
                        // label's size (no bar jitter) but "⏎ Translate" is wider and would
                        // be clipped by a fixed 48pt.
                        .frame(height: 26)
                        .frame(minWidth: 48)
                }
                .buttonStyle(.plain)
                .disabled(!hasInput)
                .foregroundStyle(hasInput ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .accessibilityLabel(L("翻译"))
                .help(L("翻译"))
                .transition(.opacity)
            }

            BarIconButton(
                systemName: panelState.pinned ? "pin.fill" : "pin",
                isActive: panelState.pinned,
                help: panelState.pinned ? "取消固定" : "固定面板（点击外部不关闭）",
                // The pin glyph is 14pt tall next to 13pt circles (clock/gearshape) at
                // the same 12pt font size; nudge it down 0.5pt so its optical center
                // aligns with its neighbors instead of sitting visually higher.
                glyphOffset: 0.5
            ) {
                panelState.pinned.toggle()
            }
            BarIconButton(
                systemName: panelState.showHistory ? "clock.fill" : "clock",
                isActive: panelState.showHistory,
                help: panelState.showHistory ? "关闭历史" : "翻译历史"
            ) {
                panelState.showHistory.toggle()
            }

            BarIconButton(systemName: "gearshape", help: "设置 (⌘,)") {
                panelState.showSettings = true
            }

            if measuring || (!engine.isTranslating && !engine.output.isEmpty) {
                CopyButton(copied: engine.copied, failed: engine.copyFailed, shortcutHint: showsCopyShortcut ? settings.shortcut(.copy)?.display : nil) {
                    engine.copyOutput()
                }
                    // Opacity only. The stop and translate controls that share this
                    // slot both plain-fade; a scale pop on just one of the three made
                    // the same position behave differently depending on which control
                    // happened to be in it.
                    .transition(.opacity)
            }
        }
        // One value, one timeline. Pressing ⏎ swaps a control here *and* opens the result
        // section above, and finishing a translation swaps it back *and* resizes the
        // panel to fit the text — so this row is part of a height change whether or not
        // its own height moves, and has to run on the same clock as the panel. Three
        // separate `.motion` scopes would let one keystroke start three animations.
        .motion(.layout, value: barConfiguration)
    }
}

private struct HistoryRecordRow: View {
    let record: TranslationEngine.Record
    let relativeTime: String
    let action: () -> Void

    @State private var hovering = false

    private var tooltip: String {
        var value = "\(record.input)\n\n\(record.output)"
        if record.isTruncated {
            value += "\n\n" + L("历史仅保留部分内容")
        }
        return value
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(record.input)
                        .font(Theme.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if record.isTruncated {
                        Image(systemName: "scissors")
                            .font(Theme.caption2Semibold)
                            .foregroundStyle(.orange)
                            .help(L("历史仅保留部分内容"))
                    }
                }
                Text(record.output)
                    .font(Theme.contentFont)
                    .lineSpacing(3)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text(record.sourceLabel + " → " + record.target.symbol)
                    Spacer(minLength: 4)
                    Text(relativeTime)
                }
                .font(Theme.caption)
                .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusStandard, style: .continuous)
                    .fill(hovering ? Theme.fillHover : Theme.fillFaint)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusStandard, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(.micro, value: hovering)
        // Rows truncate to keep the list compact; the hover tooltip shows the full
        // text so a long record is still fully readable without opening it.
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
