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

            // Horizontal padding matches inputArea/resultArea/SoftDivider above (16, not
            // 12) so the copy button's right edge lines up with the clear button's and
            // with the input/result text's own right margin — one consistent margin for
            // the whole panel instead of the bottom row sitting 4pt closer to the edge.
            bottomBar
                .padding(.horizontal, 16)
                .padding(.top, engine.hasResultSection || panelState.showHistory ? 12 : 10)
                .padding(.bottom, 10)
        }
        .overlay(alignment: .bottom) {
            if let toast = engine.toast {
                Group {
                    switch toast {
                    case .fellBack: Toast.fellBack()
                    case .truncatedInput: Toast.truncatedInput()
                    }
                }
                .padding(.bottom, 48)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: Theme.durationSlow), value: engine.hasResultSection)
        .animation(.snappy(duration: Theme.durationSlow), value: engine.toast)
        .animation(.snappy(duration: Theme.durationSlow), value: panelState.showHistory)
        .onReceive(NotificationCenter.default.publisher(for: .tusiFocusInput)) { notification in
            let selectAll = notification.object as? Bool == true
            inputFocused = true
            guard selectAll else { return }
            Task { @MainActor in
                await Task.yield()
                (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
            }
        }
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
        return ZStack(alignment: .topLeading) {
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
                .scrollIndicators(.never)
                .focused($inputFocused)
                .frame(height: min(max(height, 24), maxInputHeight))
        }
    }

    // MARK: - Result

    @ViewBuilder
    private var resultArea: some View {
        switch engine.state {
        case .failed(let message):
            ErrorBox(message: message) { engine.translate() }
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
                    .scrollIndicators(.never)
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
                if engine.interrupted {
                    Label(L("已停止，结果不完整"), systemImage: "stop.circle.fill")
                        .font(Theme.footnoteMedium)
                        .foregroundStyle(.orange)
                        .transition(.opacity)
                } else if engine.outputCapped {
                    // Same honesty for an overlong result cut at the length cap.
                    Label(L("结果过长，已截断，仅保留开头部分"), systemImage: "scissors")
                        .font(Theme.footnoteMedium)
                        .foregroundStyle(.orange)
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
                    .background(Capsule().fill(Color.primary.opacity(0.055)))
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

    private var bottomBar: some View {
        HStack(spacing: 8) {
            DirectionChip(
                sourceLabel: engine.sourceLabel,
                target: engine.target,
                isActive: !engine.input.isEmpty,
                isFlipped: engine.flipped,
                // Disabled while translating: the in-flight request already captured
                // its target, so a flip would make the chip disagree with the result.
                isInteractive: !settings.multiLanguageMode && !engine.isTranslating,
                onFlip: { engine.flipDirection() }
            )

            // Tone occupies the slot the model name used to: it's an action, the model
            // is static trivia that settings already shows. It stays in the tooltip.
            ToneSelector(tone: $settings.tone)
                .help(String(format: L("翻译文风 · 当前模型：%@"), engine.activeModel))

            Spacer(minLength: 4)

            if engine.isTranslating {
                // No spinner: the shimmering result placeholder already says "working".
                BarIconButton(systemName: "stop.fill", help: "停止") {
                    engine.cancelTranslation()
                }
                .transition(.opacity)
            } else if !engine.input.isEmpty && engine.output.isEmpty {
                Text("⏎ 翻译")
                    .font(Theme.footnoteMedium)
                    .foregroundStyle(.tertiary)
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
                withAnimation(.snappy(duration: Theme.durationSlow)) {
                    panelState.showHistory.toggle()
                }
            }

            BarIconButton(systemName: "gearshape", help: "设置 (⌘,)") {
                withAnimation(.snappy(duration: Theme.durationSlow)) {
                    panelState.showSettings = true
                }
            }

            if !engine.isTranslating && !engine.output.isEmpty {
                CopyButton(copied: engine.copied, shortcutHint: settings.shortcut(.copy)?.display) {
                    engine.copyOutput()
                }
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: Theme.durationStandard), value: engine.output.isEmpty)
        .animation(.snappy(duration: Theme.durationStandard), value: engine.isTranslating)
        .animation(.snappy(duration: Theme.durationStandard), value: panelState.showHistory)
    }
}

private struct HistoryRecordRow: View {
    let record: TranslationEngine.Record
    let relativeTime: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                Text(record.input)
                    .font(Theme.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
                RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.065) : Color.primary.opacity(0.025))
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: Theme.durationFast), value: hovering)
        // Rows truncate to keep the list compact; the hover tooltip shows the full
        // text so a long record is still fully readable without opening it.
        .help("\(record.input)\n\n\(record.output)")
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
