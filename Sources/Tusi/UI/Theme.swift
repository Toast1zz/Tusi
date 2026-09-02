import AppKit
import SwiftUI

/// Central design tokens for Tusi. Every visual constant that repeats across the UI
/// lives here so the interface reads as one coherent system instead of a collection
/// of per-view literals.
///
/// Type scale (from the audit of all `.system(size:)` call sites):
/// - 9    → `.caption2` — badge counts, tiny metadata
/// - 10   → `.caption`   — secondary labels, hints, field captions
/// - 11   → `.footnote`  — compact controls, chip labels, history meta
/// - 12   → `.bodySmall` — button text, compact labels
/// - 12.5 → `.body`      — settings rows, field content
/// - 14   → `.title`     — page headers
/// - 15   → `.content`   — main input/result text
/// - 18   → `.emptyState` — empty-state hero icons
enum Theme {
    /// System accent color — whatever the user picked in System Settings ▸ Appearance.
    /// Using it (instead of a baked-in brand gradient) is what makes controls read as
    /// native macOS chrome rather than a cross-platform app that shipped its own palette.
    static let accent = Color.accentColor
    static let success = Color(nsColor: .systemGreen)

    // MARK: - Fill tokens
    //
    // Audited every `Color.primary.opacity(…)` call site in the UI: 0.05 / 0.055 / 0.06
    // showed up five separate times as "a static quiet background", 0.065 / 0.07 four
    // times as "a hover background", 0.07 / 0.08 as "a hairline stroke" — different
    // numbers picked at different times for the same intent, not deliberately distinct
    // steps. Collapsed to the tokens below; each one now means exactly one thing.
    //
    // Left alone (not part of this system): SoftDivider's gradient stops (a fade
    // curve, not a flat fill), the 0.35/0.18 shadow and placeholder-dot opacities, and
    // anything ≥0.6 (those are foreground/text opacities, a different axis entirely).

    /// The faintest tier: a resting state that must stay barely-there so a hover state
    /// two tiers up still reads as a real change (history rows).
    static let fillFaint = Color.primary.opacity(0.025)
    /// Static quiet backgrounds: field chrome, badges, unselected pills/tabs/rows.
    static let fillQuiet = Color.primary.opacity(0.05)
    /// Hover state, and anywhere a slightly stronger presence than `fillQuiet` is
    /// deliberate (not another accidental near-duplicate of it).
    static let fillHover = Color.primary.opacity(0.07)
    /// Stronger emphasis fill: the skeleton-loading bars, and a chip's engaged state
    /// (flipped/expanded) — anything that wants to read as more "present" than a quiet
    /// background without being a hover state.
    static let fillActive = Color.primary.opacity(0.1)
    /// Borders and field outlines.
    static let strokeHairline = Color.primary.opacity(0.08)
    /// ToneSelector's selection pill on macOS < 26 (the Liquid Glass fallback) — its
    /// own tier because a selection indicator is deliberately more present than any
    /// hover state, and it's the only thing in the UI that needs to be.
    static let fillSelection = Color.primary.opacity(0.14)

    /// The panel's physical surface corner. Larger than any inner control radius so
    /// nested corners stay visually distinct.
    static let panelCornerRadius: CGFloat = 20

    /// Panel width bounds, shared by `PanelController`'s init/resize handling and the
    /// persisted-width clamp in `SettingsStore` — one source instead of the same two
    /// literals typed out at four call sites.
    static let panelMinWidth: CGFloat = 470
    static let panelMaxWidth: CGFloat = 700

    /// The shared content font for the translator input and result text.
    static let contentFont = Font.system(size: 15)

    // MARK: - Typography

    // Base sizes (regular weight unless noted).

    /// 9pt — the smallest metadata: badge counts, tiny inline labels.
    static let caption2 = Font.system(size: 9)
    /// 10pt — secondary labels, hints, field captions.
    static let caption = Font.system(size: 10)
    /// 11pt — compact controls, chip labels, history metadata, toasts.
    static let footnote = Font.system(size: 11)
    /// 12pt — button text, compact labels, small icons.
    static let bodySmall = Font.system(size: 12)
    /// 12.5pt — settings rows, field content, larger labels.
    static let body = Font.system(size: 12.5)
    /// 14pt — page headers (Settings, Shortcuts).
    static let title = Font.system(size: 14, weight: .semibold)
    /// 15pt — the main input/result text (alias of `contentFont`).
    static let content = Font.system(size: 15)
    /// 18pt — empty-state hero icon.
    static let emptyState = Font.system(size: 18, weight: .light)

    // Weighted/specialized variants used by controls.

