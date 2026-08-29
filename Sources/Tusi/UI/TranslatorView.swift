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
    /// Exact height of one `HistoryRecordRow`, measured (not guessed) from the same
    /// AppKit metrics as the other line-height math below — see `measureHistoryRowHeight`.
    private let historyRowHeight: CGFloat
    init() {
        let metrics = Self.measureLineMetrics()
        firstLineHeight = metrics.first
        lineStep = metrics.step
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

    // Caps expressed as whole lines so a clamped view never cuts a line in half — the panel
    // grows to fit short content, and long content scrolls inside a whole-line viewport.
    // The input's cap sits exactly on the 6-line boundary (no +2 fudge): the scrolling
    // TextEditor's inset otherwise pushed the cap ~2pt into the 7th line, showing a sliver.
    private var maxInputHeight: CGFloat { height(lines: 6) }
    private var maxResultHeight: CGFloat { height(lines: 14) }

    private var editorTextWidth: CGFloat { panelState.panelWidth - 32 - 10 }

    /// Measures the input's natural height with AppKit metrics so it matches
    /// TextEditor's actual NSTextView layout (SwiftUI Text metrics differ for CJK).
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
        if text.hasSuffix("\n") { text += " " }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 15),
            .paragraphStyle: style,
        ])
        let rect = attributed.boundingRect(
            with: NSSize(width: editorTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        )
        let height = ceil(rect.height) + 2
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

            if panelState.showHistory {
                SoftDivider()
                    .padding(.horizontal, 16)
                    .padding(.top, 14)

                historyList
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            } else if engine.hasResultSection {
                SoftDivider()
                    .padding(.horizontal, 16)
                    .padding(.top, 14)

                resultArea
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }

            // Inline target picker: expands ABOVE the bottom bar (never a popover — a
            // popup makes the panel resign key and trip the click-outside auto-hide,
            // the same constraint ToneSelector documents).
            if panelState.showLanguagePicker {
                languagePickerRow
                    .padding(.horizontal, 16)
                    .padding(.top, engine.hasResultSection || panelState.showHistory ? 12 : 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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
        .overlay(alignment: .top) {
            // All toasts live at the top now, one overlay instead of two split by
            // case: the bottom spot sits right over the result text the user just
            // asked to read, and that was true for fellBack/truncatedInput too, not
            // just raceWon — the top only ever covers the input they already typed
            // and aren't rereading. A slide-down-and-fade (not scale) reads as a
            // notification arriving, not a bubble popping.
            if let toast = engine.toast {
                Group {
                    switch toast {
                    case .fellBack: Toast.fellBack()
                    case .truncatedInput: Toast.truncatedInput()
                    case .copyFailed: Toast.copyFailed()
                    case .raceWon(let host): Toast.raceWon(host)
                    }
                }
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Theme.layoutChange, value: engine.hasResultSection)
        .animation(Theme.stateChange, value: engine.toast)
        .animation(Theme.layoutChange, value: panelState.showHistory)
        .animation(Theme.layoutChange, value: panelState.showLanguagePicker)
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
                    // System overlay scroller, not hidden: with the editor capped at
                    // five lines, a longer draft has nothing else saying there is more
                    // text above or below. macOS only draws the scroller while the view
                    // actually scrolls, so a short input stays exactly as clean as it
                    // was — this costs nothing until there is something to discover.
                    .scrollIndicators(.automatic)
                    .focused($inputFocused)
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
    }

    // MARK: - Result

    /// The one button that can move a failed state forward. A missing configuration is
    /// fixed in Settings, not by asking the same endpoint again; a dropped connection is
    /// the opposite. `FailureKind` carries which case this is.
    private var failureActionLabel: String {
        switch engine.failureKind {
        case .localModelNotConfigured: return L("配置本地模型")
        case .notConfigured, .credentials, .configuration: return L("打开设置")
        case .transient, .unknown, .none: return L("重试")
        }
    }

    private func performFailureAction() {
        switch engine.failureKind {
        case .localModelNotConfigured:
            // Land on the slot that needs filling in rather than the page's last tab.
            panelState.settingsProfileIndex = SettingsStore.localProfileIndex
            withAnimation(Theme.pageTransition) { panelState.showSettings = true }
        case .notConfigured, .credentials, .configuration:
            withAnimation(Theme.pageTransition) { panelState.showSettings = true }
        case .transient, .unknown, .none:
            engine.translate()
        }
    }

    @ViewBuilder
    private var resultArea: some View {
        switch engine.state {
        case .failed(let message):
            ErrorBox(
                message: message,
                primaryLabel: failureActionLabel,
                primaryAction: performFailureAction,
                onCopyDiagnostics: { engine.copyDiagnostics() }
            )
        case .translating:
            StreamingPlaceholder()
                .padding(.vertical, 2)
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
                    // Same reasoning as the input editor: a result taller than its
                    // viewport is otherwise indistinguishable from one that ends there.
                    .scrollIndicators(.automatic)
                    .frame(height: min(max(resultHeight, 20), maxResultHeight))
                    .trackBottomEdge($isAtBottom)
                    .onPreferenceChange(ResultHeightKey.self) { resultHeight = $0 }
                    .onChange(of: engine.output) { _, _ in
                        if engine.isTranslating, isAtBottom {
                            proxy.scrollTo("end", anchor: .bottom)
                        }
                    }
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
                        .transition(.opacity)
                } else if engine.interrupted {
                    Label(L("已停止，结果不完整"), systemImage: "stop.circle.fill")
                        .font(Theme.footnoteMedium)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                } else if engine.outputCapped {
                    // Same honesty for an overlong result cut at the length cap.
                    Label(L("结果过长，已截断，仅保留开头部分"), systemImage: "scissors")
                        .font(Theme.footnoteMedium)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                } else if engine.restoredFromTruncatedHistory {
                    Label(L("历史仅保留部分内容"), systemImage: "scissors")
                        .font(Theme.footnoteMedium)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
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
                // A history list longer than the viewport looked exactly like a full
                // one; the overlay scroller is the system's own answer to that.
                .scrollIndicators(.automatic)
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
        withAnimation(Theme.stateChange) {
            panelState.showLanguagePicker = false
        }
    }

    /// Where the remaining-characters count starts appearing: close enough to the
    /// ceiling that it is information, far enough that a normal paste never sees it.
    private static let inputCountdownThreshold = TranslationEngine.maxInputCharacters - 4_000

    /// The side margin every row in `body` uses. Named here because the bottom bar's
    /// width measurement has to add it back to report a panel width.
    private static let contentHorizontalInset: CGFloat = 16

    /// Names the slot the local-model mode is pointing at. Host, not base URL: the
    /// marker should say which machine is answering, not reprint a configuration line.
    private var localModelTooltip: String {
        let index = SettingsStore.localProfileIndex
        guard settings.profiles.indices.contains(index) else { return L("正在使用本地模型") }
        let profile = settings.profiles[index]
        let model = profile.model.trimmingCharacters(in: .whitespaces)
        let host = profile.config.displayHost
        guard !model.isEmpty || !host.isEmpty else {
            return L("正在使用本地模型（尚未配置，请在设置中填写）")
        }
        let detail = [model, host].filter { !$0.isEmpty }.joined(separator: " · ")
        return String(format: L("正在使用本地模型 · %@"), detail)
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

    private func bottomBarRow(showsCopyShortcut: Bool, measuring: Bool = false) -> some View {
        HStack(spacing: 8) {
            DirectionChip(
                sourceLabel: engine.sourceLabel,
                target: engine.target,
                isActive: !engine.input.isEmpty,
                isFlipped: engine.flipped,
                isExpanded: panelState.showLanguagePicker,
                onTap: {
                    withAnimation(Theme.stateChange) {
                        panelState.showLanguagePicker.toggle()
                    }
                }
            )

            // Tone occupies the slot the model name used to: it's an action, the model
            // is static trivia that settings already shows. It stays in the tooltip.
            ToneSelector(tone: $settings.tone)
                .help(String(format: L("翻译文风 · 当前模型：%@"), engine.activeModel))

            // "Use the local model" is a standing mode, not a per-request choice: once
            // it's on, every ⏎ goes to that one slot — no primary, no backup, no race.
            // A mode with those consequences must be visible where translating happens,
            // not only on the Settings page where it was switched on. Icon only, no
            // label: the bar is already the width-critical row, and the tooltip carries
            // the model and host (never the full URL, which may contain a port and path
            // the user has no reason to broadcast on screen).
            if settings.useLocalModel {
                Image(systemName: "desktopcomputer")
                    .font(Theme.footnote)
                    .foregroundStyle(.secondary)
                    .help(localModelTooltip)
                    .accessibilityLabel(L("正在使用本地模型"))
                    .transition(.opacity)
            }

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
                    engine.translate()
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
                withAnimation(Theme.stateChange) {
                    panelState.showHistory.toggle()
                }
            }

            BarIconButton(systemName: "gearshape", help: "设置 (⌘,)") {
                withAnimation(Theme.pageTransition) {
                    panelState.showSettings = true
                }
            }

            if measuring || (!engine.isTranslating && !engine.output.isEmpty) {
                CopyButton(copied: engine.copied, shortcutHint: showsCopyShortcut ? settings.shortcut(.copy)?.display : nil) {
                    engine.copyOutput()
                }
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(Theme.layoutChange, value: engine.output.isEmpty)
        .animation(Theme.layoutChange, value: engine.isTranslating)
        .animation(Theme.layoutChange, value: panelState.showHistory)
        .animation(Theme.layoutChange, value: settings.useLocalModel)
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
        .animation(Theme.microMotion, value: hovering)
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
