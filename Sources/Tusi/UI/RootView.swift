import SwiftUI

private struct PanelHeightKey: PreferenceKey {
    // `let`, not `var`: the protocol only needs a getter, and a mutable static is a
    // data-race error under the Swift 6 language mode.
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct RootView: View {
    @EnvironmentObject private var engine: TranslationEngine
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var panelState: PanelState

    let onHeightChange: (CGFloat) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            if panelState.showSettings {
                if panelState.showShortcuts {
                    ShortcutsView()
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                } else {
                    SettingsView()
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                }
            } else {
                TranslatorView()
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
        }
        .frame(width: panelState.panelWidth, alignment: .top)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: PanelHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(PanelHeightKey.self) { height in
            guard height > 0 else { return }
            onHeightChange(height)
        }
        // No background, corner radius or border here — those belong to the window and are
        // drawn by PanelContainerView. Sizing them from the content instead means they
        // animate on the content's timeline while the window resizes on AppKit's, and the
        // gap between the two timelines is where the corners flash square.
        .animation(.snappy(duration: 0.25 * Theme.animationScale), value: panelState.showSettings)
        .animation(.snappy(duration: 0.25 * Theme.animationScale), value: panelState.showShortcuts)
    }
}