    /// 9pt semibold — badge counts.
    static let caption2Semibold = Font.system(size: 9, weight: .semibold)
    /// 9.5pt semibold rounded — history count badge.
    static let caption2Rounded = Font.system(size: 9.5, weight: .semibold, design: .rounded)
    /// 10pt medium — small button labels.
    static let captionMedium = Font.system(size: 10, weight: .medium)
    /// 10pt semibold — emphasized small labels.
    static let captionSemibold = Font.system(size: 10, weight: .semibold)
    /// 10.5pt medium — secondary action labels.
    static let caption2Medium = Font.system(size: 10.5, weight: .medium)
    /// 10.5pt bold — copy button icon.
    static let caption2Bold = Font.system(size: 10.5, weight: .bold)
    /// 11pt medium — compact control labels.
    static let footnoteMedium = Font.system(size: 11, weight: .medium)
    /// 11pt semibold — section headers in the translator.
    static let footnoteSemibold = Font.system(size: 11, weight: .semibold)
    /// 11pt semibold rounded — direction chip.
    static let footnoteRounded = Font.system(size: 11, weight: .semibold, design: .rounded)
    /// 11.5pt medium — update status, recording state.
    static let footnote2Medium = Font.system(size: 11.5, weight: .medium)
    /// 11.5pt semibold — slot tab label.
    static let footnote2Semibold = Font.system(size: 11.5, weight: .semibold)
    /// 12pt medium — icon button glyphs.
    static let bodySmallMedium = Font.system(size: 12, weight: .medium)
    /// 12pt semibold — primary button text.
    static let bodySmallSemibold = Font.system(size: 12, weight: .semibold)
    /// 12.5pt monospaced — code-like fields (base URL, model, key, routing).
    static let bodyMonospaced = Font.system(size: 12.5, design: .monospaced)
    /// 10.5pt semibold/medium toggle — tone selector labels.
    static let toneLabel = Font.system(size: 10.5, weight: .semibold)
    /// 8pt bold — direction arrow.
    static let arrowBold = Font.system(size: 8, weight: .bold)
    /// 11.5pt medium, rounded — the shortcut combo pill in its resting state.
    static let shortcutCombo = Font.system(size: 11.5, weight: .medium, design: .rounded)
    /// 11.5pt medium, default — the same pill while a shortcut is being recorded
    /// (recording swaps away from the rounded design so the active state reads as
    /// a fresh field, not a settled badge).
    static let shortcutComboRecording = Font.system(size: 11.5, weight: .medium)

    // MARK: - Corner radii

    /// Small inline elements: badges, tiny pills.
    static let radiusSmall: CGFloat = 6
    /// Everything else: fields, buttons, cards, history rows, the toast surface.
    /// Used to be three separate values (8/9/10) a single point apart — a difference
    /// no eye can actually pick out, so it was cycle-of-history, not a real scale.
    static let radiusStandard: CGFloat = 8

    // MARK: - Motion
    //
    // Four rules hold this system together. They are not style preferences; each one
    // is a bug class that was actually hit and then designed out.
    //
    // 1. **One user action = one timeline = one token.** Tokens are chosen by *cause*
    //    (what the user did), never by *property* (which thing happens to be changing).
    //    A page push animates the slide, the panel height, and every fade inside it
    //    with `.page` — so it reads as one motion instead of three overlapping ones
    //    at 0.18 / 0.22 / 0.28.
    // 2. **Everything is declared with `.motion(_:value:)`; nothing uses
    //    `withAnimation`.** An imperative transaction animates whatever else happened
    //    to change on the same runloop turn — that is how an unrelated control ends up
    //    twitching because a translation landed while the mouse was moving. Binding a
    //    token to a *value* keeps the cause explicit and the blast radius local.
    // 3. **Everything that can change the panel's height shares one duration.** SwiftUI
    //    does not deliver interpolated heights: a `GeometryReader` preference fires
    //    *once* per transition, with the final value, about a layout pass after the
    //    action starts (measured, not assumed — see `windowResizeDuration`). So the
    //    window cannot mirror the content frame by frame; it necessarily runs its own
    //    animation towards that one value. The only way for the two to stay together is
    //    for them to be the same animation: same curve, same duration. Hence `.layout`
    //    and `.page` share a duration, `windowResizeDuration` equals it, and anything
    //    that moves the panel's height must use one of those two — never `.state`.
    // 4. **A tool panel's chrome decelerates and never overshoots.** Folds, pushes,
    //    toggles and resizes are state switches, not direct manipulation — the system's
    //    own Spotlight/menus/popovers read as crisp for exactly this reason.
    //    `.selection` is the single deliberate exception.

