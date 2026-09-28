import SwiftUI

/// Secondary page nested inside Settings — see `PanelState.showShortcuts`.
struct ShortcutsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var panelState: PanelState

    /// The row under the pointer. Clear and restore are one click with no undo, so they
    /// show only on the row being pointed at instead of sitting beside every binding.
    @State private var hoveredAction: ShortcutAction?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                header

                // Rows carry their 8pt gap as 4pt of padding each, so the hover regions
                // meet: with stack spacing, a pointer in the gap belonged to no row and
                // the clear button blinked off between two rows.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(ShortcutAction.allCases) { action in
                        shortcutRow(action)
                    }

                    if let error = panelState.shortcutError {
                        Text(error)
                            .font(Theme.caption)
                            .foregroundStyle(.orange)
                            .padding(.top, 4)
                            .transition(.opacity)
                    }

                    if let pending = panelState.pendingBareShortcut {
                        bareShortcutConfirmation(pending)
                            .padding(.top, 4)
                            .transition(.opacity)
                    }
                }
                // `.layout`, not `.state`: each of these adds or removes a row, so the
                // panel gets taller or shorter and the window animates with it. Only
                // `.layout` and `.page` share the window's duration.
                .motion(.layout, value: panelState.recordingShortcut)
                .motion(.layout, value: panelState.shortcutError)
                .motion(.layout, value: panelState.pendingBareShortcut)
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ShortcutsHeightKey.self, value: proxy.size.height + 32)
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 18)
            // The last row's own 4pt of padding makes up the rest of the 18.
            .padding(.bottom, 14)
        }
        // Leaving the page mid-recording would otherwise swallow the next keystroke
        // typed into the translator.
        .onDisappear {
            panelState.recordingShortcut = nil
            panelState.shortcutError = nil
            // An unanswered confirmation is a no: leaving the page must not bind a key
            // the user never agreed to.
            panelState.pendingBareShortcut = nil
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                panelState.showShortcuts = false
            } label: {
                Image(systemName: "chevron.left")
                    .font(Theme.bodySmallSemibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.fillQuiet))
            }
            .buttonStyle(.plain)
            .help(settings.commandLabel(L("返回"), action: .close))

            Text("快捷键")
                .font(Theme.title)

            Spacer()
        }
    }

    // MARK: - Bare-key confirmation

    /// The second yes for a shortcut with no modifier. Says which key and what it costs,
    /// in that order, because the key is what the user just pressed and the cost is what
    /// they don't yet know.
    private func bareShortcutConfirmation(_ pending: PanelState.PendingShortcut) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(
                format: L("「%@」没有修饰键：绑定后在输入框里就打不出这个字符了"),
                pending.combo.display
            ))
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(L("仍然绑定")) {
                    settings.setShortcut(pending.combo, for: pending.action)
                    panelState.pendingBareShortcut = nil
                }
                .buttonStyle(.plain)
                .font(Theme.bodySmallSemibold)
                .foregroundStyle(Theme.accent)

                Button(L("取消")) {
                    panelState.pendingBareShortcut = nil
                }
                .buttonStyle(.plain)
                .font(Theme.bodySmall)
                .foregroundStyle(.secondary)
            }
        }
        .font(Theme.caption)
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusStandard, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
    }

    // MARK: - Rows

    private func shortcutRow(_ action: ShortcutAction) -> some View {
        let recording = panelState.recordingShortcut == action
        let combo = settings.shortcut(action)
        let isDefault = combo.map { KeyCombo.sameKey($0, action.defaultCombo) } ?? false
        let revealed = hoveredAction == action

        return HStack(spacing: 8) {
            Text(action.label)
                .font(Theme.body)

            Spacer()

            if combo != nil && !recording {
                Button {
                    settings.clearShortcut(for: action)
                    panelState.shortcutError = nil
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(Theme.footnote)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(L("清除此快捷键"))
                .opacity(revealed ? 1 : 0)
                .allowsHitTesting(revealed)
            }

            if !isDefault && !recording {
                Button {
                    panelState.shortcutError = settings.restoreShortcut(action)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                // Built explicitly rather than as an interpolated literal: matching the
                // key SwiftUI would auto-generate for an interpolated LocalizedStringKey
                // by hand (in Localizable.strings) is easy to get subtly wrong.
                .help(String(format: L("恢复默认 %@"), action.defaultCombo.display))
                .opacity(revealed ? 1 : 0)
                .allowsHitTesting(revealed)
            }

            Button {
                if recording {
                    panelState.recordingShortcut = nil
                } else {
                    panelState.recordingShortcut = action
                }
                panelState.shortcutError = nil
                // Recording again supersedes whatever was awaiting confirmation.
                panelState.pendingBareShortcut = nil
            } label: {
                // combo.display (e.g. "⇧⌘C") is a String, so this ternary can't rely on
                // Text's automatic LocalizedStringKey lookup — the other branch needs L().
                Text(recording ? L("按下新快捷键…") : (combo?.display ?? L("未绑定")))
                    .font(recording ? Theme.shortcutComboRecording : Theme.shortcutCombo)
                    .foregroundStyle(recording ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                    .frame(minWidth: 62)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(recording ? Theme.fillFaint : Theme.fillQuiet)
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            recording ? AnyShapeStyle(Theme.accent.opacity(0.6)) : AnyShapeStyle(Color.clear),
                            lineWidth: 1
                        )
                    )
            }
            .buttonStyle(.plain)
            .help(recording ? "按 Esc 取消" : "点击后按下新的组合键")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hoveredAction = action } else if hoveredAction == action { hoveredAction = nil }
        }
        .motion(.micro, value: revealed)
    }
}
