import AppKit
import SwiftUI

/// Central design tokens for Tusi. Every visual constant that repeats across the UI
/// lives here so the interface reads as one coherent system instead of a collection
/// of per-view literals.
///
/// The system is deliberately small. Hierarchy comes from ink — primary, secondary,
/// tertiary — not from a ladder of sizes, weights and colors:
///
/// - Three sizes in the translator: 15 for the text itself, 12 for controls, 11 for
///   metadata. The settings page keeps the scale it was designed with (see "Settings
///   page" below) — those tokens belong to it alone.
/// - Two weights: regular and medium. No rounded or light variants.
/// - The accent color marks focus, text selection, links — and the copy button, which
///   keeps its solid blue/green/orange capsule so its state reads at a glance. Orange is
///   otherwise reserved for failures the user has to act on.
/// - The tone selector keeps its 1.14.15 design, Liquid Glass pill included; the
///   translator's other controls use matte fills.
enum Theme {
    /// System accent color — whatever the user picked in System Settings ▸ Appearance.
    /// Spent only on focus, selection and links, so it still means something when it
    /// appears.
    static let accent = Color.accentColor
    static let success = Color(nsColor: .systemGreen)

    // MARK: - Fills
    //
    // Three steps, each meaning one thing. Anything that rests on `fillQuiet` hovers to
    // `fillActive`; anything that rests on nothing hovers to `fillQuiet`.

    /// A resting control surface: the tone track, copy capsule, language pills.
    static let fillQuiet = Color.primary.opacity(0.05)
    /// Engaged: a selection, a hover over a resting surface, a chip that is open.
    static let fillActive = Color.primary.opacity(0.1)
    /// Borders and field outlines.
    static let strokeHairline = Color.primary.opacity(0.08)

    /// The panel's physical surface corner. Larger than any inner control radius so
    /// nested corners stay visually distinct.
    static let panelCornerRadius: CGFloat = 20

    /// Panel width bounds, shared by `PanelController`'s init/resize handling and the
    /// persisted-width clamp in `SettingsStore`.
    static let panelMinWidth: CGFloat = 470
    static let panelMaxWidth: CGFloat = 700

    // MARK: - Typography

    /// 15pt — the text itself: input, result, and translations in history.
    static let contentFont = Font.system(size: 15)
    /// 12pt — every control label in the panel.
    static let control = Font.system(size: 12)
    static let controlMedium = Font.system(size: 12, weight: .medium)
    /// 11pt — metadata: provenance, notices, day headers, the source line in history.
    static let meta = Font.system(size: 11)
    static let metaMedium = Font.system(size: 11, weight: .medium)

    // MARK: - Corner radii

    /// Rows and inline surfaces: history rows, notices, fields.
    static let radiusStandard: CGFloat = 8

    // MARK: - Settings page
    //
    // The settings page keeps the design it had before the translator was reduced to
    // three sizes. These tokens are its own; nothing in the translator should use them.

    /// 9pt — the smallest metadata.
    static let caption2 = Font.system(size: 9)
    /// 10pt — secondary labels, hints, field captions.
    static let caption = Font.system(size: 10)
    /// 11pt — compact controls and labels.
    static let footnote = Font.system(size: 11)
    /// 12pt — button text, compact labels, small icons.
    static let bodySmall = Font.system(size: 12)
    /// 12.5pt — settings rows, field content.
    static let body = Font.system(size: 12.5)
    /// 14pt — page headers (Settings, Shortcuts).
    static let title = Font.system(size: 14, weight: .semibold)
    /// 9pt semibold.
    static let caption2Semibold = Font.system(size: 9, weight: .semibold)
    /// 10pt semibold.
    static let captionSemibold = Font.system(size: 10, weight: .semibold)
    /// 10.5pt medium — secondary action labels.
    static let caption2Medium = Font.system(size: 10.5, weight: .medium)
    /// 11pt medium — compact control labels.
    static let footnoteMedium = Font.system(size: 11, weight: .medium)
    /// 11pt semibold — section headers.
    static let footnoteSemibold = Font.system(size: 11, weight: .semibold)
    /// 11.5pt medium — update status, recording state.
    static let footnote2Medium = Font.system(size: 11.5, weight: .medium)
    /// 11.5pt semibold — slot tab label.
    static let footnote2Semibold = Font.system(size: 11.5, weight: .semibold)
    /// 12pt semibold — primary button text.
    static let bodySmallSemibold = Font.system(size: 12, weight: .semibold)
    /// 10.5pt bold — the copy button's icon.
    static let caption2Bold = Font.system(size: 10.5, weight: .bold)
    /// 10pt medium — the copy button's shortcut hint.
    static let captionMedium = Font.system(size: 10, weight: .medium)
    /// 10.5pt semibold — the tone selector's selected label.
    static let toneLabel = Font.system(size: 10.5, weight: .semibold)
    /// 12.5pt monospaced — code-like fields (base URL, model, key).
    static let bodyMonospaced = Font.system(size: 12.5, design: .monospaced)
    /// 11.5pt medium, rounded — the shortcut combo pill in its resting state.
    static let shortcutCombo = Font.system(size: 11.5, weight: .medium, design: .rounded)
    /// 11.5pt medium, default — the same pill while a shortcut is being recorded.
    static let shortcutComboRecording = Font.system(size: 11.5, weight: .medium)
    /// The faintest resting surface.
    static let fillFaint = Color.primary.opacity(0.025)
    /// Hover state for rows and pills.
    static let fillHover = Color.primary.opacity(0.07)
    /// The selection pill of the tone selector and the settings choices on macOS < 26
    /// (the Liquid Glass fallback).
    static let fillSelection = Color.primary.opacity(0.14)
    /// Small inline elements: badges, the shortcuts row hover.
    static let radiusSmall: CGFloat = 6

    // MARK: - Motion
    //
    // Four rules hold this system together. They are not style preferences; each one
    // is a bug class that was actually hit and then designed out.
    //
    // 1. **One user action = one timeline = one token.** Tokens are chosen by *cause*
    //    (what the user did), never by *property* (which thing happens to be changing).
    //    A page push animates the slide, the panel height, and every fade inside it
    //    with `.page` — so it reads as one motion instead of three overlapping ones.
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
        /// it names a different cause, not a different timing.
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

    /// Evaluate the same cubic Bezier used by SwiftUI, with cancellable frame
    /// updates so editing can take over an in-flight window transition.
    static func windowResizeProgress(elapsed: Double) -> CGFloat {
        let x = min(1, max(0, elapsed / (windowResizeDuration * animationScale)))
        if x == 0 || x == 1 { return CGFloat(x) }
        func cubic(_ t: Double, _ a: Double, _ b: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t
        }
        var lower = 0.0
        var upper = 1.0
        for _ in 0..<24 {
            let t = (lower + upper) / 2
            if cubic(t, curve.0, curve.2) < x { lower = t } else { upper = t }
        }
        return CGFloat(cubic((lower + upper) / 2, curve.1, curve.3))
    }

    static let inputResizeDuration: Double = 0.12

    /// One frame clock drives both the editor's layout and the native window.
    static func inputResizeHeight(from: CGFloat, to: CGFloat, elapsed: Double) -> CGFloat {
        let t = min(1, max(0, elapsed / (inputResizeDuration * animationScale)))
        let progress = t * t * (3 - 2 * t)
        return from + (to - from) * progress
    }

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