    /// The one curve every non-spring animation uses: the standard ease-out shape
    /// (the same control points macOS/CSS/CA's own `easeOut` uses), not a hand-picked
    /// one. An earlier version used (0.2, 0.8, 0.3, 1.0), which covers 80% of the
    /// distance in the first 20% of the duration and then crawls — mathematically zero
    /// overshoot, but it reads as "snap, then creep", which is worse than a bounce.
    private static let curve: (Double, Double, Double, Double) = (0.25, 0.1, 0.25, 1.0)

    /// TUSI_SLOWMO stretches every animation so transitions can be inspected frame by
    /// frame. 1 in normal runs.
    static let animationScale: Double = ProcessInfo.processInfo.environment["TUSI_SLOWMO"] != nil ? 10 : 1

    /// What caused the change. The only vocabulary call sites get: no durations, no
    /// curves, no raw `Animation` values. Adding a sixth case should feel expensive —
    /// the last token to be removed (`historyTransition`, 0.26) existed only to mask
    /// the window-lag described in rule 3, and had nothing left to do once that went.
    enum Motion: Hashable {
        /// Hover and press feedback — the fastest, most frequent thing in the app.
        case micro
        /// A discrete state flipping: toggles, chevrons, selection, inline notices,
        /// controls swapping in the bottom bar.
        case state
        /// Anything that changes the panel's height: folds, disclosures, the result
        /// section, history, the language picker row. Shares `windowResizeDuration` with
        /// `.page` so the window and the content always finish together.
        case layout
        /// Pushing between the translator, settings and shortcuts pages — including the
        /// panel height change that comes with it. A separate case from `.layout` because
        /// it names a different cause, not a different timing: a push travels much
        /// further than a fold, and pricing it longer for that reason is what put the
        /// window (0.22) and the slide (0.28) on visibly different clocks.
        case page
        /// The one legitimate spring in the app: ToneSelector's selection pill has real
        /// inertia (a shape moving between resting positions), unlike everything above,
        /// which is a state switching rather than an object moving.
        case selection

        var animation: Animation {
            switch self {
            case .micro: return Theme.timed(0.12)
            case .state: return Theme.timed(0.18)
            case .layout: return Theme.timed(windowResizeDuration)
            case .page: return Theme.timed(windowResizeDuration)
            case .selection: return .spring(duration: 0.3 * Theme.animationScale, bounce: 0.15)
            }
        }
    }

    fileprivate static func timed(_ duration: Double) -> Animation {
        .timingCurve(curve.0, curve.1, curve.2, curve.3, duration: duration * animationScale)
    }

    /// How long the window itself takes to reach a new height, and therefore how long
    /// every height-changing animation in the view layer takes.
    ///
    /// This is a shared constant rather than the window copying whatever SwiftUI is
    /// doing, because SwiftUI will not tell it. Preferences are not interpolated: a
    /// height measured through a `GeometryReader` reaches `PanelController` exactly once
    /// per transition, carrying the final value, roughly one layout pass after the action
    /// begins. The window therefore has to run its own animation to that value — so the
    /// two are kept identical by construction instead, and the small arrival delay is the
    /// only difference left between them.
    static let windowResizeDuration: Double = 0.22

    // MARK: - Panel summon (AppKit)

    /// The panel's fade-in is the only animation left outside SwiftUI: `alphaValue`
    /// belongs to the window, not to any view, so it cannot go through `.motion`.
    /// It is deliberately faster than any in-panel token — this is the app's most-seen
    /// animation (⌥Space, dozens of times a day) and a summon should feel like the
    /// panel was already there, not like it is arriving.
    static let panelAppearDuration: Double = 0.14

    /// AppKit form of `curve`, for the summon above. Nothing else in the app uses
    /// `NSAnimationContext` — see rule 3.
    static var caTimingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(curve.0), Float(curve.1), Float(curve.2), Float(curve.3))
    }
}

/// The app's sole animation entry point.
///
/// Reduce Motion comes from the environment rather than a direct
/// `NSWorkspace.accessibilityDisplayShouldReduceMotion` read: an environment value
/// establishes a real SwiftUI dependency, so toggling the system setting re-renders
/// the panel immediately instead of taking effect whenever a body next happens to be
/// evaluated. This app animates a lot — pushes, folds, resizes, toasts — so ignoring
/// the setting is a standing annoyance rather than a missing nicety.
struct MotionModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let motion: Theme.Motion
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : motion.animation, value: value)
    }
}

extension View {
    /// Animate everything in this subtree that changes because `value` changed, on the
    /// timeline `motion` names. Prefer attaching this once, high up, at the point the
    /// user action lands — one action should drive one timeline, not one per property.
    func motion<V: Equatable>(_ motion: Theme.Motion, value: V) -> some View {
        modifier(MotionModifier(motion: motion, value: value))
    }
}
