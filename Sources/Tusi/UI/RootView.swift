import SwiftUI

struct PanelHeightKey: PreferenceKey {
    // `let`, not `var`: the protocol only needs a getter, and a mutable static is a
    // data-race error under the Swift 6 language mode.
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The narrowest the panel can be without clipping its content. Height has always been
/// content-driven; width was not, so a row of non-compressible controls (the bottom bar,
/// whose labels are much wider in English than in Chinese) could exceed `panelWidth` and
/// get centre-clipped against the fixed frame below. Views that contain such a row report
/// their natural width here and the window widens to match.
struct PanelContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Which of the three pages is on screen. A single value, rather than the two booleans
/// it is derived from, so one `.motion(.page, value:)` drives the whole push — the
/// slide, the panel height, and every fade inside both pages — on one timeline.
enum Page: Hashable {
    case translator
    case settings
    case shortcuts
}

struct RootView: View {
    @EnvironmentObject private var engine: TranslationEngine
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var panelState: PanelState

    let onHeightChange: (CGFloat) -> Void
    let onContentMinWidthChange: (CGFloat) -> Void

    private var activePage: Page {
        guard panelState.showSettings else { return .translator }
        return panelState.showShortcuts ? .shortcuts : .settings
    }

    var body: some View {
        ZStack(alignment: .top) {
            if panelState.showSettings {
                if panelState.showShortcuts {
                    ShortcutsView()
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: retreat(.trailing)
                        ))
                } else {
                    SettingsView()
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: retreat(.trailing)
                        ))
                }
            } else {
                TranslatorView()
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: retreat(.leading)
                    ))
            }
        }
        .frame(width: panelState.panelWidth, alignment: .top)
        // One value for the whole push. Previously two `.animation` modifiers watched
        // `showSettings` and `showShortcuts` separately; `activePage` is the thing the
        // user actually changed, and one modifier on it means one timeline.
        //
        // The stack's height is deliberately left to the content. An earlier version of
        // this constrained it to the *active* page's measured height, on the theory that
        // both pages stay in layout during a push and pin the panel to the taller one.
        // Measuring it says otherwise: SwiftUI drops the outgoing page from layout as
        // soon as the transition starts and keeps it only for drawing, so the new
        // height already reaches PanelController about 35ms into the push, in both
        // directions. The constraint bought nothing and cost correctness — it raced with
        // the remounted translator's own measurement and could latch the panel 21pt
        // short, clipping the last line of a result.
        .motion(.page, value: activePage)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: PanelHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(PanelHeightKey.self) { height in
            guard height > 0 else { return }
            onHeightChange(height)
        }
        // Read outside the fixed-width frame above: the preference travels up from the
        // content, which measures itself unconstrained, so it reports what the content
        // *wants* rather than the width it was forced into.
        .onPreferenceChange(PanelContentWidthKey.self) { width in
            guard width > 0 else { return }
            onContentMinWidthChange(width)
        }
        // No background, corner radius or border here — those belong to the window and are
        // drawn by PanelContainerView. Sizing them from the content instead means they
        // animate on the content's timeline while the window resizes on AppKit's, and the
        // gap between the two timelines is where the corners flash square.
    }

    /// The outgoing page's half of a page-push transition. A full-width `.move` on
    /// both pages made the middle of the transition feel crowded — two pages both
    /// travelling the panel's full width past each other at once. Classic navigation-
    /// stack parallax: the page leaving travels half as far and fades while the page
    /// arriving still travels the full distance, so the incoming page reads as the one
    /// actually "doing" the transition.
    private func retreat(_ edge: Edge) -> AnyTransition {
        let distance = panelState.panelWidth * 0.5
        return .offset(x: edge == .leading ? -distance : distance).combined(with: .opacity)
    }
}
