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

    // Line geometry for the 15pt content font with lineSpacing 3, measured empirically:
    // the first line is 19pt and every line after adds 22pt. Input (AppKit metrics) and
    // result (SwiftUI Text) both come out to these same numbers.
    private let firstLineHeight: CGFloat = 19
    private let lineStep: CGFloat = 22
    private func height(lines: Int) -> CGFloat { firstLineHeight + CGFloat(lines - 1) * lineStep }

    // Caps expressed as whole lines so a clamped view never cuts a line in half — the panel
    // grows to fit short content, and long content scrolls inside a whole-line viewport.
    // The input's cap sits exactly on the 6-line boundary (no +2 fudge): the scrolling
    // TextEditor's inset otherwise pushed the cap ~2pt into the 7th line, showing a sliver.
    private var maxInputHeight: CGFloat { height(lines: 6) }
    private var maxResultHeight: CGFloat { height(lines: 14) }

    private var editorTextWidth: CGFloat { panelState.panelWidth - 32 - 10 }

    /// Measures the input's natural height with AppKit metrics so it matches
    /// TextEditor's actual NSTextView layout (SwiftUI Text metrics differ for CJK).
    private var inputHeight: CGFloat {
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
        return ceil(rect.height) + 2
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
                    }
                }
                .padding(.bottom, 48)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: engine.hasResultSection)
        .animation(.snappy(duration: 0.25), value: engine.toast)
        .animation(.snappy(duration: 0.25), value: panelState.showHistory)
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
        .onChange(of: settings.tone) { _ in
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
        case .translating where engine.output.isEmpty:
            StreamingPlaceholder()
                .padding(.vertical, 2)
        default:
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    // The scroll anchor rides on the text itself — a separate spacer
                    // child would add implicit VStack spacing and clip the top.
                    Text(engine.output)
                        .font(Theme.contentFont)
                        .lineSpacing(3)
                        .textSelection(.enabled)
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
                .onPreferenceChange(ResultHeightKey.self) { resultHeight = $0 }
                .onChange(of: engine.output) { _ in
                    if engine.isTranslating {
                        proxy.scrollTo("end", anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Bottom bar

    // MARK: - History
    private var historyViewportHeight: CGFloat {
        guard !engine.history.isEmpty else { return 112 }
        return min(320, 28 + CGFloat(engine.history.count) * 86)
    }
    private var historyList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("翻译历史")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(engine.history.count)")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
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
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.bottom, 9)

            if engine.history.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 18, weight: .light))
                    Text("翻译历史为空")
                        .font(.system(size: 12))
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
                isInteractive: !settings.multiLanguageMode,
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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            }

            BarIconButton(
                systemName: panelState.pinned ? "pin.fill" : "pin",
                isActive: panelState.pinned,
                help: panelState.pinned ? "取消固定" : "固定面板（点击外部不关闭）"
            ) {
                panelState.pinned.toggle()
            }
            BarIconButton(
                systemName: panelState.showHistory ? "clock.fill" : "clock",
                isActive: panelState.showHistory,
                help: panelState.showHistory ? "关闭历史" : "翻译历史"
            ) {
                withAnimation(.snappy(duration: 0.25)) {
                    panelState.showHistory.toggle()
                }
            }

            BarIconButton(systemName: "gearshape", help: "设置 (⌘,)") {
                withAnimation(.snappy(duration: 0.25)) {
                    panelState.showSettings = true
                }
            }

            if !engine.output.isEmpty {
                CopyButton(copied: engine.copied, shortcutHint: settings.shortcut(.copy).display) {
                    engine.copyOutput()
                }
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: engine.output.isEmpty)
        .animation(.snappy(duration: 0.22), value: engine.isTranslating)
        .animation(.snappy(duration: 0.22), value: panelState.showHistory)
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
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(record.output)
                    .font(Theme.contentFont)
                    .lineSpacing(3)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text(record.sourceLabel + " → " + (record.target == .english ? "EN" : "中"))
                    Spacer(minLength: 4)
                    Text(relativeTime)
                }
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.065) : Color.primary.opacity(0.025))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
    }
}
