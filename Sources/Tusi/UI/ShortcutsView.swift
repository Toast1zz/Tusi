import SwiftUI

/// Secondary page nested inside Settings — see `PanelState.showShortcuts`.
struct ShortcutsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var panelState: PanelState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            VStack(alignment: .leading, spacing: 8) {
                ForEach(ShortcutAction.allCases) { action in
                    shortcutRow(action)
                }

                if let error = panelState.shortcutError {
                    Text(error)
                        .font(Theme.caption)
                        .foregroundStyle(.orange)
                        .transition(.opacity)
                }
            }
            .animation(Theme.stateChange, value: panelState.recordingShortcut)
            .animation(Theme.stateChange, value: panelState.shortcutError)
        }
        .padding(18)
        // Leaving the page mid-recording would otherwise swallow the next keystroke
        // typed into the translator.
        .onDisappear {
            panelState.recordingShortcut = nil
            panelState.shortcutError = nil
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(Theme.pageTransition) {
                    panelState.showShortcuts = false
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(Theme.bodySmallSemibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.fillQuiet))
            }
            .buttonStyle(.plain)
            .help("返回 (Esc)")

            Text("快捷键")
                .font(Theme.title)

            Spacer()
        }
    }

    // MARK: - Rows

    private func shortcutRow(_ action: ShortcutAction) -> some View {
        let recording = panelState.recordingShortcut == action
        let combo = settings.shortcut(action)
        let isDefault = combo.map { KeyCombo.sameKey($0, action.defaultCombo) } ?? false

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
            }

            if !isDefault && !recording {
                Button {
                    settings.setShortcut(action.defaultCombo, for: action)
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
            }

            Button {
                if recording {
                    panelState.recordingShortcut = nil
                } else {
                    panelState.recordingShortcut = action
                }
                panelState.shortcutError = nil
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
    }
}
